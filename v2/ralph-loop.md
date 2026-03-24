# ralph loop 是一种自动调用 agent 运行的机制。

项目下文档空间是重要的在 loop 之间传递信息的部分。
```
docs/plan.md  // 计划
docs/failures.log // 失败记录
```

## 启动机制

首先有一个 plan.md 文档。

pending：未开始
blocked：被依赖或外部条件阻塞
done：已完成
failed：本轮失败，待修复

- 如果文档中包含 `pending  / failed` 文本，说明计划没有完成，进入执行环节。
- 如果文档中不包含 `pending / failed` 文本，说明计划已完成，退出。

plan.md 文档举例，由多个 Task 构成
```
## Task-02: 实现用户登录
status: pending
priority: high
depends_on: [Task-01]	// 可为空
acceptance:
  - 登录成功返回 token
  - 错误密码提示
```


## 执行环节

调用 codex / claude cli 传入 prompt，开始执行。

prompt template

```
{系统架构摘要}

项目路径：{project-path}
项目计划：{plan-path}
最新进展：{近 3 条 commit}
失败记录：{failure.log}

0. 如果最新进展没有失败记录，就不用读失败记录
1. 从 plan 中选择一个任务
2. 开发这个任务
3. 写完后进行功能测试、语法检查
4. 如果完成功能且测试通过则写进 plan.md，改写 Task status: done
5. 如果失败，将尝试方案和失败原因 append 写进 log
6. 无论成功还是失败，都必须git commit 

git commit 传递重要的执行记录，遵守书写规范：
feat(task_login): 
fix(task_login): 
fail(task_login): 
```