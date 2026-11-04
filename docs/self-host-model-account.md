# External model account

An optional external account supplies each user's model key. The external model service owns
balance, limits and charges. Rakazo does not reserve or settle local model credits in this mode.

## Configure the server

Configure [OIDC](self-host-accounts.md#openid-connect-sso) first. Leave local billing credentials
unset. The API refuses to enable this connection alongside local billing.

Set `MODEL_ACCOUNT_CONNECTION` on the API to a JSON object:

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

Authorization discovers `/models` with the user key and exposes those models in the
existing model picker. Set the existing generic default-model environment variable on the API
for automatic first-time setup:

```dotenv
PI_DEFAULT_MODEL=gpt-6.1-terra
```

Use the exact model ID accepted by the configured compatible endpoint. Once authorization
succeeds, the API initializes an unset main model with this ID and the user's authorized
connection. It never replaces an existing main model, including on reauthorization. Leaving
this setting unset keeps manual model selection. Refresh models retries discovery. Catalog failures do not invalidate an otherwise
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

The API stores the user key through the existing encrypted credential store. The worker reads
an ordinary OpenAI-compatible connection and needs no external-account configuration or
identity-provider credentials.

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
Web authorizes in the current tab and returns to the original URL, including its settings panel.
The existing composer draft storage restores saved text and mentions after the redirect; unsent
attachments held only in memory are not restored. Electron retains its native authorization
window so external navigation does not replace the app shell.
Mobile returns to its previous screen, with model settings as the cold-start fallback.
On Web, the browser Back action returns to the original page.

A successful connection leaves all existing model selections intact. Choose a main model using
the existing model settings after authorizing. An explicit Space override remains in effect.
The account page manages authorization and model selection without an ordinary key editor. Disconnect through the Model account
API to revoke the external authorization when necessary. Connected settings show the account
status without a routine Disconnect action; older pending disconnections still offer Retry
disconnect. Other personal model connections continue to use their own keys.

Authorization saves the non-expiring user key and trusted base URL as an ordinary compatible
connection. Account binding metadata stays with the encrypted secret for account management.
Model calls use the existing provider without contacting the authorization service or checking
the login identity again. A model-service rejection follows ordinary credential error and
fallback handling. Disconnect removes the local connection before calling the external revoke
endpoint. Already sent model requests may still finish and be charged.

When model authorization is required, model setup follows the existing fallback and failure
handling. Missing or unfinished account authorization opens model setup directly on entry. After
authorizing, retry any previously failed task manually. A remotely rejected key still follows
the ordinary provider error handling; it does not trigger a new authorization automatically.

Balances are displayed with their original decimal amount and unit. They are informational;
the model service makes the final decision on whether a request has sufficient funds. Failed
balance reads are shown as unavailable. Use Refresh balance to retry; focus or app foreground
also refreshes the balance after visiting the recharge page. No polling is added. Local usage
records are not an external invoice.

## Deploy and recover

Keys saved by this version work through the existing API and worker credential path.
Connections saved by an earlier version with only an account reference need one reconnection
from the account setup prompt. Reconnection preserves their credential IDs and model selections.

Changing the application credential invalidates in-flight authorization transactions. Users
start authorization again; no credential-version registry is maintained. A lost exchange reply
is checked with `ensure` rather than replaying the authorization code. The UI distinguishes
incomplete authorization, unknown authorization results and pending disconnection. Existing OIDC
sign-in is unchanged. If identity binding is missing, model setup offers the existing SSO
account-link flow directly. Unknown exchanges are
confirmed automatically once on refresh through a session-bound recovery request. Only failed
confirmation exposes Retry, and only failed disconnection exposes Retry disconnect. Recovery
never starts a new authorization or repeats a code exchange.
Unknown disconnection remains recorded in the existing authorization table until an explicit
retry succeeds. A newer authorization
attempt in the same app session replaces the previous attempt.

To disable account management, clear `MODEL_ACCOUNT_CONNECTION` on the API. Existing stored
keys remain ordinary compatible connections. Disconnect or revoke them before disabling
management if model access should also end.

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

## 模型设置入口

Web、桌面和移动端的模型设置展示平台账户授权以及账户内的模型选择。普通连接的管理入口隐藏。服务端沿用上游的连接 API 和模型选择规则，后台任务仍可使用原有凭据和已保存的模型。启动不会删除连接或重写模型选择。语音、远程记忆、媒体生成和云代理按各自的上游配置运行。

首次模型设置直接展示授权内容，展示服务名称、费用说明和授权主操作；余额、充值、模型与协议管理在连接成功后显示。授权前不读取余额。进入应用时若账户尚未授权或有未完成的授权，Web 和桌面端自动打开现有设置层，移动端打开原生账户授权页面。缺少身份绑定时可在这里直接继续 SSO 绑定，无需另找账户页。确认授权成功后，Web 和桌面端自动关闭设置层，移动端返回原页面；首次设置没有上一页时返回首页。Web 首次引导若仍需选择主模型，在关闭弹层后的原页面继续，选择完成后自动进入下一步。失败、取消或结果未确认时保留授权界面。关闭后不会在同一会话中因同一状态反复弹出；外部授权由用户点击按钮后开始。

授权成功后，服务端把无过期 Key、可信服务地址、协议和模型列表保存为普通兼容连接。后续模型调用复用原有 provider，不再向授权服务取 Key 或校验账户绑定。

## Compose deployment

Load the account overlay after the base Compose file so the API receives
the external account configuration. For a source deployment, use:

```sh
docker compose --env-file .env \
  -f infra/compose/docker-compose.yml \
  -f infra/compose/docker-compose.model-account.yml up -d --build
```

The same overlay can follow `docker-compose.prod.yml` or `docker-compose.images.yml`.
For an image deployment in a separate directory, copy the overlay alongside the base file
and use their local filenames. Include the overlay on subsequent Compose operations too.
