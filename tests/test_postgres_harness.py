import re
import subprocess
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
HARNESS_PATH = PROJECT_ROOT / "scripts" / "test-postgres.sh"


def run_disabled_helper(function_source: str, invocation: str) -> None:
    script = "\n".join(
        (
            "set -euo pipefail",
            'EVIDENCE_ENABLED="false"',
            'EVIDENCE_DIR=""',
            function_source,
            invocation,
            'printf "DISABLED_EVIDENCE_OK\\n"',
        )
    )
    completed = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert completed.returncode == 0, completed.stderr
    assert completed.stdout == "DISABLED_EVIDENCE_OK\n"


def test_disabled_evidence_append_succeeds_under_errexit() -> None:
    source = HARNESS_PATH.read_text()
    match = re.search(
        r"(?ms)^evidence_append\(\) \{\n.*?^\}\n",
        source,
    )
    assert match is not None, "evidence_append must exist"

    run_disabled_helper(
        match.group(0),
        'evidence_append "ignored.txt" "ignored"',
    )


def test_other_disabled_evidence_helpers_succeed_under_errexit() -> None:
    source = HARNESS_PATH.read_text()

    for name in ("finalize_evidence", "capture_public_http_evidence"):
        start = source.index(f"{name}()")
        guard = next(
            line.strip()
            for line in source[start:].splitlines()
            if line.strip().startswith('[[ "$EVIDENCE_ENABLED" == true ]]')
        )
        function_source = "\n".join(
            (
                f"{name}() {{",
                f"  {guard}",
                "  return 99",
                "}",
            )
        )
        run_disabled_helper(function_source, name)
