# Sealos FastAPI Tutorial: Tasks API

This repository is the reference application for the Sealos FastAPI tutorial
series. The `stage-1-deploy` tag is the immutable first stage: a small FastAPI
service with generated Swagger UI, a health check, and process-local task CRUD.

## Prerequisites

- Git
- Python 3.12
- [`uv`](https://docs.astral.sh/uv/)
- `curl`

## Clone Stage 1

Clone the immutable source tag so your files match the deploy tutorial:

```bash
git clone --branch stage-1-deploy \
  https://github.com/yangchuansheng/sealos-fastapi-tutorial.git
cd sealos-fastapi-tutorial
```

Install the exact dependency graph recorded in `uv.lock`:

```bash
uv sync --locked
```

## Run the Behavior Suite

```bash
uv run pytest -q
```

The suite contains nine named public HTTP behavior functions that collect as
12 pytest cases. It verifies `/health`, generated `/docs`, task CRUD, title
validation, and stable missing-task responses through fresh FastAPI
applications.

## Start the API

```bash
uv run uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Keep this process running while you use the commands below. The API is
available at `http://127.0.0.1:8000`, and the interactive Swagger UI is
available at `http://127.0.0.1:8000/docs`.

## Verify Health and Documentation

```bash
curl --fail --silent http://127.0.0.1:8000/health
curl --fail --silent http://127.0.0.1:8000/docs | grep "Swagger UI"
```

The health response is:

```json
{"status":"ok"}
```

## Exercise Task CRUD

Run these commands in order against a fresh Stage 1 process. The first task has
ID `1`.

Create a task:

```bash
curl --fail --silent \
  --request POST \
  --header 'Content-Type: application/json' \
  --data '{"title":"Write the FastAPI tutorial"}' \
  http://127.0.0.1:8000/tasks
```

List tasks:

```bash
curl --fail --silent http://127.0.0.1:8000/tasks
```

Read task `1`:

```bash
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

Delete task `1`:

```bash
curl --fail --silent \
  --request DELETE \
  http://127.0.0.1:8000/tasks/1
```

The create response assigns an integer `id` and defaults `completed` to
`false`. Update uses complete `PUT` replacement, deletion returns an empty
`204` response, and later reads of a deleted or unknown task return:

```json
{"detail":"Task not found"}
```

## Stage 1 Data Lifecycle

Stage 1 stores records inside one application process. Restarting Uvicorn
clears every task and resets the next ID to `1`. Run one Uvicorn process for
this source stage so every request reaches the same in-memory store.

The `stage-2-postgresql` source stage adds durable PostgreSQL persistence. The
`stage-3-production` source stage adds the production container and runtime
controls. Those stages retain the same public Tasks API while introducing their
own deployment requirements.
