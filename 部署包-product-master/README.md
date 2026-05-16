# 产品大师（MAGI System）

三 Agent 协作的产品方案生成系统。

## 灵感来源

> 「MAGI 是由三個獨立思考的量子電腦組成的超級電腦系統。三個 MAGI 分別命名為 MELCHIOR、BALTHASAR 和 CASPER。當需要做出重大決策時，MAGI 會進行投票，如果三個 MAGI 中至少有兩個達成一致，決策就會被執行。」

— 新世紀福音戰士（Neon Genesis Evangelion）

产品大师借用了 MAGI 的核心思想：**用多个独立 Agent 互相审查达成共识**，而不是靠单一个体的一次性输出。

| MAGI | 产品大师 |
|------|---------|
| MELCHIOR（科學家） | Lead PM — 产出方案，负责创造 |
| BALTHASAR（母親） | Controller — 调度流程，负责协调 |
| CASPER（女性） | Reviewer — 审查缺陷，负责挑刺 |

与 MAGI 不同的是，产品大师不是投票制——Controller 是最终裁决者，但必须在 Lead PM 和 Reviewer 都给出意见后才能做决定。

## 三阶段流程

```
阶段一：方案共识          阶段二：交互验证          阶段三：文档定稿
   │                        │                        │
Lead PM + Reviewer      Lead PM + Reviewer       Lead PM 终稿
达成方案概要            产出+审查 HTML Demo       + 双重终审
   │                        │                        │
  ⏸ 等用户确认            ⏸ 等用户确认              ✅ 完成
```

## 特性

- **双 Agent 共识**：每个阶段产出都是 Lead PM + Reviewer 合并结果
- **先验证再定稿**：先做交互 Demo 让用户确认，再写正式 PRD
- **PRD 类型自适应**：功能型 / 策略型 / 修复型 / 架构型，自动调整流程
- **竞品真搜索**：所有竞品对标基于 DuckDuckGo 搜索结果，不拍脑袋
- **证据诚实**：数据无真实来源一律标注「假设值」，不假装有数据
- **自愈机制**：子 Agent 超时自动重试，看门狗防卡死
- **格式自动化验证**：ASCII 框图、技术实现细节自动拦截

## 文件结构

```
product-master/
├── SKILL.md              # Controller — 三阶段调度逻辑
├── lead-pm-prompt.md     # Lead PM — 场景确认、方案概要、Demo、PRD
├── reviewer-prompt.md    # Reviewer — 三阶段各环节审查
├── watchdog.sh           # 看门狗 — 自动检测卡死并恢复
├── README.md             # 本文件
└── 部署说明.md           # 部署指南
```

## 依赖的 OpenClaw 配置

- `2red-product-monster-prd` skill — PRD 格式规范（嵌入在 lead-pm-prompt.md 模式 C 中）
- `prd-review` skill — PRD 结构审查标准（嵌入在 SKILL.md 终审中）
- DuckDuckGo web search（免费，免 API Key） — 竞品分析数据源
