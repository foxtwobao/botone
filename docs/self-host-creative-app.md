# 可选创作应用客户端

客户端复用「连接应用」、个人连接、工具审批和聊天附件。Web 与 Electron 共用入口，移动端复用原生入口。配置后默认向所有空间展示，也可通过 `spaceIds` 限定；未配置时不依赖外部创作服务。

向 API 和 worker 安全注入同一份 `APP_CONNECTIONS` JSON；两者使用统一入口；API 加载应用适配器，worker 只加载通用调用代理：

```json
{
  "creative": {
    "origin": "https://creation.example.test",
    "name": "Creation app",
    "icon": "https://creation.example.test/icon.png",
    "authorizationUrl": "https://creation.example.test/api/auth/login?returnTo=/studio"
  }
}
```

上述地址均为占位符。可选 `spaceIds` 是非空的空间 ID 数组；省略表示所有空间。使用 Compose 时，在原基础文件之后追加可选的 `infra/compose/docker-compose.apps.yml`；该覆盖文件仅向 API 与 worker 传入应用配置，不把它加入其他服务。原有基础模板不需要修改。API 侧的应用适配器封装外部调用、任务恢复和附件交付；worker 不加载应用实现，只通过内部入口转发工具发现及执行。未配置的适配器不加载，也不启动后台工作。新增内置适配器只需在统一入口注册，不再分别修改 API 和 worker。创作接口结构、Provider 接口和技能说明集中在适配器模块，不向共享契约包或接口包增加创作专用导出。标准 MCP/API 连接继续使用已有配置入口。

例如从仓库部署开发栈：

```sh
docker compose --env-file .env -f infra/compose/docker-compose.yml -f infra/compose/docker-compose.apps.yml up --build
```

生产或镜像部署保留原有基础文件和其他覆盖文件，再将 `docker-compose.apps.yml` 加在后面。仅在 `.env` 中填写应用配置不会让未追加此覆盖文件的容器自动收到它。systemd 等直接启动 Node 的部署继续向 API 和 worker 注入相同配置。

创作指导随已连接应用的提交工具说明加载，保留完整能力与默认预设的区分、参考素材及恢复规则；不再向所有用户注册全局的「Create media」内置技能。未配置应用时不会向模型注入这份说明。

使用私有 CA 时，让 API 和 worker 的 Node 进程信任该证书：可使用系统信任库（`NODE_USE_SYSTEM_CA=1`），或用 `NODE_EXTRA_CA_CERTS` 指定 CA 文件。保留 HTTPS 证书校验。

认证仅在 API 侧复用已有实例。worker 不持有 `BETTER_AUTH_SECRET`、`OIDC_CLIENT_SECRET` 或用户 Access/Refresh Token，也不加载认证包。`APP_INTERNAL_URL` 指向内部 API 的根地址，默认为 `http://127.0.0.1:3100`；Compose 默认使用 `http://api:3100`。代理仅接受固定应用 ID 及工具操作，不能传入任意外部 URL 或请求头。内部入口不应映射到公共反向代理。

内部鉴权从 API 与 worker 原本已共享的 `ENCRYPTION_KEY` 派生专用调用凭证，不复用登录签名密钥，不新增部署密钥。API 每次核对运行中的任务租约、原用户、空间、Bot、当前成员资格及选中的连接，再从数据库重建连接上下文。代理不自动重试不确定的付费请求；原操作及附件交付由 API 侧适配器恢复。

身份与凭证复用现有 OIDC 账户：后端读取当前用户已经验证的账号绑定，通过现有认证 API 获取解密后的 Access Token，并沿用它的刷新与加密存储机制。每次外部调用使用 `Authorization: Bearer <当前用户的 Access Token>`。收到 401 后最多通过原账号刷新一次，再重试原请求；不会更换用户或 operationId。刷新前后均检查账号绑定。Refresh Token、模型 Key、BotONE 会话凭证和用户 Token 不进入工具、URL、任务快照、附件或日志。无需服务 JWT、签名密钥、grant 或反查端点；旧版签名配置不再接受。

用户登录后的账户初始化会触发后台连接检查，应用目录刷新也会检查。已有创作资格时自动连接；缺少资格时打开部署指定的官方页面完成登录和模型授权，返回后重查。主动断开后不自动恢复。断开只停止 BotONE 使用该连接，不撤销用户在身份服务或创作服务中的账号。身份绑定变化后，不将原任务交给其他账号。

能力目录保留可读 `name`、可选 `description`、模型级参数 JSON Schema、组合 `constraints` 及根 `submission`。型号 Schema 描述完整支持范围，预设参数是一个具体组合；二者不能混为一谈。展示使用名称，提交保留不透明 ID。滚动升级时旧目录缺少这些扩展字段，客户端仅说明已知预设，不推断型号没有其他能力。当前目录的 `presetOnly=false` 表示已开放参数覆盖；参考素材还需全局 referenceMedia=true、referenceKinds 包含相应 image/video/audio 类型，且所选型号 inputs.referenceImages/referenceVideos/referenceAudios=true。视频生成可按型号能力混用三类素材；图片模型仅接受图片，音乐仍只接受文字。旧目录标记 presetOnly=true 或缺少标记时，客户端仅提交已列预设。

三个工具分别读取能力目录、提交 `{kind,model,prompt,preset?,parameters?,referenceArtifactIds?}` 和查询本地任务状态。型号、基础预设及参数规则由服务端定义；客户端可省略预设，由后端从目录解析默认预设并固定保存，未指定的参数沿用它的值，不维护供应商规则，仅接受当前目录已开放字段的参数覆盖，不在失败后切换付费账号。参数随审批请求和原操作一起保存。false、0 和目录允许的自动时长 -1 原样保留；未知参数名在外部提交前拒绝，类型、范围及组合由创作服务按其权威规则校验，拒绝时不偷偷改回默认。重放沿用已保存的参数，JSON 属性换序不改变本地操作身份。创作仍经过现有审批，并要求可验证的用户发起人。

参考素材复用现有聊天图片、视频和音频附件：模型只传入用户明确选中的 `referenceArtifactIds`，顺序保持不变，不接收路径、URL、Data URI、Base64 或外部参考 ID。API 验证附件属于原用户、空间及原聊天，按目录返回的单图上限 maxReferenceImageBytes、单视频/音频上限 maxReferenceMediaBytes，以及型号输入开关和已知数量约束检查，不复制供应商规则。实际格式由创作服务对原始字节识别、校验；不在客户端压缩、改图或转码。

上传回执保留实际 kind、MIME 及可用的 durationMs；音频专用 MP4 可以与附件声明的 video/mp4 不同，以服务端从字节识别的真实类型为准。型号设有 referenceSeconds 时，视频和音频各自累计毫秒时长并分别校验；缺失或非正时长不能当作零。已知数量限制按实际类型计算。parameters.mode=frames 按图片内部顺序解释首帧和尾帧，不与视频/音频混用；reference 沿用目录组合规则。省略 mode 时保留服务端现有选择逻辑，不由客户端猜默认；帧数量/成对规则、画幅及其他参数组合仍由创作服务最终校验，非法组合不回落默认。

API 在上传前持久保存操作及附件快照，再以原用户凭证发送原始二进制文件。逐个保存字节摘要和不可变上传回执，之后保存带有上游 references ID 的完整提交结构，最后才发送付费 PUT。丢失上传响应时可重传完全相同的字节，由服务端按用户和内容去重；付费请求恢复只用原操作和已保存的参考 ID。素材顺序变化属于新请求，不能复用已批准的执行。文件字节和令牌不会写进任务 JSON，也不经过 worker 内部代理。

新混合参考任务使用独立的外部操作种类，旧 API 副本不会接管新媒体请求；已保存的纯文字和图片参考任务仍可恢复。上传期间撤销连接、退出空间或取消原运行后，不继续付费提交。上传引用用于原任务恢复，不在成功后自动删除同用户可能复用的去重素材。

任务在第一次付费提交前保存 UUID、原公开请求、用户、连接绑定和原聊天归属。API 侧应用适配器内的独立任务检查从已有数据库记录恢复，各操作使用数据库租约协调多个实例，不新增共享任务类型。正常请求立即执行；后续检查使用独立定时器。停止进程时取消定时器、终止并等待正在执行的检查，重启后恢复未完成记录。

PUT 响应不确定时先 GET 原 ID，必要重放仍使用同一 ID；已受理、隐藏或 unknown 的任务不通过新提交恢复。401 表示需要刷新或登录；503 `authentication_unavailable` 保留原操作等待恢复，不视为撤销。用户、空间成员资格和原连接在查询、下载及交付前重新核对。

结果使用现有附件大小上限与 MIME 处理，逐文件限量读取并去重。恢复时先寻找已经保存的附件，避免重新下载。音乐处理全部输出；unknown 可交付已保存部分并继续查询。文件消失或超限不触发重新生成。协议未提供官方作品 URL，因此不自行拼接链接。

离线验证：

```sh
pnpm exec vitest run packages/adapters/src/creative-references.test.ts packages/adapters/src/creative-app.test.ts packages/adapters/src/creative-application.test.ts packages/adapters/src/configured-apps.test.ts packages/adapters/src/application-proxy.test.ts apps/api/src/connected-app-credentials.test.ts
pnpm test:integration --spec=creative-jobs
pnpm test:e2e --spec=creative-app.spec.ts
```

测试使用合成身份、令牌及文件；数据库用例使用隔离数据库。lab 已验证真实用户认证、401 后刷新、图片提交、新进程续查、附件保存及聊天投递。lab 已验证合成图片、视频、音频的真实二进制上传、元数据返回、同用户内容去重及测试素材清理，并验证 worker 在没有认证配置时通过通用代理读取完整能力目录。此次参考素材联调未发起付费生成；原生浏览器返回、使用视频/音频参考的实际视频生成、音乐和账单归属仍需单独验收。实测图片的输出像素与目录尺寸声明存在差异，客户端保留上游原文件，尺寸语义待服务端确认。

预设可省略，不能以空字符串或显示名称代替。所有新操作在提交前读取目录，model 必须精确匹配目录 ID；省略 preset 时解析 defaultPreset。现有 effect.request.input 保存补齐预设后的快照，省略时另存原始 effect.request.toolInput 用于请求比较；恢复复用 state.submission、原 operationId、预设、参数和参考 ID，不随最新默认值变化，也不重发新的付费任务。
