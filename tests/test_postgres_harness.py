import re
import subprocess
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
HARNESS_PATH = PROJECT_ROOT / "scripts" / "test-postgres.sh"
MIGRATION_TEMPLATE_PATH = PROJECT_ROOT / "deploy" / "migration-job.yaml"
VALIDATION_IMAGE = (
    "ghcr.io/yangchuansheng/sealos-fastapi-tutorial@"
    "sha256:b11293cf8ebb0e73fbabfd33ef6e812d53cb8176ea2db853769aae3dfa273337"
)


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


def test_parameterized_production_job_renderer_is_allowlisted(
    tmp_path: Path,
) -> None:
    source = HARNESS_PATH.read_text()
    start_marker = "render_production_job() {"
    end_marker = "\nvalidate_production_job() ("
    assert start_marker in source, "render_production_job must exist"
    assert end_marker in source, "validate_production_job must exist"
    function_source = source[
        source.index(start_marker) : source.index(end_marker)
    ]
    output = tmp_path / "rendered.yaml"
    run_id = "abcdef123456"
    job_name = f"tutorial-fastapi-pg-test-{run_id}-production-validation"
    secret_name = f"tutorial-fastapi-pg-test-{run_id}-secret"
    script = "\n".join(
        (
            "set -euo pipefail",
            f'PRODUCTION_JOB_TEMPLATE="{MIGRATION_TEMPLATE_PATH}"',
            function_source,
            f'render_production_job "{job_name}" "{run_id}" '
            f'"{secret_name}" "{VALIDATION_IMAGE}" >"{output}"',
        )
    )
    completed = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
    )

    assert completed.returncode == 0, completed.stderr
    rendered = output.read_text()
    assert f"name: {job_name}" in rendered
    assert f"tutorial.sealos.io/run-id: {run_id}" in rendered
    assert f"image: {VALIDATION_IMAGE}" in rendered
    assert f"name: {secret_name}" in rendered
    assert re.search(r"__[A-Z0-9_]+__", rendered) is None

    unexpected_template = tmp_path / "unexpected.yaml"
    unexpected_template.write_text(
        MIGRATION_TEMPLATE_PATH.read_text().replace(
            "workingDir: /app",
            "workingDir: __UNEXPECTED_TOKEN__",
        )
    )
    rejected = subprocess.run(
        [
            "bash",
            "-c",
            script.replace(
                str(MIGRATION_TEMPLATE_PATH),
                str(unexpected_template),
            ),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert rejected.returncode != 0
    assert "unexpected token set" in rejected.stderr


def test_production_job_validation_uses_safe_temporary_render() -> None:
    source = HARNESS_PATH.read_text()
    start_marker = "validate_production_job() ("
    end_marker = "\nrun_jobs() {"
    assert start_marker in source, "validate_production_job must exist"
    assert end_marker in source
    validation_source = source[
        source.index(start_marker) : source.index(end_marker)
    ]

    assert 'rendered_manifest="$(mktemp ' in validation_source
    assert 'chmod 600 "$rendered_manifest"' in validation_source
    assert '[[ "$(state_mode "$rendered_manifest")" == "600" ]]' in (
        validation_source
    )
    assert "trap cleanup_production_render EXIT INT TERM HUP" in (
        validation_source
    )
    assert validation_source.index(
        "trap cleanup_production_render EXIT INT TERM HUP"
    ) < validation_source.index("render_production_job")
    assert "apply --dry-run=server --validate=strict" in validation_source
    assert "__[A-Z0-9_]+__" in validation_source
    assert "rm -f \"$rendered_manifest\"" in validation_source
