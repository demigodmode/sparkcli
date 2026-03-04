#!/usr/bin/env bash
# sparkcli — Ollama-style CLI for vLLM on DGX Spark
# https://github.com/demigodmode/sparkcli
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
CONFIG_FILE="${HOME}/.sparkcli/config.conf"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
MODELS_CONF="${SCRIPT_DIR}/models.conf"
DOCKER_ENV_CONF="${SCRIPT_DIR}/docker_env.conf"
CONTAINER_NAME=vllm

# ── Defaults (overridden by config) ───────────────────────────────────────────
SPARKCLI_HF_CACHE="${HOME}/.cache/huggingface"
SPARKCLI_VLLM_IMAGE=sparky-vllm:26.02
SPARKCLI_PORT=8000
SPARKCLI_GPU_UTIL=0.80
SPARKCLI_VLLM_BUILD_DIR=""

# Load user config
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# Expand ~ in paths from config
SPARKCLI_HF_CACHE="${SPARKCLI_HF_CACHE/#\~/$HOME}"

# ── Colors ────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; RESET=''
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
die()  { echo -e "${RED}Error:${RESET} $*" >&2; exit 1; }
info() { echo -e "${BLUE}→${RESET} $*"; }
ok()   { echo -e "${GREEN}✓${RESET} $*"; }
warn() { echo -e "${YELLOW}!${RESET} $*"; }

# Parse a model entry from models.conf.
# Outputs "model_id|max_len|extra_flags" (flags stripped of inline comments).
lookup_model() {
  local target="$1"
  while IFS='|' read -r id maxlen flags; do
    id="$(echo "$id" | xargs 2>/dev/null || echo "$id" | tr -d '[:space:]')"
    [[ -z "$id" || "$id" == \#* ]] && continue
    if [ "$id" = "$target" ]; then
      maxlen="$(echo "$maxlen" | xargs 2>/dev/null || echo "$maxlen" | tr -d '[:space:]')"
      # Strip inline comment from flags
      flags="$(echo "$flags" | sed 's/#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
      echo "${id}|${maxlen}|${flags}"
      return 0
    fi
  done < <(grep -v '^\s*#' "$MODELS_CONF" | grep -v '^\s*$')
}

# Look up model-specific docker env vars from docker_env.conf.
# Outputs space-separated KEY=VALUE pairs, or empty string if none.
lookup_docker_env() {
  local target="$1"
  [ -f "$DOCKER_ENV_CONF" ] || return 0
  while IFS='|' read -r id env_vars; do
    id="$(echo "$id" | xargs 2>/dev/null || echo "$id" | tr -d '[:space:]')"
    [[ -z "$id" || "$id" == \#* ]] && continue
    if [ "$id" = "$target" ]; then
      echo "$env_vars" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//'
      return 0
    fi
  done < <(grep -v '^\s*#' "$DOCKER_ENV_CONF" | grep -v '^\s*$')
}

# Get the inline comment (if any) for a model in models.conf.
model_comment() {
  local target="$1"
  while IFS='|' read -r id _maxlen flags; do
    id="$(echo "$id" | xargs 2>/dev/null || echo "$id" | tr -d '[:space:]')"
    [[ -z "$id" || "$id" == \#* ]] && continue
    if [ "$id" = "$target" ]; then
      if [[ "$flags" =~ \#(.+)$ ]]; then
        echo "${BASH_REMATCH[1]}" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//'
      fi
      return 0
    fi
  done < <(grep -v '^\s*#' "$MODELS_CONF" | grep -v '^\s*$')
}

# Convert model_id (org/name) to the HF hub cache directory name.
hf_dir_name() { echo "models--$(echo "$1" | sed 's|/|--|g')"; }

hf_model_path() { echo "${SPARKCLI_HF_CACHE}/hub/$(hf_dir_name "$1")"; }

is_downloaded() { [ -d "$(hf_model_path "$1")" ]; }

container_running() {
  docker ps --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' 2>/dev/null \
    | grep -q "^${CONTAINER_NAME}$"
}

container_exists() {
  docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' 2>/dev/null \
    | grep -q "^${CONTAINER_NAME}$"
}

get_running_model() {
  docker inspect "$CONTAINER_NAME" \
    --format '{{index .Config.Labels "sparkcli_model"}}' 2>/dev/null || true
}

stop_container() {
  if container_running; then
    info "Stopping existing vLLM container..."
    docker stop "$CONTAINER_NAME" >/dev/null
  fi
  if container_exists; then
    docker rm "$CONTAINER_NAME" >/dev/null
  fi
}

wait_for_ready() {
  local max_wait=300
  local elapsed=0
  local interval=5
  info "Waiting for vLLM to be ready on port ${SPARKCLI_PORT}..."
  printf "  "
  while [ "$elapsed" -lt "$max_wait" ]; do
    if curl -sf "http://localhost:${SPARKCLI_PORT}/v1/models" >/dev/null 2>&1; then
      echo ""
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
    printf '.'
  done
  echo ""
  die "Timed out waiting for vLLM to start. Run 'sparkcli logs' to investigate."
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_pull() {
  local model_id="${1:-}"
  [ -n "$model_id" ] || die "Usage: sparkcli pull <model_id>"

  local entry
  entry="$(lookup_model "$model_id")" || true
  [ -n "$entry" ] || die "'${model_id}' is not in models.conf.
Add it to models.conf with correct flags before pulling.
Use 'sparkcli ls' to see registered models."

  info "Pulling ${model_id} into ${SPARKCLI_HF_CACHE}..."

  local hf_token_args=()
  local token="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
  [ -n "$token" ] && hf_token_args=(-e "HUGGING_FACE_HUB_TOKEN=${token}")

  docker run --rm \
    -v "${SPARKCLI_HF_CACHE}:/root/.cache/huggingface" \
    "${hf_token_args[@]+"${hf_token_args[@]}"}" \
    "$SPARKCLI_VLLM_IMAGE" \
    huggingface-cli download "$model_id"

  local model_path size
  model_path="$(hf_model_path "$model_id")"
  size="$(du -sh "$model_path" 2>/dev/null | cut -f1 || echo "unknown")"
  ok "Downloaded ${model_id} (${size})"
}

cmd_rm() {
  local model_id=""
  local force=false
  for arg in "$@"; do
    case "$arg" in
      --yes|-y) force=true ;;
      *) [ -z "$model_id" ] && model_id="$arg" ;;
    esac
  done
  [ -n "$model_id" ] || die "Usage: sparkcli rm <model_id> [--yes]"

  local entry
  entry="$(lookup_model "$model_id")" || true
  [ -n "$entry" ] || die "'${model_id}' is not in models.conf."

  is_downloaded "$model_id" || die "'${model_id}' is not downloaded."

  local model_path size
  model_path="$(hf_model_path "$model_id")"
  size="$(du -sh "$model_path" 2>/dev/null | cut -f1 || echo "unknown")"

  if ! $force; then
    echo -n "Remove ${model_id} (${size})? [y/N] "
    read -r confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  fi

  sudo rm -rf "$model_path"
  ok "Removed ${model_id} (freed ~${size})"
}

cmd_run() {
  local model_id="${1:-}"
  [ -n "$model_id" ] || die "Usage: sparkcli run <model_id>"

  local entry
  entry="$(lookup_model "$model_id")" || true
  [ -n "$entry" ] || die "'${model_id}' is not in models.conf.
Add it to models.conf with correct flags before running.
Use 'sparkcli ls' to see registered models."

  local max_model_len extra_flags
  IFS='|' read -r _ max_model_len extra_flags <<< "$entry"

  local docker_env
  docker_env="$(lookup_docker_env "$model_id")"

  if ! is_downloaded "$model_id"; then
    warn "Model not in cache. Pulling first..."
    cmd_pull "$model_id"
    echo ""
  fi

  stop_container

  info "Starting vLLM with ${model_id}..."

  # Build docker run args as array for safe word splitting
  local docker_args=(
    run -d
    --name "$CONTAINER_NAME"
    --restart always
    --runtime nvidia
    # --ipc host removed: not needed on single GB10; add back if multi-node NCCL ever becomes relevant
    --gpus all
    -v "${SPARKCLI_HF_CACHE}:/root/.cache/huggingface"
    -p "${SPARKCLI_PORT}:8000"
    --label "sparkcli_model=${model_id}"
    "$SPARKCLI_VLLM_IMAGE"
    python3 -m vllm.entrypoints.openai.api_server
    --model "$model_id"
    --max-model-len "$max_model_len"
    --host 0.0.0.0
    --enforce-eager
    --no-async-scheduling
    --gpu-memory-utilization "${SPARKCLI_GPU_UTIL}"
    --port 8000
  )

  # Inject model-specific docker env vars from docker_env.conf
  if [ -n "$docker_env" ]; then
    local env_arr=()
    read -ra env_arr <<< "$docker_env"
    for env_var in "${env_arr[@]}"; do
      docker_args+=(-e "$env_var")
    done
  fi

  # Append extra flags from models.conf (safe array expansion)
  if [ -n "$extra_flags" ]; then
    local extra_arr=()
    read -ra extra_arr <<< "$extra_flags"
    docker_args+=("${extra_arr[@]}")
  fi

  docker "${docker_args[@]}"

  wait_for_ready
  ok "Serving ${model_id} on http://localhost:${SPARKCLI_PORT}"
}

cmd_ls() {
  local running_model
  running_model="$(get_running_model)"

  printf "${BOLD}%-44s %-12s %s${RESET}\n" "MODEL" "DOWNLOADED" "RUNNING"
  printf "%-44s %-12s %s\n" \
    "--------------------------------------------" \
    "------------" \
    "----------"

  while IFS='|' read -r id _maxlen flags; do
    id="$(echo "$id" | xargs 2>/dev/null || echo "$id" | tr -d '[:space:]')"
    [[ -z "$id" || "$id" == \#* ]] && continue

    # Extract inline comment from flags column
    local comment=""
    if [[ "$flags" =~ \#(.+)$ ]]; then
      comment="$(echo "${BASH_REMATCH[1]}" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
    fi

    local downloaded_s="no"
    is_downloaded "$id" && downloaded_s="yes"

    local running_s="—"
    if [ "$id" = "$running_model" ]; then
      running_s="${GREEN}✓ (active)${RESET}"
    elif [ -n "$comment" ]; then
      running_s="— (${comment})"
    fi

    printf "%-44s %-12s " "$id" "$downloaded_s"
    echo -e "$running_s"
  done < <(grep -v '^\s*#' "$MODELS_CONF" | grep -v '^\s*$')
}

cmd_status() {
  local model_only=false
  for arg in "$@"; do
    [ "$arg" = "--model-only" ] && model_only=true
  done

  if ! container_running 2>/dev/null; then
    $model_only && exit 1
    echo "No vLLM container running."
    exit 0
  fi

  local model
  model="$(get_running_model)"

  if $model_only; then
    echo "$model"
    exit 0
  fi

  local started health_s
  started="$(docker inspect "$CONTAINER_NAME" --format '{{.State.StartedAt}}' 2>/dev/null \
    | xargs -I{} date -d {} '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")"

  if curl -sf "http://localhost:${SPARKCLI_PORT}/v1/models" >/dev/null 2>&1; then
    health_s="${GREEN}healthy${RESET}"
  else
    health_s="${RED}unhealthy${RESET}"
  fi

  echo -e "${BOLD}vLLM Status${RESET}"
  printf "  %-10s %s\n" "Model:"   "$model"
  printf "  %-10s %s\n" "Port:"    "$SPARKCLI_PORT"
  printf "  %-10s " "Health:"
  echo -e "$health_s"
  printf "  %-10s %s\n" "Started:" "$started"
}

cmd_stop() {
  if ! container_running 2>/dev/null && ! container_exists 2>/dev/null; then
    echo "No vLLM container running."
    exit 0
  fi
  info "Stopping vLLM..."
  stop_container
  ok "Stopped."
}

cmd_logs() {
  local follow=false
  for arg in "$@"; do
    [[ "$arg" = "-f" || "$arg" = "--follow" ]] && follow=true
  done

  container_exists 2>/dev/null || die "No vLLM container found."

  if $follow; then
    docker logs -f "$CONTAINER_NAME"
  else
    docker logs "$CONTAINER_NAME"
  fi
}

cmd_update() {
  [ -n "$SPARKCLI_VLLM_BUILD_DIR" ] || die "SPARKCLI_VLLM_BUILD_DIR is not set.
Set it in ~/.sparkcli/config.conf to point at your vLLM Dockerfile directory."
  local vllm_dir="${SPARKCLI_VLLM_BUILD_DIR/#\~/$HOME}"
  [ -d "$vllm_dir" ] || die "vLLM build directory not found: ${vllm_dir}"

  # Capture running model before rebuild
  local current_model=""
  if container_running 2>/dev/null; then
    current_model="$(get_running_model)"
    [ -n "$current_model" ] && info "Current model: ${current_model}"
  fi

  info "Rebuilding ${SPARKCLI_VLLM_IMAGE} from ${vllm_dir} (--no-cache)..."
  docker build --no-cache -t "$SPARKCLI_VLLM_IMAGE" "$vllm_dir"
  ok "Image rebuilt: ${SPARKCLI_VLLM_IMAGE}"

  if [ -n "$current_model" ]; then
    info "Restarting with ${current_model}..."
    cmd_run "$current_model"
  else
    ok "No model was running. Use 'sparkcli run <model>' to start."
  fi
}

cmd_info() {
  local model_id="${1:-}"
  [ -n "$model_id" ] || die "Usage: sparkcli info <model_id>"

  local entry
  entry="$(lookup_model "$model_id")" || true
  [ -n "$entry" ] || die "'${model_id}' is not in models.conf."

  local max_model_len extra_flags
  IFS='|' read -r _ max_model_len extra_flags <<< "$entry"

  local comment
  comment="$(model_comment "$model_id")"

  local docker_env
  docker_env="$(lookup_docker_env "$model_id")"

  echo -e "${BOLD}${model_id}${RESET}"
  [ -n "$comment" ] && echo "  Note:          ${YELLOW}${comment}${RESET}"
  printf "  %-16s %s\n" "Max context:"  "${max_model_len} tokens"
  printf "  %-16s %s\n" "Extra flags:"  "$extra_flags"
  printf "  %-16s %s\n" "Base flags:"   "--host 0.0.0.0 --enforce-eager --no-async-scheduling --gpu-memory-utilization ${SPARKCLI_GPU_UTIL}"
  [ -n "$docker_env" ] && printf "  %-16s %s\n" "Docker env:"   "$docker_env"

  local model_path
  model_path="$(hf_model_path "$model_id")"
  if is_downloaded "$model_id"; then
    local size
    size="$(du -sh "$model_path" 2>/dev/null | cut -f1 || echo "unknown")"
    printf "  %-16s " "Downloaded:"
    echo -e "${GREEN}yes${RESET} (${size}, ${model_path})"
  else
    printf "  %-16s " "Downloaded:"
    echo -e "${RED}no${RESET}"
  fi

  local running_model
  running_model="$(get_running_model)"
  printf "  %-16s " "Running:"
  if [ "$model_id" = "$running_model" ]; then
    echo -e "${GREEN}yes (active on port ${SPARKCLI_PORT})${RESET}"
  else
    echo "no"
  fi
}

cmd_doctor() {
  local pass="${GREEN}PASS${RESET}"
  local fail="${RED}FAIL${RESET}"
  local warn_s="${YELLOW}WARN${RESET}"
  local all_pass=true

  check() {
    local label="$1" result="$2" suggestion="${3:-}"
    printf "  %-48s " "$label"
    if [ "$result" = "pass" ]; then
      echo -e "[$pass]"
    elif [ "$result" = "warn" ]; then
      echo -e "[$warn_s]${suggestion:+  → $suggestion}"
    else
      echo -e "[$fail]${suggestion:+  → $suggestion}"
      all_pass=false
    fi
  }

  echo -e "${BOLD}sparkcli doctor${RESET}"
  echo ""

  # Docker daemon
  if docker info >/dev/null 2>&1; then
    check "Docker daemon running" pass
  else
    check "Docker daemon running" fail "sudo systemctl start docker"
  fi

  # NVIDIA runtime
  if docker info 2>/dev/null | grep -qi nvidia; then
    check "NVIDIA runtime registered" pass
  else
    check "NVIDIA runtime registered" fail "Install nvidia-container-toolkit and configure Docker"
  fi

  # vLLM image present
  if docker image inspect "$SPARKCLI_VLLM_IMAGE" >/dev/null 2>&1; then
    check "vLLM image present (${SPARKCLI_VLLM_IMAGE})" pass
  else
    check "vLLM image present (${SPARKCLI_VLLM_IMAGE})" fail "Run 'sparkcli update' or build manually"
  fi

  # HF cache directory
  if [ -d "$SPARKCLI_HF_CACHE" ]; then
    check "HF cache dir exists (${SPARKCLI_HF_CACHE})" pass
  else
    check "HF cache dir exists (${SPARKCLI_HF_CACHE})" warn "mkdir -p ${SPARKCLI_HF_CACHE}"
  fi

  # Port availability
  local port_in_use=""
  port_in_use="$(ss -tlnp "sport = :${SPARKCLI_PORT}" 2>/dev/null | grep -c "LISTEN" || true)"
  if [ "${port_in_use:-0}" -eq 0 ]; then
    check "Port ${SPARKCLI_PORT} available" pass
  elif container_running 2>/dev/null; then
    check "Port ${SPARKCLI_PORT} (in use by vLLM)" pass
  else
    check "Port ${SPARKCLI_PORT} available" warn \
      "Port in use by another process"
  fi

  # Config file
  if [ -f "$CONFIG_FILE" ]; then
    check "~/.sparkcli/config.conf present" pass
  else
    check "~/.sparkcli/config.conf present" warn \
      "cp ${SCRIPT_DIR}/config.conf.example ${CONFIG_FILE}"
  fi

  # models.conf present
  if [ -f "$MODELS_CONF" ]; then
    check "models.conf present" pass
  else
    check "models.conf present" fail "models.conf not found at ${MODELS_CONF}"
  fi

  echo ""
  if $all_pass; then
    ok "All checks passed. Ready to run."
  else
    warn "Some checks failed — review the suggestions above."
  fi
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${BOLD}sparkcli${RESET} — Ollama-style CLI for vLLM on DGX Spark

${BOLD}Usage:${RESET}
  sparkcli pull <model_id>       Download a model from HuggingFace
  sparkcli run  <model_id>       Switch vLLM to serve the specified model
  sparkcli rm   <model_id>       Remove a downloaded model [--yes to skip confirm]
  sparkcli ls                    List registered models: download status + running
  sparkcli status                Show running model, health, port, uptime
  sparkcli stop                  Stop the vLLM container
  sparkcli logs [-f]             Show vLLM container logs (optionally follow)
  sparkcli update                Rebuild vLLM Docker image, restart current model
  sparkcli info  <model_id>      Show model details, flags, disk usage
  sparkcli doctor                Pre-flight checks: Docker, GPU, image, config

${BOLD}Config:${RESET}  ~/.sparkcli/config.conf
${BOLD}Models:${RESET}  ${MODELS_CONF}
EOF
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
COMMAND="${1:-}"
shift || true

case "$COMMAND" in
  pull)        cmd_pull   "$@" ;;
  rm|remove)   cmd_rm     "$@" ;;
  run)         cmd_run    "$@" ;;
  ls|list)     cmd_ls     "$@" ;;
  status)      cmd_status "$@" ;;
  stop)        cmd_stop   "$@" ;;
  logs)        cmd_logs   "$@" ;;
  update)      cmd_update "$@" ;;
  info)        cmd_info   "$@" ;;
  doctor)      cmd_doctor "$@" ;;
  help|--help|-h|"") usage ;;
  *) die "Unknown command: '${COMMAND}'\nRun 'sparkcli help' for usage." ;;
esac
