#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="ns-let51wad"
EXPECTED_CONTEXT="dn9ue3wz@sealos"
RUN_LABEL_KEY="tutorial.sealos.io/run-id"
RESOURCE_PREFIX="tutorial-fastapi-pg-test"
POSTGRES_IMAGE="postgres:17.10-bookworm@sha256:4f736ae292687621d4dbe0d499ffd024a36bd2ee7d8ca6f2ccd4c800f047b394"
POSTGRES_USER="tasks"
POSTGRES_DB="tasks"
WAIT_SECONDS=120

MODE="phase-gate"
STATE_FILE=""
ATTACHED_SESSION=false
RUN_ID=""
RUN_LABEL=""
SECRET_NAME=""
DEPLOYMENT_NAME=""
SERVICE_NAME=""
DATABASE_URL=""
TEST_DATABASE_URL=""
SUPERVISOR_PID=""
PORT_FORWARD_PID=""
LOCAL_PORT=""
POSTGRES_PASSWORD=""
CLEANUP_REQUIRED=false
PORT_FORWARD_LOG=""
SUPERVISOR_LOG=""

usage() {
  cat <<'EOF'
Usage:
  ./scripts/test-postgres.sh --session-start --state-file PATH
  ./scripts/test-postgres.sh --session-stop --state-file PATH
  ./scripts/test-postgres.sh --assert-clean --state-file PATH
  ./scripts/test-postgres.sh --pytest-only [PYTEST_ARGS...]
  ./scripts/test-postgres.sh --migrations-only
  ./scripts/test-postgres.sh --jobs-only [--state-file PATH]
  ./scripts/test-postgres.sh --phase-gate
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

state_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

process_command() {
  ps -p "$1" -o command= 2>/dev/null || true
}

process_is_alive() {
  kill -0 "$1" 2>/dev/null
}

validate_state_file() {
  local state_file="$1"
  local line_count
  local key

  [[ -f "$state_file" && ! -L "$state_file" ]] || fail "state file is missing or unsafe: $state_file"
  [[ "$(state_mode "$state_file")" == "600" ]] || fail "state file permissions must be 0600: $state_file"
  line_count="$(wc -l <"$state_file" | tr -d ' ')"
  [[ "$line_count" == "5" ]] || fail "state file must contain exactly five keys: $state_file"

  while IFS= read -r key; do
    [[ "$(grep -c "^${key}=" "$state_file")" == "1" ]] || fail "state file key is missing or duplicated: $key"
  done <<'EOF'
RUN_ID
DATABASE_URL
TEST_DATABASE_URL
SUPERVISOR_PID
PORT_FORWARD_PID
EOF

  if grep -Ev '^(RUN_ID|SUPERVISOR_PID|PORT_FORWARD_PID)=[A-Za-z0-9]+$|^(DATABASE_URL|TEST_DATABASE_URL)=postgresql\+psycopg://[A-Za-z0-9]+:[A-Za-z0-9]+@127\.0\.0\.1:[0-9]+/[A-Za-z0-9]+$' "$state_file" >/dev/null; then
    fail "state file contains malformed data: $state_file"
  fi

  # shellcheck disable=SC1090
  source "$state_file"
  [[ "$RUN_ID" =~ ^[a-z0-9]{12}$ ]] || fail "state file run ID is malformed"
  [[ "$SUPERVISOR_PID" =~ ^[0-9]+$ ]] || fail "state file supervisor PID is malformed"
  [[ "$PORT_FORWARD_PID" =~ ^[0-9]+$ ]] || fail "state file port-forward PID is malformed"
  set_run_identity "$RUN_ID"
}

set_run_identity() {
  RUN_ID="$1"
  RUN_LABEL="${RUN_LABEL_KEY}=${RUN_ID}"
  SECRET_NAME="${RESOURCE_PREFIX}-${RUN_ID}-secret"
  DEPLOYMENT_NAME="${RESOURCE_PREFIX}-${RUN_ID}-db"
  SERVICE_NAME="${RESOURCE_PREFIX}-${RUN_ID}-service"
  PORT_FORWARD_LOG="/tmp/sealos-fastapi-postgres-${RUN_ID}-port-forward.log"
  SUPERVISOR_LOG="/tmp/sealos-fastapi-postgres-${RUN_ID}-supervisor.log"
}

new_run_id() {
  python - <<'PY'
import secrets
print(secrets.token_hex(6))
PY
}

new_password() {
  python - <<'PY'
import secrets
print(secrets.token_hex(24))
PY
}

new_local_port() {
  python - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

preflight_cluster() {
  local current_context

  current_context="$(kubectl config current-context)"
  [[ "$current_context" == "$EXPECTED_CONTEXT" ]] || fail "unexpected kubectl context: $current_context"
  kubectl get namespace "$NAMESPACE" -o name >/dev/null

  local resource
  for resource in deployments services secrets jobs configmaps; do
    [[ "$(kubectl auth can-i create "$resource" --namespace "$NAMESPACE")" == "yes" ]] || fail "cannot create $resource in $NAMESPACE"
    [[ "$(kubectl auth can-i delete "$resource" --namespace "$NAMESPACE")" == "yes" ]] || fail "cannot delete $resource in $NAMESPACE"
  done
}

assert_inventory_names_match_run() {
  local inventory
  local item

  inventory="$(kubectl --namespace "$NAMESPACE" get job,deploy,svc,secret,configmap,pod -l "$RUN_LABEL" -o name)"
  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    [[ "${item##*/}" == "${RESOURCE_PREFIX}-${RUN_ID}-"* ]] || fail "run label points to an unexpected object: $item"
  done <<<"$inventory"
}

apply_secret() {
  POSTGRES_PASSWORD="$POSTGRES_PASSWORD" python - "$SECRET_NAME" "$RUN_ID" "$RUN_LABEL_KEY" <<'PY' | kubectl --namespace "$NAMESPACE" apply -f - >/dev/null
import json
import os
import sys

name, run_id, label_key = sys.argv[1:]
document = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {"name": name, "labels": {label_key: run_id}},
    "type": "Opaque",
    "stringData": {
        "username": "tasks",
        "password": os.environ["POSTGRES_PASSWORD"],
        "database": "tasks",
    },
}
print(json.dumps(document))
PY
}

apply_database() {
  kubectl --namespace "$NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOYMENT_NAME
  labels:
    $RUN_LABEL_KEY: $RUN_ID
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: $DEPLOYMENT_NAME
      $RUN_LABEL_KEY: $RUN_ID
  template:
    metadata:
      labels:
        app.kubernetes.io/name: $DEPLOYMENT_NAME
        $RUN_LABEL_KEY: $RUN_ID
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: postgres
          image: $POSTGRES_IMAGE
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          env:
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: $SECRET_NAME
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: $SECRET_NAME
                  key: password
            - name: POSTGRES_DB
              valueFrom:
                secretKeyRef:
                  name: $SECRET_NAME
                  key: database
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          ports:
            - name: postgres
              containerPort: 5432
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "$POSTGRES_USER", "-d", "$POSTGRES_DB"]
            initialDelaySeconds: 2
            periodSeconds: 2
            timeoutSeconds: 2
            failureThreshold: 30
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: 250m
              memory: 512Mi
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: $SERVICE_NAME
  labels:
    $RUN_LABEL_KEY: $RUN_ID
spec:
  selector:
    app.kubernetes.io/name: $DEPLOYMENT_NAME
    $RUN_LABEL_KEY: $RUN_ID
  ports:
    - name: postgres
      port: 5432
      targetPort: postgres
EOF
}

wait_for_database() {
  local pod_name

  kubectl --namespace "$NAMESPACE" rollout status "deployment/$DEPLOYMENT_NAME" --timeout="${WAIT_SECONDS}s"
  pod_name="$(kubectl --namespace "$NAMESPACE" get pods -l "$RUN_LABEL" -o jsonpath='{.items[0].metadata.name}')"
  [[ "$pod_name" == "${DEPLOYMENT_NAME}-"* ]] || fail "database Pod does not match the run identity"
  kubectl --namespace "$NAMESPACE" exec "$pod_name" -- pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null
  printf 'POSTGRES_READY run_id=%s deployment=%s\n' "$RUN_ID" "$DEPLOYMENT_NAME"
}

start_port_forward() {
  local attempt

  for attempt in 1 2 3; do
    LOCAL_PORT="$(new_local_port)"
    nohup kubectl --namespace "$NAMESPACE" port-forward --address 127.0.0.1 "service/$SERVICE_NAME" "${LOCAL_PORT}:5432" </dev/null >"$PORT_FORWARD_LOG" 2>&1 &
    PORT_FORWARD_PID=$!

    local ready=false
    local check
    for check in $(seq 1 60); do
      if ! process_is_alive "$PORT_FORWARD_PID"; then
        break
      fi
      if python - "$LOCAL_PORT" 2>/dev/null <<'PY'
import socket
import sys

with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.25):
    pass
PY
      then
        ready=true
        break
      fi
      sleep 0.5
    done

    if [[ "$ready" == true ]]; then
      DATABASE_URL="postgresql+psycopg://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:${LOCAL_PORT}/${POSTGRES_DB}"
      TEST_DATABASE_URL="$DATABASE_URL"
      printf 'PORT_FORWARD_READY run_id=%s local_port=%s\n' "$RUN_ID" "$LOCAL_PORT"
      return
    fi

    if process_is_alive "$PORT_FORWARD_PID"; then
      kill "$PORT_FORWARD_PID" 2>/dev/null || true
    fi
    wait "$PORT_FORWARD_PID" 2>/dev/null || true
    PORT_FORWARD_PID=""
  done

  fail "port-forward did not become ready after three bounded attempts"
}

provision() {
  preflight_cluster
  POSTGRES_PASSWORD="$(new_password)"
  apply_secret
  CLEANUP_REQUIRED=true
  apply_database
  assert_inventory_names_match_run
  wait_for_database
  start_port_forward
}

cleanup() {
  local status=$?
  local cleanup_status=0
  local inventory
  local check

  trap - EXIT INT TERM HUP
  set +e

  if [[ -n "$PORT_FORWARD_PID" ]] && process_is_alive "$PORT_FORWARD_PID"; then
    if [[ "$(process_command "$PORT_FORWARD_PID")" == *"kubectl"*"port-forward"*"service/$SERVICE_NAME"* ]]; then
      kill "$PORT_FORWARD_PID" 2>/dev/null
      for check in $(seq 1 40); do
        process_is_alive "$PORT_FORWARD_PID" || break
        sleep 0.25
      done
      wait "$PORT_FORWARD_PID" 2>/dev/null || true
      process_is_alive "$PORT_FORWARD_PID" && cleanup_status=1
    else
      printf 'CLEANUP_ERROR run_id=%s reason=port-forward-identity\n' "$RUN_ID" >&2
      cleanup_status=1
    fi
  fi

  if [[ "$CLEANUP_REQUIRED" == true ]]; then
    kubectl --namespace "$NAMESPACE" delete job,deploy,svc,secret,configmap -l "$RUN_LABEL" --ignore-not-found --wait=true --timeout=90s >/dev/null || cleanup_status=1
    for check in $(seq 1 60); do
      inventory="$(kubectl --namespace "$NAMESPACE" get pod -l "$RUN_LABEL" -o name 2>/dev/null)"
      [[ -z "$inventory" ]] && break
      sleep 1
    done
    inventory="$(kubectl --namespace "$NAMESPACE" get job,deploy,svc,secret,configmap,pod -l "$RUN_LABEL" -o name 2>/dev/null)"
    [[ -z "$inventory" ]] || cleanup_status=1
  fi

  rm -f "$PORT_FORWARD_LOG"

  if [[ "$cleanup_status" == 0 ]]; then
    printf 'CLEANUP_OK run_id=%s inventory=0 port_forward=stopped\n' "$RUN_ID"
  else
    printf 'CLEANUP_FAILED run_id=%s\n' "$RUN_ID" >&2
  fi

  if [[ "$status" != 0 ]]; then
    exit "$status"
  fi
  exit "$cleanup_status"
}

write_state_file() {
  local state_file="$1"
  local temporary="${state_file}.tmp.$$"

  umask 077
  [[ ! -e "$temporary" && ! -L "$temporary" ]] || fail "temporary state path already exists: $temporary"
  {
    printf 'RUN_ID=%s\n' "$RUN_ID"
    printf 'DATABASE_URL=%s\n' "$DATABASE_URL"
    printf 'TEST_DATABASE_URL=%s\n' "$TEST_DATABASE_URL"
    printf 'SUPERVISOR_PID=%s\n' "$$"
    printf 'PORT_FORWARD_PID=%s\n' "$PORT_FORWARD_PID"
  } >"$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$state_file"
}

supervise_session() {
  local state_file="$1"

  [[ -n "${INTERNAL_RUN_ID:-}" ]] || fail "supervisor run ID is missing"
  set_run_identity "$INTERNAL_RUN_ID"
  SUPERVISOR_PID=$$
  trap cleanup EXIT INT TERM HUP
  provision
  write_state_file "$state_file"
  printf 'SESSION_SUPERVISOR_READY run_id=%s\n' "$RUN_ID"

  while true; do
    sleep 5
  done
}

start_session() {
  local state_file="$1"
  local run_id
  local supervisor_pid
  local check

  [[ -n "$state_file" ]] || fail "--session-start requires --state-file PATH"
  [[ "$state_file" == /* ]] || fail "state file path must be absolute"
  [[ ! -e "$state_file" && ! -L "$state_file" ]] || fail "state file already exists: $state_file"
  [[ -d "$(dirname "$state_file")" && -w "$(dirname "$state_file")" ]] || fail "state file directory is not writable"

  run_id="$(new_run_id)"
  set_run_identity "$run_id"
  rm -f "$SUPERVISOR_LOG"
  nohup python - "$run_id" "$0" "$state_file" >"$SUPERVISOR_LOG" 2>&1 <<'PY' &
import os
from pathlib import Path
import sys

run_id, script, state_file = sys.argv[1:]
os.setsid()
script = str(Path(script).resolve())
environment = os.environ.copy()
environment["INTERNAL_RUN_ID"] = run_id
os.execve(script, [script, "--supervisor", "--state-file", state_file], environment)
PY
  supervisor_pid=$!

  trap 'kill "$supervisor_pid" 2>/dev/null || true' EXIT INT TERM HUP
  for check in $(seq 1 240); do
    if [[ -f "$state_file" ]]; then
      validate_state_file "$state_file"
      [[ "$SUPERVISOR_PID" == "$supervisor_pid" ]] || fail "supervisor PID changed during startup"
      assert_inventory_names_match_run
      trap - EXIT INT TERM HUP
      printf 'SESSION_READY state_file=%s run_id=%s\n' "$state_file" "$RUN_ID"
      return
    fi
    if ! process_is_alive "$supervisor_pid"; then
      sed -E 's#postgresql\+psycopg://[^[:space:]]+#postgresql+psycopg://REDACTED#g' "$SUPERVISOR_LOG" >&2
      fail "session supervisor stopped before readiness"
    fi
    sleep 0.5
  done

  fail "session supervisor readiness timed out"
}

require_supervisor_identity() {
  local command

  process_is_alive "$SUPERVISOR_PID" || fail "recorded supervisor is not running"
  command="$(process_command "$SUPERVISOR_PID")"
  [[ "$command" == *"test-postgres.sh"*"--supervisor"*"--state-file"*"$STATE_FILE"* ]] || fail "recorded supervisor identity does not match the state file"

  process_is_alive "$PORT_FORWARD_PID" || fail "recorded port-forward is not running"
  command="$(process_command "$PORT_FORWARD_PID")"
  [[ "$command" == *"kubectl"*"port-forward"*"service/$SERVICE_NAME"* ]] || fail "recorded port-forward identity does not match the run"
}

stop_session() {
  local state_file="$1"
  local check

  STATE_FILE="$state_file"
  validate_state_file "$state_file"
  require_supervisor_identity
  assert_inventory_names_match_run
  kill "$SUPERVISOR_PID"

  for check in $(seq 1 240); do
    process_is_alive "$SUPERVISOR_PID" || break
    sleep 0.5
  done
  process_is_alive "$SUPERVISOR_PID" && fail "session supervisor did not stop within the cleanup timeout"
  grep -F "CLEANUP_OK run_id=$RUN_ID inventory=0 port_forward=stopped" "$SUPERVISOR_LOG" >/dev/null || fail "session cleanup proof is missing"
  printf 'SESSION_STOPPED state_file=%s run_id=%s\n' "$state_file" "$RUN_ID"
}

assert_clean_session() {
  local state_file="$1"
  local inventory

  STATE_FILE="$state_file"
  validate_state_file "$state_file"
  process_is_alive "$SUPERVISOR_PID" && fail "recorded supervisor is still running"
  process_is_alive "$PORT_FORWARD_PID" && fail "recorded port-forward is still running"
  inventory="$(kubectl --namespace "$NAMESPACE" get job,deploy,svc,secret,configmap,pod -l "$RUN_LABEL" -o name)"
  [[ -z "$inventory" ]] || fail "owned Kubernetes resources remain after cleanup"
  grep -F "CLEANUP_OK run_id=$RUN_ID inventory=0 port_forward=stopped" "$SUPERVISOR_LOG" >/dev/null || fail "cleanup proof is missing"
  rm -f "$state_file" "$SUPERVISOR_LOG" "$PORT_FORWARD_LOG"
  printf 'ASSERT_CLEAN_OK run_id=%s inventory=0 processes=stopped\n' "$RUN_ID"
}

check_database_connection() {
  DATABASE_URL="$DATABASE_URL" uv run python - <<'PY'
import os

from sqlalchemy import create_engine, text

engine = create_engine(os.environ["DATABASE_URL"], pool_pre_ping=True)
try:
    with engine.connect() as connection:
        assert connection.execute(text("SELECT 1")).scalar_one() == 1
finally:
    engine.dispose()
print("SQLALCHEMY_READY select=1")
PY
}

run_migrations() {
  DATABASE_URL="$DATABASE_URL" uv run alembic upgrade head
  DATABASE_URL="$DATABASE_URL" uv run alembic upgrade head
  DATABASE_URL="$DATABASE_URL" uv run alembic current
}

run_jobs() {
  [[ -f deploy/source-migration-job.yaml ]] || fail "deploy/source-migration-job.yaml is required for --jobs-only"
  fail "source migration Job execution is added by Phase 22 Plan 03"
}

dispatch_attached_mode() {
  check_database_connection
  case "$MODE" in
    pytest-only)
      DATABASE_URL="$DATABASE_URL" TEST_DATABASE_URL="$TEST_DATABASE_URL" uv run pytest "${PASSTHROUGH_ARGS[@]}"
      ;;
    migrations-only)
      run_migrations
      ;;
    jobs-only)
      run_jobs
      ;;
    phase-gate)
      run_migrations
      DATABASE_URL="$DATABASE_URL" TEST_DATABASE_URL="$TEST_DATABASE_URL" uv run pytest -q
      run_jobs
      ;;
    *)
      fail "unsupported execution mode: $MODE"
      ;;
  esac
}

run_one_shot() {
  set_run_identity "$(new_run_id)"
  SUPERVISOR_PID=$$
  trap cleanup EXIT INT TERM HUP
  provision
  dispatch_attached_mode
}

PASSTHROUGH_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-start)
      MODE="session-start"
      shift
      ;;
    --session-stop)
      MODE="session-stop"
      shift
      ;;
    --assert-clean)
      MODE="assert-clean"
      shift
      ;;
    --supervisor)
      MODE="supervisor"
      shift
      ;;
    --pytest-only)
      MODE="pytest-only"
      shift
      while [[ $# -gt 0 && "$1" != "--state-file" ]]; do
        PASSTHROUGH_ARGS+=("$1")
        shift
      done
      ;;
    --migrations-only)
      MODE="migrations-only"
      shift
      ;;
    --jobs-only)
      MODE="jobs-only"
      shift
      ;;
    --phase-gate)
      MODE="phase-gate"
      shift
      ;;
    --state-file)
      [[ $# -ge 2 ]] || fail "--state-file requires a path"
      STATE_FILE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

case "$MODE" in
  session-start)
    start_session "$STATE_FILE"
    ;;
  session-stop)
    [[ -n "$STATE_FILE" ]] || fail "--session-stop requires --state-file PATH"
    stop_session "$STATE_FILE"
    ;;
  assert-clean)
    [[ -n "$STATE_FILE" ]] || fail "--assert-clean requires --state-file PATH"
    assert_clean_session "$STATE_FILE"
    ;;
  supervisor)
    [[ -n "$STATE_FILE" ]] || fail "--supervisor requires --state-file PATH"
    supervise_session "$STATE_FILE"
    ;;
  pytest-only|migrations-only|jobs-only|phase-gate)
    if [[ -n "$STATE_FILE" ]]; then
      ATTACHED_SESSION=true
      validate_state_file "$STATE_FILE"
      require_supervisor_identity
      assert_inventory_names_match_run
      dispatch_attached_mode
    else
      run_one_shot
    fi
    ;;
esac
