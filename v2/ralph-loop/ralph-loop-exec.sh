#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./ralph-loop-exec.sh --runs-file <runs.jsonl> --project <project-name> [--cli claude|codex] [--model <model>]

Examples:
  ./ralph-loop-exec.sh --runs-file ./runs.jsonl --project my_project
  ./ralph-loop-exec.sh --runs-file ./runs.jsonl --project my_project --cli claude --model claude-sonnet-4-6
  ./ralph-loop-exec.sh --runs-file ./runs.jsonl --project my_project --cli codex --model gpt-5.4
EOF
}

RUNS_FILE=""
PROJECT=""
CLI="claude"
MODEL="claude-sonnet-4-6"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs-file)
      RUNS_FILE="$2"
      shift 2
      ;;
    --project)
      PROJECT="$2"
      shift 2
      ;;
    --cli)
      CLI="$2"
      shift 2
      ;;
    --model)
      MODEL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$RUNS_FILE" || -z "$PROJECT" ]]; then
  usage
  exit 1
fi

if [[ ! -f "$RUNS_FILE" ]]; then
  echo "[ralph-loop] runs file not found: $RUNS_FILE" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[ralph-loop] jq is required but not installed" >&2
  exit 1
fi

# 取出项目配置
RUN_JSON="$(jq -sc --arg project "$PROJECT" '
  map(select(.project == $project)) | .[0]
' "$RUNS_FILE")"

if [[ "$RUN_JSON" == "null" || -z "$RUN_JSON" ]]; then
  echo "[ralph-loop] project not found in runs file: $PROJECT" >&2
  exit 1
fi

PROJECT_PATH="$(jq -r '.path' <<<"$RUN_JSON")"
PLAN_PATH="$(jq -r '.plan' <<<"$RUN_JSON")"
DESCRIPTION="$(jq -r '.description // ""' <<<"$RUN_JSON")"

FAILURE_LOG="$PROJECT_PATH/docs/failures.log"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "[ralph-loop] project path not found: $PROJECT_PATH" >&2
  exit 1
fi

if [[ ! -f "$PLAN_PATH" ]]; then
  echo "[ralph-loop] plan file not found: $PLAN_PATH" >&2
  exit 1
fi

if [[ ! -d "$PROJECT_PATH/.git" ]]; then
  echo "[ralph-loop] project is not a git repo: $PROJECT_PATH" >&2
  exit 1
fi

# 如果 plan 里没有 pending / failed，则认为完成
if ! grep -Eq 'status:[[:space:]]*(pending|failed)\b' "$PLAN_PATH"; then
  echo "[ralph-loop] no pending/failed task, mark completed: $PROJECT"

  tmp_file="$(mktemp)"
  jq -c --arg project "$PROJECT" '
    if .project == $project
    then .completed = true
    else .
    end
  ' "$RUNS_FILE" > "$tmp_file"
  mv "$tmp_file" "$RUNS_FILE"

  exit 0
fi

mkdir -p "$PROJECT_PATH/docs"
touch "$FAILURE_LOG"

# 最近 3 条 commit
LATEST_COMMITS="$(git -C "$PROJECT_PATH" log --oneline -n 3 2>/dev/null || true)"
if [[ -z "$LATEST_COMMITS" ]]; then
  LATEST_COMMITS="(no commits yet)"
fi

# 是否需要把 failures.log 放进 prompt
INCLUDE_FAILURES="yes"
LAST_COMMIT_SUBJECT="$(git -C "$PROJECT_PATH" log -1 --pretty=%s 2>/dev/null || true)"
if [[ "$LAST_COMMIT_SUBJECT" != fail* ]]; then
  INCLUDE_FAILURES="no"
fi

if [[ "$INCLUDE_FAILURES" == "yes" ]]; then
  FAILURE_CONTENT="$(tail -n 80 "$FAILURE_LOG" 2>/dev/null || true)"
  [[ -z "$FAILURE_CONTENT" ]] && FAILURE_CONTENT="(empty)"
else
  FAILURE_CONTENT="(skip reading failures.log because latest progress does not indicate failure)"
fi

PLAN_CONTENT="$(cat "$PLAN_PATH")"

read -r -d '' PROMPT <<EOF || true
你是 Ralph Loop 的执行代理。你在一个真实 git 项目中工作，必须直接修改文件、运行命令、测试并提交 commit。

# 项目描述
$DESCRIPTION

# 项目路径
$PROJECT_PATH

# 项目计划文件
$PLAN_PATH

# 最新进展（近 3 条 commit）
$LATEST_COMMITS

# 失败记录
$FAILURE_CONTENT

# 执行规则
0. 如果最新进展没有失败记录，可以跳过参考 failures.log；上面已做处理
1. 从 plan.md 中选择一个 status 为 pending 或 failed，且依赖满足的任务
2. 开发这个任务
3. 写完后必须做最小必要验证：
   - 功能测试
   - 语法检查 / lint / typecheck / unit test（按项目实际情况选择）
4. 如果完成功能且测试通过，更新 plan.md，将对应 Task status 改为 done
5. 如果失败：
   - 不要伪造完成
   - 将尝试方案、失败原因、下一步建议 append 写入 docs/failures.log
   - 将该任务 status 保持 failed 或改为 failed
6. 无论成功还是失败，都必须 git commit
7. commit message 必须遵守：
   - feat(task_xxx):
   - fix(task_xxx):
   - fail(task_xxx):
8. 只做一个任务，不要贪多
9. 如果被依赖阻塞或外部条件阻塞，可把任务标记为 blocked，并说明原因
10. 完成后输出简短总结：
    - selected task
    - changed files
    - validation result
    - commit sha

# plan.md 当前内容
$PLAN_CONTENT
EOF

run_claude() {
  if ! command -v claude >/dev/null 2>&1; then
    echo "[ralph-loop] claude CLI not found" >&2
    exit 1
  fi

  # -p 为非交互单次执行；--model 指定模型
  # 这里使用当前项目目录运行
  (
    cd "$PROJECT_PATH"
    claude -p --model "$MODEL" "$PROMPT"
  )
}

run_codex() {
  if ! command -v codex >/dev/null 2>&1; then
    echo "[ralph-loop] codex CLI not found" >&2
    exit 1
  fi

  # codex exec 适合脚本化执行；-C 指定目录；-m 指定模型
  # 这里给出相对保守的执行方式，不主动开启 yolo
  codex exec -C "$PROJECT_PATH" -m "$MODEL" "$PROMPT"
}

case "$CLI" in
  claude)
    run_claude
    ;;
  codex)
    run_codex
    ;;
  *)
    echo "[ralph-loop] unsupported cli: $CLI" >&2
    exit 1
    ;;
esac

# 执行后重新检查 plan 状态，决定是否把 runs.jsonl 标记为 completed
if grep -Eq 'status:[[:space:]]*(pending|failed)\b' "$PLAN_PATH"; then
  NEW_COMPLETED="false"
else
  NEW_COMPLETED="true"
fi

tmp_file="$(mktemp)"
jq -c --arg project "$PROJECT" --argjson completed "$NEW_COMPLETED" '
  if .project == $project
  then .completed = $completed
  else .
  end
' "$RUNS_FILE" > "$tmp_file"
mv "$tmp_file" "$RUNS_FILE"

echo "[ralph-loop] finished project=$PROJECT completed=$NEW_COMPLETED"-