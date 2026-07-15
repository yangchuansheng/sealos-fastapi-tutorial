# Sealos FastAPI Tutorial: Tasks API

This repository is the reference application for the Sealos FastAPI tutorial
series. The `stage-3-production` tag is the immutable production stage: a
locked Python 3.12 image runs two hardened FastAPI replicas while Alembic owns
PostgreSQL migrations and full-source-SHA image tags resolve to immutable
deployment digests.

The protected `stage-1-deploy` and `stage-2-postgresql` tags retain the earlier
application and database stages unchanged.

## Prerequisites

- Git
- Python 3.12
- [`uv`](https://docs.astral.sh/uv/)
- PostgreSQL 17 with an empty database
- `curl`
- `jq`
- [`crane`](https://github.com/google/go-containerregistry/tree/main/cmd/crane)
- [GitHub CLI](https://cli.github.com/)
- `kubectl` with an authenticated Sealos context for the integration harness

## Clone Stage 3

Clone the immutable source tag so the source, workload contracts, and reader
commands share one release identity:

```bash
git clone --branch stage-3-production \
  https://github.com/yangchuansheng/sealos-fastapi-tutorial.git
cd sealos-fastapi-tutorial
```

Use Python 3.12, install the exact dependency graph recorded in `uv.lock`, then
prove the runtime-only compatibility export still matches the lock:

```bash
uv sync --locked
uv export --locked --no-dev --no-emit-project --no-hashes \
  --format requirements.txt --output-file requirements.txt
git diff --exit-code -- requirements.txt
```

## Configure PostgreSQL

Set `DATABASE_URL` to a fresh PostgreSQL database. SQLAlchemy uses the explicit
psycopg 3 dialect:

```bash
export DATABASE_URL='postgresql+psycopg://tasks:password@127.0.0.1:5432/tasks'
```

Keep the real password in your shell or a Sealos Secret. Do not commit it to
the repository.

## Migrate Before Readiness

Alembic is the only schema owner. Run the migration before starting or scaling
the API:

```bash
uv run alembic upgrade head
uv run alembic current
uv run alembic upgrade head
```

The first command creates `tasks` and records revision `0001`. The second
upgrade is a safe repeat at the same head. Application startup and tests never
call SQLAlchemy `create_all()`.

`GET /health` returns `200 {"status":"ok"}` only when PostgreSQL is reachable
and the `tasks` schema exists. A missing URL, unreachable server, or database
awaiting migration returns the same stable response:

```json
{"detail":"Database is not ready"}
```

## Run the Behavior Suite

The public HTTP suite requires a real migrated test database:

```bash
export TEST_DATABASE_URL="$DATABASE_URL"
uv run pytest -q
```

The suite verifies health, generated Swagger UI, task CRUD, validation, stable
errors, and persistence across independently constructed FastAPI application
instances. Test fixtures reset rows between behaviors through the database
boundary; assertions observe results through HTTP.

## Start the API

```bash
uv run uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Keep this process running while you use the commands below. The API is
available at `http://127.0.0.1:8000`, and generated Swagger UI is available at
`http://127.0.0.1:8000/docs`.

## Verify the Public API

Verify readiness and documentation:

```bash
curl --fail --silent http://127.0.0.1:8000/health
curl --fail --silent http://127.0.0.1:8000/docs | grep 'Swagger UI'
```

Create a task:

```bash
curl --fail --silent \
  --request POST \
  --header 'Content-Type: application/json' \
  --data '{"title":"Write the FastAPI tutorial"}' \
  http://127.0.0.1:8000/tasks
```

List and read tasks:

```bash
curl --fail --silent http://127.0.0.1:8000/tasks
curl --fail --silent http://127.0.0.1:8000/tasks/1
```

Replace task `1` with a completed task:

```bash
curl --fail --silent \
  --request PUT \
  --header 'Content-Type: application/json' \
  --data '{"title":"Publish the FastAPI tutorial","completed":true}' \
  http://127.0.0.1:8000/tasks/1
```

Stop and restart Uvicorn with the same `DATABASE_URL`, then read task `1`
again to verify process-restart persistence:

```bash
curl --fail --silent http://127.0.0.1:8000/tasks/1
```

Delete task `1`:

```bash
curl --fail --silent \
  --request DELETE \
  http://127.0.0.1:8000/tasks/1
```

Create assigns an integer `id` and defaults `completed` to `false`. Update uses
complete `PUT` replacement, deletion returns an empty `204` response, and a
later read returns:

```json
{"detail":"Task not found"}
```

## Resolve an Immutable Image

The publisher exposes one lookup tag for each complete 40-character source
commit. Resolve that tag once, then use only the returned digest in Kubernetes:

```bash
SOURCE_SHA="$(git rev-parse HEAD)"
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]

IMAGE_REPOSITORY='ghcr.io/yangchuansheng/sealos-fastapi-tutorial'
IMAGE_TAG="$IMAGE_REPOSITORY:sha-$SOURCE_SHA"
IMAGE_DIGEST="$(crane digest "$IMAGE_TAG")"
[[ "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]
IMAGE_REFERENCE="$IMAGE_REPOSITORY@$IMAGE_DIGEST"

crane config "$IMAGE_REFERENCE" | jq -e --arg source "$SOURCE_SHA" \
  '.architecture == "amd64" and .os == "linux" and
   .config.Labels["org.opencontainers.image.revision"] == $source and
   .config.Labels["org.opencontainers.image.source"] ==
     "https://github.com/yangchuansheng/sealos-fastapi-tutorial"'
crane manifest "$IMAGE_REFERENCE" | jq -e . >/dev/null
```

The workflow publishes no branch, `latest`, date, or short-SHA tag. The full
SHA tag is a discovery surface; `IMAGE_REFERENCE` is the deployment input.

## Render the Production Workloads

`deploy/migration-job.yaml` and `deploy/application.yaml` are parameterized
contracts. Render their bounded token sets into mode-0600 temporary files. The
Job and Deployment receive the same immutable image, database Secret, run
identity, and source release:

```bash
RUN_ID="$(python -c 'import secrets; print(secrets.token_hex(6))')"
APP_NAME="tutorial-fastapi-pg-test-$RUN_ID-app"
JOB_NAME="tutorial-fastapi-pg-test-$RUN_ID-migration"
SECRET_NAME="tutorial-fastapi-pg-test-$RUN_ID-secret"
RENDER_DIR="$(mktemp -d)"
chmod 700 "$RENDER_DIR"
trap 'rm -rf "$RENDER_DIR"' EXIT
umask 077

python - "$RUN_ID" "$APP_NAME" "$JOB_NAME" "$SECRET_NAME" \
  "$IMAGE_REFERENCE" "$SOURCE_SHA" "$RENDER_DIR" <<'PY'
from pathlib import Path
import re
import sys

run_id, app_name, job_name, secret_name, image, source, output = sys.argv[1:]
contracts = (
    (
        Path("deploy/migration-job.yaml"),
        Path(output) / "migration-job.yaml",
        {
            "__RUN_ID__": run_id,
            "__JOB_NAME__": job_name,
            "__IMAGE_REFERENCE__": image,
            "__SECRET_NAME__": secret_name,
        },
    ),
    (
        Path("deploy/application.yaml"),
        Path(output) / "application.yaml",
        {
            "__RUN_ID__": run_id,
            "__APP_NAME__": app_name,
            "__IMAGE_REFERENCE__": image,
            "__SOURCE_RELEASE__": source,
            "__SECRET_NAME__": secret_name,
        },
    ),
)
for template, destination, values in contracts:
    rendered = template.read_text(encoding="utf-8")
    assert set(re.findall(r"__[A-Z0-9_]+__", rendered)) == set(values)
    for token, value in values.items():
        rendered = rendered.replace(token, value)
    assert re.search(r"__[A-Z0-9_]+__", rendered) is None
    destination.write_text(rendered, encoding="utf-8")
    destination.chmod(0o600)
PY

kubectl --namespace ns-let51wad apply --dry-run=server --validate=strict \
  -f "$RENDER_DIR/migration-job.yaml"
kubectl --namespace ns-let51wad apply --dry-run=server --validate=strict \
  -f "$RENDER_DIR/application.yaml"
```

Provision `SECRET_NAME` with key `url` through your secret-management path.
The value is a `postgresql+psycopg://` URL reachable from the namespace. Keep
the value out of shell history, command output, retained logs, and evidence.

## Migrate, Then Roll Out

Run the migration from the same image digest before creating or updating the
application. Accept readiness only after the Job reports `Complete`:

```bash
kubectl --namespace ns-let51wad apply --validate=strict \
  -f "$RENDER_DIR/migration-job.yaml"
kubectl --namespace ns-let51wad wait --for=condition=complete \
  "job/$JOB_NAME" --timeout=300s

kubectl --namespace ns-let51wad apply --validate=strict \
  -f "$RENDER_DIR/application.yaml"
kubectl --namespace ns-let51wad rollout status \
  "deployment/$APP_NAME" --timeout=240s
kubectl --namespace ns-let51wad get "deployment/$APP_NAME" \
  -o jsonpath='{.status.readyReplicas}{"/"}{.spec.replicas}{" Ready\n"}'
```

The accepted result is `2/2 Ready`. Each Pod runs as UID/GID 10001 with one
PID-1 Uvicorn application command bound to `0.0.0.0:8000`, a read-only root
filesystem, dropped capabilities, no privilege escalation, RuntimeDefault
seccomp, and a writable Memory-backed 64 MiB `/tmp` mount.

Correlate source, image, process, and startup identity on both Pods:

```bash
kubectl --namespace ns-let51wad get "deployment/$APP_NAME" \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl --namespace ns-let51wad get pods \
  -l "app.kubernetes.io/name=$APP_NAME,tutorial.sealos.io/run-id=$RUN_ID" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].imageID}{"\n"}{end}'
kubectl --namespace ns-let51wad logs \
  -l "app.kubernetes.io/name=$APP_NAME,tutorial.sealos.io/run-id=$RUN_ID" \
  --all-containers --prefix | \
  grep -F "event=service_start source_release=$SOURCE_SHA image_reference=$IMAGE_REFERENCE"
```

## Roll Back and Recover

Keep the baseline source SHA and digest before a release update. After the
final migration and rollout, use Deployment history for the immediate rollback
and verify the persistent task through public HTTP:

```bash
kubectl --namespace ns-let51wad rollout undo "deployment/$APP_NAME"
kubectl --namespace ns-let51wad rollout status \
  "deployment/$APP_NAME" --timeout=240s
curl --fail --silent "http://127.0.0.1:8000/tasks/1"
```

Recovery uses the retained final `application.yaml`, whose Pod template binds
the final source and digest atomically:

```bash
kubectl --namespace ns-let51wad apply --validate=strict \
  -f "$RENDER_DIR/application.yaml"
kubectl --namespace ns-let51wad rollout status \
  "deployment/$APP_NAME" --timeout=240s
curl --fail --silent "http://127.0.0.1:8000/tasks/1"
```

The complete acceptance sequence is baseline migration/deploy, final
migration/update, `kubectl rollout undo` to baseline, then explicit final
manifest recovery. The same PostgreSQL task survives all four states.

## Run the Owned Integration Harness

The full gate creates one uniquely labeled PostgreSQL 17 Deployment, Service,
Secret, and temporary migration Jobs in namespace `ns-let51wad`. It verifies
the unmigrated `503`, fresh and repeat migration, all public HTTP behaviors,
strict production Job schema, two source Job completions, migrated `200`, lock
reproduction, and exact cleanup:

```bash
PHASE22_EVIDENCE_DIR=evidence/phase-22 \
  ./scripts/test-postgres.sh --phase-gate
sha256sum -c evidence/phase-22/checksums.txt
```

Every owned Kubernetes object carries one generated
`tutorial.sealos.io/run-id` label. The exit trap removes only that exact label,
stops the recorded port-forward, and writes a zero-object cleanup inventory.
The retained evidence package contains curated public results and no database
credentials, Secret payloads, tokens, or credential-bearing URLs.

## Run the Production Harness

The production harness consumes two accepted source/digest pairs and executes
the four-state sequence in one owned PostgreSQL run. Use an empty evidence
directory inside the repository that retains the phase evidence:

```bash
./scripts/test-production.sh --run \
  --baseline-source "$BASELINE_SOURCE" \
  --baseline-image "$BASELINE_IMAGE" \
  --final-source "$FINAL_SOURCE" \
  --final-image "$FINAL_IMAGE" \
  --evidence-dir "$EVIDENCE_DIR"

./scripts/test-production.sh --verify-evidence live \
  --evidence-dir "$EVIDENCE_DIR"
```

Both image arguments use
`ghcr.io/yangchuansheng/sealos-fastapi-tutorial@sha256:<64-hex-digest>`.
The verifier checks eight reviewed data files and their eight-entry checksum
manifest without contacting Kubernetes.

The installed exit trap stops owned port-forwards, calls the PostgreSQL session
stop and assert-clean paths, and removes only objects carrying the generated
run label and exact `tutorial-fastapi-pg-test-$RUN_ID-` prefix. The final audit
covers Deployment, ReplicaSet, Pod, Service, Job, Secret, ConfigMap, state and
render files, temporary registry configs, clone directories, and owned
processes. A successful run retains only redacted, checksum-valid evidence.

## Source Stage Lifecycle

- `stage-1-deploy`: generated docs, health, and process-local task CRUD.
- `stage-2-postgresql`: SQLAlchemy 2 persistence, Alembic migration ownership,
  schema-aware readiness, and repeatable migration Jobs.
- `stage-3-production`: locked non-root image publication, digest-only
  migration and application workloads, two replicas, release identity logs,
  public task continuity, rollback, explicit recovery, and exact cleanup.
