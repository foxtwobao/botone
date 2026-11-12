# Bot 市场竞品调研：Grok Bot Marketplace 与 OpenMausBot

日期：2026-11-12。只读调研，未改任何代码。所有事实均带一手证据（官方文档 `.md` 原文、真实页面 HTML、GitHub 仓库源码）；二手转述单独标注。

## 0. 一句话结论

- **Grok 的「Bot 市场」真实存在**，URL 是 `https://x.ai/bot/marketplace`（网页版画廊，91 个 bot、按职能分类、搜索、作者署名、免费），应用内通过「Import Bot」把 bot 配置复制到用户账户。它不是独立 App，是 Grok Bot（桌面/移动端 agent 产品）的模板分发层。
- **OpenMausBot（现名 MausBot，`openmausbot.com` 301 到 `mausbot.com`）没有公开网页市场**（`/marketplace`、`/templates` 等全部 404）。它的「市场」是**应用内 Templates 页**：内置 ready-made bot 画廊（约 18 个）+ 导入（可粘贴 Grok 市场链接或 `.openmaus.json` 文件）+ 组织库（Admin 发布）。核心设计是「preset 是白名单，永远不能扩大 bot 的权限」。
- **botone 已有 80% 的管道**：4 个内置 Bot 模板（`BOT_TEMPLATES`）+ 完整的 agent import 事务写入 + 一个现成的**插件市场**（聚合 Cursor/xAI 插件注册表、含投稿/审核/邮件确认流程）。缺的只是「模板数量、分类/搜索、发布体系」。

---

## 1. 已验证事实：Grok Bot Marketplace

### 1.1 市场首页（https://x.ai/bot/marketplace，2026-11-12 抓取 HTML，370KB）

| 能力 | 观察到的证据 |
|---|---|
| 分类导航 | `All · From Grok Bot Team · Engineering · Sales · Marketing · Design · Personal · Recruiting & People · Product · Operations · Featured`（首页导航原文） |
| 搜索 | `<input type="search" placeholder="Search by creator or bot name">`（按创作者或 bot 名搜索） |
| 规模 | 首页 HTML 中提取到 91 个 `/bot/marketplace/bots/<slug>` 链接 |
| 卡片信息 | 名称 + 作者署名（`by Lauren Tan` / `by Lenny Rachitski` / `by Krista Letz`）+ 一句话描述 + **Add** 按钮 |
| Featured 位 | 4 个：dr eggbot、Overheard、Tradbot、Projects Manager（官方文档也直接推荐：https://docs.x.ai/grok-bot/get-started.md） |
| 价格 | JSON-LD 里 `"offers": {"price": 0, "priceCurrency": "USD"}` —— 当前免费 |
| 评分/收藏/安装量 | **抓取的两页 HTML 中未出现**任何评分、收藏、安装计数 UI（不能断言不存在，但首页和详情页均未见） |

### 1.2 单品详情页（https://x.ai/bot/marketplace/bots/echo "Meeting Recap Deck"）

| 元素 | 证据 |
|---|---|
| CTA | **Import Bot**（导入 = 在自己账户创建一份副本） |
| 四个展开区块 | `memories — Facts it already knows`、`skills — Playbooks it can run`、`routines — Jobs that run on their own`、`integrations — Apps it can use` |
| 数据模型（页面内嵌 JSON） | `"memories":[{id,name,description}...]`、`"skills":[{id,name,description,content}...]`，每条 skill 带触发条件描述（如 "Use on the first conversation after setup..."）；另有 `updatedAt` 时间戳、作者头像存于 `grok-bot-marketplace-public-assets.s3.amazonaws.com` |
| 自我介绍 | 详情页直接展示 bot 的完整第一人称 system prompt（工作方式、边界、"never send without your yes"） |
| 结构化数据 | JSON-LD `SoftwareApplication`：name/description/applicationCategory/operatingSystem/offers(price 0)/author(Person)/isPartOf(marketplace collection) |
| 安全边界表述 | 模板卡文案明说草稿不发送、例程默认关闭（"My post-meeting draft and Friday roundup stay off until you turn them on"） |

### 1.3 发布与版本（官方文档 https://docs.x.ai/grok-bot/bots.md，一手原文）

- **发布路径**：应用内 Bot 详情 → **Share → Create a copy** → 生成模板卡 → **Publish** → 公开链接（x.ai 预览页 + "Add to Grok Bot"）。
- **版本管理**：发布后 Share 菜单提供 **Update template**（推送最新更改到共享副本）和 **Delete Template**（下线链接）。
- **安全模型（原文关键句）**：
  - "A public link … exposes the Bot's shared configuration: its identity, description, skills, and routines."
  - "Adding a shared template creates a copy on the recipient's account. **They never get your computer, logins, or conversation history.**"
  - 文档明确警告分享前移除 API keys、内部 URL、客户数据。
  - 导入时展示并要求接受第三方 bot 条款（x.ai/legal/bot-sharing-terms）。
- **企业管理**：Teams/Enterprise 管理员可关闭公开模板分享或限制为 team-only；企业默认仅团队内分享。
- **市场入口（应用内）**：侧栏 **Connect apps → Bot templates**，画廊在浏览器打开（即上面那个 x.ai 网页）。
- **发现位**：首次使用引导里直接放 4 个市场 bot 链接（get-started.md）。

### 1.4 无法验证 / 二手信息

- 「Agent Store 收入分成 / 开发者赚钱」：仅见于新闻转述（WebSearch 摘要），官方页面显示 price 0、文档未提分成。**不要当事实用。**
- "Grok Agent Store" 这个名字本身：xAI 官方页面自称 **"Grok Bot Marketplace"**（页脚导航原文）。新闻里叫 Agent Store。
- 未抓取：分类子页（如 `/marketplace?category=...` 的分页行为）、移动端内嵌视图。

---

## 2. 已验证事实：OpenMausBot / MausBot

身份：`openmausbot.com` → 301 → `mausbot.com`，自称 "The open source Grok Bot alternative"，GitHub 仓库 `milind-soni/OpenMausBot`（Apache-2.0，21.3k stars，2026-11-12 仍在活跃提交）。主页自述 + 仓库 API 元数据均可验证。

### 2.1 它没有公开网页市场

`mausbot.com/marketplace`、`/templates`、`/bots`、`/gallery`、`/community` 全部 **404**（逐一探测）。文档站 sitemap（https://docs.openmausbot.com/sitemap.xml，48 页）里没有任何 marketplace/template/store 页面。它的「市场」完全在**应用内 Templates 页**。

> 仓库里有一张 `docs/screenshots/marketplace.png`，但 changelog 上下文表明那是 **Composio 连接应用目录**（"Report why the Composio marketplace catalog stalled"），即 Gmail/Slack 这类 app 连接器市场，**不是 bot 市场**。两者别混。

### 2.2 应用内 Templates 页（源码 + changelog 验证）

**a) 内置 ready-made bot 画廊** — `src/components/ReadyBotGallery.tsx` + `src/lib/ready-bots.ts`（GitHub main 分支源码）：

- 6 个分类：`everyday / work / writing / design / sales / personal`（`READY_BOT_CATEGORIES`）。
- 约 18 个内置 bot（`READY_BOTS` 数组，含 Assistant、Inbox、Scout、Dev 等），每个含：name、title、description、**soul（完整 system prompt）**、外观、`tryAsking` 示例问题、`apps`（建议连接的应用，"suggested, never connected"）、可选 `routines`（**默认 paused**）。
- 卡片显示：分类徽标、描述、示例提问、"Works with Gmail"、paused routine 标记；Add → 打开 NewBotDialog 审阅后才创建。
- 来源：changelog PR #3095 "feat(templates): a gallery of ready-made bots"。

**b) 导入** — changelog #3073（https://docs.openmausbot.com/docs/changelog）：

> "Import a shared Grok Bot. **Paste a Grok Bot link or marketplace page in Templates → Import** … You see who made it and what it does, then bring in its full setup."

即 MausBot 能直接吃 Grok 市场链接（竞争对手的 URL 当导入源）。另支持 `.openmaus.json` 团队/预设文件导入（`src/lib/template-add.ts`：导入规则是 "new records only, skills off, routines paused"，走 `/api/teams/import?mode=add`）。

**c) 组织库（Templates → From {Organization}）** — `docs/org-library.md`：

- Admin 在后台上传包，桌面端一键 Add；无确认步骤（"the person's click is the decision"）。
- 与文件导入的差异：组织发布的 skills **默认开启**（Admin 审核过），routines 仍暂停，连接器仍不带值。
- 每条记录盖 install 戳（source/installId/publisher/ref/sha256）；每部分存两个 hash（发布版 `r` + 本地修改版 `w`），后续自动更新用它区分"你的修改 vs 发布者的修改"。
- 幂等：同一包重复 Add 返回 `200 {alreadyAdded: true}`。
- 下架：组织撤回后模板不再提供，已建 bot 的该版本 skills 关闭一次（可自行重开）。

### 2.3 安全模型（这是最值得抄的设计）

`docs/presets.md` 原文：

> "A preset is an allowlist. It can carry only: name/description; the new bot's name, title, description and standing instructions; its look; playbooks; skills (the `SKILL.md` text only, never scripts); starter notes. **It has no field for a model, a folder, a computer, an approval level, connected apps, MCP servers, a browser, peers or routines … so a preset can never widen what a bot may do.**"

配套措施（`server/presets.ts` 源码注释 + `docs/team-sharing.md`）：

- 存储的 preset 每次使用都重新过同一个包解析器（"a hand-edited presets.json still says only what a file may"）。
- 分享文件导出时跑**密钥脱敏**：token 形状的文本替换为标记，URL 里的 key/query 值清空（`?key=`、`;matrix` 参数名保留值清空），保存前逐项列出改了什么。
- 文件导入的 skills 默认**关闭**，用户读过再开。
- 上限：每 bot 30 skills、每团队 60、单 skill 名唯一、`MAX_STORED_PRESETS = 200`、头像 ≤256×256/64KB。

### 2.4 创作者体系

没有公开创作者主页/分成。创作者 = 组织（publisher：organizationId/slug/name）或文件发送者。来源标注做得很认真：Bot 设置页显示 "From Sales desk 1.3.0 · Acme Partners"。

---

## 3. 竞品功能对照表

| 维度 | Grok Bot Marketplace | OpenMausBot/MausBot Templates | botone 现状 |
|---|---|---|---|
| 形态 | 公开网页画廊 + 应用内入口 | 应用内页面，无公开网页 | 应用内（web 弹窗 + 移动端页），无公开画廊 |
| 分类 | 职能分类 ~9 个 + Featured | 6 个分类 | **无**（仅 4 个模板平铺） |
| 搜索 | "Search by creator or bot name" | 画廊内文本过滤（`matchesReadyBot`） | **无** |
| 数量 | 91（首页 HTML 实测） | ~18 内置 + 导入/组织库 | **4**（`packages/core/src/bot-templates.ts:9`） |
| 详情页 | 自我介绍全文 + memories/skills/routines/integrations 四区块 | 预览（preview shows preset bots + skills） | 有：示例输出 + skills + routines(cron) + apps 徽标（`apps/web/src/components/bot-templates/bot-templates-dialog.tsx`） |
| 示例 | 描述 + 部分带 starter prompt | `tryAsking` 示例问题 | `sample` 示例输出（已有，比两家都实） |
| 安装 | Import Bot → 账户副本 | Add → NewBotDialog 审阅后创建 | `createBotFromTemplate` → 一事务写入，**每用户每模板一个 bot**（幂等，`apps/api/src/bot-templates.ts:30`） |
| 安全不变量 | 不带 computer/logins/history；企业管控公开分享 | 白名单：无 model/computer/approval/apps/MCP 字段；skills 默认关；密钥脱敏 | 已符合：`templatePlan` 里 model:null、mcpServers:[]、apiKeys:[]、routines 全部 paused（`apps/api/src/bot-templates.ts:56-117`） |
| 权限/连接 | 导入后引导连 app | 连接器仅"建议"，值不随包走 | 未连接的 app 发 appConnectCard 引导（`templateAppCards`） |
| 版本管理 | Update template 推送 / Delete 下线 | release + r/w 双 hash 自动更新 + sha256 戳 | `template.version` + `BOT_TEMPLATE_CHANGED` 预检（旧预览拒绝创建）——已有 |
| 发布 | 用户从应用发布公开链接 | Admin 组织库 / 文件分享 | **无**（模板硬编码在仓库）；但插件侧已有完整投稿+审核+邮件流程（`apps/api/src/plugin-submissions.ts`） |
| 创作者体系 | 作者署名 + 头像 | 组织 publisher + 来源标注 | 无 |
| 定价/分成 | price 0；分成仅传闻未验证 | 无（开源免费） | 无 |

---

## 4. botone 现状盘点（本地代码证据）

已有的、直接可复用的管道：

1. **模板目录与数据模型**：`packages/core/src/bot-templates.ts:9` — `BotTemplate` 含 id/version/name/summary/sample/description/instructions/skills/routines/apps。注释明确「内容变更必须 bump version，旧预览的创建会被拒绝」。
2. **创建事务**：`apps/api/src/bot-templates.ts:133` `createBotFromTemplate` — 单事务、routines 暂停、setup checklist、缺失 app 的连接卡片、同空间内未改动 skill 的复用（防重复）、每用户幂等（importKey），archived bot 自动让位。
3. **导入通用管道**：`packages/contracts/src/agent-import.ts:49` — 来源枚举 `["openclaw","hermes","document","template"]`，preview → 选择 → create 两段式，digest 防重放。**「template」已经是四种合法来源之一**。
4. **一个现成的插件市场**（这是容易被忽略的资产）：
   - `packages/adapters/src/plugin-marketplace.ts:10` — 聚合 **Cursor 插件注册表和 xAI plugin-marketplace 仓库**两个上游，含分类、查询过滤、digest 固定。
   - `apps/api/src/routes/capabilities.ts:69` — `marketplace.catalog / submissions / review` 三条路由，审核需 `requireAdmin`。
   - `apps/api/src/plugin-submissions.ts` — 投稿、IP/邮箱限流、邮件确认、integration claim、审核邮件。
   - Web UI：`apps/web/src/pages/PluginsOverlay.tsx`、`plugin-browse.tsx`、`PluginSubmissionsPanel.tsx`。
5. **双端 UI**：web `bot-templates-dialog.tsx`（含示例输出渲染、cron 人性化、app 徽标）；mobile `apps/mobile/app/(settings)/bot-templates.tsx` + `bot-template.tsx`。

结论：botone 缺的不是管道，是**内容量（4 个太少）、发现层（分类/搜索）、发布闭环**。

---

## 5. 设计方案（按最小可行 → 逐阶段）

### 设计原则（从竞品提炼，一句话版）

> **一个市场条目是一份白名单配置，只能缩小、不能扩大 bot 能做什么**：不带 model、不带 computer/权限级、不带已连接 app、不带密钥；routines 一律暂停；skills 走用户审阅。这条是 OpenMausBot 用整个 presets.ts 换来的教训，botone 的 `templatePlan` 已经天然符合——把它固化成测试，别在迭代中破坏。

### Phase 1 — 把现有模板页升级成「市场」（纯内容 + 浅 UI，无新后端概念）

1. **扩目录**：`BOT_TEMPLATES` 从 4 个扩到 15–20 个。对照 Grok 的分类选型（Engineering/Sales/Marketing/Design/Personal…），每个模板保持现有字段完整度（含 `sample` —— 这是 botone 已有、两家竞品都没有的优势，务必保留）。
2. **加字段**：`BotTemplate` 增加 `category: string`、`author?: string`、`featured?: boolean`（contracts + core 同步，纯增量）。
3. **发现层**：web dialog 和 mobile 列表页加分类 chip + 搜索框（按名称/摘要/作者过滤，前端过滤即可，20 个条目不需要后端搜索）。Featured 置顶。
4. **安全不变量测试**：给 `templatePlan` 加一个断言测试——输出的 plan 永远 `model === null && mcpServers.length === 0 && apiKeys.length === 0 && routines 全部 active:false`。
5. 沿用现有 `version` + `BOT_TEMPLATE_CHANGED`，不加更新推送。

这一步对用户的可见变化：模板页从「4 个平铺」变成「像样的市场」。改动集中在 `packages/core/src/bot-templates.ts`、contracts、两个 UI 文件。

### Phase 2 — 用户发布闭环（复用插件投稿管道）

1. **导出**：「把我的 Bot 分享为模板」：从现有 bot 提取 instructions + skills（仅 SKILL.md 文本）+ routines（导出为暂停）+ apps 需求标签，走 agent-import 已有的 `containsKey` 检测做密钥脱敏（OpenMausBot 的做法，botone 的 contracts 里已有该标记位）。
2. **投稿与审核**：新 `botTemplateSubmission`，完全镜像 `plugin-submissions.ts` 的形态：限流、邮件确认、`requireAdmin` 审核、approved 后进目录（Grok 用公开链接 + 企业管控，MausBot 用 Admin 审核；botone 已有审核管道，选审核制成本最低）。
3. **导入兼容**：Templates → Import 支持「粘贴 Grok 市场链接」可以列为可选增强（MausBot 已验证可行，changelog #3073），但**不是 MVP**。

### Phase 3 — 组织库（space 级）

对照 MausBot org-library：space Admin 发布模板 → 成员一键创建；skills 默认开（Admin 即审核）、routines 仍暂停；记录 install 来源（publisher/release/sha256），为将来「模板更新」留 r/w 双 hash 的口子。botone 的 `availableInSpace` 模型天然支持这个范围。

### 明确不做（本轮）

- **定价/收入分成**：Grok 市场实测 price 0，分成仅传闻；无先例可抄。
- **评分/评论/收藏**：两家已验证页面里都没看到，无需求证据。
- **公开网页画廊（x.ai 式）**：botone 的 `apps/www` 是 Astro 营销站，可以先放 2–3 个精选模板的静态展示引流，但完整画廊等 Phase 2 之后再评估。
- **模板更新推送**：Grok 的 Update template 和 MausBot 的自动更新都建立在「创作者长期维护」之上，botone 现阶段模板都是官方维护，`version` 预检够了。

---

## 6. 证据清单

**Grok（全部 2026-11-12 抓取/读取）**
- 市场首页 HTML：https://x.ai/bot/marketplace （分类导航、搜索框 placeholder、91 个 bot slug、Add 按钮）
- 详情页 HTML：https://x.ai/bot/marketplace/bots/echo （四区块、Import Bot、JSON-LD、内嵌 memories/skills JSON、S3 创作者头像）
- 官方文档（markdown 原文）：https://docs.x.ai/grok-bot/bots.md （Share as Template / Publish / Update template / 安全边界 / 企业管控）
- https://docs.x.ai/grok-bot/get-started.md （应用内入口 Connect apps → Bot templates、4 个推荐 bot、市场链接）
- https://docs.x.ai/grok-bot/overview （Grok Bot 产品全貌）
- 文档索引：https://docs.x.ai/llms.txt

**OpenMausBot / MausBot**
- 官网（301 目标）：https://mausbot.com/ （"open source Grok Bot alternative"、Templates/New bot 文案）
- 404 探测：mausbot.com/{marketplace,templates,bots,gallery,community}
- 文档站 sitemap（48 页无市场页）：https://docs.openmausbot.com/sitemap.xml
- Changelog（#3073 导入 Grok 市场链接、#3095 画廊）：https://docs.openmausbot.com/docs/changelog
- GitHub 源码（main 分支）：https://github.com/milind-soni/OpenMausBot
  - `src/lib/bot-presets.ts`（BotPreset 白名单结构、presetDraftPatch 不碰 model/computer/approval）
  - `server/presets.ts`（"A preset is an allowlist … nothing it says can widen what a bot may do"、MAX_STORED_PRESETS=200）
  - `src/components/ReadyBotGallery.tsx` + `src/lib/ready-bots.ts`（6 分类、~18 bot、tryAsking、paused routines）
  - `src/lib/template-add.ts`（导入规则 "new records only, skills off, routines paused"）
  - `docs/presets.md`、`docs/team-sharing.md`（密钥脱敏规则原文）、`docs/org-library.md`（组织库、install 戳、r/w hash、幂等）
  - `apps/docs/content/docs/getting-started/move-from-grok-bot.mdx`（Grok→MausBot 迁移矩阵）

**botone（本地路径）**
- `packages/core/src/bot-templates.ts:9`（4 个模板 + version 规则）
- `apps/api/src/bot-templates.ts:34,56,133`（列表、plan 白名单、创建事务/幂等/复用）
- `packages/contracts/src/agent-import.ts:49`（来源含 "template"；containsKey 标记）
- `apps/api/src/routes/capabilities.ts:69`（marketplace.catalog/submissions/review）
- `packages/adapters/src/plugin-marketplace.ts:10`（Cursor + xAI 注册表聚合）
- `apps/api/src/plugin-submissions.ts`（投稿/审核/限流/邮件）
- `apps/web/src/components/bot-templates/bot-templates-dialog.tsx`、`apps/web/src/pages/PluginsOverlay.tsx`
- `apps/mobile/app/(settings)/bot-templates.tsx`、`apps/mobile/app/(settings)/bot-template.tsx`
