#!/usr/bin/env bash
set -Eeuo pipefail

# Prefill-focused wrapper around perf-run.sh.
#
# PREFILL_TOKENS is a target, not a tokenizer-exact guarantee. The generated
# prompt is deliberately repetitive so prompt length is stable; the actual
# token count is recorded by llama-server in performance.json/server.log.
#
# Examples:
#   PREFILL_TOKENS=2048 PUSH_RESULTS=1 ./scripts/perf-prefill-run.sh
#   PREFILL_TOKENS=8192 UBATCH=256 ./scripts/perf-prefill-run.sh
#   PREFILL_TOKENS=16384 MAX_TOKENS=1 ./scripts/perf-prefill-run.sh -lv 4 -ot '...'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFILL_TOKENS="${PREFILL_TOKENS:-2048}"
MAX_TOKENS="${MAX_TOKENS:-1}"

[[ "${PREFILL_TOKENS}" =~ ^[0-9]+$ ]] || {
    echo "ERROR: PREFILL_TOKENS must be a positive integer" >&2
    exit 1
}
(( PREFILL_TOKENS > 0 )) || {
    echo "ERROR: PREFILL_TOKENS must be > 0" >&2
    exit 1
}

# This block is intentionally repetitive. It is approximately 20-25 tokens
# depending on the tokenizer, and is repeated enough to create a stable,
# synthetic prefill workload. The server's measured prompt_tokens is the
# authoritative number.
TOKEN_BLOCK='Prefill benchmark token block alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa'

python3 - "${PREFILL_TOKENS}" "${TOKEN_BLOCK}" <<'PY' > "${REPO_ROOT}/.prefill_prompt.tmp"
import sys

target = int(sys.argv[1])
block = sys.argv[2]

# Start with a generous estimate, then trim at whitespace boundaries. We
# intentionally overshoot because the llama tokenizer is the source of truth.
words = block.split()
n_words = max(1, target * 2)
out = (words * ((n_words + len(words) - 1) // len(words)))[:n_words]
print(" ".join(out))
PY

USER_PROMPT="$(cat "${REPO_ROOT}/.prefill_prompt.tmp")"
rm -f "${REPO_ROOT}/.prefill_prompt.tmp"

export PREFILL_TOKENS
export USER_PROMPT
export MAX_TOKENS

echo "Prefill target tokens: ${PREFILL_TOKENS}"
echo "Decode max tokens:     ${MAX_TOKENS}"
echo "UBATCH:                ${UBATCH:-256}"
echo "BATCH:                 ${BATCH:-4096}"

exec "${REPO_ROOT}/scripts/perf-run.sh" "$@"
