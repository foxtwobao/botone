# M6 scope — 附件与媒体（收发 + 渲染）

> 本文档写于动手编码**之前**，是当时的决策记录。收尾时把最终实现与它对齐的结果写在
> `m6-notes.md`；下文与 notes 有出入处均以 notes 为准（主要是 D2 的降级方向反转、D7
> 的选会话 sheet 按真机实测落地、以及走查后砍掉的中间预览页）。

Starter branch `t3/m6-attachments-media`（fork 自 PR #67 合并后的 main）。参考实现：`apps/mobile`（一切以其实际行为为准）。契约：`packages/contracts/src/threads/attachments.ts`、`artifacts/artifacts-rpc.ts`、`threads/thread-send.ts`；`packages/core/src/messages/attachments.ts`。所有决策以下面的「范围」四层展开，砍掉项各带理由，写明 ArkTS/HarmonyOS 能力边界。

## 移动端行为基准（实测代码摘要）

**上传协议**（mobile `thread-feedback.ts` deliverSend）：`artifacts/create {target, name, mimeType, contentBase64, clientNonce:`sendNonce:i`}`（60 s 超时）逐个上传 → `threads/send {target, text, artifactIds, replyToMessageId?, replyQuote?, clientNonce}`。限额从 `me` 读 `maxUploadSizeBytes`/`maxAttachmentsPerMessage`（contracts 缺省 10 MiB / 4 个）。`imageHandling:"confirm"`（服务器 409 `model_image_input_unsupported` 时失败条显示 **Send as file** 重试）。
**图片准备**（mobile pick-attachments）：>1600px 长边缩到 1600、quality 0.7 重编码 JPEG/PNG；GIF/WebP 原样（保动画/透明）；HEIC/HEIF 当 file 发（movile 会转 JPEG，鸿蒙无系统转码 API —— 降级为 file，见决策 D2）；PNG 仅静态才重编码（isStaticPng 扫描块头）。
**接收渲染**（mobile message-bubble）：image block（非 SVG）→ InlineImageAttachment：走 `artifacts/get` 下载、磁盘缓存、按自然尺寸缩放（maxW≤400/68% 屏宽、maxH 360）、点击进全屏 viewer（image-artifact-viewer）；SVG/未知 image → 文件名行；audio → 播放器（播放/暂停/时长/分享）；file → `📎 name` + formatFileSize，`artifactPreviewKind != none`（pdf/video/mp4/text/html/markdown/image）点开预览页，其余 openMobileArtifact（系统分享面板）。
**reply 发送**：长按菜单 **Reply**（非 readOnly、非 progress 行）→ composer 上方预览（作者 + replyLabel(quote/preview/attachment) + 32px 附件缩略图，可关）→ send 带 `replyToMessageId`。**Quote**：长按 Quote → 选区 sheet → `replyQuote`（≤2000 字符，truncateReplyQuote）随 reply 一起发送 —— 独立路径，移动端 7 行 UI + selection 模型，鸿蒙本期砍（决策 D6）。
**系统分享接收**（mobile incoming-share + native-intent）：分享进来 → /share 页选目标 chat → 文件逐个读为附件、文本插 composer；5 分钟过期；去重靠 scope key。鸿蒙 Share Kit 的目标端 API（`systemShare.getSharedData(want)`，`@kit.ShareKit`，HMS systemShare.d.ts 实测存在，`SharedRecord{utd,content?,uri?,title?}`）确实暴露 —— 但本模拟器上系统分享面板的目标端行为（skills 里 `ohos.want.action.sendData` 的 utd 匹配）无法在 devphone 上可靠驱动验证（无法从 adb/hdc 侧触发系统分享面板选择本 app），列入挂账，代码落地但设备验证受限（见决策 D7）。

## 范围（依上表裁剪）

1. **接收渲染**（对齐 mobile tier）：
   - 图片（含多图并排）：`Image` 组件内联（`ImageAutoFit`），缓存 `artifacts/get` 的 base64 → 沙箱 cache 文件 → `file://` URI；点击全屏（bindContentCover + Image 缩放）。SVG/未知 mime → 文件行（与 mobile 一致）。
   - 音频：AVPlayer（`@ohos.multimedia.media`）行内播放器：播放/暂停按钮、`currentTime/duration`、错误降级文案（复用 msgid `Could not play that clip.`）；无单独分享按钮（mobile 有 —— 砍，决策 D5）。
   - 视频：`Video` 组件内联自动尺寸（objectFit Contain），tap 播放/暂停；`video/mp4|quicktime|3gpp`。
   - PDF：HMS PdfView（`@kit.PDFKit` 的 `PdfView` struct，`pdfViewManager.PdfController.loadDocument(path)`）内嵌预览页；失败降级 `Could not open this PDF.`（msgid 已有）。
   - 通用文件：图标 glyph + name + formatFileSize + 点击 → **直接打开系统保存对话框**（`DocumentSaveOptions` + picker；保存成功后行内/页头显示 `Saved` 三秒，失败 `Could not save`）。text/*、application/json 等移动端可预览的：移动端用 text viewer；鸿蒙砍 text/html/markdown/json 内嵌预览页（决策 D3），tap 直接走保存（视频和 PDF 仍先进全屏预览页，页内有下载按钮）。**收尾修正**：首版在「无可预览文件」与「保存对话框」之间有一层几乎空白的中间页，ux-declutter 走查后砍掉。
   - sandboxed HTML：砍（决策 D3）。
2. **发送上传**：composer `＋`（菜单：**Photo library**/**File**，两项——**Camera** 砍，决策 D4）→ `photoAccessHelper.PhotoViewPicker`（MIMEType.IMAGE）或 `DocumentViewPicker`（fileSuffixFilters + maxSelectNumber）→ 读字节（fs.open/read 分块 ≤1 MiB）→ util Base64Helper encodeToString → 复用 SaveController 挂 `artifacts/create`（逐个上传、进度 = 第 N/共 M 个）→ send 带 artifactIds。校验对齐 contracts：mime 白名单（含 archive/audio 别名映射 inferAttachmentMimeType 的对齐 port）、10 MiB/文件、4 个/消息（me 配置优先）；超限/超数以 notice 行报告（对齐 mobile `Skipped {items}` msgid）。上传中：按钮转 LoadingProgress + 逐附件进度；取消：附件 chip 上 `×`（send 前）；上传中取消 = 保存的输入恢复 composer 草稿（对齐 mobile send 失败保留 input 的语义——SaveController onFailed 已有 sendFailedText 机制，附件走同一通道）。
3. **reply 发送流**：长按菜单加 **Reply**（M5 预留 msgid 回归；非 readOnly、非 progress: 行）→ composer 上方预览行（作者 + replyLabel + 32×32 缩略图 + **Cancel reply** msgid 关闭）→ send 带 `replyToMessageId`（+ replyQuote：本期仅随 Reply 无选区，见 D6）。M5 的 reply 行渲染闭环（发送后自己的消息带 replyToMessageId 时服务端会回 preview —— 由既有渲染承担）。Quote 选区 sheet 砍（D6）。
4. **系统分享接收**：module.json5 的 EntryAbility skills 加 `ohos.want.action.sendData` + utd 匹配；`onCreate/onNewWant` 里 `systemShare.getSharedData(want)` → 全局 pending share（5 分钟过期、代次计数，对齐 incoming-share 语义）→ 落到「当前打开的 chat 的 composer」（单 Space 无选会话页，见 D7 里的 UI 简化说明）。多文件全收（上限/大小走同一 filter）；文本插 composer。设备验证：模拟器驱动受限，尽量以 hdc `aa start` 带 want 参数直启验证（见 m6-notes 验证矩阵）。

## 决策（砍掉项及理由）

- **D1 图片全屏 viewer 简化**：mobile 是多页滑动 + 双指缩放的 gallery；鸿蒙本期 = bindContentCover 全屏单图 + `ImageInterpolation`/缩放。理由：ArkUI 无等价 gallery 组件，Swiper+pinch 可后补；单图全屏已满足「点击全屏查看」。
- **D2 HEIC/HEIF 不转码**：鸿蒙无公开的 HEIC→JPEG 系统转码 API（image kit 的 ImagePacker 只接受解码后的 PixelMap，而 ImageSource 对 HEIF 解码能力未承诺在所有设备可用）。**收尾修正**：编码失败时按 mobile 的语义报「不支持的类型」跳过，而不是当 file 原样发送——mobile prepareImage 正是这么做的，大多数接收方打不开的格式不该发出去。
- **D3 文本/HTML 内嵌预览页砍**：mobile 的 text viewer / sandboxed HTML WebView 页是独立 surface（沙箱 CSP、滚动、复制）。鸿蒙本期 file tap = 保存到下载目录 + 系统「打开方式」。理由：单 PR 塞不下两套预览 surface，且 HTML 沙箱语义在 ArkWeb 组件上的对齐（CSP、无 cookie、导航拦截）需要单独一轮验证。
- **D4 相机砍**：`@ohos.multimedia.camera` 权限 + 预览 surface 是一个完整页面，超本包；mobile takePhoto 亦是可选入口。
- **D5 音频卡片无分享按钮**：mobile 有系统分享按钮；鸿蒙侧「保存/分享已下载文件」与通用文件保存同一能力（D3 的保存路径），单独按钮重复。
- **D6 Quote 选区砍**：mobile quote-sheet 是「长按 Quote → 文本选区 sheet → excerpt」独立流；本期 Reply 菜单直通 replyToMessageId。msgid `Quote` 保留不新增。
- **D7 分享目标端 UI 简化**：mobile 有 /share 选会话页；鸿蒙做半屏 `bindSheet` 选会话（**收尾修正**：真机可驱动，不再挂账），带移动端 `share-preview` 的预览行（缩略图/文件数/文本），选完重置导航栈为「首页+会话」，关闭即丢弃，5 分钟过期。module.json5 的 skills 按 UTD **类型族**穷举（image/audio/video/text/composite-object/archive/file）——实测 `general.file` 覆盖不到 PDF 和压缩包，走查发现此坑后修正。
- **D8 outbox/磁盘未发送队列砍**：mobile 有 outbox-disk 持久化重试队列（unsent-sends 20 条上限、磁盘 hydrate）；鸿蒙本期发送失败 = SaveController 的 error + retry（M3 已有语义），附件在内存中保留。理由：无持久化需求信号，磁盘 outbox 是一整个子系统。
- **D9 上传不分块协议**：契约是整文件 base64 JSON（服务器亦然）；分块只在本地读文件时（fs.read 1 MiB 循环拼 base64），网络侧无分块可对齐。
- **D10 `Send as file`（imageHandling）**：对齐 mobile 的 409 `model_image_input_unsupported` 失败条 + 重试路径：失败错误行附「Send as file」动作，重试时带 `imageHandling:"file"`。fixture 服务器注入 409 分支验证。

## 新 msgid 清单（全部来自共享 catalog，零新增）

`Photo library`、`File`、`Skipped {items}`、`Skipped`、`Cancel reply`、`Reply`、`Attachment`、`Photo`、`Message`、`File`、`Could not play that clip.`、`Could not open this PDF.`、`No preview for this file type.`、`Saved {name} locally`、`Save`、`Saved`、`Play`/`Pause`/`Play {name}`/`Pause {name}`、`Loading image…`、`Tap to open`、`Open image {name}`、`Download`、`Try again.`、`Send as file`、`Image`、`Could not attach files`、`Could not open file`、`Could not share file`。附件 chip 移除用 `Remove`。逐条核过 en/zh-CN/zh-TW 三 catalog 已存在（m6-notes 附核对表）。

## fixture/对齐计划

- `contract/fixtures/attachments.json`（新，layer-2）：从真实 core `inferAttachmentMimeType`/`artifactTypeLabel`/`formatFileSize`/`attachmentStoredName`/`isStaticPng`/`attachmentMaxBytes/Count` 生成输入→期望表；vitest 差分 + hypium 回放。
- fixture 服务器增路由：`/rpc/artifacts/create`（校验 target/name/mime/base64/clientNonce、幂等 nonce 重放返回同 id、按名失败、**慢速读取请求体**以供取消用例）、`/rpc/artifacts/get`、409 分支（`model_image_input_unsupported`）供 Send-as-file 验证。
- hypium 新 suite：`Attachments.test.ets`（纯逻辑回放 + fixture 服务器 create/get/send 闭环 + 限额拒绝 + 幂等重试 + 传输中取消 + 照片缩放实测），reply/menu 断言并入现有 suite（`ThreadRender` 的 attachment tier、`MessageText` 既有 reply 规则）。**收尾修正**：原计划的 `MediaRender`/`ReplyFlow` 独立 suite 并入这两处，避免为断言拆碎 suite。
- 设备验证矩阵 + `m6-*.png` 截图 + ux-declutter 走查（m5 模式）。

## 完成标准（DoD）

vitest contract 全绿（含新 fixture）；`pnpm checks` 全绿；lint 0 error；`harmony:codegen` + `devecocli build` + ohosTest 构建零 ArkTS 警告；hypium 全量（含新 suite）设备实测；notes 与 scope 决策成文；分支真实过钩子推送。
