# M7 scope — 语音Ⅰ：听写、朗读、bot 声音设置

> 本文档写于动手编码**之前**（能力探针先行，结论见「能力探针」），是当时的决策记录。收尾时
> 把最终实现与它对齐的结果写在 `m7-notes.md`；下文与 notes 有出入处均以 notes 为准。

Stacked on `harmony/m6-attachments`（M6，`9bb61a9a4`）。参考实现：`apps/mobile`（一切以其实际行为
为准）；纯规则来自 `packages/core`。契约：`packages/contracts/src/models/models-rpc.ts` 的 `voice/*`
过程与 `packages/contracts/src/models/voice.ts`，`BotSchema.autoSpeak`，HTTP `/api/voice/speak`、
`/api/voice/transcribe`（`apps/api/src/calls/voice.ts`）。

## 移动端行为基准（实测代码摘要）

**语音有两条引擎路径，由同一个计划选择**（`apps/mobile/lib/calls/voice-call-entry.ts`
`resolveVoiceCallPlan`）：设备语音开着**且**设备识别可用（能力 + 麦克风权限）→ 设备路径；否则读
`voice/status`：`ready`（或听写时 `transcribe`）→ 服务端语音提供商（hosted）路径；都没有 →
「去语音设置」。「设备语音」开关（`lib/voice/device-voice.ts`，键 `rakazo.device-voice`）在没人选过时
取 `!voice/status.ready`：已经连过提供商的老安装保持原路径，其余默认用手机自己的声音。读开关失败
按**开**处理（fail-closed：本机-only 的回复绝不会因为一次读失败被送去 hosted）。

**听写**（`lib/composer/composer-dictation.ts` + `lib/voice/dictation.ts` + `lib/voice/voice-clip.ts`）：
composer 的麦克风按钮（`Dictate`）→ `listening`：设备识别器边说边出字（`onInterim`）；30 秒没新词
或从没听到声音就结束（`DICTATION_PAUSE_MS`，`endpointMs` 由调用方给）；再点一次停止并保留已听到的
字；`×`（`Cancel dictation`）丢弃录音和它写进输入框的字。hosted：录一段（≤5 分钟，`until` 信号结束
录音并保留）→ `POST /api/voice/transcribe`（先过 voice 用途的 AI 数据同意）→ 一次性文本，期间状态
`transcribing`。文字合并（composer `showDictation`）：以开麦时的草稿为基底，`base.trimEnd() + ' ' +
words`；实时词不覆盖用户在此期间的编辑；提供商的一次性转写并入编辑后的文本。听写中按发送 = 先停
后发；转写中禁用发送。退后台：正在听 → 取消；正在转写 → 保留。权限被拒：`Allow microphone access
to dictate.`。
设备识别会话（`dictation.ts`）：识别器的 `isFinal`/`end` 只是换气或系统超时，只有这里量的静默间隔
才算说完；`end` 带着重启退避（250 ms→2 s）与死重启上限；文字按 `carried`（已定句）+ `heard`（当前
句）折叠，`join` 归一空白。

**朗读**（`lib/thread/thread-voice.ts` + `lib/voice/voice.ts`）：长按菜单 **Speak message**（有文字的
bot 消息；通话中不出）→ 从这条起，其后每条有文字的 bot 消息组成 `speakQueue([{text, botId,
messageId, speaker{name,color}}])`；没有可用声音 → 「Could not speak / Add a voice provider in Voice
settings.」+ Cancel / Open Voice。全局 `VoicePlayerBar`（布局里的普通块，不遮挡列表与 composer）：
波形图标 + 说话者名字 + Pause/Resume（可暂停时）+ Stop。设备语音：`expo-speech` 按 bot 的离线音色
逐句读；hosted：`voice/prepare`（`ready`/`utterances`）→ 每句 `POST /api/voice/speak`，预渲染下一句
→ 播放 MP3/WAV。换会话或换 Space 即停止。
**自动朗读**（`lib/voice/auto-speak.ts` `nextAutoSpeakAction`）：bot 的 `autoSpeak`（移动端 bot 设置里的
「Read replies aloud」开关，服务端字段）打开且会话在前台聚焦时，run 结束后朗读最新一条 bot 消息
（文字 = `speechFromBlocks(blocks).trim()`）；刚打开、切换 bot、关掉开关、没有文字 → 只记下已读位置
（seed），不补读历史；群聊不读。

**语音设置**（`app/(settings)/voice.tsx`，账户作用域）：Provider 选择器（`This device` + 目录里的
提供商）；提供商表单：服务器 URL（自托管）、API 密钥、语音模型、转写模型、转写词汇、转写服务器
URL 与密钥、Connect/Reconnect/Replace key、Disconnect、Speech model 选择器、Voice 选择器（列表或
自由填写）、`Hear a sample`；另有通话铃声/等待音/通话问候三个本机开关。
**bot 音色**（`lib/voice/bot-voices.ts` + `voice-assignment.ts`）：每 bot 一个本机离线音色，分配存本机
（`rakazo-bot-voices.json`）；候选 = 与设备语言相同的离线音色，优先同地区 → 该语言主地区 → 全部，
先取没被占用的，再偏好高质量；`pickUnusedVoice` 以 botId 的稳定哈希为起点轮询。bot 设置页有
「Device voice」选择器（音色 >1 时），选完试听。

## 能力探针（devphone 模拟器，API 26；`VoiceProbe` 探针用例，未入库）

| 能力 | 结果 |
| --- | --- |
| `SystemCapability.AI.SpeechRecognizer` / `AI.TextToSpeech` | 均 `true` |
| TTS 引擎 | `createEngine({zh-CN, person 13, offline 1})` 成功，211–1384 ms；`listVoices` 返回 3 个音色：`zh_CN/13`（聆小珊，女）**INSTALLED**，`zh_CN/21`（男）与 `en_US/8`（女）为 `GA`（需下载，未安装） |
| TTS 播放 | 真实时推进：2.85 s 的音频在 +2781~3208 ms 收到 `playbackComplete`（type 1）；期间 `isBusy()` 为 true；`pause`/`resume` 不抛，`stop()` 后 `onStop`「stop success」；合成先于播放完成（`onComplete` type 0） |
| TTS 未安装音色 | `createEngine({en-US, person 8})` 报 `1002300005`（资源路径无效） |
| `textToSpeech.downloadVoice` | **打死测试进程**（"App died"；走系统 `ModelDownloadUIExtensionAbility` 的下载界面）。产品代码不调用 |
| ASR 引擎 | `createEngine({zh-CN, offline 1})` 300 ms；`listLanguages` = `["zh-CN"]`；`startListening` 后 24 ms `onStart`；`writeAudio` 接受 1280 字节 PCM 块；`finish` → `onResult(isLast)` + `onComplete`「recognize complete」 |
| 正则 | 后行断言、`\p{L}`/`\p{Script=Han}`、命名分组、`\u{1F600}` 区间在 ArkTS 运行时全部按预期工作（core `speech-text.ts` 可原样移植）；`Intl.Segmenter` 不在 ArkTS 标准库类型里（移植走无 Segmenter 的回退分支） |
| 麦克风 | 探针在 hypium 进程里拿不到前台 ability（`requestPermissionsFromUser` 报 16000100）；权限申请改在应用自己的 EntryAbility 上下文里走查（见 m7-notes 的设备验证表，`m7-mic-permission`） |

## 范围决策

1. **两条引擎路径都做，选择规则照搬移动端**（D1）：设备语音 = `@kit.CoreSpeechKit`
   （`speechRecognizer` + `textToSpeech`），hosted = 既有 `net/` 层（`voice/prepare` RPC、
   `/api/voice/speak`、`/api/voice/transcribe`）。移动端两种都有，只做设备路径会让英语用户无法听写、让
   关掉设备语音的用户在鸿蒙上听到另一种声音。
2. **听写**：composer 加麦克风按钮；识别中显示「取消 / 电平 / 停止」条（复用目录里的
   `Cancel dictation`、`Stop dictating`）；增量文字进草稿，合并规则同移动端；停止、取消、退后台、
   离开会话、换会话都释放识别器与录音。设备会话逻辑是 `dictation.ts` 的移植（静默端点、carried/heard
   折叠、重启），CoreSpeechKit 事件映射到同一个识别器接口；引擎单段音频上限 60 s，用 58 s 轮转
   （`finish` → 定稿 → 续开新段）适配。hosted 录音以 **WAV**（16 kHz/单声道/S16LE 的 PCM 加 44 字节
   头）上传（D11）：设备上不需要编码器，`mimeType` 原样透传给提供商。
3. **朗读**：长按菜单加 **Speak message**（移动端顺序：Reply 之后、Select text 之前）；从该条起的
   bot 消息入队；根布局（`pages/Index` 的 Column，Navigation 之下）放播放条（`Bot`/说话者名、
   `Pause`/`Play`、`Stop`），只在朗读或暂停时出现。自动朗读按 `nextAutoSpeakAction` 移植，读 roster
   的 `bot.autoSpeak`。退后台、换会话/Space、线程退出即停并释放。
4. **语音设置页**（设置里新增 `Voice` 行，独立目的地）：Provider 选择器、服务器 URL、API 密钥、
   语音模型、转写模型、Connect/Reconnect/Replace key、Disconnect、Voice 选择器（列表或自由填写）、
   `Hear a sample`。
5. **bot 音色**：`voiceForBot` 的选择规则与持久化移植，首次朗读时自动分配（只认 `INSTALLED` 音色，
   D3）。**选择器砍**（D5）：鸿蒙还没有 bot 设置页可挂，且本模拟器只装了一个音色，选择器既无处放也
   无法在设备上验证；随 bot 设置页那一期补。
6. **麦克风权限**：`module.json5` 申请 `ohos.permission.MICROPHONE`（`usedScene: EntryAbility /
   inuse`），理由文案写在资源 `string.json`（键同权限名，base/zh_CN/zh_TW 三份）。运行时在用户点麦
   克风时申请。

## 砍掉项及理由

- **D4 语速**：移动端没有语速设置（任务描述里的「语速」是对 `voice.tsx` 的猜测）；CoreSpeechKit 虽支持
  `speed`，没有可对齐的语义，不新增产品面。
- **D6 「Read replies aloud」开关**：它是 bot 设置页里的服务端字段开关，鸿蒙没有 bot 设置页。本期
  只读取该字段（可在 web/移动端打开后同步过来）。
- **D7 语音设置表单的高级字段**：语音模型列表选择器（`speechModels`）、转写词汇、独立转写服务器
  URL/密钥砍。它们只在特定提供商/自托管拆分部署时出现，属于渐进披露的后一层；连接自托管服务器
  所需的最小字段（URL + 两个模型名 + 密钥）保留。
- **D8 通话铃声/等待音/通话问候**：鸿蒙没有通话。
- **D9 通话相关的音频模式与 `queueSpeech`**：`voice.ts` 里为通话服务的音频会话切换、边合成边播的
  feed 不移植。
- **D10 失败用 composer 的通知行，不用 AlertDialog**：移动端用 Alert 弹「Could not dictate/speak」。
  鸿蒙 composer 已有一条内联通知行（附件失败用它），再叠一个对话框是重复的 chrome；需要「去语音
  设置」时通知行带一个 `Open Voice` 动作，语义不变。
- **D3 不调用 `downloadVoice`**：探针里它直接打死了进程，且它要拉起系统下载界面。

## 新 msgid 清单

目标：**零新增目录 msgid**。下列 msgid 已逐条核过 en/zh-CN/zh-TW 三份目录都存在：
`Dictate`、`Cancel dictation`、`Stop dictating`、`Speak message`、`Stop speaking`、`Play`、`Pause`、
`Stop`、`Bot`、`This device`、`Provider`、`Voice`、`Server URL`、`API key`、`Speech model`、
`Transcription model`、`Optional`、`Paste your API key`、`Paste a replacement key`、`Connect`、
`Reconnect`、`Replace key`、`Disconnect`、`Default`、`Hear a sample`、`Open Voice`、`Could not dictate`、
`Try again.`、`Allow microphone access to dictate.`、`Allow speech recognition in Settings, or connect a
voice provider that transcribes.`、`Could not transcribe that.`、`Could not speak`、`Add a voice provider
in Voice settings.`、`Could not speak that.`、`Could not play that clip.`、`Voice request timed out.`、
`Could not load voice settings`、`Could not connect`、`Could not disconnect`、`Could not save that voice`、
`Could not save that preference`、`Connect a voice provider first.`、`Could not play a sample`、
`Your voice provider is out of credit.`、`Your voice provider key was rejected.`。
新增的 **harmony-only 字符串**只有一条：麦克风权限理由（系统权限弹窗里显示），三语各一份——它是平台
要求的资源，lingui 目录不收资源字符串。

## fixture / 对齐计划

- `contract/fixtures/voice.json`（layer-2，`scripts/gen-voice-fixtures.ts`）从真实实现生成：
  - core `speakable` / `splitSentences` / `toUtterances` / `speechFromBlocks`（语料 + 种子随机串）；
  - core `speechLocaleTag` / `recognitionLocaleTag` / `supportedSpeechTag`；
  - 移动端 `nextAutoSpeakAction`、`resolveVoiceCallPlan`、`pickUnusedVoice`；
  - 移动端 `device-voice.ts` 的默认值与持久化（真实模块 + mock 的 SecureStore/rpc）；
  - 移动端 `dictation.ts`：注入假识别器脚本（result/end/error/speechstart/speechend + 假时钟），记录
    识别器调用序列与 onInterim/onFinal/onGiveUp；
  - 移动端 `voice.ts`：mock 播放器、设备 TTS、rpc/fetch，记录 prepare/render/play 的调用序列、返回值与
    播放状态迁移（单条、多条入队、准备中停止、换会话停止、无声音、失败、设备语音读失败 fail-closed）。
- `contract/voice-port.test.ts`：差分直连真实模块（移植的 `.ets` 以可擦除 TS 加载），形态同 M6 的
  `attachments-port.test.ts`。
- layer-1：`voice/status|catalog|credentials|voices|prepare|connect|disconnect|setVoice|setSpeechModel`
  的视图与 `botView.autoSpeak`，`HARMONY_UPDATE_SNAPSHOTS=1` 落盘。
- 夹具服务器加 `voice-fixture.mjs`：`/rpc/voice/*`、`/api/voice/speak`（一小段 MP3）、
  `/api/voice/transcribe`（按 WAV 头校验后回一段固定文字）、voice 用途的同意脚本。
- hypium `Voice.test.ets`：fixture 回放 + 注入假引擎的听写/朗读状态机 + 夹具服务器的 hosted 闭环。

## 设备验证可行性

- **听写**：识别器吃的是 PCM 流（`writeAudio`），不依赖真实麦克风。可控输入 = TTS 合成的语音
  （`onData` 的 PCM）回灌识别器，hypium 里可断言识别文本；composer 的真实麦克风链路（AudioCapturer →
  识别器）在模拟器上是否有输入见 notes。
- **朗读**：TTS 在模拟器上真实时播放（探针已证），播放条/暂停/停止可走查；hosted 播放走 AVPlayer
  （M6 已证可播）。
- **语音设置**：夹具服务器的假提供商（假名字、假密钥）可走通连接/选声音/试听。

## 完成标准（DoD）

vitest contract 全绿（含新 fixture 与差分）；`pnpm checks` 全绿；lint 0 error；`harmony:codegen` +
`devecocli build` + ohosTest 构建全过、新文件零 ArkTS 警告；hypium 全量（含新 suite）设备实测；
Device verification 表 + `m7-*.png` + ux-declutter 走查；notes 成文；分支真实过钩子推送。
