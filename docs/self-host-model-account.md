# External model account

An optional external account supplies each user's model key. The external model service owns
balance, limits and charges. Rakazo does not reserve or settle local model credits in this mode.

## Configure the server

Configure [OIDC](self-host-accounts.md#openid-connect-sso) first. Leave local billing credentials
unset. The API refuses to enable this connection alongside local billing.

Set `MODEL_ACCOUNT_CONNECTION` on both API and worker to a JSON object:

```json
{
  "provider": "reseller",
  "origin": "https://accounts.example.com",
  "credential": "replace-with-app-credential",
  "baseUrl": "https://models.example.com/v1"
}
```

These are synthetic examples. The application credential belongs in deployment secret storage;
never supply a user model key. No model ID, protocol, enabled-model list or browser-authorization
origin list is required. Authorization URLs returned by the trusted service must be HTTPS with
no userinfo or fragment. An existing explicit authorization-origin allowlist is still honored.
Legacy `model` connection envelopes remain accepted during upgrades. The public config response
also retains derived legacy link fields and an empty default-model field for already-installed
clients; these are response compatibility fields, not required deployment settings.

The server account `origin` accepts HTTP or HTTPS without an additional setting. Use HTTP only
on a trusted private network: application credentials and user keys travel without TLS on that
link. Browser authorization, callbacks, model `baseUrl` and navigation still require HTTPS.

Authorization discovers `/models` with a transient user key and exposes those models in the
existing model picker. It never replaces the selected main model. Pick the desired model in
Settings; Refresh models retries discovery. Catalog failures do not invalidate an otherwise
successful authorization. The API protocol defaults to Chat Completions; select Responses in
Model account settings when the target models support it. Protocol changes do not send model
requests or automatically retry another protocol.

Home and Recharge come from the public HomeONE navigation policy at `/auth.json`, the same
policy used by its browser navigation module. The default origin is the platform's standard
HomeONE entry, matching CreativeOne. A self-hosted portal may set optional `navigationOrigin`
in the same JSON; there are no required `homeUrl` or `rechargeUrl` settings. Web/Electron only
accept channel cookies matching exact destinations in the published policy; dedicated hosts
without a matching channel hide navigation. Mobile uses platform defaults and opens links in
the system browser. If the policy cannot be loaded, navigation links are hidden while model
authorization and balance remain available. No remote JavaScript is executed by API or mobile.

The worker needs the same `BETTER_AUTH_SECRET` as the API, plus `OIDC_ISSUER`, to read the
existing encrypted account binding. It does not need the OIDC client secret. Compose passes
these values explicitly. No additional identity table or identity cache is created.

All public authorization URLs require HTTPS. Register the following exact model callback using
the public `BETTER_AUTH_URL` origin:

```text
https://app.example.com/api/model-account/callback
```

This is separate from the existing OIDC callback `/api/auth/callback/oidc`. Give the application
`keys:ensure` and `balance:read`, configure its default model group, and verify the model service
uses the same issuer and subject semantics. No management credentials are needed by the app.

For the portal product, register `/api/model-account/oidc` as the direct OIDC start path. The
ordinary launch path can remain `/app`. Web, desktop and mobile all retain their existing
OIDC login flows. Native clients do not share portal navigation cookies. Navigation uses the public platform policy; native clients fall back to platform defaults.

## Use the account

On the initial Connect a model screen, open **Model account**; existing users can open account
model settings. Mobile opens the existing model settings after sign-in when no usable model is
configured, following the optional signup survey when needed. Choose **Use model account**,
authorize, and select a main model in that same
settings panel. If authorization is required,
the browser opens a one-time launch URL, obtains a browser-bound cookie, and continues to the
authorization provider. The callback checks the original app session and pinned identity.
The same handoff supports mobile bearer sessions without putting their session tokens in URLs.
Web and Electron use a popup and keep the original page, composer text and attachments in memory.
Mobile returns to its previous screen, with model settings as the cold-start fallback.
Cancelling leaves the original work intact.

A successful connection leaves all existing model selections intact. Choose a main model using
the existing model settings after authorizing. An explicit Space override remains in effect.
Managed connections are excluded from ordinary key editors. Disconnect through the Model account
API to revoke the external authorization when necessary. Connected settings show the account
status without a routine Disconnect action; older pending disconnections still offer Retry
disconnect. Other personal model connections continue to use their own keys.

The server stores a reference to the existing Account and its binding, not copied identity
claims or a persistent model key. Every run resolves a fresh user key. Background runs can
continue after a browser closes, but a missing, replaced or ambiguous identity fails closed.
Disconnect removes the local connection before calling the external revoke endpoint. Already
sent model requests may still finish and be charged.

Model authorization pauses affected tasks before a model call. Successful authorization resumes
only runs paused for that same account binding, using their original run IDs and the existing
executor. Completed runs and unrelated approval waits are never replayed.
The paused task shows **Authorize and continue** only to its user. Clicking it opens the existing
authorization flow in place; it does not require opening settings or replace the current draft.
Tasks never open authorization windows automatically. Snapshot and live-event hints derive from
the current server checkpoint, so old prompts, other users' tasks and ordinary input waits do
not expose the action. Old clients retain the existing text guidance and settings entry.

Balances are displayed with their original decimal amount and unit. They are informational;
the model service makes the final decision on whether a request has sufficient funds. Failed
balance reads are shown as unavailable. Use Refresh balance to retry; focus or app foreground
also refreshes the balance after visiting the recharge page. No polling is added. Local usage
records are not an external invoice.

## Deploy and recover

Deploy API and worker before allowing users to create these connections. Keep the previous
worker running until its current jobs finish. An older worker cannot resolve an external key;
do not roll it back onto pending external-account jobs. This implementation needs no migration.

Changing the application credential invalidates in-flight authorization transactions. Users
start authorization again; no credential-version registry is maintained. A lost exchange reply
is checked with `ensure` rather than replaying the authorization code. The UI distinguishes
incomplete authorization, unknown authorization results and pending disconnection. Existing OIDC
sign-in is unchanged; model settings do not add an SSO linking action. Unknown exchanges are
confirmed automatically once on refresh through a session-bound recovery request. Only failed
confirmation exposes Retry, and only failed disconnection exposes Retry disconnect. Recovery
never starts a new authorization or repeats a code exchange.
Unknown disconnection remains recorded in the existing authorization table until an explicit
retry succeeds. A newer authorization
attempt in the same app session replaces the previous attempt.

To disable the integration, clear `MODEL_ACCOUNT_CONNECTION` on API and worker. Saved external
connections fail closed; ordinary personal connections keep working. No deployment key is
substituted for an external account key. Resolve or cancel affected jobs before rolling back.

Use isolated offline fixtures for verification. Live identity login, native OS browser handoff,
and actual model charges need separate deployment acceptance; do not treat mocked browser
responses as proof that a live platform has been configured.

If connection or balance requests return `unavailable`, inspect API logs for
`Model account service rejected a request` or `Model account service request failed`. These
record the operation and HTTP status, or distinguish transport, timeout and response failures.
They omit endpoint addresses, credentials, identity claims and upstream response bodies.
`Model account operation failed` identifies a local failure outside that service request.

## Docker Hub amd64 publication

`publish-dockerhub.yml` builds the existing application Dockerfile on pushes to `main` or a manual
run on `main`. It includes Web, API and worker in one `linux/amd64` image. Configure repository
secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (a token with write access to the target image).
The default image is `<Docker Hub username>/<GitHub repository name>`; optional repository variable
`DOCKERHUB_IMAGE` overrides that repository, for example `example/app`.

Each build checks the image for credentials before pushing `sha-<full commit>` and `latest`.
Rerunning an older commit does not move `latest` backwards. Registry credentials are used only by
the workflow, never passed to the image build. Use the SHA tag for reproducible deployment;
configure API, Web and worker services to use the same image. This workflow publishes the
application only; the existing upstream workflow handles optional updater and computer images.

CI defaults to GitHub-hosted Ubuntu runners. Set `CI_RUNNER` to use a compatible custom runner.

## 模型账户专用模式

整个产品仅允许 TokenONE 模型账户，无需新增开关。未配置 `MODEL_ACCOUNT_CONNECTION` 或未完成授权时不能调用模型；不会恢复普通提供方、API Key、第三方模型 OAuth 或部署默认模型。外部云端编码代理也不启用。Web、桌面和移动端保留账户内主模型、备用模型、审批模型和 Bot 模型选择。

API 启动时自动清理普通模型连接、其不再被模型或语音连接引用的密钥、连接偏好和普通模型 OAuth 事务；非账户主模型／备用模型选择会删除，非账户 Bot／定时任务模型覆盖会清空，随后跟随账户默认。已有平台连接、平台模型选择、OIDC 登录身份与历史会话保留。此操作不可逆，仅回退程序不能恢复普通连接。

升级前先停止旧 API 和 worker，再更新并启动，避免旧进程继续读取或写入旧模型配置。启动后授权模型账户，并从账户列表选择主模型；需要自动审批时也选择账户内审批模型。
