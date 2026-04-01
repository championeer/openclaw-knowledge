# OpenClaw Knowledge Base

收集整理 OpenClaw 社区的优质文章与实践经验。所有内容均从 X (Twitter) 归档，保留原文 Markdown 格式及配图。

## 文章列表

| 文章 | 作者 | 日期 | 主题 |
|------|------|------|------|
| [跟 OpenClaw 学习如何给 Agent 加定时任务](跟OpenClaw学习如何给Agent加定时任务/article.md) | [@verysmallwoods](https://x.com/verysmallwoods) | 2026-02-10 | Cron 子系统可靠性：亚秒精度、LLM 超时、指数退避、投递管道等 7 个实战问题 |
| [OpenClaw QMD 本地语义搜索 + ZenMux 节省 20 倍 Token](OpenClaw-QMD本地语义搜索+ZenMux节省20倍Token消耗/article.md) | [@AppSaildotDEV](https://x.com/AppSaildotDEV) | 2026-02-06 | 用 QMD 语义检索替代全量上下文 + ZenMux 聚合平台降低 API 成本 |
| [如何给 OpenClaw 搭建永不失忆的记忆系统](如何给OpenClaw搭建永不失忆的记忆系统/article.md) | [@calicastle](https://x.com/calicastle) | 2026-02-10 | 三层记忆架构：Daily Sync + Weekly Compound + Hourly Micro-Sync + qmd 语义搜索 |
| [搞定 OpenClaw 多层备份策略](搞定OpenClaw多层备份策略/article.md) | [@wlzh](https://x.com/wlzh) | 2026-02-11 | 三层配置备份防护：Patch 自动备份、Cron Git 备份、系统自带备份 |
| [一万字提示词给你的 AI 造一个数字灵魂](一万字提示词给你的AI造一个数字灵魂/article.md) | [@vista8](https://x.com/vista8) | 2026-02-10 | TELOS 数字身份系统 + 三层记忆架构 + Hooks/Skills 可编程 AI 基础设施 |
| [龙虾 4 兄弟的 AI 协作实战](龙虾4兄弟的AI写作实战/龙虾4兄弟的AI协作实战.md) | [@servasyy_ai](https://x.com/servasyy_ai) | 2026-02-08 | 多人协作使用 OpenClaw 构建数字人分身的真实经历 |

## 目录结构

```
├── <文章标题>/
│   ├── article.md          # 正文（Markdown 格式）
│   └── media/              # 配图与截图
│       ├── full_page.png
│       └── img_*.jpg
└── README.md
```

## 涵盖话题

- **定时任务 (Cron)** — 调度精度、超时处理、退避策略、投递可靠性
- **记忆系统 (Memory)** — qmd 语义搜索、分层记忆架构、自动化 context 捕获
- **成本优化 (Token)** — QMD 检索替代全量上下文、聚合平台价格杠杆
- **配置管理 (Config)** — 多层备份、安全修改流程、紧急恢复
- **个人 AI 基础设施** — TELOS 数字身份、Hooks/Skills 可编程框架、Personal AI Infrastructure
- **协作实践** — 多人 Agent 协作、数字人分身

## License

本仓库仅作学习与归档用途，文章版权归原作者所有。
