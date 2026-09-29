"""Isolated P85 reversion probes; the caller owns the workstation gate lock."""

import argparse
from dataclasses import dataclass
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

import claude_finops


ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "cli" / "finops" / "src" / "claude_finops"
TESTS = ROOT / "cli" / "finops" / "tests"


@dataclass(frozen=True)
class Probe:
    name: str
    file: str
    before: str
    after: str
    test_file: str
    selector: str


PROBES = [
    Probe("remove-engine-route", "developer_screens.py", 'row["id"], remove=True,',
          'row["id"], remove=False,', "test_p85_people.py",
          "test_remove_person_preview_confirm_apply_and_refresh"),
    Probe("confirmation-forwarding", "developer_screens.py", 'apply=apply, confirm=values["confirm"])',
          'apply=apply, confirm="")', "test_p85_people.py",
          "test_remove_person_preview_confirm_apply_and_refresh"),
    Probe("confirmation-refusal", "developer_actions.py",
          'if remove and confirm != person["user_principal_name"]:',
          'if False and remove and confirm != person["user_principal_name"]:',
          "test_p85_people.py", "test_remove_person_wrong_confirmation_is_refused"),
    Probe("owner-admission", "tui.py",
          'return (self.config.backend != "aum-service" and self.identity.get("role") == "owner"',
          'return (self.config.backend != "aum-service" and True',
          "test_p85_people.py", "test_remove_person_owner_guard_covers_button_key_palette_and_direct_entry"),
    Probe("service-admission", "tui.py",
          'return (self.config.backend != "aum-service" and self.identity.get("role") == "owner"',
          'return (True and self.identity.get("role") == "owner"',
          "test_p85_people.py", "test_remove_person_service_refusal_uses_existing_explanation"),
    Probe("remove-key", "tui.py", 'Binding("h", "remove_developer",',
          'Binding("j", "remove_developer",', "test_p85_people.py",
          "test_remove_person_wrong_confirmation_is_refused"),
    Probe("remove-palette", "palette.py",
          'commands.append(("Remove person from team", self.app.action_remove_developer,',
          'commands.append(("Hidden removal", self.app.action_remove_developer,',
          "test_p85_people.py", "test_remove_person_action_bar_key_help_and_palette"),
    Probe("last-member-scoped-publication", "developer_actions.py",
          'allow_empty[f"allow_empty_{name}"] = True', 'allow_empty[f"allow_empty_{name}"] = False',
          "test_p85_people.py", "test_remove_person_preview_confirm_apply_and_refresh"),
    Probe("picker-completion", "developer_screens.py",
          'app.switch_screen(ActionForm("Remove person from team", [',
          'app.push_screen(ActionForm("Remove person from team", [',
          "test_p85_people.py", "test_remove_person_preview_confirm_apply_and_refresh"),
    Probe("retained-directory-origin", "developer_screens.py",
          '], operation, read_guard=directory_guard))',
          '], operation, read_guard=app.current_guard()))',
          "test_p85_people.py", "test_remove_person_stale_form_cannot_preview_or_apply"),
    Probe("usd-readonly-discovery", "palette.py", 'if self.app.check_action("usd_edit", ()):',
          'if True:', "test_p85_budgets.py",
          "test_service_usd_palette_and_shortcut_refuse_read_only_selection"),
    Probe("native-receipt-polling", "screens.py", 'elif self.engine.backend.immediate_writes:',
          'elif False:', "test_p85_budgets.py",
          "test_service_native_token_receipt_does_not_follow_turnstile_apply"),
    Probe("refresh-transport-containment", "errors.py",
          "READ_FAILURES = (FinOpsError, OSError, httpx.HTTPError)", "READ_FAILURES = (FinOpsError,)",
          "test_p85_escape.py", "test_escape_triggered_refresh_errors_are_visible_not_fatal"),
    Probe("plain-refresh-explanation", "progressive.py",
          'f"{reason}Read failed (exit {error.code}). {self._error_text(error)} {fix}"',
          'f"{reason}Read failed (exit {error.code}). {fix}"',
          "test_p85_escape.py", "test_escape_triggered_refresh_errors_are_visible_not_fatal"),
    Probe("cae-cli-preservation", "config.py", "if is_location_challenge(result.stderr):", "if False:",
          "test_p85_escape.py", "test_azure_cli_preserves_actionable_cae_location_reason"),
    Probe("cae-marker-specificity", "errors.py",
          '"interactionrequired" in folded and "locationconditionevaluationsatisfied" in folded',
          '"interactionrequired" in folded or "locationconditionevaluationsatisfied" in folded',
          "test_p85_escape.py", "test_other_azure_cli_errors_are_not_labelled_cae"),
    Probe("single-quit-confirmation", "tui.py", "self.push_screen(QuitScreen())", "self.exit()",
          "test_p85_escape.py", "test_quit_requires_confirmation_and_escape_cancels_it"),
    Probe("escape-cancels-quit", "feature_screens.py",
          '("escape", "dismiss", "Stay")', '("escape", "confirm", "Quit")',
          "test_p85_escape.py", "test_quit_requires_confirmation_and_escape_cancels_it"),
    Probe("programming-error-distinction", "errors.py",
          'raise TypeError("Only expected backend read failures can be normalized.")',
          'return FinOpsError("Programming error hidden as a read failure.", 7)',
          "test_p85_escape.py", "test_read_error_normalizer_rejects_programming_errors"),
    Probe("cloudshell-dry-run", "aum-cloudshell.sh", 'if "$dry_run"; then exit 0; fi',
          "if false; then exit 0; fi", "test_p85_cloudshell.py", "test_cloudshell_dry_run_has_plan_without_writes"),
    Probe("cloudshell-home-boundary", "aum-cloudshell.sh",
          '*) fail "Refusing a destination outside HOME: $path" ;;', "*) : ;;",
          "test_p85_cloudshell.py", "test_cloudshell_refuses_escaping_destination_links_before_writing"),
    Probe("cloudshell-python-pip-environment", "aum-cloudshell.sh",
          "unset PYTHONHOME PYTHONPATH VIRTUAL_ENV PIP_TARGET PIP_PREFIX PIP_USER", ":",
          "test_p85_cloudshell.py", "test_cloudshell_overrides_inherited_write_destinations"),
    Probe("cloudshell-uv-environment", "aum-cloudshell.sh",
          "unset UV_TARGET UV_PREFIX UV_SYSTEM_PYTHON UV_PROJECT_ENVIRONMENT UV_CONFIG_FILE UV_PYTHON", ":",
          "test_p85_cloudshell.py", "test_cloudshell_overrides_inherited_write_destinations"),
    Probe("cloudshell-stage-failure", "aum-cloudshell.sh", "set -euo pipefail", "set -uo pipefail",
          "test_p85_cloudshell.py", "test_cloudshell_failed_stage_never_launches_aum"),
    Probe("cloudshell-runtime-floor", "aum-cloudshell.sh",
          "|| fail 'The AUM venv requires Python 3.12 or newer; the existing venv was not replaced.'",
          "|| true", "test_p85_cloudshell.py", "test_cloudshell_rejects_reused_old_python"),
    Probe("cloudshell-source-boundary", "aum-cloudshell.sh",
          "*) fail 'The package source resolves outside the repository.' ;;", "*) : ;;",
          "test_p85_cloudshell.py", "test_cloudshell_requires_source_in_selected_checkout"),
]


def run_tests(output, name, selectors):
    log, report = output / f"{name}.log", output / f"{name}.xml"
    started = time.monotonic()
    with log.open("w", encoding="utf-8") as stream:
        result = subprocess.run(
            [sys.executable, "-m", "pytest", *selectors, "-q", "--tb=short", f"--junitxml={report}"],
            cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, timeout=180,
            env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"),
        )
    tree = ET.parse(report)
    cases = list(tree.iter("testcase"))
    return dict(
        exit=result.returncode, seconds=round(time.monotonic() - started, 3),
        ids=sorted((case.get("classname"), case.get("name")) for case in cases),
        failures=sum(case.find("failure") is not None for case in cases),
        errors=sum(case.find("error") is not None for case in cases),
        skipped=sum(case.find("skipped") is not None for case in cases),
    )


def clear_bytecode(path):
    if path.suffix == ".py":
        Path(importlib.util.cache_from_source(str(path))).unlink(missing_ok=True)


def check_syntax(path, changed):
    if path.suffix == ".py":
        compile(changed, str(path), "exec")
        return
    sys.path.insert(0, str(TESTS))
    from test_p85_cloudshell import bash, shell_path
    subprocess.run([bash(), "--noprofile", "--norc", "-n", shell_path(path)],
                   check=True, capture_output=True, timeout=20)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if not Path(claude_finops.__file__).resolve().is_relative_to(SOURCE):
        raise RuntimeError("The interpreter must import this worktree, not another editable checkout.")
    args.output.mkdir(parents=True, exist_ok=True)
    baselines, results = {}, []
    started = time.monotonic()
    for probe in PROBES:
        selector = str(TESTS / probe.test_file) + "::" + probe.selector
        if selector not in baselines:
            baseline = run_tests(args.output, f"baseline-{len(baselines) + 1}", [selector])
            if baseline["exit"] or not baseline["ids"] or any(baseline[key] for key in ("failures", "errors", "skipped")):
                raise RuntimeError(f"Baseline did not pass: {selector}; {baseline}")
            baselines[selector] = baseline
        baseline = baselines[selector]
        path = (ROOT / "scripts" if probe.file.endswith(".sh") else SOURCE) / probe.file
        original = path.read_bytes()
        text = original.decode("utf-8").replace("\r\n", "\n")
        if text.count(probe.before) != 1:
            raise RuntimeError(f"{probe.name}: expected exactly one mutation target")
        changed = text.replace(probe.before, probe.after).encode("utf-8")
        try:
            path.write_bytes(changed)
            check_syntax(path, changed)
            clear_bytecode(path)
            result = run_tests(args.output, probe.name, [selector])
        finally:
            if path.read_bytes() != changed:
                raise RuntimeError(f"Concurrent edit of {path}; no overwrite was attempted.")
            path.write_bytes(original)
            clear_bytecode(path)
        caught = (result["exit"] == 1 and result["ids"] == baseline["ids"]
                  and result["failures"] > 0 and result["errors"] == 0 and result["skipped"] == 0)
        results.append(dict(name=probe.name, caught=caught, **result))
        print(f"{probe.name}: {'CAUGHT' if caught else 'NOT CAUGHT'}; "
              f"{len(result['ids'])} identical cases; {result['failures']} failures; {result['seconds']} s",
              flush=True)
    restored = run_tests(args.output, "restored", list(baselines))
    expected = sorted(case for baseline in baselines.values() for case in baseline["ids"])
    restored_ok = (restored["exit"] == 0 and restored["ids"] == expected
                   and not any(restored[key] for key in ("failures", "errors", "skipped")))
    receipt = dict(baselines=baselines, probes=results, restored=restored, restored_ok=restored_ok,
                   seconds=round(time.monotonic() - started, 3))
    (args.output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(f"Restored: {len(restored['ids'])} cases; {restored['seconds']} s; total {receipt['seconds']} s")
    if not restored_ok or not all(result["caught"] for result in results):
        raise RuntimeError("The probe receipt contains a survivor, invalid run or failed restoration.")


if __name__ == "__main__":
    main()
