# 产品大师 MAGI

用三个 AI Agent 自动写 PRD 和交互 Demo。Leader PM 出方案，Reviewer 找茬，Controller 调度——三人吵架一人拍板。

---

## 推荐运行环境

**OpenClaw**（`openclaw.ai`）。支持 macOS / Linux，用 `deepseek-v4-pro` 实测通过。

---

## 安装

在 OpenClaw 里发一句话就行：

> 帮我安装 git@github.com:Kira2red/magi-product.git

OpenClaw 会自动 clone 到 `.openclaw/skills/product-master/`，无需手动操作。

---

## 使用

在 OpenClaw 里说：

> 启用产品大师，做一个智能座舱后视镜调节的 PRD 和可交互 HTML Demo

它怎么跑：

```
阶段一：方案共识 ──→ 你确认
       ↓
阶段二：交互验证 ──→ 你确认  （Demo 出来了，打开浏览器试）
       ↓
阶段三：文档定稿 ──→ 交付
```

每阶段结束都会停下来等你确认，不会自说自话跑偏。

---

## 三 Agent 角色

| Agent | 职责 |
|-------|------|
| 🎯 Controller | 调度流程、管理确认门、执行格式检查 |
| 📝 Lead PM | 场景理解、方案概要、Demo 产出、PRD 撰写 |
| 🔍 Reviewer | 找茬：证据审查、交互审查、逻辑一致性 |

---

## 能做什么

- 功能型 PRD + 可交互 HTML Demo（完整三阶段）
- 策略型 PRD（优化算法/AB 测试，加埋点实验，跳过 Demo）
- 架构型 PRD（系统重构/模块拆分，加系统关联，跳过 Demo）
- 修复型 PRD（Bug 修复/体验优化，简化阶段一，跳过 Demo）
- 纯后端 / 硬件 / 合规需求（跳过 Demo，其余正常跑）

## 目前做不了什么

- 多端同步 Demo（车机 + 手机 + Web，能做多个 HTML 但需后续整合）
- 硬件定义的功能（物理手感没法在 HTML 里模拟）
- 需要真实业务数据作依据的功能（Agent 没有数据库）

---

## 自定义

产品大师的 skill 文件都在 `部署包-product-master/` 里：

```
部署包-product-master/
├── SKILL.md              ← Controller 调度规则
├── lead-pm-prompt.md     ← Lead PM 的工作指令
├── reviewer-prompt.md    ← Reviewer 的审查标准
├── watchdog.sh           ← 看门狗脚本（自动检测卡死）
└── 部署说明.md
```

如果你觉得写得不好，**在同一台电脑上随便用 Codex CLI、Cursor、Kilo 等 coding agent 去改这些 MD 文件**。改完让 OpenClaw 重载就行。

---

## 核心设计

### 防卡死

- `sessions_spawn` 工具调用必须紧跟宣告文本，空喊不执行
- 外部 watchog 脚本四路检测：时间差 / 网关警告 / 漏读结果 / 状态停滞
- 子 Agent 超时自动重试，两次不行通知用户裁决

### 格式约束

- PRD 正文只用文字 + 表格 + Mermaid，禁止 ASCII 框图
- 嵌入 2red-product-monster-prd 完整规范（共享层/模块层分离、界面元素自查清单、验收标准五维覆盖）
- 嵌入 prd-review-skill 终审标准

### 竞品搜索

通过 OpenClaw 的 web_search 能力（DuckDuckGo，免费无需 API Key），Lead PM 可真实搜索竞品信息作为 PRD 依据。

---

## 反馈

直接提 Issue，或者把改过的 skill 文件 PR 回来。
