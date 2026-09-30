from pathlib import Path
import runpy


def test_probe_restoration_preserves_unique_cases_without_an_aggregate_timeout(monkeypatch, tmp_path):
    module = runpy.run_path(str(Path(__file__).resolve().parents[1] / "tools" / "probe_p85.py"))
    restore = module["restore_tests"]
    calls = []
    expected = {
        "first.py::test_cases": [("first", "test_cases[a]"), ("first", "test_cases[b]")],
        "second.py::test_other": [("second", "test_other")],
    }

    def run(output, name, selectors):
        calls.append((name, selectors))
        assert output == tmp_path
        return dict(exit=0, seconds=150, ids=[case for selector in selectors for case in expected[selector]],
                    failures=0, errors=0, skipped=0)

    monkeypatch.setitem(restore.__globals__, "run_tests", run)
    baselines = {selector: {"ids": cases} for selector, cases in expected.items()}
    baselines["first.py::test_cases[a]"] = {"ids": [("first", "test_cases[a]")]}
    result, success = restore(tmp_path, baselines)
    assert calls == [("restored-1", ["first.py::test_cases"]), ("restored-2", ["second.py::test_other"])]
    assert success and result["seconds"] == 300 and len(result["ids"]) == 3
