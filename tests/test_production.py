import logging
import re
from pathlib import Path

from fastapi.testclient import TestClient

from app.main import create_app


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DOCKERFILE_PATH = PROJECT_ROOT / "Dockerfile"
DOCKERIGNORE_PATH = PROJECT_ROOT / ".dockerignore"
WORKFLOW_PATH = PROJECT_ROOT / ".github" / "workflows" / "publish-image.yml"

PYTHON_IMAGE = (
    "python:3.12.13-slim-bookworm@"
    "sha256:d50fb7611f86d04a3b0471b46d7557818d88983fc3136726336b2a4c657aa30b"
)
UV_IMAGE = (
    "ghcr.io/astral-sh/uv:0.10.9@"
    "sha256:10902f58a1606787602f303954cea099626a4adb02acbac4c69920fe9d278f82"
)
POSTGRES_IMAGE = (
    "postgres:17.10-bookworm@"
    "sha256:4f736ae292687621d4dbe0d499ffd024a36bd2ee7d8ca6f2ccd4c800f047b394"
)
APPROVED_ACTIONS = {
    (
        "actions/checkout",
        "9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0",
    ),
    (
        "astral-sh/setup-uv",
        "11f9893b081a58869d3b5fccaea48c9e9e46f990",
    ),
    (
        "docker/login-action",
        "af1e73f918a031802d376d3c8bbc3fe56130a9b0",
    ),
    (
        "docker/setup-buildx-action",
        "bb05f3f5519dd87d3ba754cc423b652a5edd6d2c",
    ),
    (
        "docker/metadata-action",
        "dc802804100637a589fabce1cb79ff13a1411302",
    ),
    (
        "docker/build-push-action",
        "53b7df96c91f9c12dcc8a07bcb9ccacbed38856a",
    ),
}


def test_hardened_container_contract() -> None:
    assert DOCKERFILE_PATH.is_file(), "Dockerfile must exist"
    assert DOCKERIGNORE_PATH.is_file(), ".dockerignore must exist"

    dockerfile = DOCKERFILE_PATH.read_text()
    dockerignore = set(DOCKERIGNORE_PATH.read_text().splitlines())

    assert f"FROM {UV_IMAGE} AS uv" in dockerfile
    assert dockerfile.count(f"FROM {PYTHON_IMAGE}") == 2
    assert "uv sync --locked --no-dev" in dockerfile
    assert "COPY pyproject.toml uv.lock ./" in dockerfile
    assert "COPY . ." not in dockerfile
    assert "USER 10001:10001" in dockerfile
    assert "ARG SOURCE_RELEASE" in dockerfile
    assert "ENV SOURCE_RELEASE=${SOURCE_RELEASE}" in dockerfile
    assert "EXPOSE 8000" in dockerfile
    assert (
        'CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", '
        '"--port", "8000", "--workers", "1", "--log-level", "info", '
        '"--no-use-colors"]'
    ) in dockerfile
    assert dockerfile.count('CMD ["uvicorn"') == 1

    required_exclusions = {
        ".git",
        ".github",
        ".pytest_cache",
        ".venv",
        "**/__pycache__",
        "*.pyc",
        "deploy",
        "evidence",
        "scripts",
        "tests",
    }
    assert required_exclusions <= dockerignore


def test_publisher_uses_one_validated_source_identity() -> None:
    assert WORKFLOW_PATH.is_file(), "publish-image workflow must exist"
    workflow = WORKFLOW_PATH.read_text()

    action_references = set(
        re.findall(r"uses:\s*([^@\s]+)@([0-9a-f]{40})", workflow)
    )
    assert action_references == APPROVED_ACTIONS
    assert "contents: read" in workflow
    assert "packages: write" in workflow
    assert "source_sha:" in workflow
    assert "required: true" in workflow
    assert "^[0-9a-f]{40}$" in workflow
    assert "target_sha: ${{ steps.target.outputs.target_sha }}" in workflow
    assert workflow.count("ref: ${{ needs.prepare.outputs.target_sha }}") >= 2
    assert workflow.count("git rev-parse HEAD") >= 2
    assert "sha-${{ needs.prepare.outputs.target_sha }}" in workflow
    assert "SOURCE_RELEASE=${{ needs.prepare.outputs.target_sha }}" in workflow
    assert (
        "org.opencontainers.image.revision="
        "${{ needs.prepare.outputs.target_sha }}"
    ) in workflow
    assert "SOURCE_DATE_EPOCH" in workflow
    assert "publish-image-${{ needs.prepare.outputs.target_sha }}" in workflow
    assert "target_sha=$TARGET_SHA" in workflow
    assert "image_digest=$IMAGE_DIGEST" in workflow
    assert "linux/amd64" in workflow
    assert POSTGRES_IMAGE in workflow
    assert "ANON_DOCKER_CONFIG" in workflow
    assert 'chmod 700 "$ANON_DOCKER_CONFIG"' in workflow
    assert "candidate_digest" in workflow
    assert "publish_needed" in workflow
    assert "type=ref" not in workflow
    assert "latest=true" not in workflow
    assert ":latest" not in workflow
    assert ":main" not in workflow


def test_startup_log_identifies_release(monkeypatch, caplog) -> None:
    source_release = "a" * 40
    image_reference = "ghcr.io/example/tasks@sha256:" + "b" * 64
    monkeypatch.setenv("SOURCE_RELEASE", source_release)
    monkeypatch.setenv("IMAGE_REFERENCE", image_reference)

    with caplog.at_level(logging.INFO, logger="app.main"):
        with TestClient(create_app()):
            pass

    release_records = [
        record
        for record in caplog.records
        if record.name == "app.main"
        and record.getMessage().startswith("event=service_start ")
    ]
    assert [record.getMessage() for record in release_records] == [
        "event=service_start "
        f"source_release={source_release} "
        f"image_reference={image_reference}"
    ]
