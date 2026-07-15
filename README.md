# Sealos FastAPI Tutorial: Tasks API

This repository is the reference application for the Sealos FastAPI tutorial
series. The `stage-2-postgresql` tag is the immutable database stage: FastAPI
serves the same public Tasks API while SQLAlchemy 2 and psycopg 3 persist every
record in PostgreSQL after Alembic owns the schema migration.

The earlier `stage-1-deploy` tag keeps the process-local first stage unchanged.

## Prerequisites

- Git
- Python 3.12
- [`uv`](https://docs.astral.sh/uv/)
- PostgreSQL 17 with an empty database
- `curl`
- `kubectl` with an authenticated Sealos context for the integration harness

## Clone Stage 2

Clone the immutable source tag so your files match the PostgreSQL tutorial:

```bash
git clone --branch stage-2-postgresql \
  https://github.com/yangchuansheng/sealos-fastapi-tutorial.git
cd sealos-fastapi-tutorial
```

Install the exact dependency graph recorded in `uv.lock`, then prove the
runtime-only compatibility export still matches the lock:

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

## Run the Migration Job Contract

`deploy/migration-job.yaml` is the production one-shot contract. It runs
`alembic upgrade head` from the application image and reads `DATABASE_URL` from
Secret `sealos-fastapi-postgresql`, key `url`.

Validate the manifest against the active cluster API before rollout:

```bash
kubectl apply --dry-run=server --validate=strict \
  -f deploy/migration-job.yaml
```

After the application image and Secret exist, apply and wait for migration
completion before accepting application readiness:

```bash
kubectl apply --validate=strict -f deploy/migration-job.yaml
kubectl wait --for=condition=complete \
  job/sealos-fastapi-migration --timeout=300s
```

`deploy/source-migration-job.yaml` is the pre-image validation adapter. The
integration harness mounts only the tracked model, Alembic files, revision, and
runtime export, then completes two independently created Jobs against one
database. Readers deploy with the production Job contract above.

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

## Source Stage Lifecycle

- `stage-1-deploy`: generated docs, health, and process-local task CRUD.
- `stage-2-postgresql`: SQLAlchemy 2 persistence, Alembic migration ownership,
  schema-aware readiness, and repeatable migration Jobs.
- `stage-3-production`: the next source stage adds the hardened non-root image,
  production runtime, replicas, rollout logs, and rollback evidence.
