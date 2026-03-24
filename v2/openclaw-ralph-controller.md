# 在 OpenClaw 中设计 Ralph Loop 的执行

给 ralph 一个项目注册空间。

ralph-loop/runs.jsonl

```json
{
  "project": "my_project",
  "path": "/path/to/project",
  "plan": "/path/to/plan.md",
  "completed": false,
  "description": ""
}
```


用 cron 检查 runs.jsonl ，如果 completed 都为 true 就结束。

如果有 false，启动 ralph loop 脚本。


