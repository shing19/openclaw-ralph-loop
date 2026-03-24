# Ralph Loop

Ralph Loop 是一个自主 agent 执行循环 —— cron 驱动调度，`plan.md` 定义任务，coding agent（Claude CLI / Codex CLI）执行开发工作。

每次 cron 触发时，找到未完成的项目，从 plan 中选一个 pending 或 failed 的任务交给 agent 执行并 commit。循环往复，直到所有任务完成。

## 工作原理

```
cron
 └─ ralph-cron-check.sh        # 读取 runs.jsonl，找到未完成项目
     └─ ralph-loop-exec.sh     # 构建 prompt，调用 agent CLI
         └─ claude / codex     # 执行一个任务，提交 commit
```

### 数据流

1. **`runs.jsonl`** — 项目注册表。每行一个项目，包含 `path`、`plan` 路径和 `completed` 状态。
2. **`plan.md`** — 项目内的任务清单。每个 Task 有 `status: pending | failed | blocked | done`。
3. **`docs/failures.log`** — 只追加的失败日志。记录尝试方案和失败原因，供下次重试参考。
4. **git commit** — 每轮迭代必须提交。提交前缀：`feat()`、`fix()`、`fail()`。

### 执行规则

- 每轮只做一个任务，不贪多
- agent 必须验证（测试 / lint / typecheck）后才能标记 done
- 失败的任务保持 `failed`，不允许伪造完成
- 失败上下文通过 `failures.log` 传递给下一次重试
- lockfile 防止 cron 并发执行

## 快速开始

```bash
# 1. 创建项目和计划
mkdir -p my-project/docs
cat > my-project/docs/plan.md <<'EOF'
## Task-01: 搭建项目脚手架
status: pending
priority: high
depends_on: []
acceptance:
  - package.json 存在
  - npm install 成功
EOF

# 2. 初始化 git
cd my-project && git init && cd ..

# 3. 注册项目
cat > runs.jsonl <<'EOF'
{"project":"my_project","path":"/abs/path/to/my-project","plan":"/abs/path/to/my-project/docs/plan.md","completed":false,"description":"项目描述"}
EOF

# 4. 手动执行一次
./v2/ralph-loop/ralph-cron-check.sh ./runs.jsonl claude claude-sonnet-4-6

# 5. 或设置 cron 定时执行（每 10 分钟）
# crontab -e
# */10 * * * * /abs/path/to/ralph-cron-check.sh /abs/path/to/runs.jsonl >> /tmp/ralph-cron.log 2>&1
```

## Plan 格式

```markdown
## Task-02: 实现用户登录
status: pending
priority: high
depends_on: [Task-01]     // 可选项
acceptance:
  - 登录成功返回 token
  - 错误密码提示
```

状态值：`pending`（待执行）、`failed`（失败待修复）、`blocked`（被阻塞）、`done`（已完成）

agent 会选择 `status` 为 `pending` 或 `failed`，且 `depends_on` 均已完成的任务。

## CLI 支持

| CLI | 调用方式 | 说明 |
|-----|---------|------|
| `claude` | `-p --model <model>` | 非交互单次执行 |
| `codex` | `exec -C <path> -m <model>` | 脚本执行模式 |

默认使用 `claude` + `claude-sonnet-4-6`，可通过参数覆盖：

```bash
./ralph-cron-check.sh ./runs.jsonl codex gpt-5.4
```

## 依赖

- `bash` (4.0+)
- `jq`
- `git`
- `claude` 或 `codex` CLI
