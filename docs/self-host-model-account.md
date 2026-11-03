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
  "authorizationOrigins": ["https://gateway.example.com"],
  "homeUrl": "https://home.example.com/",
  "rechargeUrl": "https://wallet.example.com/",
  "modelId": "example-model",
  "model": {
    "kind": "openai_compatible",
    "baseUrl": "https://models.example.com/v1",
    "apiProtocol": "chat-completions",
    "enabledModelIds": ["example-model"]
  }
}
```

These are synthetic examples. Keep the application credential in deployment secret storage.
Do not put a user's model key in this configuration. `model` uses the existing compatible
connection format, including enabled model IDs, image capability lists and model limits.
The endpoint is operator-controlled; users cannot change it on this connection.

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
OIDC login flows. Native clients do not share portal navigation cookies. This version supplies explicit public Home and Recharge links;
channel-specific navigation-cookie selection and arbitrary channel domains are not enabled.

## Use the account

Open account model settings and choose **Use model account**. If authorization is required,
the browser opens a one-time launch URL, obtains a browser-bound cookie, and continues to the
authorization provider. The callback checks the original app session and pinned identity.
The same handoff supports mobile bearer sessions without putting their session tokens in URLs.
Web and Electron use a popup and keep the original page, composer text and attachments in memory.
Mobile returns to its previous screen, with model settings as the cold-start fallback.
Cancelling leaves the original work intact.

A successful connection selects the configured model as the account's main model. An explicit
Space override remains in effect until changed through the existing model role controls.
Managed connections are excluded from ordinary key editors. Disconnect through the Model account
controls to revoke the external authorization. Other personal model connections continue to use their own keys.

The server stores a reference to the existing Account and its binding, not copied identity
claims or a persistent model key. Every run resolves a fresh user key. Background runs can
continue after a browser closes, but a missing, replaced or ambiguous identity fails closed.
Disconnect removes the local connection before calling the external revoke endpoint. Already
sent model requests may still finish and be charged.

Model authorization pauses affected tasks before a model call. Successful authorization resumes
only runs paused for that same account binding, using their original run IDs and the existing
executor. Completed runs and unrelated approval waits are never replayed.

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
