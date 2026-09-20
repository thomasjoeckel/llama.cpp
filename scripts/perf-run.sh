#!/usr/bin/env bash
set -Eeuo pipefail

# Reproducible local llama.cpp performance run.
#
# Produces exactly three tracked files per run:
#   benchmarks/runs/<UTC-timestamp>/server.log
#   benchmarks/runs/<UTC-timestamp>/meta.json
#   benchmarks/runs/<UTC-timestamp>/performance.json
#
# With PUSH_RESULTS=1 the three files are committed and pushed automatically.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ============================================================
# SERVER VARIABLES
# ============================================================

SERVER_BIN="${SERVER_BIN:-${REPO_ROOT}/build/bin/llama-server}"
MODEL="${MODEL:-/opt/models/Qwen3.8-Flash-Next/UD-Q3_K_XL/Qwen3.8-Flash-Next-UD-Q3_K_XL-00001-of-00003.gguf}"
MTP_MODEL="${MTP_MODEL:-/opt/models/Qwen3.8-Flash-Next/MTP/mtp-Qwen3.8-Flash-Next-Q4_K_M.gguf}"

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8080}"

NGL="${NGL:-all}"
THREADS="${THREADS:-12}"
THREADS_BATCH="${THREADS_BATCH:-12}"
CTX="${CTX:-65536}"
BATCH="${BATCH:-4096}"
UBATCH="${UBATCH:-256}"
EXPERT_CACHE="${EXPERT_CACHE:-152}"
MTP_N_MAX="${MTP_N_MAX:-2}"
NO_HOST="${NO_HOST:-0}"
POLL="${POLL:-}"

POLL_SECONDS="${POLL_SECONDS:-2}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"
KEEP_SERVER="${KEEP_SERVER:-0}"
PUSH_RESULTS="${PUSH_RESULTS:-0}"
GIT_REMOTE="${GIT_REMOTE:-github-fork}"
GIT_BRANCH="${GIT_BRANCH:-}"


# ============================================================
# REQUEST VARIABLES
# ============================================================

TEMPERATURE="${TEMPERATURE:-0.0}"
TOP_P="${TOP_P:-1.0}"
MIN_P="${MIN_P:-0.0}"
PRESENCE_PENALTY="${PRESENCE_PENALTY:-0.0}"
FREQUENCY_PENALTY="${FREQUENCY_PENALTY:-0.0}"
SEED="${SEED:-12345}"

CACHE_PROMPT="${CACHE_PROMPT:-false}"
STREAM="${STREAM:-false}"
MAX_TOKENS="${MAX_TOKENS:-1024}"

USER_PROMPT="${USER_PROMPT:-Act as the release operator. First reason through the deployment hazards, dependencies, and rollback criteria. Then explicitly finish reasoning and produce a final executable rollout plan dominated by shell commands and configuration snippets. Deploy the payments API to the blue canary pool, hold traffic at ten percent, verify latency and error budgets, and publish a signed go-or-rollback decision. Keep the reasoning brief enough to leave most of the response budget for the final plan.
Include concrete scripts with error handling, configuration examples, and verification commands rather than only prose.}"


# ============================================================
# RUN STATE
# ============================================================

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RUN_DIR="${REPO_ROOT}/benchmarks/runs/${RUN_ID}"
SERVER_LOG="${RUN_DIR}/server.log"
META_JSON="${RUN_DIR}/meta.json"
PERF_JSON="${RUN_DIR}/performance.json"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""
TEE_PID=""
LOG_FIFO=""

cleanup() {
    local rc=$?

    if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
        if [[ "${KEEP_SERVER}" == "1" ]]; then
            echo "Keeping llama-server (PID ${SERVER_PID})."
        else
            kill "${SERVER_PID}" 2>/dev/null || true
            for _ in {1..40}; do
                if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
                    break
                fi
                sleep 0.25
            done
            if kill -0 "${SERVER_PID}" 2>/dev/null; then
                echo "llama-server did not exit cleanly; sending SIGKILL." >&2
                kill -9 "${SERVER_PID}" 2>/dev/null || true
            fi
            wait "${SERVER_PID}" 2>/dev/null || true
        fi
    fi

    if [[ -n "${TEE_PID}" ]]; then
        wait "${TEE_PID}" 2>/dev/null || true
    fi

    [[ -z "${LOG_FIFO}" ]] || rm -f "${LOG_FIFO}"
    rm -rf "${TMP_DIR}"
    exit "${rc}"
}
trap cleanup EXIT INT TERM

die() {
    echo "ERROR: $*" >&2
    exit 1
}

command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required"
command -v git >/dev/null || die "git is required"
[[ -x "${SERVER_BIN}" ]] || die "llama-server not found/executable: ${SERVER_BIN}"

mkdir -p "${RUN_DIR}"

REQUEST_JSON="$(jq -n \
    --arg content "${USER_PROMPT}" \
    --argjson temperature "${TEMPERATURE}" \
    --argjson top_p "${TOP_P}" \
    --argjson min_p "${MIN_P}" \
    --argjson presence_penalty "${PRESENCE_PENALTY}" \
    --argjson frequency_penalty "${FREQUENCY_PENALTY}" \
    --argjson seed "${SEED}" \
    --argjson cache_prompt "${CACHE_PROMPT}" \
    --argjson stream "${STREAM}" \
    --argjson max_tokens "${MAX_TOKENS}" \
    '{
      temperature: $temperature,
      top_p: $top_p,
      min_p: $min_p,
      presence_penalty: $presence_penalty,
      frequency_penalty: $frequency_penalty,
      seed: $seed,
      cache_prompt: $cache_prompt,
      stream: $stream,
      max_tokens: $max_tokens,
      messages: [{
        role: "user",
        content: $content
      }]
    }')"

START_EPOCH_NS="$(date +%s%N)"
GIT_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
GIT_BRANCH_CURRENT="$(git -C "${REPO_ROOT}" branch --show-current)"

cat > "${META_JSON}" <<EOF
{
  "run_id": "${RUN_ID}",
  "started_at_utc": "$(date -u --iso-8601=seconds)",
  "host": "$(hostname)",
  "repo_root": "${REPO_ROOT}",
  "git_branch": "${GIT_BRANCH_CURRENT}",
  "git_commit": "${GIT_COMMIT}",
  "server_bin": "${SERVER_BIN}",
  "model": "${MODEL}",
  "mtp_model": "${MTP_MODEL}",
  "host_address": "${HOST}",
  "port": ${PORT},
  "ctx": ${CTX},
  "batch": ${BATCH},
  "ubatch": ${UBATCH},
  "threads": ${THREADS},
  "threads_batch": ${THREADS_BATCH},
  "ngl": "${NGL}",
  "expert_cache": ${EXPERT_CACHE},
  "mtp_n_max": ${MTP_N_MAX},
  "no_host": ${NO_HOST},
  "poll": "${POLL}",
  "max_tokens": ${MAX_TOKENS},
  "temperature": ${TEMPERATURE},
  "seed": ${SEED},
  "cuda_visible_devices": "${CUDA_VISIBLE_DEVICES:-}",
  "ggml_cuda_moe_early_router": "${GGML_CUDA_MOE_EARLY_ROUTER:-}",
  "ggml_cuda_moe_early_router_lookahead": "${GGML_CUDA_MOE_EARLY_ROUTER_LOOKAHEAD:-}",
  "trace_sched_sync_sites": "${GGML_TRACE_SCHED_SYNC_SITES:-0}",
  "trace_backend_sync": "${GGML_TRACE_BACKEND_SYNC:-0}"
}
EOF

SERVER_ARGS=(
    --offline
    --model "${MODEL}"
    --spec-type draft-mtp
    --spec-draft-model "${MTP_MODEL}"
    --spec-draft-n-max "${MTP_N_MAX}"
    --spec-draft-ubatch-size "${UBATCH}"
    -c "${CTX}"
    -b "${BATCH}"
    -ub "${UBATCH}"
    -np 1
    -t "${THREADS}"
    -tb "${THREADS_BATCH}"
    -ngl "${NGL}"
    -fa on
    -fit off
    --load-mode none
    --lazy-mode on
    --moe-expert-cache-size "${EXPERT_CACHE}"
    -ctk q4_0
    -ctv q4_0
    -kvo
    --cache-ram 0
    --jinja
    --no-warmup
    --backend-sampling
    --decode-overlap
    --decode-boundary-overlap
    --ple-prefetch
    --phase-aware-workspace
    --live-context-workspace
    --experimental-logs
    --host "${HOST}"
    --port "${PORT}"
)

if [[ "${NO_HOST}" == "1" ]]; then
    SERVER_ARGS+=(--no-host)
fi

if [[ -n "${POLL}" ]]; then
    SERVER_ARGS+=(--poll "${POLL}")
fi

echo "Starting llama-server..."
echo "Run directory: ${RUN_DIR}"
echo "Server log:    ${SERVER_LOG}"

LOG_FIFO="${TMP_DIR}/server.log.pipe"
mkfifo "${LOG_FIFO}"

# Keep tee as an explicit child process so log capture has a PID we can wait for.
tee "${SERVER_LOG}" < "${LOG_FIFO}" &
TEE_PID=$!

"${SERVER_BIN}" "${SERVER_ARGS[@]}" > "${LOG_FIFO}" 2>&1 &
SERVER_PID=$!

HEALTH_URL="http://${HOST}:${PORT}/health"
DEADLINE=$((SECONDS + HEALTH_TIMEOUT))
until curl -fsS "${HEALTH_URL}" >/dev/null 2>&1; do
    if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
        echo "llama-server exited during startup." >&2
        tail -n 100 "${SERVER_LOG}" >&2 || true
        exit 1
    fi
    if (( SECONDS >= DEADLINE )); then
        echo "Timed out waiting for ${HEALTH_URL}" >&2
        tail -n 100 "${SERVER_LOG}" >&2 || true
        exit 1
    fi
    sleep "${POLL_SECONDS}"
done

HEALTH_READY_AT="$(date -u --iso-8601=seconds)"
echo "Server ready: ${HEALTH_READY_AT}"

REQUEST_START_NS="$(date +%s%N)"
HTTP_CODE="$(
    curl -sS -o "${TMP_DIR}/response.json" -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        --data "${REQUEST_JSON}" \
        "http://${HOST}:${PORT}/v1/chat/completions"
)"
REQUEST_END_NS="$(date +%s%N)"

if [[ "${HTTP_CODE}" != "200" ]]; then
    echo "Request failed with HTTP ${HTTP_CODE}" >&2
    cat "${TMP_DIR}/response.json" >&2 || true
    exit 1
fi

sleep 1

# Stop the server before parsing the log so the file is closed and no more
# diagnostic output can race with the parser.
if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null && [[ "${KEEP_SERVER}" != "1" ]]; then
    echo "Stopping llama-server..."
    kill "${SERVER_PID}" 2>/dev/null || true
    for _ in {1..40}; do
        if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
            break
        fi
        sleep 0.25
    done
    if kill -0 "${SERVER_PID}" 2>/dev/null; then
        echo "llama-server did not exit cleanly; sending SIGKILL." >&2
        kill -9 "${SERVER_PID}" 2>/dev/null || true
    fi
    wait "${SERVER_PID}" 2>/dev/null || true
    SERVER_PID=""

    # The server closed the FIFO writer, so tee receives EOF and exits cleanly.
    if [[ -n "${TEE_PID}" ]]; then
        wait "${TEE_PID}" 2>/dev/null || true
        echo "Log capture stopped."
        TEE_PID=""
    fi
fi

python3 - "${SERVER_LOG}" "${TMP_DIR}/server_timing.json" <<'PY'
import json
import re
import sys

log_path, out_path = sys.argv[1:3]

patterns = {
    "prompt_eval_ms": re.compile(r"prompt eval time\s*=\s*([0-9.]+) ms"),
    "prompt_tokens": re.compile(r"prompt eval time\s*=\s*[0-9.]+ ms /\s*([0-9]+) tokens"),
    "prompt_tok_s": re.compile(r"prompt eval time.*?([0-9.]+) tokens per second"),
    "eval_ms": re.compile(r"eval time\s*=\s*([0-9.]+) ms"),
    "eval_tokens": re.compile(r"eval time\s*=\s*[0-9.]+ ms /\s*([0-9]+) tokens"),
    "eval_tok_s": re.compile(r"eval time.*?([0-9.]+) tokens per second"),
    "total_ms": re.compile(r"total time\s*=\s*([0-9.]+) ms"),
    "graphs_reused": re.compile(r"graphs reused\s*=\s*([0-9]+)"),
    "draft_acceptance": re.compile(r"draft acceptance\s*=\s*([0-9.]+)"),
}

data = {
    "prompt_eval_ms": None,
    "prompt_tokens": None,
    "prompt_tok_s": None,
    "eval_ms": None,
    "eval_tokens": None,
    "eval_tok_s": None,
    "total_ms": None,
    "graphs_reused": None,
    "draft_acceptance": None,
    "sched_sync_sites": {},
    "backend_sync_trace_samples": {},
    "timing_lines": {},
}

with open(log_path, encoding="utf-8", errors="replace") as f:
    for line in f:
        for key, pattern in patterns.items():
            m = pattern.search(line)
            if m:
                data[key] = float(m.group(1)) if key not in {"prompt_tokens", "eval_tokens", "graphs_reused"} else int(m.group(1))
                data["timing_lines"][key] = line.rstrip("\n")

        m = re.search(r"sched-sync-site: site=([^ ]+) count=([0-9]+)", line)
        if m:
            data["sched_sync_sites"][m.group(1)] = int(m.group(2))

        m = re.search(r"backend-sync-trace: count=([0-9]+) backend=([^ ]+) caller=(.+)", line)
        if m:
            caller = m.group(3).strip()
            data["backend_sync_trace_samples"][caller] = data["backend_sync_trace_samples"].get(caller, 0) + 1

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
PY

REQUEST_MS="$(awk -v a="${REQUEST_START_NS}" -v b="${REQUEST_END_NS}" 'BEGIN { printf "%.3f", (b-a)/1000000 }')"
RUN_MS="$(awk -v a="${START_EPOCH_NS}" -v b="${REQUEST_END_NS}" 'BEGIN { printf "%.3f", (b-a)/1000000 }')"

GPU_CSV="${TMP_DIR}/gpu.csv"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,driver_version,pstate,temperature.gpu,utilization.gpu,clocks.sm,clocks.mem,power.draw,memory.used,memory.total --format=csv,noheader,nounits >"${GPU_CSV}" 2>/dev/null || true
fi

jq -n \
    --arg run_id "${RUN_ID}" \
    --arg started_at "$(jq -r .started_at_utc "${META_JSON}")" \
    --arg health_ready_at "${HEALTH_READY_AT}" \
    --arg http_code "${HTTP_CODE}" \
    --arg request_ms "${REQUEST_MS}" \
    --arg run_ms "${RUN_MS}" \
    --argjson server_timing "$(cat "${TMP_DIR}/server_timing.json")" \
    --arg response_tokens "$(jq -r '.usage.completion_tokens // 0' "${TMP_DIR}/response.json" 2>/dev/null || echo 0)" \
    --arg prompt_tokens "$(jq -r '.usage.prompt_tokens // 0' "${TMP_DIR}/response.json" 2>/dev/null || echo 0)" \
    --arg finish_reason "$(jq -r '.choices[0].finish_reason // ""' "${TMP_DIR}/response.json" 2>/dev/null || true)" \
    '{
      run_id: $run_id,
      started_at_utc: $started_at,
      health_ready_at_utc: $health_ready_at,
      http_code: ($http_code|tonumber),
      request_wall_ms: ($request_ms|tonumber),
      run_wall_ms: ($run_ms|tonumber),
      prompt_tokens_api: ($prompt_tokens|tonumber),
      completion_tokens_api: ($response_tokens|tonumber),
      finish_reason: $finish_reason,
      server_timing: $server_timing
    }' >"${PERF_JSON}"

if [[ -s "${GPU_CSV}" ]]; then
    python3 - "${GPU_CSV}" "${PERF_JSON}" <<'PY'
import csv
import json
import sys

csv_path, perf_path = sys.argv[1:3]
with open(csv_path, newline="", encoding="utf-8") as f:
    rows = list(csv.reader(f))
if rows:
    r = [x.strip() for x in rows[-1]]
    gpu = {
        "name": r[0],
        "driver_version": r[1],
        "pstate": r[2],
        "temperature_c": float(r[3]),
        "utilization_pct": float(r[4]),
        "clocks_sm_mhz": float(r[5]),
        "clocks_mem_mhz": float(r[6]),
        "power_w": float(r[7]),
        "memory_used_mib": float(r[8]),
        "memory_total_mib": float(r[9]),
    }
    data = json.load(open(perf_path, encoding="utf-8"))
    data["gpu_end"] = gpu
    json.dump(data, open(perf_path, "w", encoding="utf-8"), indent=2)
PY
fi

jq --argjson request "${REQUEST_JSON}" '. + {request: $request}' "${PERF_JSON}" >"${PERF_JSON}.tmp"
mv "${PERF_JSON}.tmp" "${PERF_JSON}"

echo
echo "=== Performance result ==="
jq '.server_timing, {request_wall_ms, prompt_tokens_api, completion_tokens_api, finish_reason}' "${PERF_JSON}"

if [[ "${PUSH_RESULTS}" == "1" ]]; then
    if [[ -n "${GIT_BRANCH}" ]]; then
        git -C "${REPO_ROOT}" switch "${GIT_BRANCH}"
    else
        GIT_BRANCH="${GIT_BRANCH_CURRENT}"
    fi
    [[ -n "${GIT_BRANCH}" ]] || die "Not on a git branch; set GIT_BRANCH explicitly."

    git -C "${REPO_ROOT}" add "${RUN_DIR}"
    git -C "${REPO_ROOT}" commit -m "bench: record performance run ${RUN_ID}"
    git -C "${REPO_ROOT}" push "${GIT_REMOTE}" "${GIT_BRANCH}"
    echo "Pushed ${RUN_DIR} to ${GIT_REMOTE}/${GIT_BRANCH}."
fi
