#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="ns-let51wad"
EXPECTED_CONTEXT="dn9ue3wz@sealos"
RUN_LABEL_KEY="tutorial.sealos.io/run-id"
RESOURCE_PREFIX="tutorial-fastapi-pg-test"
IMAGE_REPOSITORY="ghcr.io/yangchuansheng/sealos-fastapi-tutorial"
SOURCE_REPOSITORY="https://github.com/yangchuansheng/sealos-fastapi-tutorial"
GITHUB_REPOSITORY="yangchuansheng/sealos-fastapi-tutorial"
WAIT_SECONDS=240
JOB_WAIT_SECONDS=300

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POSTGRES_HARNESS="$SCRIPT_DIR/test-postgres.sh"
APPLICATION_TEMPLATE="$PROJECT_ROOT/deploy/application.yaml"
MIGRATION_TEMPLATE="$PROJECT_ROOT/deploy/migration-job.yaml"

MODE=""
EVIDENCE_SCOPE=""
EVIDENCE_DIR=""
BASELINE_IMAGE=""
BASELINE_SOURCE=""
FINAL_IMAGE=""
FINAL_SOURCE=""
BASELINE_RUNTIME_DIGEST=""
FINAL_RUNTIME_DIGEST=""

WORK_DIR=""
WORK_EVIDENCE=""
STATE_FILE=""
RUN_ID=""
RUN_LABEL=""
SECRET_NAME=""
APP_NAME=""
BASELINE_JOB_NAME=""
FINAL_JOB_NAME=""
APP_PORT_FORWARD_PID=""
APP_PORT_FORWARD_LOG=""
APP_LOCAL_PORT=""
PRIMARY_TASK_ID=""
DISPOSABLE_TASK_ID=""
SESSION_STARTED=false
RUN_SUCCEEDED=false

trap cleanup EXIT INT TERM HUP

usage() {
  cat <<'EOF'
Usage:
  ./scripts/test-production.sh --run \
    --baseline-image IMAGE@sha256:DIGEST --baseline-source SOURCE_SHA \
    --final-image IMAGE@sha256:DIGEST --final-source SOURCE_SHA \
    --evidence-dir PATH
  ./scripts/test-production.sh --preflight-evidence publication --evidence-dir PATH
  ./scripts/test-production.sh --verify-evidence live --evidence-dir PATH
  ./scripts/test-production.sh --verify-evidence publication --evidence-dir PATH
  ./scripts/test-production.sh --help
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

process_is_alive() {
  [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null
}

process_command() {
  ps -p "$1" -o command= 2>/dev/null || true
}

stop_application_port_forward() {
  local check

  [[ -n "$APP_PORT_FORWARD_PID" ]] || return 0
  if process_is_alive "$APP_PORT_FORWARD_PID"; then
    [[ "$(process_command "$APP_PORT_FORWARD_PID")" == *"kubectl"*"port-forward"*"service/$APP_NAME"* ]] || return 1
    kill "$APP_PORT_FORWARD_PID" 2>/dev/null || return 1
    for check in $(seq 1 40); do
      process_is_alive "$APP_PORT_FORWARD_PID" || break
      sleep 0.25
    done
    wait "$APP_PORT_FORWARD_PID" 2>/dev/null || true
    process_is_alive "$APP_PORT_FORWARD_PID" && return 1
  else
    wait "$APP_PORT_FORWARD_PID" 2>/dev/null || true
  fi
  APP_PORT_FORWARD_PID=""
}

cleanup() {
  local status=$?
  local cleanup_status=0
  local inventory=""
  local matching_processes=""

  trap - EXIT INT TERM HUP
  set +e

  stop_application_port_forward || cleanup_status=1

  if [[ "$SESSION_STARTED" == true ]]; then
    "$POSTGRES_HARNESS" --session-stop --state-file "$STATE_FILE" || cleanup_status=1
    "$POSTGRES_HARNESS" --assert-clean --state-file "$STATE_FILE" || cleanup_status=1
    inventory="$(kubectl --namespace "$NAMESPACE" get \
      deployment,replicaset,pod,service,job,secret,configmap \
      -l "$RUN_LABEL" -o name 2>/dev/null)"
    [[ -z "$inventory" ]] || cleanup_status=1
    matching_processes="$(ps -axo pid=,comm=,args= | awk -v prefix="$RESOURCE_PREFIX-$RUN_ID-" '$2 ~ /(^|\/)kubectl$/ && index($0, "port-forward") && index($0, prefix) {print $1}')"
    [[ -z "$matching_processes" ]] || cleanup_status=1
  fi

  if [[ "$status" == 0 && "$cleanup_status" == 0 && "$RUN_SUCCEEDED" == true ]]; then
    {
      printf 'run_id=%s selector=%s\n' "$RUN_ID" "$RUN_LABEL"
      printf 'deployment=0 replicaset=0 pod=0 service=0 job=0 secret=0 configmap=0\n'
      printf 'port_forward=stopped owned_processes=0 state_file=absent rendered_files=0 clone_directories=0\n'
    } >"$WORK_EVIDENCE/cleanup.txt"
    finalize_live_evidence || cleanup_status=1
  fi

  [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR" || cleanup_status=1

  if [[ "$SESSION_STARTED" == true ]]; then
    if [[ "$cleanup_status" == 0 ]]; then
      printf 'PRODUCTION_CLEANUP_OK run_id=%s inventory=0 processes=0\n' "$RUN_ID"
    else
      printf 'PRODUCTION_CLEANUP_FAILED run_id=%s\n' "$RUN_ID" >&2
    fi
  fi

  if [[ "$status" != 0 ]]; then
    exit "$status"
  fi
  exit "$cleanup_status"
}

validate_source() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]] || fail "source release must match ^[0-9a-f]{40}$"
}

validate_image() {
  [[ "$1" =~ ^${IMAGE_REPOSITORY}@sha256:[0-9a-f]{64}$ ]] || fail "image reference must end with @sha256:[0-9a-f]{64}$"
}

prepare_run_paths() {
  EVIDENCE_DIR="$(python - "$EVIDENCE_DIR" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1]).expanduser()
if path.exists() and (path.is_symlink() or not path.is_dir()):
    raise SystemExit("evidence path must be a real directory")
path.mkdir(parents=True, exist_ok=True)
if any(path.iterdir()):
    raise SystemExit("evidence directory must be empty")
resolved = path.resolve()
if resolved == Path("/"):
    raise SystemExit("evidence directory cannot be the filesystem root")
print(resolved)
PY
)"
  WORK_DIR="$(mktemp -d /tmp/sealos-fastapi-production.XXXXXXXX)"
  chmod 700 "$WORK_DIR"
  WORK_EVIDENCE="$WORK_DIR/evidence"
  mkdir -m 700 "$WORK_EVIDENCE"
  STATE_FILE="$WORK_DIR/postgres.state"
  APP_PORT_FORWARD_LOG="$WORK_DIR/application-port-forward.log"
  umask 077
  for filename in workflow.txt images.txt migration.txt runtime.txt logs.txt http.jsonl rollback.txt; do
    : >"$WORK_EVIDENCE/$filename"
  done
}

evidence_append() {
  local filename="$1"
  shift
  printf '%s\n' "$*" >>"$WORK_EVIDENCE/$filename"
}

require_commands() {
  local command

  for command in bash crane curl gh jq kubectl python sha256sum uv; do
    command -v "$command" >/dev/null || fail "required command is unavailable: $command"
  done
}

preflight_public_identity() {
  local public_main
  local package_repository
  local package_visibility
  local local_head

  local_head="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
  [[ "$local_head" == "$FINAL_SOURCE" ]] || fail "local source is not the final release"
  [[ -z "$(git -C "$PROJECT_ROOT" status --short)" ]] || fail "local source tree must be clean"
  public_main="$(gh api "repos/$GITHUB_REPOSITORY/commits/main" --jq .sha)"
  [[ "$public_main" == "$FINAL_SOURCE" ]] || fail "public main does not equal the final release"
  package_visibility="$(gh api "users/yangchuansheng/packages/container/sealos-fastapi-tutorial" --jq .visibility)"
  [[ "$package_visibility" == "public" ]] || fail "container package must be public"
  package_repository="$(gh api "users/yangchuansheng/packages/container/sealos-fastapi-tutorial" --jq .repository.name)"
  [[ "$package_repository" == "sealos-fastapi-tutorial" ]] || fail "container package repository link drifted"

  record_workflow_identity baseline "$BASELINE_SOURCE" "$BASELINE_IMAGE"
  record_workflow_identity final "$FINAL_SOURCE" "$FINAL_IMAGE"
  BASELINE_RUNTIME_DIGEST="$(anonymous_image_gate baseline "$BASELINE_IMAGE" "$BASELINE_SOURCE")"
  FINAL_RUNTIME_DIGEST="$(anonymous_image_gate final "$FINAL_IMAGE" "$FINAL_SOURCE")"
  [[ "$BASELINE_IMAGE" != "$FINAL_IMAGE" ]] || fail "baseline and final digests must differ"
}

record_workflow_identity() {
  local role="$1"
  local source="$2"
  local image="$3"
  local runs_file="$WORK_DIR/workflow-runs-$role.json"
  local log_file="$WORK_DIR/workflow-$role.log"
  local candidate_id=""
  local selected_id=""
  local event=""
  local head_sha=""
  local url=""
  local digest="${image##*@}"

  gh run list --repo "$GITHUB_REPOSITORY" --workflow publish-image.yml \
    --limit 100 --json databaseId,event,headSha,status,conclusion,url >"$runs_file"
  while IFS= read -r candidate_id; do
    [[ -n "$candidate_id" ]] || continue
    gh run view "$candidate_id" --repo "$GITHUB_REPOSITORY" --log >"$log_file"
    if grep -F "target_sha=$source" "$log_file" >/dev/null \
      && grep -F "image_digest=$digest" "$log_file" >/dev/null; then
      selected_id="$candidate_id"
      break
    fi
  done < <(python - "$runs_file" "$source" <<'PY'
import json
from pathlib import Path
import sys

runs = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
source = sys.argv[2]
accepted = [
    run for run in runs
    if run["status"] == "completed" and run["conclusion"] == "success"
]
accepted.sort(key=lambda run: (run["headSha"] != source, -run["databaseId"]))
for run in accepted:
    print(run["databaseId"])
PY
)
  [[ -n "$selected_id" ]] || fail "no successful exact-source workflow run found for $role"
  IFS=$'\t' read -r event head_sha url < <(python - "$runs_file" "$selected_id" <<'PY'
import json
from pathlib import Path
import sys

runs = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
selected = int(sys.argv[2])
run = next(item for item in runs if item["databaseId"] == selected)
print(run["event"], run["headSha"], run["url"], sep="\t")
PY
)
  if [[ "$event" == "push" ]]; then
    [[ "$head_sha" == "$source" ]] || fail "push workflow head does not match target source"
  else
    [[ "$event" == "workflow_dispatch" ]] || fail "unexpected workflow event: $event"
    [[ "$head_sha" == "$FINAL_SOURCE" ]] || fail "dispatch workflow head does not match public main"
  fi
  evidence_append workflow.txt \
    "role=$role run_id=$selected_id event=$event head_sha=$head_sha target_sha=$source conclusion=success digest=$digest url=$url"
  rm -f "$runs_file" "$log_file"
}

anonymous_image_gate() (
  local role="$1"
  local image="$2"
  local source="$3"
  local expected_digest="${image##*@}"
  local tag="$IMAGE_REPOSITORY:sha-$source"
  local resolved_digest=""
  local runtime_digest=""
  local config_file="$WORK_DIR/image-$role-config.json"
  local manifest_file="$WORK_DIR/image-$role-manifest.json"
  local ANON_DOCKER_CONFIG=""

  ANON_DOCKER_CONFIG="$(mktemp -d)"
  chmod 700 "$ANON_DOCKER_CONFIG"
  [[ -z "$(find "$ANON_DOCKER_CONFIG" -mindepth 1 -print -quit)" ]] || exit 1
  cleanup_anonymous_registry() {
    local status=$?
    trap - EXIT INT TERM HUP
    rm -rf "$ANON_DOCKER_CONFIG" || exit 1
    [[ ! -e "$ANON_DOCKER_CONFIG" ]] || exit 1
    exit "$status"
  }
  trap cleanup_anonymous_registry EXIT INT TERM HUP

  resolved_digest="$(env -u GH_TOKEN -u GITHUB_TOKEN -u GHCR_TOKEN \
    -u REGISTRY_TOKEN -u DOCKER_AUTH_CONFIG -u REGISTRY_AUTH_FILE \
    -u CRANE_AUTH DOCKER_CONFIG="$ANON_DOCKER_CONFIG" crane digest "$tag")"
  [[ "$resolved_digest" == "$expected_digest" ]] || fail "$role tag digest mismatch"
  env -u GH_TOKEN -u GITHUB_TOKEN -u GHCR_TOKEN -u REGISTRY_TOKEN \
    -u DOCKER_AUTH_CONFIG -u REGISTRY_AUTH_FILE -u CRANE_AUTH \
    DOCKER_CONFIG="$ANON_DOCKER_CONFIG" crane config "$image" >"$config_file"
  env -u GH_TOKEN -u GITHUB_TOKEN -u GHCR_TOKEN -u REGISTRY_TOKEN \
    -u DOCKER_AUTH_CONFIG -u REGISTRY_AUTH_FILE -u CRANE_AUTH \
    DOCKER_CONFIG="$ANON_DOCKER_CONFIG" crane manifest "$image" >"$manifest_file"

  runtime_digest="$(python - "$config_file" "$manifest_file" "$source" "$expected_digest" <<'PY'
import json
from pathlib import Path
import re
import sys

config_path, manifest_path, source, expected_digest = sys.argv[1:]
config = json.loads(Path(config_path).read_text(encoding="utf-8"))
manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
labels = config.get("config", {}).get("Labels", {})
assert labels.get("org.opencontainers.image.revision") == source
assert labels.get("org.opencontainers.image.source") == "https://github.com/yangchuansheng/sealos-fastapi-tutorial"
assert config.get("architecture", "amd64") == "amd64"
assert config.get("os", "linux") == "linux"
if "manifests" in manifest:
    matches = [
        item for item in manifest["manifests"]
        if item.get("platform", {}).get("os") == "linux"
        and item.get("platform", {}).get("architecture") == "amd64"
    ]
    assert len(matches) == 1
    runtime_digest = matches[0]["digest"]
else:
    runtime_digest = expected_digest
assert re.fullmatch(r"sha256:[0-9a-f]{64}", runtime_digest)
print(runtime_digest)
PY
)"
  evidence_append images.txt \
    "role=$role source=$source image=$image tag=$tag digest=$expected_digest runtime_digest=$runtime_digest architecture=amd64 os=linux revision=$source source_label=$SOURCE_REPOSITORY package=public"
  rm -f "$config_file" "$manifest_file"
  rm -rf "$ANON_DOCKER_CONFIG"
  [[ ! -e "$ANON_DOCKER_CONFIG" ]] || exit 1
  trap - EXIT INT TERM HUP
  printf '%s\n' "$runtime_digest"
)

preflight_cluster() {
  local current_context
  local existing_inventory
  local resource

  current_context="$(kubectl config current-context)"
  [[ "$current_context" == "$EXPECTED_CONTEXT" ]] || fail "unexpected kubectl context: $current_context"
  kubectl get namespace "$NAMESPACE" -o name >/dev/null
  for resource in deployments replicasets pods services jobs secrets configmaps; do
    [[ "$(kubectl auth can-i get "$resource" --namespace "$NAMESPACE")" == "yes" ]] || fail "cannot get $resource"
    [[ "$(kubectl auth can-i list "$resource" --namespace "$NAMESPACE")" == "yes" ]] || fail "cannot list $resource"
    [[ "$(kubectl auth can-i delete "$resource" --namespace "$NAMESPACE")" == "yes" ]] || fail "cannot delete $resource"
  done
  for resource in deployments services jobs secrets configmaps; do
    [[ "$(kubectl auth can-i create "$resource" --namespace "$NAMESPACE")" == "yes" ]] || fail "cannot create $resource"
  done
  [[ "$(kubectl auth can-i patch deployments --namespace "$NAMESPACE")" == "yes" ]] || fail "cannot patch deployments"
  [[ "$(kubectl auth can-i get pods/log --namespace "$NAMESPACE")" == "yes" ]] || fail "cannot read Pod logs"
  [[ "$(kubectl auth can-i create pods/exec --namespace "$NAMESPACE")" == "yes" ]] || fail "cannot exec in Pods"
  existing_inventory="$(kubectl --namespace "$NAMESPACE" get \
    deployment,replicaset,pod,service,job,secret,configmap -o name | \
    awk -F/ -v prefix="$RESOURCE_PREFIX-" '$2 ~ ("^" prefix) {print}')"
  [[ -z "$existing_inventory" ]] || fail "an earlier tutorial run requires exact forensic cleanup"
}

render_manifest() {
  local template="$1"
  local output="$2"
  shift 2

  python - "$template" "$output" "$@" <<'PY'
from pathlib import Path
import re
import sys

template_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
pairs = sys.argv[3:]
if len(pairs) % 2:
    raise SystemExit("render replacements must be key/value pairs")
replacements = dict(zip(pairs[::2], pairs[1::2], strict=True))
text = template_path.read_text(encoding="utf-8")
tokens = set(re.findall(r"__[A-Z0-9_]+__", text))
if tokens != set(replacements):
    raise SystemExit(f"unexpected template tokens: {sorted(tokens)}")
for token, value in replacements.items():
    if not value or "\n" in value:
        raise SystemExit(f"unsafe render value for {token}")
    text = text.replace(token, value)
if re.search(r"__[A-Z0-9_]+__", text):
    raise SystemExit("render left an unresolved token")
output_path.write_text(text, encoding="utf-8")
PY
  chmod 600 "$output"
  ! grep -Eq '__[A-Z0-9_]+__' "$output" || fail "rendered manifest contains unresolved tokens"
  kubectl --namespace "$NAMESPACE" apply --dry-run=server --validate=strict -f "$output" >/dev/null
}

render_application() {
  local output="$1"
  local image="$2"
  local source="$3"

  render_manifest "$APPLICATION_TEMPLATE" "$output" \
    __RUN_ID__ "$RUN_ID" \
    __APP_NAME__ "$APP_NAME" \
    __IMAGE_REFERENCE__ "$image" \
    __SOURCE_RELEASE__ "$source" \
    __SECRET_NAME__ "$SECRET_NAME"
}

render_migration_job() {
  local output="$1"
  local job_name="$2"
  local image="$3"

  render_manifest "$MIGRATION_TEMPLATE" "$output" \
    __RUN_ID__ "$RUN_ID" \
    __JOB_NAME__ "$job_name" \
    __IMAGE_REFERENCE__ "$image" \
    __SECRET_NAME__ "$SECRET_NAME"
}

# Phase 22 lifecycle contract:
# scripts/test-postgres.sh --session-start --state-file
# scripts/test-postgres.sh --session-stop --state-file
# scripts/test-postgres.sh --assert-clean --state-file
start_database_session() {
  "$POSTGRES_HARNESS" --session-start --state-file "$STATE_FILE"
  SESSION_STARTED=true
  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || fail "database state file is unsafe"
  [[ "$(state_mode "$STATE_FILE")" == "600" ]] || fail "database state file must have mode 0600"
  [[ "$(wc -l <"$STATE_FILE" | tr -d ' ')" == "5" ]] || fail "database state file has the wrong shape"
  if grep -Ev '^(RUN_ID|SUPERVISOR_PID|PORT_FORWARD_PID)=[A-Za-z0-9]+$|^(DATABASE_URL|TEST_DATABASE_URL)=postgresql\+psycopg://[A-Za-z0-9]+:[A-Za-z0-9]+@127\.0\.0\.1:[0-9]+/[A-Za-z0-9]+$' "$STATE_FILE" >/dev/null; then
    fail "database state file contains malformed data"
  fi
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [[ "$RUN_ID" =~ ^[a-z0-9]{12}$ ]] || fail "run ID is malformed"
  RUN_LABEL="$RUN_LABEL_KEY=$RUN_ID"
  SECRET_NAME="$RESOURCE_PREFIX-$RUN_ID-secret"
  APP_NAME="$RESOURCE_PREFIX-$RUN_ID-app"
  BASELINE_JOB_NAME="$RESOURCE_PREFIX-$RUN_ID-migration-baseline"
  FINAL_JOB_NAME="$RESOURCE_PREFIX-$RUN_ID-migration-final"
}

scan_file_for_credentials() {
  python - "$1" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")
patterns = {
    "credential-bearing PostgreSQL URL": re.compile(
        r"postgresql(?:\+psycopg)?://[^\s/:]+:[^\s@]+@", re.IGNORECASE
    ),
    "database URL assignment": re.compile(r"\bDATABASE_URL\s*=", re.IGNORECASE),
    "password assignment": re.compile(r"\bpassword\s*=\s*[^\s]+", re.IGNORECASE),
    "GitHub token": re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"),
    "bearer token": re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{16,}", re.IGNORECASE),
    "Kubernetes token": re.compile(r"\beyJhbGciOiJ[A-Za-z0-9._-]+"),
}
for label, pattern in patterns.items():
    if pattern.search(text):
        raise SystemExit(f"{path.name}: found {label}")
PY
}

run_migration_job() {
  local sequence="$1"
  local role="$2"
  local job_name="$3"
  local image="$4"
  local source="$5"
  local rendered="$WORK_DIR/migration-$role.yaml"
  local job_log="$WORK_DIR/migration-$role.log"
  local current_revision

  render_migration_job "$rendered" "$job_name" "$image"
  kubectl --namespace "$NAMESPACE" apply -f "$rendered" >/dev/null
  kubectl --namespace "$NAMESPACE" wait --for=condition=complete \
    "job/$job_name" --timeout="${JOB_WAIT_SECONDS}s" >/dev/null
  [[ "$(kubectl --namespace "$NAMESPACE" get "job/$job_name" -o jsonpath='{.status.succeeded}')" == "1" ]] || fail "$role migration Job did not succeed once"
  [[ -z "$(kubectl --namespace "$NAMESPACE" get "job/$job_name" -o jsonpath='{.status.failed}')" ]] || fail "$role migration Job recorded a failure"
  [[ "$(kubectl --namespace "$NAMESPACE" get "job/$job_name" -o jsonpath='{.spec.template.spec.containers[0].image}')" == "$image" ]] || fail "$role migration Job image drifted"
  kubectl --namespace "$NAMESPACE" logs "job/$job_name" --container migrate >"$job_log"
  scan_file_for_credentials "$job_log"
  current_revision="$(DATABASE_URL="$DATABASE_URL" uv run alembic current)"
  grep -F '0001 (head)' <<<"$current_revision" >/dev/null || fail "$role migration did not reach revision 0001"
  evidence_append migration.txt \
    "sequence=$sequence role=$role job=$job_name source=$source image=$image digest=${image##*@} condition=Complete status=True revision=0001"
  rm -f "$job_log"
}

apply_release() {
  local role="$1"
  local image="$2"
  local source="$3"
  local rendered="$WORK_DIR/application-$role.yaml"

  render_application "$rendered" "$image" "$source"
  kubectl --namespace "$NAMESPACE" apply -f "$rendered" >/dev/null
  kubectl --namespace "$NAMESPACE" rollout status "deployment/$APP_NAME" \
    --timeout="${WAIT_SECONDS}s" >/dev/null
  kubectl --namespace "$NAMESPACE" wait --for=condition=available \
    "deployment/$APP_NAME" --timeout="${WAIT_SECONDS}s" >/dev/null
}

new_local_port() {
  python - <<'PY'
import socket

with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

start_application_port_forward() {
  local ready=false
  local check

  stop_application_port_forward
  APP_LOCAL_PORT="$(new_local_port)"
  nohup kubectl --namespace "$NAMESPACE" port-forward --address 127.0.0.1 \
    "service/$APP_NAME" "${APP_LOCAL_PORT}:8000" </dev/null \
    >"$APP_PORT_FORWARD_LOG" 2>&1 &
  APP_PORT_FORWARD_PID=$!
  for check in $(seq 1 120); do
    process_is_alive "$APP_PORT_FORWARD_PID" || break
    if python - "$APP_LOCAL_PORT" 2>/dev/null <<'PY'
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
  [[ "$ready" == true ]] || fail "application port-forward did not become ready"
}

http_request() {
  local method="$1"
  local path="$2"
  local output="$3"
  local expected_status="$4"
  local payload="${5:-}"
  local status
  local args=(
    --silent --show-error --max-time 15
    --request "$method"
    --output "$output"
    --write-out '%{http_code}'
  )

  if [[ -n "$payload" ]]; then
    args+=(--header 'Content-Type: application/json' --data "$payload")
  fi
  status="$(curl "${args[@]}" "http://127.0.0.1:${APP_LOCAL_PORT}${path}")"
  [[ "$status" == "$expected_status" ]] || fail "$method $path returned HTTP $status"
}

collect_cluster_contract() {
  local image="$1"
  local source="$2"
  local runtime_digest="$3"
  local deployment_file="$WORK_DIR/deployment.json"
  local replicasets_file="$WORK_DIR/replicasets.json"
  local pods_file="$WORK_DIR/pods.json"
  local service_file="$WORK_DIR/service.json"

  kubectl --namespace "$NAMESPACE" get "deployment/$APP_NAME" -o json >"$deployment_file"
  kubectl --namespace "$NAMESPACE" get replicasets \
    -l "app.kubernetes.io/name=$APP_NAME,$RUN_LABEL" -o json >"$replicasets_file"
  kubectl --namespace "$NAMESPACE" get pods \
    -l "app.kubernetes.io/name=$APP_NAME,$RUN_LABEL" -o json >"$pods_file"
  kubectl --namespace "$NAMESPACE" get "service/$APP_NAME" -o json >"$service_file"
  python - "$deployment_file" "$replicasets_file" "$pods_file" "$service_file" \
    "$image" "$source" "$runtime_digest" "$APP_NAME" "$RUN_ID" <<'PY'
import json
from pathlib import Path
import re
import sys

deployment_path, replicasets_path, pods_path, service_path = map(Path, sys.argv[1:5])
image, source, runtime_digest, app_name, run_id = sys.argv[5:]
deployment = json.loads(deployment_path.read_text(encoding="utf-8"))
replicasets = json.loads(replicasets_path.read_text(encoding="utf-8"))["items"]
pods = json.loads(pods_path.read_text(encoding="utf-8"))["items"]
service = json.loads(service_path.read_text(encoding="utf-8"))
expected_digest = image.rsplit("@", 1)[1]

assert deployment["spec"]["replicas"] == 2
assert deployment["status"]["readyReplicas"] == 2
assert deployment["status"]["availableReplicas"] == 2
assert any(
    item["type"] == "Available" and item["status"] == "True"
    for item in deployment["status"]["conditions"]
)
template = deployment["spec"]["template"]["spec"]
assert template["automountServiceAccountToken"] is False
assert template["securityContext"] == {
    "runAsNonRoot": True,
    "runAsUser": 10001,
    "runAsGroup": 10001,
    "seccompProfile": {"type": "RuntimeDefault"},
}
container = template["containers"][0]
assert container["image"] == image
assert container["command"] == ["uvicorn"]
assert container["args"] == [
    "app.main:app",
    "--host",
    "0.0.0.0",
    "--port",
    "8000",
    "--workers",
    "1",
    "--log-level",
    "info",
    "--no-use-colors",
    "--log-config",
    "/etc/uvicorn/logging.json",
]
environment = {item["name"]: item for item in container["env"]}
assert environment["SOURCE_RELEASE"]["value"] == source
assert environment["IMAGE_REFERENCE"]["value"] == image
assert environment["DATABASE_URL"]["valueFrom"]["secretKeyRef"]["key"] == "url"
security = container["securityContext"]
assert security["runAsNonRoot"] is True
assert security["runAsUser"] == security["runAsGroup"] == 10001
assert security["allowPrivilegeEscalation"] is False
assert security["readOnlyRootFilesystem"] is True
assert security["capabilities"]["drop"] == ["ALL"]
assert container["ports"] == [{"containerPort": 8000, "name": "http", "protocol": "TCP"}]
assert container["readinessProbe"]["httpGet"]["path"] == "/health"
assert container["readinessProbe"]["httpGet"]["port"] == "http"
assert container["volumeMounts"] == [
    {"name": "tmp", "mountPath": "/tmp"},
    {"name": "logging", "mountPath": "/etc/uvicorn", "readOnly": True},
]
assert template["volumes"] == [
    {"name": "tmp", "emptyDir": {"medium": "Memory", "sizeLimit": "64Mi"}},
    {
        "name": "logging",
        "configMap": {
            "defaultMode": 420,
            "name": app_name,
            "items": [{"key": "logging.json", "path": "logging.json"}],
        },
    },
]

revision = deployment["metadata"]["annotations"]["deployment.kubernetes.io/revision"]
active = [item for item in replicasets if item["spec"].get("replicas", 0) == 2]
assert len(active) == 1
replicaset_revision = active[0]["metadata"]["annotations"]["deployment.kubernetes.io/revision"]
assert replicaset_revision == revision

assert len(pods) == 2
pod_names = []
image_ids = []
for pod in sorted(pods, key=lambda item: item["metadata"]["name"]):
    assert pod["metadata"]["labels"]["tutorial.sealos.io/run-id"] == run_id
    assert pod["status"]["phase"] == "Running"
    assert next(item for item in pod["status"]["conditions"] if item["type"] == "Ready")["status"] == "True"
    status = pod["status"]["containerStatuses"][0]
    assert status["ready"] is True
    match = re.search(r"sha256:[0-9a-f]{64}$", status["imageID"])
    assert match
    digest = match.group(0)
    assert digest in {expected_digest, runtime_digest}
    pod_names.append(pod["metadata"]["name"])
    image_ids.append(digest)

assert service["spec"]["selector"] == {
    "app.kubernetes.io/name": app_name,
    "tutorial.sealos.io/run-id": run_id,
}
assert service["spec"]["ports"][0]["port"] == 8000
assert service["spec"]["ports"][0]["targetPort"] == "http"
print(revision, replicaset_revision, ",".join(pod_names), ",".join(image_ids), sep="\t")
PY
}

verify_pod_process() {
  local pod_name="$1"

  kubectl --namespace "$NAMESPACE" exec -i "$pod_name" -- python - <<'PY'
from pathlib import Path

processes = []
for path in Path("/proc").iterdir():
    if not path.name.isdigit():
        continue
    try:
        argv = (path / "cmdline").read_bytes().split(b"\0")
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        continue
    decoded = [item.decode("utf-8", errors="replace") for item in argv if item]
    if "app.main:app" in decoded and any(item.endswith("/uvicorn") for item in decoded):
        processes.append((int(path.name), decoded))
assert len(processes) == 1, processes
pid, argv = processes[0]
assert pid == 1, processes
assert argv[argv.index("--host") + 1] == "0.0.0.0"
assert argv[argv.index("--port") + 1] == "8000"
assert argv[argv.index("--workers") + 1] == "1"
print("processes=1 pid1=true host=0.0.0.0 port=8000 workers=1")
PY
}

record_http_evidence() {
  local sequence="$1"
  local state="$2"
  local operation="$3"
  local task_file="$4"
  local disposable_create="$5"
  local disposable_update="$6"
  local disposable_delete="$7"
  local disposable_missing="$8"

  python - "$WORK_EVIDENCE/http.jsonl" "$sequence" "$state" "$operation" \
    "$task_file" "$disposable_create" "$disposable_update" \
    "$disposable_delete" "$disposable_missing" <<'PY'
import json
from pathlib import Path
import sys

output = Path(sys.argv[1])
sequence = int(sys.argv[2])
state, operation = sys.argv[3:5]
task = json.loads(Path(sys.argv[5]).read_text(encoding="utf-8"))

def status(value: str):
    return None if value == "null" else int(value)

record = {
    "sequence": sequence,
    "state": state,
    "health_status": 200,
    "docs_status": 200,
    "task_operation": operation,
    "task": task,
    "disposable_create_status": status(sys.argv[6]),
    "disposable_update_status": status(sys.argv[7]),
    "disposable_delete_status": status(sys.argv[8]),
    "disposable_missing_status": status(sys.argv[9]),
}
with output.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

verify_http_state() {
  local sequence="$1"
  local state="$2"
  local task_file="$WORK_DIR/task-$state.json"
  local health_file="$WORK_DIR/health-$state.json"
  local docs_file="$WORK_DIR/docs-$state.html"
  local disposable_file="$WORK_DIR/disposable-$state.json"
  local disposable_create=null
  local disposable_update=null
  local disposable_delete=null
  local disposable_missing=null
  local operation

  http_request GET /health "$health_file" 200
  jq -e '. == {"status":"ok"}' "$health_file" >/dev/null
  http_request GET /docs "$docs_file" 200
  grep -F 'Swagger UI' "$docs_file" >/dev/null || fail "docs page is missing Swagger UI"

  case "$state" in
    baseline)
      operation=create
      http_request POST /tasks "$task_file" 201 \
        '{"title":"Production continuity","completed":false}'
      PRIMARY_TASK_ID="$(jq -er '.id | select(type == "number")' "$task_file")"
      http_request POST /tasks "$disposable_file" 201 \
        '{"title":"Disposable production probe","completed":false}'
      DISPOSABLE_TASK_ID="$(jq -er '.id | select(type == "number")' "$disposable_file")"
      [[ "$DISPOSABLE_TASK_ID" != "$PRIMARY_TASK_ID" ]] || fail "task IDs must differ"
      disposable_create=201
      ;;
    final)
      operation=update
      http_request GET "/tasks/$PRIMARY_TASK_ID" "$task_file" 200
      jq -e --argjson id "$PRIMARY_TASK_ID" \
        '. == {"id":$id,"title":"Production continuity","completed":false}' \
        "$task_file" >/dev/null
      http_request PUT "/tasks/$PRIMARY_TASK_ID" "$task_file" 200 \
        '{"title":"Production continuity verified","completed":true}'
      http_request PUT "/tasks/$DISPOSABLE_TASK_ID" "$disposable_file" 200 \
        '{"title":"Disposable production probe verified","completed":true}'
      disposable_update=200
      ;;
    baseline-rollback)
      operation=read-after-undo
      http_request GET "/tasks/$PRIMARY_TASK_ID" "$task_file" 200
      ;;
    final-recovered)
      operation=read-after-recovery
      http_request GET "/tasks/$PRIMARY_TASK_ID" "$task_file" 200
      http_request DELETE "/tasks/$DISPOSABLE_TASK_ID" "$disposable_file" 204
      disposable_delete=204
      http_request GET "/tasks/$DISPOSABLE_TASK_ID" "$disposable_file" 404
      jq -e '. == {"detail":"Task not found"}' "$disposable_file" >/dev/null
      disposable_missing=404
      ;;
    *)
      fail "unsupported HTTP state: $state"
      ;;
  esac

  if [[ "$state" != baseline ]]; then
    jq -e --argjson id "$PRIMARY_TASK_ID" \
      '. == {"id":$id,"title":"Production continuity verified","completed":true}' \
      "$task_file" >/dev/null
  fi
  record_http_evidence "$sequence" "$state" "$operation" "$task_file" \
    "$disposable_create" "$disposable_update" "$disposable_delete" "$disposable_missing"
}

verify_release_state() {
  local sequence="$1"
  local state="$2"
  local transition="$3"
  local image="$4"
  local source="$5"
  local runtime_digest="$6"
  local cluster_record
  local deployment_revision
  local replicaset_revision
  local pod_names_csv
  local image_ids
  local pod_name
  local uid
  local gid
  local process_record
  local uids=()
  local gids=()
  local process_counts=()
  local matching_logs=0
  local rollout_undo=not-run
  local final_recovery=not-run
  local pod_log="$WORK_DIR/pod.log"

  cluster_record="$(collect_cluster_contract "$image" "$source" "$runtime_digest")"
  IFS=$'\t' read -r deployment_revision replicaset_revision pod_names_csv image_ids <<<"$cluster_record"
  IFS=',' read -r -a pod_names <<<"$pod_names_csv"
  [[ "${#pod_names[@]}" == "2" ]] || fail "$state did not expose two Pods"
  for pod_name in "${pod_names[@]}"; do
    uid="$(kubectl --namespace "$NAMESPACE" exec "$pod_name" -- id -u)"
    gid="$(kubectl --namespace "$NAMESPACE" exec "$pod_name" -- id -g)"
    [[ "$uid" == "10001" && "$gid" == "10001" ]] || fail "$state Pod identity drifted"
    process_record="$(verify_pod_process "$pod_name")"
    [[ "$process_record" == "processes=1 pid1=true host=0.0.0.0 port=8000 workers=1" ]] || fail "$state Pod process contract drifted"
    kubectl --namespace "$NAMESPACE" exec "$pod_name" -- sh -c \
      'if touch /app/.phase23-root-write 2>/dev/null; then rm -f /app/.phase23-root-write; exit 1; fi'
    kubectl --namespace "$NAMESPACE" exec "$pod_name" -- sh -c \
      'path=/tmp/.phase23-write; printf ok >"$path"; test "$(cat "$path")" = ok; rm "$path"; test ! -e "$path"'
    kubectl --namespace "$NAMESPACE" logs "$pod_name" --container app >"$pod_log"
    scan_file_for_credentials "$pod_log"
    grep -F "event=service_start source_release=$source image_reference=$image" "$pod_log" >/dev/null || fail "$state startup identity log is missing"
    matching_logs=$((matching_logs + 1))
    uids+=("$uid")
    gids+=("$gid")
    process_counts+=(1)
  done
  rm -f "$pod_log"

  start_application_port_forward
  verify_http_state "$sequence" "$state"
  case "$transition" in
    rollout-undo)
      rollout_undo=passed
      ;;
    explicit-final-apply)
      final_recovery=passed
      ;;
  esac
  evidence_append runtime.txt \
    "sequence=$sequence state=$state source=$source image=$image digest=${image##*@} deployment_revision=$deployment_revision replicaset_revision=$replicaset_revision ready=2 available=true pods=2 pod_image_ids=$image_ids uids=$(IFS=,; echo "${uids[*]}") gids=$(IFS=,; echo "${gids[*]}") process_counts=$(IFS=,; echo "${process_counts[*]}") pid1=true host=0.0.0.0 port=8000 workers=1 root_write=rejected tmp_write=passed read_only_root=true service_account_token=false seccomp=RuntimeDefault privilege_escalation=false capabilities=ALL-dropped"
  evidence_append logs.txt \
    "sequence=$sequence state=$state source=$source image=$image event=service_start matching_pods=$matching_logs total_pods=2"
  evidence_append rollback.txt \
    "sequence=$sequence state=$state transition=$transition source=$source image=$image deployment_revision=$deployment_revision task_id=$PRIMARY_TASK_ID status=passed rollout_undo=$rollout_undo final_recovery=$final_recovery"
}

run_production_sequence() {
  local baseline_manifest="$WORK_DIR/application-baseline.yaml"
  local final_manifest="$WORK_DIR/application-final.yaml"

  start_database_session
  render_application "$baseline_manifest" "$BASELINE_IMAGE" "$BASELINE_SOURCE"
  render_application "$final_manifest" "$FINAL_IMAGE" "$FINAL_SOURCE"
  render_migration_job "$WORK_DIR/migration-baseline.yaml" "$BASELINE_JOB_NAME" "$BASELINE_IMAGE"
  render_migration_job "$WORK_DIR/migration-final.yaml" "$FINAL_JOB_NAME" "$FINAL_IMAGE"

  run_migration_job 1 baseline "$BASELINE_JOB_NAME" "$BASELINE_IMAGE" "$BASELINE_SOURCE"
  apply_release baseline "$BASELINE_IMAGE" "$BASELINE_SOURCE"
  verify_release_state 1 baseline baseline-deploy \
    "$BASELINE_IMAGE" "$BASELINE_SOURCE" "$BASELINE_RUNTIME_DIGEST"

  run_migration_job 2 final "$FINAL_JOB_NAME" "$FINAL_IMAGE" "$FINAL_SOURCE"
  apply_release final "$FINAL_IMAGE" "$FINAL_SOURCE"
  verify_release_state 2 final final-apply \
    "$FINAL_IMAGE" "$FINAL_SOURCE" "$FINAL_RUNTIME_DIGEST"

  kubectl rollout undo --namespace "$NAMESPACE" "deployment/$APP_NAME" >/dev/null
  kubectl --namespace "$NAMESPACE" rollout status "deployment/$APP_NAME" \
    --timeout="${WAIT_SECONDS}s" >/dev/null
  verify_release_state 3 baseline-rollback rollout-undo \
    "$BASELINE_IMAGE" "$BASELINE_SOURCE" "$BASELINE_RUNTIME_DIGEST"

  kubectl --namespace "$NAMESPACE" apply -f "$final_manifest" >/dev/null
  kubectl --namespace "$NAMESPACE" rollout status "deployment/$APP_NAME" \
    --timeout="${WAIT_SECONDS}s" >/dev/null
  verify_release_state 4 final-recovered explicit-final-apply \
    "$FINAL_IMAGE" "$FINAL_SOURCE" "$FINAL_RUNTIME_DIGEST"
  RUN_SUCCEEDED=true
}

verify_evidence_semantics() {
  local directory="$1"
  local scope="$2"
  local checksum_policy="$3"
  local expected_checksum_count="$4"

  python - "$directory" "$scope" "$checksum_policy" "$expected_checksum_count" <<'PY'
from __future__ import annotations

from hashlib import sha256
import json
from pathlib import Path
import re
import shlex
import sys


root = Path(sys.argv[1]).expanduser().resolve()
scope = sys.argv[2]
checksum_policy = sys.argv[3]
expected_checksum_count = int(sys.argv[4])
live_names = [
    "workflow.txt",
    "images.txt",
    "migration.txt",
    "runtime.txt",
    "logs.txt",
    "http.jsonl",
    "rollback.txt",
    "cleanup.txt",
]
publication_names = [
    "workflow.txt",
    "images.txt",
    "migration.txt",
    "runtime.txt",
    "logs.txt",
    "http.jsonl",
    "rollback.txt",
    "publication.txt",
    "cleanup.txt",
]
data_names = live_names if scope == "live" else publication_names
if scope not in {"live", "publication"}:
    raise SystemExit(f"unsupported evidence scope: {scope}")
if not root.is_dir() or root.is_symlink():
    raise SystemExit("evidence directory must be a real directory")

entries = {item.name for item in root.iterdir()}
for item in root.iterdir():
    if item.is_symlink() or not item.is_file():
        raise SystemExit(f"unsafe evidence entry: {item.name}")
required = set(data_names)
if checksum_policy == "required":
    required.add("checksums.txt")
    if entries != required:
        raise SystemExit(f"evidence file set mismatch: {sorted(entries)}")
elif checksum_policy == "publication-preflight":
    allowed = required | {"checksums.txt"}
    if not required <= entries or not entries <= allowed:
        raise SystemExit(f"publication preflight file set mismatch: {sorted(entries)}")
elif checksum_policy == "skip":
    if entries != required:
        raise SystemExit(f"internal evidence file set mismatch: {sorted(entries)}")
else:
    raise SystemExit(f"unsupported checksum policy: {checksum_policy}")

for name in data_names:
    if not (root / name).read_bytes():
        raise SystemExit(f"{name}: evidence file is empty")

credential_patterns = {
    "credential-bearing PostgreSQL URL": re.compile(
        r"postgresql(?:\+psycopg)?://[^\s/:]+:[^\s@]+@", re.IGNORECASE
    ),
    "database URL assignment": re.compile(r"\b(?:DATABASE_URL|TEST_DATABASE_URL)\s*=", re.IGNORECASE),
    "password assignment": re.compile(r"\bpassword\s*=\s*[^\s]+", re.IGNORECASE),
    "GitHub token": re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"),
    "bearer token": re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{16,}", re.IGNORECASE),
    "Kubernetes token": re.compile(r"\beyJhbGciOiJ[A-Za-z0-9._-]+"),
    "registry authorization": re.compile(r'"auths"\s*:\s*\{', re.IGNORECASE),
    "raw kubeconfig": re.compile(r"(?:client-key-data|certificate-authority-data|current-context):"),
    "private key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
}
for name in data_names:
    text = (root / name).read_text(encoding="utf-8")
    for label, pattern in credential_patterns.items():
        if pattern.search(text):
            raise SystemExit(f"{name}: found {label}")


def parse_kv_file(name: str) -> list[dict[str, str]]:
    records: list[dict[str, str]] = []
    for line_number, line in enumerate(
        (root / name).read_text(encoding="utf-8").splitlines(), start=1
    ):
        if not line or line != line.strip():
            raise SystemExit(f"{name}:{line_number}: malformed line")
        record: dict[str, str] = {}
        for token in shlex.split(line):
            if "=" not in token:
                raise SystemExit(f"{name}:{line_number}: malformed field")
            key, value = token.split("=", 1)
            if not key or not value or key in record:
                raise SystemExit(f"{name}:{line_number}: duplicate or empty field")
            record[key] = value
        records.append(record)
    return records


def require_keys(name: str, records: list[dict[str, str]], keys: set[str]) -> None:
    for index, record in enumerate(records, start=1):
        if set(record) != keys:
            raise SystemExit(
                f"{name}:{index}: field set mismatch: {sorted(record)}"
            )


sha_pattern = re.compile(r"[0-9a-f]{40}")
digest_pattern = re.compile(r"sha256:[0-9a-f]{64}")
image_pattern = re.compile(
    r"ghcr\.io/yangchuansheng/sealos-fastapi-tutorial@sha256:[0-9a-f]{64}"
)
states = ["baseline", "final", "baseline-rollback", "final-recovered"]

images = parse_kv_file("images.txt")
require_keys(
    "images.txt",
    images,
    {
        "role",
        "source",
        "image",
        "tag",
        "digest",
        "runtime_digest",
        "architecture",
        "os",
        "revision",
        "source_label",
        "package",
    },
)
if [record["role"] for record in images] != ["baseline", "final"]:
    raise SystemExit("images.txt: role order mismatch")
image_by_role = {record["role"]: record for record in images}
for role, record in image_by_role.items():
    if not sha_pattern.fullmatch(record["source"]):
        raise SystemExit(f"images.txt: malformed {role} source")
    if not image_pattern.fullmatch(record["image"]):
        raise SystemExit(f"images.txt: malformed {role} image")
    if record["digest"] != record["image"].rsplit("@", 1)[1]:
        raise SystemExit(f"images.txt: {role} digest drift")
    if not digest_pattern.fullmatch(record["runtime_digest"]):
        raise SystemExit(f"images.txt: malformed {role} runtime digest")
    if record["tag"] != f"ghcr.io/yangchuansheng/sealos-fastapi-tutorial:sha-{record['source']}":
        raise SystemExit(f"images.txt: {role} tag drift")
    if record["revision"] != record["source"]:
        raise SystemExit(f"images.txt: {role} OCI revision drift")
    if record["source_label"] != "https://github.com/yangchuansheng/sealos-fastapi-tutorial":
        raise SystemExit(f"images.txt: {role} OCI source drift")
    if (record["architecture"], record["os"], record["package"]) != (
        "amd64",
        "linux",
        "public",
    ):
        raise SystemExit(f"images.txt: {role} public platform drift")
if images[0]["source"] == images[1]["source"] or images[0]["digest"] == images[1]["digest"]:
    raise SystemExit("images.txt: release identities must be distinct")

workflow = parse_kv_file("workflow.txt")
require_keys(
    "workflow.txt",
    workflow,
    {"role", "run_id", "event", "head_sha", "target_sha", "conclusion", "digest", "url"},
)
if [record["role"] for record in workflow] != ["baseline", "final"]:
    raise SystemExit("workflow.txt: role order mismatch")
if len({record["run_id"] for record in workflow}) != 2:
    raise SystemExit("workflow.txt: workflow run IDs must be distinct")
for record in workflow:
    role = record["role"]
    image = image_by_role[role]
    if not record["run_id"].isdigit():
        raise SystemExit("workflow.txt: malformed run ID")
    if record["event"] not in {"push", "workflow_dispatch"}:
        raise SystemExit("workflow.txt: unsupported event")
    if record["event"] == "push" and record["head_sha"] != image["source"]:
        raise SystemExit("workflow.txt: push head mismatch")
    if record["event"] == "workflow_dispatch" and record["head_sha"] != image_by_role["final"]["source"]:
        raise SystemExit("workflow.txt: dispatch head mismatch")
    if record["target_sha"] != image["source"] or record["digest"] != image["digest"]:
        raise SystemExit("workflow.txt: target or digest mismatch")
    if record["conclusion"] != "success":
        raise SystemExit("workflow.txt: workflow conclusion mismatch")
    if not re.fullmatch(r"https://github\.com/yangchuansheng/sealos-fastapi-tutorial/actions/runs/[0-9]+", record["url"]):
        raise SystemExit("workflow.txt: workflow URL mismatch")

migrations = parse_kv_file("migration.txt")
require_keys(
    "migration.txt",
    migrations,
    {"sequence", "role", "job", "source", "image", "digest", "condition", "status", "revision"},
)
if [(record["sequence"], record["role"]) for record in migrations] != [("1", "baseline"), ("2", "final")]:
    raise SystemExit("migration.txt: migration order mismatch")
for record in migrations:
    image = image_by_role[record["role"]]
    if (record["source"], record["image"], record["digest"]) != (
        image["source"],
        image["image"],
        image["digest"],
    ):
        raise SystemExit("migration.txt: release identity mismatch")
    if not re.fullmatch(r"tutorial-fastapi-pg-test-[a-z0-9]{12}-migration-(?:baseline|final)", record["job"]):
        raise SystemExit("migration.txt: Job ownership mismatch")
    if (record["condition"], record["status"], record["revision"]) != ("Complete", "True", "0001"):
        raise SystemExit("migration.txt: completion contract mismatch")

runtime = parse_kv_file("runtime.txt")
runtime_keys = {
    "sequence", "state", "source", "image", "digest", "deployment_revision",
    "replicaset_revision", "ready", "available", "pods", "pod_image_ids",
    "uids", "gids", "process_counts", "pid1", "host", "port", "workers",
    "root_write", "tmp_write", "read_only_root", "service_account_token",
    "seccomp", "privilege_escalation", "capabilities",
}
require_keys("runtime.txt", runtime, runtime_keys)
if [record["state"] for record in runtime] != states or [record["sequence"] for record in runtime] != ["1", "2", "3", "4"]:
    raise SystemExit("runtime.txt: state order mismatch")
runtime_by_state = {record["state"]: record for record in runtime}
expected_roles = ["baseline", "final", "baseline", "final"]
revisions: list[int] = []
for record, role in zip(runtime, expected_roles, strict=True):
    image = image_by_role[role]
    if (record["source"], record["image"], record["digest"]) != (
        image["source"], image["image"], image["digest"]
    ):
        raise SystemExit("runtime.txt: state identity mismatch")
    revisions.append(int(record["deployment_revision"]))
    if record["replicaset_revision"] != record["deployment_revision"]:
        raise SystemExit("runtime.txt: ReplicaSet revision mismatch")
    if record["pod_image_ids"].split(",") != [image["runtime_digest"], image["runtime_digest"]] and record["pod_image_ids"].split(",") != [image["digest"], image["digest"]]:
        raise SystemExit("runtime.txt: Pod imageID mismatch")
    expected_values = {
        "ready": "2", "available": "true", "pods": "2",
        "uids": "10001,10001", "gids": "10001,10001",
        "process_counts": "1,1", "pid1": "true", "host": "0.0.0.0",
        "port": "8000", "workers": "1", "root_write": "rejected",
        "tmp_write": "passed", "read_only_root": "true",
        "service_account_token": "false", "seccomp": "RuntimeDefault",
        "privilege_escalation": "false", "capabilities": "ALL-dropped",
    }
    if any(record[key] != value for key, value in expected_values.items()):
        raise SystemExit("runtime.txt: runtime hardening mismatch")
if revisions != sorted(set(revisions)):
    raise SystemExit("runtime.txt: controller revisions must increase")

logs = parse_kv_file("logs.txt")
require_keys(
    "logs.txt",
    logs,
    {"sequence", "state", "source", "image", "event", "matching_pods", "total_pods"},
)
if [record["state"] for record in logs] != states:
    raise SystemExit("logs.txt: state order mismatch")
for record, role in zip(logs, expected_roles, strict=True):
    image = image_by_role[role]
    if record["sequence"] != str(states.index(record["state"]) + 1):
        raise SystemExit("logs.txt: sequence mismatch")
    if (record["source"], record["image"]) != (image["source"], image["image"]):
        raise SystemExit("logs.txt: startup identity mismatch")
    if (record["event"], record["matching_pods"], record["total_pods"]) != ("service_start", "2", "2"):
        raise SystemExit("logs.txt: startup log count mismatch")

http_records = []
for line_number, line in enumerate((root / "http.jsonl").read_text(encoding="utf-8").splitlines(), start=1):
    try:
        record = json.loads(line)
    except json.JSONDecodeError as error:
        raise SystemExit(f"http.jsonl:{line_number}: malformed JSON") from error
    if not isinstance(record, dict):
        raise SystemExit(f"http.jsonl:{line_number}: record must be an object")
    http_records.append(record)
http_keys = {
    "sequence", "state", "health_status", "docs_status", "task_operation", "task",
    "disposable_create_status", "disposable_update_status", "disposable_delete_status",
    "disposable_missing_status",
}
if len(http_records) != 4 or any(set(record) != http_keys for record in http_records):
    raise SystemExit("http.jsonl: record count or fields mismatch")
if [record["state"] for record in http_records] != states or [record["sequence"] for record in http_records] != [1, 2, 3, 4]:
    raise SystemExit("http.jsonl: state order mismatch")
task_ids = []
for record in http_records:
    if (record["health_status"], record["docs_status"]) != (200, 200):
        raise SystemExit("http.jsonl: health or docs status mismatch")
    task = record["task"]
    if set(task) != {"id", "title", "completed"} or not isinstance(task["id"], int):
        raise SystemExit("http.jsonl: task payload mismatch")
    task_ids.append(task["id"])
if len(set(task_ids)) != 1:
    raise SystemExit("http.jsonl: persistent task ID changed")
if http_records[0]["task"] != {"id": task_ids[0], "title": "Production continuity", "completed": False}:
    raise SystemExit("http.jsonl: baseline task mismatch")
expected_updated = {"id": task_ids[0], "title": "Production continuity verified", "completed": True}
if any(record["task"] != expected_updated for record in http_records[1:]):
    raise SystemExit("http.jsonl: updated task did not persist")
if [record["task_operation"] for record in http_records] != [
    "create", "update", "read-after-undo", "read-after-recovery"
]:
    raise SystemExit("http.jsonl: task operation order mismatch")
status_columns = [
    [record["disposable_create_status"] for record in http_records],
    [record["disposable_update_status"] for record in http_records],
    [record["disposable_delete_status"] for record in http_records],
    [record["disposable_missing_status"] for record in http_records],
]
if status_columns != [[201, None, None, None], [None, 200, None, None], [None, None, None, 204], [None, None, None, 404]]:
    raise SystemExit("http.jsonl: disposable CRUD sequence mismatch")

rollback = parse_kv_file("rollback.txt")
require_keys(
    "rollback.txt",
    rollback,
    {
        "sequence", "state", "transition", "source", "image", "deployment_revision",
        "task_id", "status", "rollout_undo", "final_recovery",
    },
)
if [record["state"] for record in rollback] != states:
    raise SystemExit("rollback.txt: state order mismatch")
expected_transitions = ["baseline-deploy", "final-apply", "rollout-undo", "explicit-final-apply"]
for index, (record, role) in enumerate(zip(rollback, expected_roles, strict=True)):
    image = image_by_role[role]
    if record["sequence"] != str(index + 1) or record["transition"] != expected_transitions[index]:
        raise SystemExit("rollback.txt: transition order mismatch")
    if (record["source"], record["image"]) != (image["source"], image["image"]):
        raise SystemExit("rollback.txt: release identity mismatch")
    if record["deployment_revision"] != runtime[index]["deployment_revision"]:
        raise SystemExit("rollback.txt: controller revision mismatch")
    if record["task_id"] != str(task_ids[0]) or record["status"] != "passed":
        raise SystemExit("rollback.txt: task continuity mismatch")
    if record["rollout_undo"] != ("passed" if index == 2 else "not-run"):
        raise SystemExit("rollback.txt: rollout undo mismatch")
    if record["final_recovery"] != ("passed" if index == 3 else "not-run"):
        raise SystemExit("rollback.txt: final recovery mismatch")

cleanup = parse_kv_file("cleanup.txt")
expected_cleanup_count = 3 if scope == "live" else 4
if len(cleanup) != expected_cleanup_count:
    raise SystemExit("cleanup.txt: record count mismatch")
if set(cleanup[0]) != {"run_id", "selector"}:
    raise SystemExit("cleanup.txt: run identity fields mismatch")
run_id = cleanup[0]["run_id"]
if not re.fullmatch(r"[a-z0-9]{12}", run_id):
    raise SystemExit("cleanup.txt: malformed run ID")
if cleanup[0]["selector"] != f"tutorial.sealos.io/run-id={run_id}":
    raise SystemExit("cleanup.txt: selector mismatch")
for record in migrations:
    if not record["job"].startswith(f"tutorial-fastapi-pg-test-{run_id}-"):
        raise SystemExit("cleanup.txt: run identity does not match migration Jobs")
resource_keys = {"deployment", "replicaset", "pod", "service", "job", "secret", "configmap"}
if set(cleanup[1]) != resource_keys or any(value != "0" for value in cleanup[1].values()):
    raise SystemExit("cleanup.txt: Kubernetes inventory is not zero")
expected_local_cleanup = {
    "port_forward": "stopped", "owned_processes": "0", "state_file": "absent",
    "rendered_files": "0", "clone_directories": "0",
}
if cleanup[2] != expected_local_cleanup:
    raise SystemExit("cleanup.txt: local inventory is not zero")

if scope == "publication":
    publication = parse_kv_file("publication.txt")
    publication_order = [
        "public_repository", "public_stage_1", "public_stage_2", "public_stage_3",
        "public_ruleset", "public_package", "public_baseline_image_replay",
        "public_final_image_replay", "public_stage_1_clone", "public_stage_2_clone",
        "public_stage_3_clone",
    ]
    if len(publication) != len(publication_order):
        raise SystemExit("publication.txt: record count mismatch")
    for record, marker in zip(publication, publication_order, strict=True):
        if record.get(marker) != "passed":
            raise SystemExit(f"publication.txt: missing {marker}=passed")
    final_source = image_by_role["final"]["source"]
    if publication[0] != {
        "public_repository": "passed", "owner": "yangchuansheng", "visibility": "public",
        "default_branch": "main", "main": final_source,
    }:
        raise SystemExit("publication.txt: repository identity mismatch")
    expected_stages = [
        (
            "public_stage_1", "77e57a281ecc087041b54273c1bfc63b66f13d1a",
            "276aa00e4d5bb7a0d5e375fee530cde3240b2ce8", "FastAPI_deploy_stage",
        ),
        (
            "public_stage_2", "b61254c237885744ae85cb6f81386f77f1e3ac09",
            "2b256b3dfc2a7d2a4b930c9970becca8c6da8cd3", "FastAPI_PostgreSQL_stage",
        ),
    ]
    for record, (marker, direct, peeled, message) in zip(publication[1:3], expected_stages, strict=True):
        if record != {marker: "passed", "direct": direct, "peeled": peeled, "message": message}:
            raise SystemExit(f"publication.txt: {marker} identity mismatch")
    stage_three = publication[3]
    if set(stage_three) != {"public_stage_3", "direct", "peeled", "message"}:
        raise SystemExit("publication.txt: Stage 3 fields mismatch")
    if not sha_pattern.fullmatch(stage_three["direct"]) or stage_three["peeled"] != final_source or stage_three["message"] != "FastAPI_production_stage":
        raise SystemExit("publication.txt: Stage 3 identity mismatch")
    if publication[4] != {
        "public_ruleset": "passed", "id": "18970425", "target": "refs/tags/stage-*",
        "update": "protected", "deletion": "protected", "bypass": "0", "exclude": "0",
    }:
        raise SystemExit("publication.txt: ruleset mismatch")
    if publication[5] != {
        "public_package": "passed", "visibility": "public", "linked_repository": "sealos-fastapi-tutorial"
    }:
        raise SystemExit("publication.txt: package mismatch")
    for record, role, marker in (
        (publication[6], "baseline", "public_baseline_image_replay"),
        (publication[7], "final", "public_final_image_replay"),
    ):
        image = image_by_role[role]
        if record != {
            marker: "passed", "source": image["source"], "digest": image["digest"],
            "config": "passed", "manifest": "passed", "isolated": "passed",
        }:
            raise SystemExit(f"publication.txt: {role} image replay mismatch")
    expected_clones = [
        {
            "public_stage_1_clone": "passed", "commit": "276aa00e4d5bb7a0d5e375fee530cde3240b2ce8",
            "lock": "passed", "export": "passed", "tests": "passed",
        },
        {
            "public_stage_2_clone": "passed", "commit": "2b256b3dfc2a7d2a4b930c9970becca8c6da8cd3",
            "lock": "passed", "export": "passed",
        },
        {
            "public_stage_3_clone": "passed", "commit": final_source, "lock": "passed",
            "export": "passed", "static": "passed", "postgres": "passed", "cleanup": "passed",
        },
    ]
    if publication[8:] != expected_clones:
        raise SystemExit("publication.txt: public clone replay mismatch")
    if cleanup[3] != {
        "public_clone_cleanup": "passed", "clones": "0", "evidence_temp": "0",
        "registry_configs": "0", "database_resources": "0", "processes": "0",
        "state_files": "0", "rendered_files": "0",
    }:
        raise SystemExit("cleanup.txt: public clone cleanup mismatch")

if checksum_policy == "required":
    checksum_lines = (root / "checksums.txt").read_text(encoding="utf-8").splitlines()
    if len(checksum_lines) != expected_checksum_count or expected_checksum_count != len(data_names):
        raise SystemExit("checksums.txt: entry count mismatch")
    repository_root = None
    for candidate in [root, *root.parents]:
        if (candidate / ".git").exists():
            repository_root = candidate
            break
    if repository_root is None:
        raise SystemExit("checksums.txt: repository root is unavailable")
    evidence_relative = root.relative_to(repository_root)
    for line, name in zip(checksum_lines, data_names, strict=True):
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if match is None:
            raise SystemExit("checksums.txt: malformed entry")
        expected_path = (evidence_relative / name).as_posix()
        if match.group(2) != expected_path:
            raise SystemExit("checksums.txt: path drift")
        actual = sha256((root / name).read_bytes()).hexdigest()
        if match.group(1) != actual:
            raise SystemExit(f"checksums.txt: checksum mismatch for {name}")
PY
}

verify_live_evidence() {
  local expected_checksum_count=8
  verify_evidence_semantics "$EVIDENCE_DIR" live required "$expected_checksum_count"
  printf 'LIVE_EVIDENCE_OK directory=%s files=9 semantics=passed checksums=passed\n' "$EVIDENCE_DIR"
}

preflight_publication_evidence() {
  local expected_checksum_count=9
  verify_evidence_semantics "$EVIDENCE_DIR" publication publication-preflight "$expected_checksum_count"
  printf 'PUBLICATION_PREFLIGHT_OK directory=%s data_files=9 semantics=passed\n' "$EVIDENCE_DIR"
}

verify_publication_evidence() {
  local expected_checksum_count=9
  verify_evidence_semantics "$EVIDENCE_DIR" publication required "$expected_checksum_count"
  printf 'PUBLICATION_EVIDENCE_OK directory=%s files=10 semantics=passed checksums=passed\n' "$EVIDENCE_DIR"
}

generate_live_checksums() {
  python - "$EVIDENCE_DIR" <<'PY'
from hashlib import sha256
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
repository_root = next(
    (candidate for candidate in [root, *root.parents] if (candidate / ".git").exists()),
    None,
)
if repository_root is None:
    raise SystemExit("evidence directory must be inside a Git worktree")
relative = root.relative_to(repository_root)
names = (
    "workflow.txt", "images.txt", "migration.txt", "runtime.txt",
    "logs.txt", "http.jsonl", "rollback.txt", "cleanup.txt",
)
lines = [
    f"{sha256((root / name).read_bytes()).hexdigest()}  {(relative / name).as_posix()}"
    for name in names
]
temporary = root / ".checksums.tmp"
temporary.write_text("\n".join(lines) + "\n", encoding="utf-8")
temporary.replace(root / "checksums.txt")
PY
}

finalize_live_evidence() {
  local name

  verify_evidence_semantics "$WORK_EVIDENCE" live skip 8 || return 1
  [[ -d "$EVIDENCE_DIR" && ! -L "$EVIDENCE_DIR" ]] || return 1
  [[ -z "$(find "$EVIDENCE_DIR" -mindepth 1 -print -quit)" ]] || return 1
  for name in workflow.txt images.txt migration.txt runtime.txt logs.txt http.jsonl rollback.txt cleanup.txt; do
    cp "$WORK_EVIDENCE/$name" "$EVIDENCE_DIR/$name" || return 1
  done
  generate_live_checksums || return 1
  verify_live_evidence || return 1
}

set_mode() {
  [[ -z "$MODE" ]] || fail "execution mode was provided more than once"
  MODE="$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      set_mode run
      shift
      ;;
    --preflight-evidence)
      [[ $# -ge 2 ]] || fail "--preflight-evidence requires publication"
      set_mode preflight-evidence
      EVIDENCE_SCOPE="$2"
      shift 2
      ;;
    --verify-evidence)
      [[ $# -ge 2 ]] || fail "--verify-evidence requires live or publication"
      set_mode verify-evidence
      EVIDENCE_SCOPE="$2"
      shift 2
      ;;
    --baseline-image)
      [[ $# -ge 2 ]] || fail "--baseline-image requires a value"
      BASELINE_IMAGE="$2"
      shift 2
      ;;
    --baseline-source)
      [[ $# -ge 2 ]] || fail "--baseline-source requires a value"
      BASELINE_SOURCE="$2"
      shift 2
      ;;
    --final-image)
      [[ $# -ge 2 ]] || fail "--final-image requires a value"
      FINAL_IMAGE="$2"
      shift 2
      ;;
    --final-source)
      [[ $# -ge 2 ]] || fail "--final-source requires a value"
      FINAL_SOURCE="$2"
      shift 2
      ;;
    --evidence-dir)
      [[ $# -ge 2 ]] || fail "--evidence-dir requires a path"
      EVIDENCE_DIR="$2"
      shift 2
      ;;
    --help|-h)
      set_mode help
      shift
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

case "$MODE" in
  help)
    usage
    ;;
  verify-evidence)
    [[ -n "$EVIDENCE_DIR" ]] || fail "--verify-evidence requires --evidence-dir"
    EVIDENCE_DIR="$(cd "$EVIDENCE_DIR" && pwd -P)"
    case "$EVIDENCE_SCOPE" in
      live)
        verify_live_evidence
        ;;
      publication)
        verify_publication_evidence
        ;;
      *)
        fail "--verify-evidence scope must be live or publication"
        ;;
    esac
    ;;
  preflight-evidence)
    [[ "$EVIDENCE_SCOPE" == "publication" ]] || fail "--preflight-evidence scope must be publication"
    [[ -n "$EVIDENCE_DIR" ]] || fail "--preflight-evidence requires --evidence-dir"
    EVIDENCE_DIR="$(cd "$EVIDENCE_DIR" && pwd -P)"
    preflight_publication_evidence
    ;;
  run)
    [[ -n "$BASELINE_IMAGE" ]] || fail "--run requires --baseline-image"
    [[ -n "$BASELINE_SOURCE" ]] || fail "--run requires --baseline-source"
    [[ -n "$FINAL_IMAGE" ]] || fail "--run requires --final-image"
    [[ -n "$FINAL_SOURCE" ]] || fail "--run requires --final-source"
    [[ -n "$EVIDENCE_DIR" ]] || fail "--run requires --evidence-dir"
    validate_image "$BASELINE_IMAGE"
    validate_source "$BASELINE_SOURCE"
    validate_image "$FINAL_IMAGE"
    validate_source "$FINAL_SOURCE"
    [[ "$BASELINE_SOURCE" != "$FINAL_SOURCE" ]] || fail "release sources must differ"
    [[ "$BASELINE_IMAGE" != "$FINAL_IMAGE" ]] || fail "release images must differ"
    require_commands
    prepare_run_paths
    preflight_public_identity
    preflight_cluster
    run_production_sequence
    ;;
  "")
    fail "an execution mode is required"
    ;;
  *)
    fail "unsupported execution mode: $MODE"
    ;;
esac
