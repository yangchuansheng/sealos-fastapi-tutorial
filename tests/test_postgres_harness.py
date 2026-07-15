import re
import subprocess
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
HARNESS_PATH = PROJECT_ROOT / "scripts" / "test-postgres.sh"


def test_disabled_evidence_append_succeeds_under_errexit() -> None:
    source = HARNESS_PATH.read_text()
    match = re.search(
        r"(?ms)^evidence_append\(\) \{\n.*?^\}\n",
        source,
    )
    assert match is not None, "evidence_append must exist"

    script = "\n".join(
        (
            "set -euo pipefail",
            'EVIDENCE_ENABLED="false"',
            'EVIDENCE_DIR=""',
            match.group(0),
            'evidence_append "ignored.txt" "ignored"',
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
