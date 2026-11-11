#!/usr/bin/env python3
"""Run every selected Godot suite in an isolated profile, retaining strict gates."""
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


def inventory(root, args):
    options = dict(a[2:].split("=", 1) if "=" in a else (a[2:], "")
                   for a in args if a.startswith("--"))
    suites = {}
    for path in sorted((root / "tests").rglob("*.gd")):
        rel = path.relative_to(root).as_posix()
        parts = path.relative_to(root / "tests").parts
        bench = parts[0] == "bench"
        if "framework" in parts or (bench and "bench" not in options):
            continue
        if not path.name.startswith("bench_" if bench else "test_"):
            continue
        if options.get("only", "") not in "res://" + rel:
            continue
        methods = re.findall(r"^func ((?:test_|bench_)\w+)\(", path.read_text(), re.M)
        selected = [m for m in methods if options.get("test", "") in m]
        if selected:
            suites[rel] = len(selected)
    return suites


def validate(code, text, expected):
    totals = re.findall(r"^(\d+) tests, (\d+) failed checks, [\d.]+s$", text, re.M)
    allowed = re.findall(r"^expected engine errors: (\d+)$", text, re.M)
    errors = len(re.findall(r"^(?:SCRIPT ERROR|ERROR:)", text, re.M))
    passed = len(re.findall(r"^PASS ", text, re.M))
    return bool(code == 0 and len(totals) == 1 and len(allowed) == 1
                and int(totals[0][0]) == expected and int(totals[0][1]) == 0
                and passed == expected and errors == int(allowed[0])
                and "STOPPED:" not in text and not re.search(r"^FAIL ", text, re.M))


def sources(root):
    paths = [p for folder in ["src", "content", "tests"]
             for p in (root / folder).rglob("*")
             if p.is_file() and p.suffix in [".gd", ".uid", ".gdshader", ".json"]]
    paths.append(root / "project.godot")
    paths.extend([root / "tools/run_tests.sh", root / "tools/run_tests_parallel.py"])
    paths.extend((root / "tools/tests").glob("*.py"))
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(paths)}


def main(args):
    jobs = int(os.environ.get("TEST_JOBS", "1"))
    if jobs < 1:
        raise ValueError("TEST_JOBS must be positive")
    suites = inventory(ROOT, args)
    if not suites:
        print("No selected test methods; refusing an empty successful run", flush=True)
        return 1
    began = time.monotonic()
    out = ROOT / "build" / "test-runs" / (datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S") + "-" + str(os.getpid()))
    out.mkdir(parents=True)
    (out / "inventory.json").write_text(json.dumps(suites, indent=2) + "\n")
    before = sources(ROOT)
    (out / "sources.json").write_text(json.dumps(before, indent=2) + "\n")
    maximum = int(os.environ.get("TEST_OUTPUT_MAX", "20000000"))
    running = set()
    lock = threading.Lock()
    stopping = threading.Event()

    def stop(signum, frame):
        stopping.set()
        with lock:
            for process in running:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    def run(pair):
        suite, count = pair
        key = suite.replace("/", "__")
        profile = out / "profiles" / key
        profile.mkdir(parents=True)
        log = out / (key + ".log")
        env = dict(os.environ, XDG_DATA_HOME=str(profile))
        filtered = [a for a in args if not a.startswith("--only=")]
        command = [os.environ.get("GODOT", "godot"), "--headless", "--audio-driver", "Dummy", "--path", str(ROOT),
                   "-s", "res://tests/framework/run.gd", "--", "--only=res://" + suite, *filtered]
        start = time.monotonic()
        flooded = False
        with log.open("w") as stream:
            with lock:
                if stopping.is_set():
                    return {"suite": suite, "ok": False, "expected_tests": count, "exit_code": 143,
                            "output_flood": False, "wall_seconds": 0, "log": log.relative_to(ROOT).as_posix()}
                process = subprocess.Popen(command, env=env, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
                running.add(process)
            while process.poll() is None:
                if log.stat().st_size >= maximum:
                    flooded = True
                    os.killpg(process.pid, signal.SIGKILL)
                    break
                time.sleep(.1)
            code = process.wait()
            with lock:
                running.remove(process)
        text = log.read_text(errors="replace")
        ok = not flooded and validate(code, text, count)
        return {"suite": suite, "ok": ok, "expected_tests": count, "exit_code": code,
                "output_flood": flooded, "wall_seconds": round(time.monotonic() - start, 2),
                "log": log.relative_to(ROOT).as_posix()}

    results = []
    print(f"Running {sum(suites.values())} tests in {len(suites)} suites with {jobs} isolated workers; logs: {out}", flush=True)
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = [pool.submit(run, pair) for pair in suites.items()]
        for future in as_completed(futures):
            result = future.result()
            results.append(result)
            print(f"{'PASS' if result['ok'] else 'FAIL'} {result['suite']}: {result['expected_tests']} tests, {result['wall_seconds']}s", flush=True)
            if not result["ok"]:
                print("\n".join((ROOT / result["log"]).read_text(errors="replace").splitlines()[-40:]), flush=True)
    unchanged = before == sources(ROOT)
    summary = {"ok": len(results) == len(suites) and all(r["ok"] for r in results) and unchanged,
               "tests": sum(suites.values()), "suites": len(suites), "sources_unchanged": unchanged,
               "wall_seconds": round(time.monotonic() - began, 2), "results": sorted(results, key=lambda r: r["suite"])}
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    # Keep compact evidence; disposable databases and keys are not run output.
    shutil.rmtree(out / "profiles")
    print(json.dumps({k: v for k, v in summary.items() if k != "results"}), flush=True)
    return 0 if summary["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
