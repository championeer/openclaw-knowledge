# 跟 OpenClaw 学习如何给 Agent 加定时任务

> **Author**: VerySmallWoods ([@verysmallwoods](https://x.com/verysmallwoods))
> **Date**: 9:34 AM · Feb 10, 2026
> **Original**: [https://x.com/verysmallwoods/status/2021034972337807765](https://x.com/verysmallwoods/status/2021034972337807765)
> **Stats**: 1 reply · 14 reposts · 60 likes · 115 bookmarks · 7,603 views

---

![Image](media/img_001.jpg)

给 Agent 加定时任务，看起来是个简单需求 - 不就是 cron 嘛。 但当你真正动手，会发现 cron 刚好坐在三个复杂性的交汇点上：时间计算（cron 表达式、时区、亚秒精度）、状态管理（持久化、重启恢复、并发锁）、结果投递（多通道、线程定位、重试策略）。传统 cron 只管触发，Agent 场景下还得处理 LLM 推理卡死、模型不按 schema 传参、投递目标过期这些独有问题。

OpenClaw 的 cron 子系统在这些方向上积累了 60+ 个 open issues。v2026.2.9 版本通过两个 PR（#11641、#12124）做了一次彻底重构，一口气 supersede 了 11 个在途 PR。

我读完了全部代码改动，从中提炼出七个在构建 Agent 定时任务系统时值得注意的可靠性问题。每个问题都用 OpenClaw 的实际代码来说明。

## 1. 亚秒精度陷阱：你的调度器和 cron 库可能不在同一个精度

Cron 表达式的最小粒度是秒，但 JavaScript 的 `Date.now()` 返回毫秒。这个不匹配会导致一个微妙的 bug。

先理解 cron 库的 `nextRun(referenceDate)` 做了什么：它返回 `referenceDate` 之后的下一个 cron 匹配时间。它按秒粒度工作 —— `12:00:00.000` 和 `12:00:00.999` 对它来说都是"在 12:00:00 这一秒内"。

假设你有一个每天中午 12 点执行的任务（`0 0 12 * * *`）。调度器在 `12:00:00.500` 计算下次执行时间：

```
当前时间 (Date.now()): 12:00:00.500
1ms 回溯（旧逻辑）: 12:00:00.499
```

调度器把 `12:00:00.499` 传给 `nextRun`。cron 库看到这个时间落在 12:00:00 这一秒内 —— 既然参考时间已经在匹配秒里面了，`12:00:00` 就不算"下一个"匹配。于是它跳到明天的 `12:00:00`。一个本该立即执行的任务被延迟了 24 小时。

OpenClaw 的第一版修复（PR #11641）就是上面的 1ms 回溯，没有解决问题。第二版（PR #12124，commit b6c556a）做对了 —— 先将毫秒时间戳向下取整到秒边界，再回溯：

```
当前时间 (Date.now()): 12:00:00.500
向下取整到秒边界: 12:00:00.000
减 1ms: 11:59:59.999
```

现在 `nextRun` 收到 `11:59:59.999` —— 一个在上一秒的时间。`11:59:59` 之后的下一个 cron 匹配是今天的 `12:00:00`。正确答案。

代码实现：

```typescript
// src/cron/schedule.ts
const nowSecondMs = Math.floor(nowMs / 1000) * 1000;
const next = cron.nextRun(new Date(nowSecondMs - 1));
if (!next) {
  return undefined;
}
const nextMs = next.getTime();
return Number.isFinite(nextMs) && nextMs >= nowSecondMs
  ? nextMs
  : undefined;
```

两个关键点：`Math.floor` 将时间对齐到秒边界，最后的比较用 `nowSecondMs` 而不是原始 `nowMs`。这确保同一秒内任意毫秒偏移都能正确匹配。

心得：当你的系统精度（毫秒）高于 cron 库的精度（秒），一定要在交互边界做对齐。这类 bug 有一个诡异的特征：它只在调度器的 tick 恰好落在匹配秒的前 1-2 秒内时触发 —— 窗口够窄让测试几乎抓不到，但在生产中天天跑，迟早会命中。

---

## 2. LLM 调用必须有执行超时

传统 cron 任务跑的是确定性代码，执行时间大致可预测。Agent 场景不同 —— 一个 cron 触发的 LLM 推理可能因为模型负载、复杂推理链、或 API 故障而卡住几十分钟甚至永远不返回。

如果你的调度器是串行执行 cron 任务的，一个卡住的任务会阻塞整个调度通道。

OpenClaw 的方案是用 `Promise.race` 加 wall-clock 超时：

```typescript
const DEFAULT_JOB_TIMEOUT_MS = 10 * 60_000; // 10 分钟

const jobTimeoutMs =
  job.payload.kind === "agentTurn" &&
  typeof job.payload.timeoutSeconds === "number"
    ? job.payload.timeoutSeconds * 1_000
    : DEFAULT_JOB_TIMEOUT_MS;

let timeoutId: NodeJS.Timeout;
const result = await Promise.race([
  executeJobCore(state, job),
  new Promise<never>((_, reject) => {
    timeoutId = setTimeout(
      () => reject(new Error("cron: job execution timed out")),
      jobTimeoutMs,
    );
  }),
]).finally(() => clearTimeout(timeoutId!));
```

默认 10 分钟，任务可以通过 `payload.timeoutSeconds` 自定义。超时后标记为 error，触发退避机制。

心得：任何调用 LLM 的定时任务都必须有 wall-clock 超时。不要依赖 LLM provider 的超时 —— 那是请求级别的，而你的任务可能包含多轮对话、工具调用、重试。用 `Promise.race` 或等效机制在调度层面兜底。

---

## 3. 失败任务需要指数退避

你的 cron 任务调用了一个外部 API，API 挂了。任务失败。下次 tick 到了，再试，再失败。如果任务是每分钟一次，你就在以每分钟一次的频率打一个已经挂掉的 API。

OpenClaw 引入了 `consecutiveErrors` 计数器和分级退避表：

```
第 1 次失败 → 30 秒
第 2 次失败 → 1 分钟
第 3 次失败 → 5 分钟
第 4 次失败 → 15 分钟
第 5 次+   → 60 分钟
```

退避逻辑取自然调度时间和退避延迟中较晚的那个：

```typescript
if (result.status === "error" && job.enabled) {
  const backoff = errorBackoffMs(job.state.consecutiveErrors ?? 1);
  const normalNext = computeJobNextRunAtMs(job, result.endedAt);
  const backoffNext = result.endedAt + backoff;
  job.state.nextRunAtMs = normalNext !== undefined
    ? Math.max(normalNext, backoffNext)
    : backoffNext;
}
```

成功时重置：`job.state.consecutiveErrors = 0`。

这里有一个设计细节值得注意：用 `Math.max(normalNext, backoffNext)` 而不是直接用 `backoffNext`。这意味着如果一个任务每天执行一次但失败了，退避 30 秒远比 24 小时的自然间隔短，不会强制延迟到明天。退避只在自然间隔比退避短时才生效。

教训：Agent 场景下的 cron 任务失败是常态（API 限流、模型过载、上下文溢出），必须有退避机制。关键是退避策略要和自然调度频率配合 —— 取两者较大值，而不是简单替换。

---

## 4. 单次任务的死循环陷阱

很多 Agent 应用支持"在某个时间执行一次"的定时任务（闹钟、提醒）。如果这个任务执行失败了，会怎样？

OpenClaw 之前的代码只在成功时禁用单次任务：

```typescript
// 旧逻辑
if (job.schedule.kind === "at" && result.status === "ok") {
  job.enabled = false;
}
```

当任务失败时，`computeJobNextRunAtMs` 仍然返回原始的目标时间（一个已经过去的时间戳）。调度器发现"已到时"，立即重新执行。再失败。无限循环。

修复很直接（PR #11641）—— 任何终态（成功、失败、跳过）之后都禁用单次任务：

```typescript
if (job.schedule.kind === "at") {
  job.enabled = false;
  job.state.nextRunAtMs = undefined;
  if (result.status === "error") {
    state.deps.log.warn(
      {
        jobId: job.id,
        jobName: job.name,
        consecutiveErrors: job.state.consecutiveErrors,
      },
      "cron: disabling one-shot job after error",
    );
  }
}
```

心得：单次任务和周期任务的失败处理逻辑必须分开。周期任务失败后等下一个周期即可，单次任务失败后如果不主动禁用，就会进入死循环。这是一个容易被忽视的边界条件 —— 你可能在实现"快乐路径"时写出正确的代码，但只有当你问"失败了会怎样"时才会发现这个问题。

---

## 5. 投递上下文会过期

Agent 的 cron 任务执行完后，要把结果发给用户。用户的"位置"可能发生了变化 —— 比如用户在 Telegram 群组的某个 topic 里设置了 cron 任务，后来投递目标变成了私聊。

如果系统还携带着旧的群组 `threadId`，Telegram API 会直接报错。

OpenClaw 做了一个三条件校验：

```typescript
const threadId =
  resolved.threadId &&
  resolved.to &&
  resolved.to === resolved.lastTo
    ? resolved.threadId
    : undefined;
```

只有同时满足三个条件才保留 `threadId`：有 `threadId`、有目标接收者 `to`、且当前 `to` 等于上次对话的 `lastTo`。任何一个不满足就丢弃线程 ID。

心得：在 IM 平台（Telegram、Discord、Slack）做消息投递时，会话上下文（threadId、topicId、channelId）不是一成不变的。每次投递前要校验上下文是否仍然有效，否则一个过期的线程 ID 就能搞垮整条投递链路。

---

## 6. 重复的投递管道迟早会分叉

在 Agent 系统里，"把执行结果发给用户"是一个看起来简单但实际上很复杂的操作。它涉及：确定投递通道（Telegram / Discord / Slack）、解析线程上下文（threadId、topicId）、处理消息格式（纯文本 vs 富文本 vs 媒体）、错误重试。

OpenClaw 有两类任务需要做这件事：子 Agent（subagent）完成任务后通知用户，以及 cron 任务执行完后投递结果。两者的投递逻辑高度重复 —— 都要做通道路由、线程解析、格式处理 —— 但一直各自维护在不同文件里。

这种重复的代价不在于代码冗余本身，而在于修复不同步。当子 Agent 的投递管道修了一个线程上下文 bug，cron 的投递管道不会自动获得同样的修复。两条管道开始以不同的速度演化，行为逐渐分叉。本次 PR 关联的 60+ issues 中，有一部分就是"子 Agent 投递正常但 cron 投递失败"这类症状。

PR #11641 把纯文本结果的投递合并到共享的 `runSubagentAnnounceFlow`：

```typescript
if (deliveryPayloadHasStructuredContent) {
  // 有媒体或 channelData → 走直接投递（保留结构化内容）
  await deliverOutboundPayloads({ ... });
} else if (synthesizedText) {
  // 纯文本 → 走共享管道
  await runSubagentAnnounceFlow({
    task: taskLabel,
    roundOneReply: synthesizedText,
    announceType: "cron job",  // subagent 用 "subagent task"
    // ...
  });
}
```

注意这里不是无脑合并所有投递。结构化内容（媒体附件、channelData）仍走直接投递 —— 因为共享管道是文本化的，会丢失结构化格式。这是一个务实的边界选择：能合的合，不能合的保留独立路径，但要有清晰的分流条件。

心跳机制的 bug 是管道分叉的一个典型例子。子 Agent 有自己的 announce flow，会把执行结果组织成对用户友好的消息。但 cron 任务触发心跳时，走的是通用心跳路径 —— 模型收到的 prompt 是"如果没什么事就回复 HEARTBEAT_OK"。模型照做了，定时提醒被吞掉，用户什么也没收到。

修复方式是给 cron 触发的心跳加一个专用 prompt：

> "A scheduled reminder has been triggered. The reminder message is shown in the system messages above. Please relay this reminder to the user in a helpful and friendly way."

这个 bug 的根因不是 prompt 写错了，而是 cron 投递路径从未接入子 Agent 已经完善的 announce flow。如果一开始就共享同一条管道，这个 bug 根本不会出现。

心得：如果你的系统里有两条做类似事情的管道（都是"把 Agent 的输出发给用户"），尽早合并。管道分叉的代价不是代码冗余，而是修复不同步 —— 每次修 bug 都要问"另一条管道是不是也有这个问题"，而这个问题你总有一天会忘记问。合并时要设定清晰的分流条件：能走共享路径的走共享路径，有结构化差异的保留独立路径。

---

## 7. 不是所有模型都会按你的 Schema 传参

这是最有 Agent 特色的一个问题，也是传统软件工程中没有对应物的新挑战。

在传统 API 开发中，你校验的是用户输入 —— 用户可能手误、可能恶意，所以你在系统边界做验证。但 Agent 应用里，工具调用的参数是 LLM 生成的。LLM 不是恶意的，但它不保证严格遵守 schema。不同模型对同一个 schema 的理解能力不同，尤其在嵌套结构、可选字段、`additionalProperties` 这类场景下，差异很大。

这意味着你的工具实现不能假设"参数一定符合 schema"。模型输出是另一种形式的外部输入，需要同等的防御性处理。

OpenClaw 的 cron 工具定义了一个 `add` action，参数 schema 里 `job` 是个嵌套对象。主流模型（Claude、GPT）能正确生成嵌套结构，但 Grok 等非前沿模型会把 `name`、`schedule`、`payload` 平铺到顶层，和 `action` 并列。

Schema 用了不透明的 `Type.Object({}, { additionalProperties: true })`，没给模型结构提示。结果 `params.job` 要么是 `undefined`，要么是个空对象，真正的数据散落在 `params` 的其他字段里。

PR #12124（commit 76fe42c）在 `cron-tool.ts` 加了一段参数恢复逻辑：

```typescript
if (
  !params.job ||
  (typeof params.job === "object" &&
    Object.keys(params.job).length === 0)
) {
  const JOB_KEYS = new Set([
    "name", "schedule", "sessionTarget", "payload",
    "delivery", "enabled", "message", "text",
    "model", "thinking", ...
  ]);
  const synthetic = {};
  for (const key of Object.keys(params)) {
    if (JOB_KEYS.has(key) && params[key] !== undefined) {
      synthetic[key] = params[key];
    }
  }
  // 信号字段门槛：至少有一个核心字段才构造合成对象
  if (
    synthetic.schedule || synthetic.payload ||
    synthetic.message || synthetic.text
  ) {
    params.job = synthetic;
  }
}
```

关键设计是信号字段门槛：只有检测到 `schedule`、`payload`、`message`、`text` 中至少一个，才认为模型确实想创建任务。仅有 `name` 或 `enabled` 不足以触发恢复 —— 这避免了误判。

如果 `params.job` 本身非空，整段逻辑被跳过。

心得：LLM 生成的工具参数本质上是外部输入，不能假设它严格符合 schema。你的工具实现需要对畸形参数做防御性恢复，就像 Web API 校验用户输入一样。具体来说：

- 不要改 schema 来适配某个模型 —— 那可能破坏已有模型的行为；
- 在工具实现层做恢复逻辑；
- 设定"意图信号"门槛 —— 有哪些字段能证明模型确实想调用这个功能，而不是误传了不相关的参数。

这不只是兼容性问题，而是 Agent 应用的健壮性基本功。

---

## 结构性改进：别让同一个 Bug 修两遍

除了这七项修复，PR #11641 做了一项值得单独说的结构性改进。

之前 `onTimer`（批量执行）和 `executeJob`（单次执行）各自维护一套执行后状态更新逻辑：错误计数、退避计算、单次任务禁用、`nextRunAtMs` 重算。同一个逻辑写了两遍，改了一处忘了另一处。

新代码抽取了 `applyJobResult` 函数，两条路径都调用它。同时添加了防御性状态初始化（`if (!j.state) { j.state = {} }`），让数据损坏或版本升级不再导致崩溃。

这看起来是教科书式的重构，但在 cron 这种"多个入口共享同一状态机"的系统里，不做这一步，前面六项修复中的任何一个都可能只修了一半。

这次重构涉及 2 个 PR（#11641、#12124），690 行新增代码，supersede 11 个在途 PR，关联 60+ 个 issues。两个 PR 前后脚合并（2 月 8 日和 9 日），第二个修正了第一个中时间精度修复的不彻底之处 —— 这说明作者在真实环境中验证了第一版。

Cron 看起来简单，但在 Agent 场景下，时间精度、LLM 不确定性、多通道投递、异构模型兼容性四个维度叠在一起，复杂度指数级上升。这次重构的价值不只在于修了 60 个 bug，更在于用结构化手段（统一结果处理、指数退避、信号字段门槛）降低了新 bug 出现的概率。如果你也在给 Agent 系统加定时任务，这些经验值得提前了解。

---

注，其中许多改动，都是在软件工程发展历史中，早已沉淀下来的最佳实践。或许是 Vibe Coding 时代的来临，代码都由 AI 编写，一些实践没有落实。这也是人类随时鞭策 AI 的必要性。
