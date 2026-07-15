from pathlib import Path
from textwrap import dedent


PROJECT_ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = PROJECT_ROOT / "deploy" / "migration-job.yaml"

EXPECTED_MANIFEST = dedent(
    """\
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: sealos-fastapi-migration
      labels:
        app.kubernetes.io/name: sealos-fastapi-migration
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 300
      template:
        metadata:
          labels:
            app.kubernetes.io/name: sealos-fastapi-migration
        spec:
          restartPolicy: Never
          containers:
            - name: migrate
              image: ghcr.io/yangchuansheng/sealos-fastapi-tutorial:stage-2-postgresql
              workingDir: /app
              command:
                - alembic
                - upgrade
                - head
              env:
                - name: DATABASE_URL
                  valueFrom:
                    secretKeyRef:
                      name: sealos-fastapi-postgresql
                      key: url
    """
)


def test_production_migration_job_contract() -> None:
    assert MANIFEST_PATH.is_file(), "deploy/migration-job.yaml must exist"

    assert MANIFEST_PATH.read_text() == EXPECTED_MANIFEST
