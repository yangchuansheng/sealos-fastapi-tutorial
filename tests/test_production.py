import logging
import os
import re
import socket
import subprocess
import sys
import time
from pathlib import Path
from textwrap import dedent

from fastapi.testclient import TestClient

from app.main import create_app


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DOCKERFILE_PATH = PROJECT_ROOT / "Dockerfile"
DOCKERIGNORE_PATH = PROJECT_ROOT / ".dockerignore"
WORKFLOW_PATH = PROJECT_ROOT / ".github" / "workflows" / "publish-image.yml"
APPLICATION_MANIFEST_PATH = PROJECT_ROOT / "deploy" / "application.yaml"
PRODUCTION_HARNESS_PATH = PROJECT_ROOT / "scripts" / "test-production.sh"

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

EXPECTED_APPLICATION_MANIFEST = dedent(
    """\
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: __APP_NAME__
      labels:
        app.kubernetes.io/name: __APP_NAME__
        tutorial.sealos.io/run-id: __RUN_ID__
    data:
      logging.json: |
        {
          "version": 1,
          "disable_existing_loggers": false,
          "formatters": {
            "default": {
              "format": "%(levelname)s: %(message)s"
            },
            "access": {
              "format": "%(levelname)s: %(client_addr)s - %(request_line)s %(status_code)s"
            }
          },
          "handlers": {
            "default": {
              "class": "logging.StreamHandler",
              "formatter": "default",
              "stream": "ext://sys.stdout"
            },
            "access": {
              "class": "logging.StreamHandler",
              "formatter": "access",
              "stream": "ext://sys.stdout"
            }
          },
          "loggers": {
            "uvicorn": {
              "handlers": ["default"],
              "level": "INFO",
              "propagate": false
            },
            "uvicorn.error": {
              "level": "INFO"
            },
            "uvicorn.access": {
              "handlers": ["access"],
              "level": "INFO",
              "propagate": false
            }
          },
          "root": {
            "handlers": ["default"],
            "level": "INFO"
          }
        }
    ---
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: __APP_NAME__
      labels:
        app.kubernetes.io/name: __APP_NAME__
        tutorial.sealos.io/run-id: __RUN_ID__
    spec:
      replicas: 2
      revisionHistoryLimit: 3
      progressDeadlineSeconds: 180
      strategy:
        type: RollingUpdate
        rollingUpdate:
          maxUnavailable: 0
          maxSurge: 1
      selector:
        matchLabels:
          app.kubernetes.io/name: __APP_NAME__
          tutorial.sealos.io/run-id: __RUN_ID__
      template:
        metadata:
          labels:
            app.kubernetes.io/name: __APP_NAME__
            tutorial.sealos.io/run-id: __RUN_ID__
        spec:
          automountServiceAccountToken: false
          securityContext:
            runAsNonRoot: true
            runAsUser: 10001
            runAsGroup: 10001
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: app
              image: __IMAGE_REFERENCE__
              imagePullPolicy: IfNotPresent
              command:
                - uvicorn
              args:
                - app.main:app
                - --host
                - 0.0.0.0
                - --port
                - "8000"
                - --workers
                - "1"
                - --log-level
                - info
                - --no-use-colors
                - --log-config
                - /etc/uvicorn/logging.json
              env:
                - name: DATABASE_URL
                  valueFrom:
                    secretKeyRef:
                      name: __SECRET_NAME__
                      key: url
                - name: SOURCE_RELEASE
                  value: "__SOURCE_RELEASE__"
                - name: IMAGE_REFERENCE
                  value: "__IMAGE_REFERENCE__"
              ports:
                - name: http
                  containerPort: 8000
                  protocol: TCP
              readinessProbe:
                httpGet:
                  path: /health
                  port: http
                  scheme: HTTP
                initialDelaySeconds: 2
                periodSeconds: 5
                timeoutSeconds: 2
                failureThreshold: 12
                successThreshold: 1
              resources:
                requests:
                  cpu: 100m
                  memory: 128Mi
                limits:
                  cpu: 500m
                  memory: 512Mi
              securityContext:
                runAsNonRoot: true
                runAsUser: 10001
                runAsGroup: 10001
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop:
                    - ALL
              volumeMounts:
                - name: tmp
                  mountPath: /tmp
                - name: logging
                  mountPath: /etc/uvicorn
                  readOnly: true
          volumes:
            - name: tmp
              emptyDir:
                medium: Memory
                sizeLimit: 64Mi
            - name: logging
              configMap:
                name: __APP_NAME__
                items:
                  - key: logging.json
                    path: logging.json
    ---
    apiVersion: v1
    kind: Service
    metadata:
      name: __APP_NAME__
      labels:
        app.kubernetes.io/name: __APP_NAME__
        tutorial.sealos.io/run-id: __RUN_ID__
    spec:
      type: ClusterIP
      selector:
        app.kubernetes.io/name: __APP_NAME__
        tutorial.sealos.io/run-id: __RUN_ID__
      ports:
        - name: http
          port: 8000
          targetPort: http
          protocol: TCP
    """
)


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
    assert "failed to authorize" in workflow
    assert "403 Forbidden" in workflow
    assert (
        "api.github.com/users/yangchuansheng/packages/container/"
        "sealos-fastapi-tutorial"
    ) in workflow
    assert "package_status" in workflow
    assert "candidate_digest" in workflow
    assert "publish_needed" in workflow
    assert "--format '{{json .Image}}'" in workflow
    assert '.config.Labels["org.opencontainers.image.revision"]' in workflow
    assert "steps.readback.outputs.image_digest" in workflow
    assert (
        "IMAGE_DIGEST: ${{ steps.readback.outputs.image_digest }}" in workflow
    )
    assert workflow.count('ANON_DOCKER_CONFIG="$(mktemp -d)"') == 2
    assert 'test "$PUBLISHED_DIGEST" = "$CANDIDATE_DIGEST"' not in workflow
    assert '[[ "$EXPECTED_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]' in workflow
    assert '[[ "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]' in workflow
    assert 'test "$EXPECTED_DIGEST" =~' not in workflow
    assert 'test "$IMAGE_DIGEST" =~' not in workflow
    assert "type=ref" not in workflow
    assert "latest=true" not in workflow
    assert ":latest" not in workflow
    assert ":main" not in workflow


def test_startup_log_identifies_release(monkeypatch, caplog) -> None:
    source_release = "a" * 40
    image_reference = "ghcr.io/example/tasks@sha256:" + "b" * 64
    monkeypatch.setenv("SOURCE_RELEASE", source_release)
    monkeypatch.setenv("IMAGE_REFERENCE", image_reference)

    with caplog.at_level(logging.INFO, logger="uvicorn.error"):
        with TestClient(create_app()):
            pass

    release_records = [
        record
        for record in caplog.records
        if record.name == "uvicorn.error"
        and record.getMessage().startswith("event=service_start ")
    ]
    assert [record.getMessage() for record in release_records] == [
        "event=service_start "
        f"source_release={source_release} "
        f"image_reference={image_reference}"
    ]


def test_uvicorn_emits_startup_release_identity() -> None:
    source_release = "a" * 40
    image_reference = "ghcr.io/example/tasks@sha256:" + "b" * 64
    environment = os.environ.copy()
    environment.pop("DATABASE_URL", None)
    environment["SOURCE_RELEASE"] = source_release
    environment["IMAGE_REFERENCE"] = image_reference

    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]

    process = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "uvicorn",
            "app.main:app",
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "--workers",
            "1",
            "--log-level",
            "info",
            "--no-use-colors",
        ],
        cwd=PROJECT_ROOT,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    ready = False
    try:
        for _ in range(100):
            if process.poll() is not None:
                break
            try:
                with socket.create_connection(
                    ("127.0.0.1", port),
                    timeout=0.1,
                ):
                    ready = True
                    break
            except OSError:
                time.sleep(0.05)
    finally:
        if process.poll() is None:
            process.terminate()
        output, _ = process.communicate(timeout=5)

    assert ready, output
    assert (
        "event=service_start "
        f"source_release={source_release} "
        f"image_reference={image_reference}"
    ) in output


def test_production_workload_contract() -> None:
    assert (
        APPLICATION_MANIFEST_PATH.is_file()
    ), "deploy/application.yaml must exist"
    assert PRODUCTION_HARNESS_PATH.is_file(), "production harness must exist"

    assert APPLICATION_MANIFEST_PATH.read_text() == EXPECTED_APPLICATION_MANIFEST
    harness = PRODUCTION_HARNESS_PATH.read_text()

    assert harness.startswith("#!/usr/bin/env bash\nset -euo pipefail\n")
    for argument in (
        "--baseline-image",
        "--baseline-source",
        "--final-image",
        "--final-source",
        "--evidence-dir",
    ):
        assert argument in harness
    for mode in (
        "--run",
        "--preflight-evidence",
        "--verify-evidence",
        "--help",
    ):
        assert mode in harness

    assert "^[0-9a-f]{40}$" in harness
    assert "@sha256:[0-9a-f]{64}$" in harness
    assert "test-postgres.sh --session-start --state-file" in harness
    assert "test-postgres.sh --session-stop --state-file" in harness
    assert "test-postgres.sh --assert-clean --state-file" in harness
    assert "apply --dry-run=server --validate=strict" in harness
    assert "kubectl rollout undo" in harness
    assert "trap cleanup EXIT INT TERM HUP" in harness
    assert harness.index("trap cleanup EXIT INT TERM HUP") < harness.index(
        "start_database_session"
    )

    for token in (
        "__RUN_ID__",
        "__APP_NAME__",
        "__IMAGE_REFERENCE__",
        "__SOURCE_RELEASE__",
        "__SECRET_NAME__",
        "__JOB_NAME__",
    ):
        assert token in harness
    assert "__[A-Z0-9_]+__" in harness

    for resource in (
        "deployment",
        "replicaset",
        "pod",
        "service",
        "job",
        "secret",
        "configmap",
    ):
        assert resource in harness.lower()
    for filename in (
        "workflow.txt",
        "images.txt",
        "migration.txt",
        "runtime.txt",
        "logs.txt",
        "http.jsonl",
        "rollback.txt",
        "cleanup.txt",
        "publication.txt",
        "checksums.txt",
    ):
        assert filename in harness

    assert "verify_live_evidence" in harness
    assert "preflight_publication_evidence" in harness
    assert "verify_publication_evidence" in harness
    assert "expected_checksum_count=8" in harness
    assert "expected_checksum_count=9" in harness
    assert "kubectl rollout undo" in harness
    assert "baseline-rollback" in harness
    assert "final-recovered" in harness

    assert 'assert container["command"] == ["uvicorn"]' in harness
    assert 'assert container["args"] == [' in harness
    assert 'assert container["volumeMounts"] == [' in harness
    assert '"name": "logging"' in harness
    assert '"configMap": {' in harness
    assert '"name": app_name' in harness
    assert '"key": "logging.json"' in harness
    assert '"path": "logging.json"' in harness

    assert 'ANON_DOCKER_CONFIG="$(mktemp -d)"' in harness
    assert 'chmod 700 "$ANON_DOCKER_CONFIG"' in harness
    for variable in (
        "GH_TOKEN",
        "GITHUB_TOKEN",
        "GHCR_TOKEN",
        "REGISTRY_TOKEN",
        "DOCKER_AUTH_CONFIG",
        "REGISTRY_AUTH_FILE",
        "CRANE_AUTH",
    ):
        assert f"-u {variable}" in harness
