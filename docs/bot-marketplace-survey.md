# botone Bot 市场勘察报告（只读研究，未改代码）

日期：2026-11-12。本报告为后续 Bot 市场架构设计的输入。参考对象：Grok Bot 市场、OpenMausBot 市场。所有结论均有仓库内路径证据。

## 一句话结论

botone 已有一个「插件/工具市场」（聚合 Cursor + xAI 公开注册表的 `marketplace` RPC 命名空间 + 提交审核工作流）和一个「Bot 模板目录」（4 个硬编码 `BOT_TEMPLATES`，经 agent-import 管线惰性安装），但**没有**跨用户的 Bot 发布/分享机制——Bot 市场需要新建发布实体与目录层，可大量复用现有模板安装管线、能力安装持久化与审核模式。

## 1. 可复用的 Bot 实体与持久化

### 1.1 Bot 实体（市场的"商品"安装后的最终形态）
- `packages/db/prisma/schema.prisma:954` `model Bot`：spaceId/userId 归属、name/description/instructions/instructionHistory、parentBotId（Bot 层级）、spawnKey（`@@unique([spaceId, spawnKey])`）、memoryScope、computerId、modelProvider/modelId/thinkingLevel、disabledBuiltinTools、webhookSecretId、routine/skill/memory/MCP/secret 关联。**Bot 是空间私有实体，没有任何对外发布/可见性字段。**

### 1.2 BotTemplate 契约与模板目录（Bot 市场商品声明的直接原型）
- `packages/contracts/src/bot-template.ts:19` `BotTemplateSchema`：strictObject，字段 id(slug)/version/name/summary(≤120)/sample(≤2000 Markdown 示例)/description/instructions/skills(≤5，name+description+body≤20000)/routines(≤5，name+prompt≤4000+crons)/apps(≤6 连接目录 slug)。**刻意不含密钥、记忆、历史、模型、服务器**（文件头注释明确此安全边界）。
- `packages/contracts/src/bot-template.ts:57` `BotTemplateListingSchema = BotTemplate + botId: nullable`（同一 space+user 幂等安装后回填已有 bot）。
- `packages/contracts/src/bot-template.ts:78` `BOT_TEMPLATE_IMPORT_KEY_PREFIX = "template:"`、`:81` `BOT_TEMPLATE_CHANGED`（版本乐观校验，预览过期拒绝创建）。
- `packages/core/src/bot-templates.ts`：`BOT_TEMPLATES` 硬编码 4 个内置模板（含本地化 name/summary/sample），**无数据库表、无外部注册表、无动态加载**。
- `apps/api/src/bot-templates.ts`：`listBotTemplates()` 用 `AgentImport`（importKey=`template:<id>`、source="template"）联结出 botId；`templatePlan()` 把模板转成与普通导入一致的 `AgentImportPlan`；createFromTemplate 幂等（"One bot per template"）。
- 安装语义（`apps/api/src/routes/bots.ts:330-395`）：导入/模板创建出的 Bot 一律 **inert**——不发介绍消息、routines 暂停、MCP 服务器未批准。

### 1.3 AgentImport 幂等导入管线（任何"安装到我的空间"流的可复用骨架）
- `packages/db/prisma/schema.prisma:1632` `model AgentImport`：`@@unique([spaceId,userId,importKey])` 幂等键、source 枚举、created(Json)。
- `packages/contracts/src/agent-import.ts:49` source 枚举 `["openclaw","hermes","document","template"]`——新增市场来源需扩此枚举 + Prisma enum。
- `packages/contracts/src/agent-import.ts:175` `AgentImportPlanSchema`：instructions/memory/skills/model/mcpServers/routines/apiKeys/skipped——安装预览的统一中间表示。
- `:230` `AgentImportCreateInput`：importKey 由客户端选定（8-100 字符，不得以 `template:` 开头），重试返回同一 Bot。

### 1.4 能力安装持久化（技能/MCP/插件的落地行）
- `packages/db/prisma/schema.prisma:1699` `model CapabilityInstall`：kind/name/source/version/digest/secretId/config/allSpaces；关联 agentSkills 与 mcpServers。**插件的持久化就是 CapabilityInstall 行，没有 Plugin 表**。
- `schema.prisma:1654` `model AgentSkill`（SKILL.md 配方，source `user|builtin|plugin`，installId→CapabilityInstall）。
- 跨空间共享：`packages/contracts/src/rpc.ts:1063` `availability` 命名空间（items/chooseForSpace）——用户自己的技能/MCP/插件跨自己的空间共享，**不跨用户**。

## 2. 已存在的市场基础设施（插件市场，可整体借鉴）

### 2.1 聚合目录
- `packages/adapters/src/plugin-marketplace.ts:8-27` `REGISTRIES = [Cursor: github.com/cursor/plugins (.cursor-plugin/marketplace.json), xAI(Grok): github.com/xai-org/plugin-marketplace (.grok-plugin/marketplace.json + plugin-index.json)]`；MANIFEST_TTL 1h / CATALOG_TTL 10min 缓存；原则："Public indexes are discovery hints, never installation authority"（公开索引只做发现，安装必须经 preview/digest 校验）。
- `apps/api/src/routes/capabilities.ts:69-100` `marketplace.catalog`：合并注册表目录 + `approvedPluginEntries(prisma)`（审核通过的提交），按 installedSource 去重。

### 2.2 提交审核工作流（Bot 市场上架审核的直接原型）
- `packages/db/prisma/schema.prisma:543` `model PluginSubmission`：email/name/website/logo/claim(slug)/confirmToken/confirmExpiresAt/source/description/testing/status(pending)/reason/pinnedSource/hasConnector/skillCount/reviewedAt——**是审核队列表，不是可安装实体表**。
- `apps/api/src/plugin-submissions.ts`：PLUGIN_REGISTRY="Rakazo"；限流（10 次/IP/小时、3 次确认/邮箱/天）；邮件确认令牌流。
- `apps/api/src/admins.ts`：`isAdmin` = 邮箱在 `RAKAZO_ADMIN_EMAILS` 环境变量且已验证；`requireAdmin` 抛 ORPCError FORBIDDEN。
- `packages/contracts/src/domain.ts:900-1000`：`PluginMarketplaceEntrySchema {id,name,displayName,description,keywords,category,logo,homepage,domains,registry,source,installedSource,hasConnector,skillCount}`、`PluginPreviewSchema`（format 枚举 `agent-plugins|cursor|grok`、digest、sha256 校验）。

### 2.3 RPC 契约结构
- `packages/contracts/src/rpc.ts:1082` `marketplace` 命名空间（catalog 任何登录用户 / submissions、review 仅 admin）；`:1091` `capabilities` 命名空间（install：kind `skill|plugin|mcp|api|graphql`，插件必须 pluginDigest `sha256:[a-f0-9]{64}`）；`:591` `bots` 命名空间（templates/createFromTemplate/duplicate/importPreview/importCreate/...）。
- 认证中间件：`apps/api/src/routes/context.ts:416-431` `signedIn`（actor + `asTenant` 租户上下文，Postgres RLS）。

### 2.4 前端界面（市场 UI 的现有落点）
- Web：`apps/web/src/pages/PluginsOverlay.tsx` + `pages/plugins/{plugin-browse,github-import,parts,add-menu,connector-detail,domain-search,manage-view}.tsx` + `PluginSubmissionsPanel.tsx`；Bot 模板 UI `components/bot-templates/bot-templates-dialog.tsx`。
- Mobile：`apps/mobile/app/(settings)/{bot-templates,bot-template,plugin,skills,skill,integrations}.tsx`。
- 官网提交入口：`packages/contracts/src/domain.ts` `SUBMIT_PLUGIN_URL = "https://rakazo.com/plugins/submit/"`、`PLUGIN_SUBMISSIONS_PATH`/`INTEGRATION_CLAIMS_PATH` 公开 HTTP 路由。

## 3. 明确的对接点清单（新 Bot 市场应挂接的位置）

| 对接点 | 文件 | 接入方式 |
|---|---|---|
| 商品声明 schema | `packages/contracts/src/bot-template.ts` | 扩展或平行新建 `BotMarketplaceEntry`；保留"不含密钥/模型/记忆"的 strictObject 纪律 |
| 安装流 | `apps/api/src/bot-templates.ts` 的 `templatePlan()` + `createFromTemplate` | 市场商品安装复用 AgentImportPlan → inert Bot 管线 + `template:` importKey 幂等模式 |
| 幂等记录 | `model AgentImport`（schema.prisma:1632） | 新增 source 枚举值（如 "marketplace"）+ importKey 约定前缀 |
| 目录列表 | `rpc.ts` `marketplace.catalog` + `PluginMarketplaceEntrySchema` | 平行加 `botMarketplace` 命名空间或在 marketplace 下扩 bots 子目录；合并外部注册表 + `approved*Entries` 的模式可直接照搬 |
| 上架审核 | `model PluginSubmission` + `plugin-submissions.ts` + `admins.ts` | 复制为 BotSubmission（邮件确认 + admin 审核 + 限流） |
| 能力落地 | `CapabilityInstall`/`AgentSkill`/`BotMcpServer` | 市场商品携带的 skills/apps 走现有 capabilities.install 与连接目录 slug |
| 前端 | web PluginsOverlay / plugins 页面组、mobile (settings) 路由 | 新增市场 tab/页面，消费同一 oRPC 契约 |
| 认证/租户 | `routes/context.ts` signedIn + `asTenant`（RLS） | 所有新 RPC 过 signedIn；审核类过 requireAdmin |

## 4. 不应假设存在的功能（与 Grok/OpenMausBot 市场对照的缺口）

1. **没有跨用户 Bot 发布/分享**：Bot 全部 space 私有；`grep publishBot|shareBot|botSubmission` 无结果；只有账户级导出 `apps/api/src/account-export.ts`（自己的 spaces 打 zip 迁移到另一实例）。
2. **没有评分/评论/下载量/热度字段**：domain.ts、plugin-marketplace.ts、schema.prisma 中无 ratings/stars/reviews/installCount/screenshot/gallery/featured/trending（已 grep 验证）。
3. **没有 Plugin 数据库表**：插件安装态就是 CapabilityInstall 行；注册表条目不落库（仅缓存）。
4. **BOT_TEMPLATES 是硬编码常量**：无外部 Bot 模板注册表、无动态目录拉取（与插件市场的 GitHub 注册表聚合不同）。
5. **模板刻意不能携带密钥/模型/记忆/历史/服务器**（bot-template.ts:14-18 注释）——Bot 市场商品若要带 MCP 服务器或模型偏好，需新设计而非假设模板可扩展存放。
6. **没有面向市场条目的支付**：计费体系存在（Payment/Purchase/ModelCreditAccount 模型、spending limits），但没有按商品付费/分成的任何表或流程。
7. **审核员体系仅一个环境变量名单**（RAKAZO_ADMIN_EMAILS），无角色/团队审核、无审核工作台 API（只有 submissions/review 两个 RPC）。
8. **vendor 中立纪律**（AGENTS.md）：供应商名只能出现在 adapters/composition root——对接 Grok/xAI 注册表时必须遵守既有 REGISTRIES 抽象方式，不能在 core/contracts 硬编码供应商。

## 5. 对架构设计的直接建议（非实施）

- 商品形态 = BotTemplate 超集但继续走 strictObject 白名单：instructions/skills/routines/apps/sample 已覆盖 Grok 式 Bot 商品的多数字段；缺的是 author/截图/统计/版本历史，全部需要新表。
- 安装路径最省：市场商品 → `AgentImportPlan` → 现有 inert 安装管线，幂等键用新前缀（如 `marketplace:`），与 `template:` 一样保留。
- 目录层可复制 plugin-marketplace.ts 的"外部注册表只做发现 + digest 校验做安装授权"双层模型，接入 xAI/Grok 的 Bot 注册表同理。
