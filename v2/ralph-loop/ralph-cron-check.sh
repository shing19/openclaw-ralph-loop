#!/usr/bin/env bash
set -euo pipefail

# 用法:
#   ./ralph-cron-check.sh [runs.jsonl路径] [cli] [model]
#
# 例子:
#   ./ralph-cron-check.sh ./runs.jsonl
#   ./ralph-cron-check.sh ./runs.jsonl claude claude-sonnet-4-6
#   ./ralph-cron-check.sh ./runs.jsonl codex gpt-5.4

RUNS_FILE="${1:-./runs.jsonl}"
DEFAULT_CLI="${2:-claude}"
DEFAULT_MODEL="${3:-claude-sonnet-4-6}"

# 转为绝对路径，避免 cron 工作目录不确定
RUNS_FILE="$(cd "$(dirname "$RUNS_FILE")" && pwd)/$(basename "$RUNS_FILE")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_SCRIPT="$SCRIPT_DIR/ralph-loop-exec.sh"

# --- Lock mechanism ---
LOCKFILE="${RUNS_FILE}.lock"

acquire_lock() {
  if [[ -f "$LOCKFILE" ]]; then
    local existing_pid
    existing_pid="$(cat "$LOCKFILE" 2>/dev/null)" || true
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      echo "[ralph-cron] already running (pid=$existing_pid), skipping" >&2
      exit 0
    fi
    echo "[ralph-cron] removing stale lock (pid=$existing_pid)"
    rm -f "$LOCKFILE"
  fi
  echo $$ > "$LOCKFILE"
}

release_lock() {
  rm -f "$LOCKFILE"
}

trap release_lock EXIT
acquire_lock
# --- End lock mechanism ---

if [[ ! -f "$RUNS_FILE" ]]; then
  echo "[ralph-cron] runs file not found: $RUNS_FILE" >&2
  exit 1
fi

if [[ ! -x "$LOOP_SCRIPT" ]]; then
  echo "[ralph-cron] loop script is not executable: $LOOP_SCRIPT" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[ralph-cron] jq is required but not installed" >&2
  exit 1
fi

# 检查是否还有未完成项目
unfinished_count="$(jq -s '[ .[] | select(.completed == false) ] | length' "$RUNS_FILE")"

if [[ "$unfinished_count" -eq 0 ]]; then
  echo "[ralph-cron] all projects completed, nothing to do"
  exit 0
fi

echo "[ralph-cron] unfinished projects: $unfinished_count"

# 逐个执行未完成项目
# 每次 loop 只跑一次，保持 cron 驱动的节奏
jq -c '. | select(.completed == false)' "$RUNS_FILE" | while IFS= read -r run; do
  project="$(jq -r '.project' <<<"$run")"
  path="$(jq -r '.path' <<<"$run")"
  plan="$(jq -r '.plan' <<<"$run")"

  echo "[ralph-cron] start project=$project path=$path plan=$plan cli=$DEFAULT_CLI model=$DEFAULT_MODEL"

  "$LOOP_SCRIPT" \
    --runs-file "$RUNS_FILE" \
    --project "$project" \
    --cli "$DEFAULT_CLI" \
    --model "$DEFAULT_MODEL" || {
      echo "[ralph-cron] project failed in this round: $project" >&2
      # 不中断其他项目
      continue
    }
done