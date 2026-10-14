#!/usr/bin/env python3
"""Runs image generation for a brief through the Codex CLI (the author's
ChatGPT account, the built-in image tool), ADR-0008: the jobs and prompts
live in tools/art/gen/NNN.json; results land in art_src/incoming/NNN/ for
the author to review, then go through tools/art/import_sheet.py.

Usage: tools/art/generate.py tools/art/gen/001.json [--only a,b] [--parallel 3]
Env: CODEX_PROXY (default http://127.0.0.1:2080, as ~/bin/chatgpt.sh),
     CODEX_MODEL (default gpt-5.5).
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INSTRUCTION = ("Use your image generation tool to create ONE image and save it in the current directory "
               "as {name}.png. Do nothing else: no code, no scripts, no edits of other files. "
               "The attached image(s) are style references only.\n\nImage:\n")


def run(job, brief, common, env):
    name = job["name"]
    work = ROOT / "art_src" / "gen" / brief / name
    work.mkdir(parents=True, exist_ok=True)
    (ROOT / "art_src" / ".gdignore").touch()  # sources, not game resources
    out = ROOT / "art_src" / "incoming" / brief / f"{name}.png"
    images = []
    for ref in job.get("refs", common.get("refs", [])):
        dst = work / Path(ref).name
        shutil.copy(ROOT / ref, dst)
        images += ["--image", str(dst)]
    prompt = INSTRUCTION.format(name=name) + job["prompt"].format(**common.get("vars", {}))
    (work / "prompt.txt").write_text(prompt)
    cmd = ["codex", "exec", "--skip-git-repo-check", "-m", os.environ.get("CODEX_MODEL", "gpt-5.5"),
           "-c", "model_reasoning_effort=low", "-s", "workspace-write", *images, "-"]
    with open(work / "codex.log", "w") as log:
        code = subprocess.run(cmd, cwd=work, input=prompt, text=True, stdout=log, stderr=subprocess.STDOUT,
                              env=env, timeout=1200).returncode
    made = work / f"{name}.png"
    if code == 0 and made.exists():
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(made, out)
        return f"ok   {name}"
    return f"FAIL {name} (code {code}, see {work / 'codex.log'})"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("jobs")
    ap.add_argument("--only", default="")
    ap.add_argument("--parallel", type=int, default=3)
    args = ap.parse_args()
    spec = json.loads(Path(args.jobs).read_text())
    proxy = os.environ.get("CODEX_PROXY", "http://127.0.0.1:2080")
    env = dict(os.environ, HTTP_PROXY=proxy, HTTPS_PROXY=proxy, http_proxy=proxy, https_proxy=proxy)
    only = set(args.only.split(",")) - {""}
    jobs = [j for j in spec["jobs"] if not only or j["name"] in only]
    with ThreadPoolExecutor(args.parallel) as ex:
        for line in ex.map(lambda j: run(j, spec["brief"], spec, env), jobs):
            print(line, flush=True)


if __name__ == "__main__":
    sys.exit(main())
