import sys
from pathlib import Path
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from run_tests_parallel import inventory, validate


class ParallelTestGates(unittest.TestCase):
    def test_full_summary_and_expected_errors_are_required(self):
        text = "PASS sample::test_ok (1 ms)\nERROR: deliberate refusal\nexpected engine errors: 1\n1 tests, 0 failed checks, 1.0s\n"
        self.assertTrue(validate(0, text, 1))
        self.assertFalse(validate(0, text.replace("errors: 1", "errors: 0"), 1))
        self.assertFalse(validate(1, text, 1))
        self.assertFalse(validate(0, text, 2))

    def test_empty_partial_and_early_stops_cannot_pass(self):
        self.assertFalse(validate(0, "", 1))
        self.assertFalse(validate(0, "PASS sample::test_ok (1 ms)\n", 1))
        text = "PASS sample::test_ok (1 ms)\nexpected engine errors: 0\n1 tests, 0 failed checks, 1.0s\n"
        self.assertFalse(validate(0, text + "STOPPED: the run was ended early", 1))
        self.assertFalse(validate(0, text + text, 1))
        self.assertFalse(validate(0, text + "SCRIPT ERROR: broken teardown\n", 1))
        self.assertFalse(validate(0, text.replace("0 failed", "1 failed"), 1))

    def test_inventory_filters_match_the_godot_runner(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for folder in ["tests/unit", "tests/bench", "tests/framework"]:
                (root / folder).mkdir(parents=True)
            (root / "tests/unit/test_one.gd").write_text("func test_first() -> void:\n pass\nfunc test_other() -> void:\n pass\n")
            (root / "tests/bench/bench_one.gd").write_text("func bench_first() -> void:\n pass\n")
            (root / "tests/framework/test_helper.gd").write_text("func test_fake() -> void:\n pass\n")
            self.assertEqual(inventory(root, []), {"tests/unit/test_one.gd": 2})
            self.assertEqual(inventory(root, ["--bench", "--test=first"]), {"tests/bench/bench_one.gd": 1, "tests/unit/test_one.gd": 1})
            self.assertEqual(inventory(root, ["--only=missing"]), {})


if __name__ == "__main__":
    unittest.main()
