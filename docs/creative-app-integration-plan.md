# BotONE 创作应用接入方案

按 CreativeOne 最新公共创作接口实现。旧版服务签名、grant 和授权反查方案已取消。CreativeOne 维护模型、预设、创作执行和计费；BotONE 复用当前用户登录、应用连接、审批和附件能力。只修改 BotONE 仓库。

## 接入边界

- 完整部署配置后默认展示应用；当前已登录用户自动检查自己的连接，无需首次点击同意。可限定空间；未配置时应用保持可选。
- 所有业务集中在新增集成模块。API 与 worker 共用应用加载入口，worker 只提供转发配置；API 加载实际适配器，worker 仅加载通用内部调用代理。认证及用户令牌只留在 API，worker 不接收认证主密钥或 OIDC 客户端密钥。复用公共连接认证接口、共享任务调度及数据库结构；连接动作与自动初始化共用锁键。
- 三端使用同一后端连接与任务状态；Electron 复用 Web。身份与付费归属始终是原操作用户，不能借 Bot 所有者或同空间其他人的账号。

## 用户认证

每次调用由后端发送当前用户有效的 OIDC Access Token：

```http
Authorization: Bearer <user-access-token>
```

复用现有账户验证、加密存储及认证 API 的刷新逻辑；不解码未验证的 Token 推断身份，不转发数据库密文、Refresh Token、BotONE 会话 Token、模型 Key 或 caller-supplied subject。令牌仅在后端使用，不写入工具、消息、URL、任务快照或日志。刷新前后核对相同账号绑定；令牌刷新不改变 operationId。

服务端通过身份服务 UserInfo 验证每一次请求，以 issuer/subject 映射自己的用户。Bearer 调用不带 Cookie、Origin 或 CSRF。没有该用户或缺少创作资格时返回 `403 authorization_required`；引导配置的官方登录及模型授权页面，返回后重查。目录成功仅代表本地资格快照，不承诺最终计费授权有效。

主动断开阻止 BotONE 后续使用该连接，且不自动恢复；不会撤销用户在其他应用的 Token。重新连接同一身份不改变服务端任务归属。身份绑定变化或旧连接异常时不静默接管旧任务。

## 能力与提交

根路径 `/api/integrations/v1`：

- `GET /capabilities` 返回型号 ID、可读 name、可选 description、模型级参数 JSON Schema、组合 constraints、默认完整预设及 submission 限制。客户端原样消费完整规则，不将某个预设的值说成模型能力上限。
- `POST /references` 使用原用户凭证上传原始图片、视频或音频，持久保存上传回执；工具只选择原聊天附件 ID，由适配器转换为上游 references，不能让模型指定文件路径或远程地址。
- `PUT /jobs/{operationId}` 接收 `{kind,model,prompt,preset?,parameters?,references?}`，首次受理 202，等价重放 200 或 202。
- `GET /jobs/{operationId}` 查询原任务。
- `GET /jobs/{operationId}/outputs/{outputId}` 下载原用户任务的文件流。

kind 为 image/video/music。模型与预设 ID 是不透明字符串，原样使用。参考素材按型号 inputs 及全局 referenceKinds 开放。图片只用图片；视频可混合图/视频/音频；音乐仍只接受文字。分别读取图片与视频/音频字节上限，并核对用户/空间/聊天归属。实际类型及可用时长来自上传回执，视频和音频累计时长分别校验，缺失时长不能当零。frames 按图片顺序定义首尾帧并禁止音视频混入；reference 按目录组合规则提交。API 先保存操作与原附件快照，上传并保存不可变回执后，再持久化最终带 references 的公开请求；worker 不读取图片字节或认证密钥。图片和视频每个型号只公开合法默认组合；音乐按实际支持提供歌曲和纯音乐预设。参数只在 CreativeOne 定义，客户端不复制型号表、参数枚举或供应商规则。当前 submission.presetOnly=false，可按目录传入 parameters 覆盖；客户端可以省略预设，后端解析后固定保存，并将参数纳入审批、持久化和同 ID 恢复。旧目录未开放时不提交覆盖。prompt 不得为空白。目录不能满足明确要求时先让用户选择，不默默切换默认档位。

音乐样例：

```json
{"models":[{"id":"demo-music","kind":"music","presets":[{"id":"demo-song","parameters":{"mode":"song"}},{"id":"demo-inst","parameters":{"mode":"instrumental"}}],"defaultPreset":"demo-song"}],"defaults":{"music":"demo-music"}}
```

提交样例：

```json
{"kind":"music","model":"demo-music","preset":"demo-inst","prompt":"柔和的钢琴片头"}
```

## 持久化与恢复

审批后、首次付费提交前，保存 UUID、原公开请求、用户、连接绑定、执行回执与聊天归属。相同用户和 operationId 对应同一任务；变更公开请求返回 409 `operation_conflict`。预设下架只影响新操作；选择变化重新取得审批。隐藏任务保留服务端去重记录，404 不证明从未受理。不能因失败、刷新 Token 或重启而自动换 ID。

服务端负责每个 operationId 最多一次上游计费发送。BotONE 在请求不确定时先查原 ID，有限重放仍用同一 PUT 和 ID；已受理记录仅查询。API 侧应用适配器独立检查数据库中的原操作，以每操作租约、回执及输出 ID 恢复查询和附件交付，不依赖页面或 Bot 运行保持打开。多个实例不能重复交付；保存附件后消息事务失败时复用已保存文件。

任务返回 `{operationId,status,outputs:[{id,mimeType,name}],errorCode?}`。queued/running 继续查询；succeeded 交付全部可用输出；failed 显示公开失败；unknown 仅恢复查询和部分作品保存，不重新付费。视频受理不代表生成完成。文件使用真实 MIME 和已有附件上限；部分消失仍处理剩余文件，全部丢失或超限不重新生成。交付前重新核对原用户、空间、身份、连接和线程权限。

错误体为 `{error:{code}}`。401 `authentication_required` 通过原机制刷新或重新登录；503 `authentication_unavailable` 是身份服务暂不可用，保留操作等待恢复。403 `authorization_required` 引导官方授权；409 `account_changed` 停止原身份操作；422 `selection_unavailable` 重读目录并重新确认。其他连接、非 JSON 及服务故障保留原 ID，不能换账号兜底。

## 验证与交接

离线覆盖个人隔离、Token 刷新、默认连接与断开、完整预设、审批、相同 ID 幂等、未知结果、重启恢复、多实例竞争、逐文件去重、附件恢复与敏感信息隔离。数据库测试使用隔离实例和合成内容。

lab 已使用获准身份验证有效 Access Token、401 自动刷新及图片的真实提交、查询、附件保存和聊天投递；新进程续查沿用原 operationId，重复检查未增加提交或附件。图片输出像素与目录尺寸声明不一致，需服务端核对，客户端按原文件交付。图片、视频和音频参考已使用合成素材完成 lab 真实上传、元数据、同用户内容去重及清理验证，worker 无认证配置时的通用代理链路也已通过。此次未发起付费生成；首次官方授权、原生浏览器返回、带视频/音频参考的实际视频生成、歌曲、纯音乐及账单归属仍需验收。离线模拟附件不作为真实生成证据。

部署使用新增的可选应用 Compose 覆盖文件，基础模板保持上游原样。创作指导只随应用工具加载，不注册全局内置技能；内容仍区分完整能力与默认预设，并保留混合参考及恢复规则。

预设可省略，不能以空字符串或显示名称代替。所有新操作在提交前读取目录，model 必须精确匹配目录 ID；省略 preset 时解析 defaultPreset。现有 effect.request.input 保存补齐预设后的快照，省略时另存原始 effect.request.toolInput 用于请求比较；恢复复用 state.submission、原 operationId、预设、参数和参考 ID，不随最新默认值变化，也不重发新的付费任务。
