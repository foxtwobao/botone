# Native agents on managed computers

The application and its existing Supervisor manage native execution. No host daemon, systemd installation, separate execution token, private reverse proxy or execution image is required. The built-in runtime remains the default.

## Deploy

The image workflow publishes the prepared computer to `<application-repository>_computer:sha-<commit>` and `:latest`. Use the application and computer images from the same release, and keep the previous references for rollback. For example:

```yaml
services:
  computer:
    image: example/application_computer:latest
    command: ["true"]
    network_mode: none
    restart: "no"
  supervisor:
    environment:
      RAKAZO_COMPUTER_IMAGE: example/application_computer:latest
```

When layering over the repository's Compose definitions, include `infra/compose/docker-compose.execution.yml` after the base files. It removes the base computer build and uses `RAKAZO_COMPUTER_IMAGE` for both services. Pull the selected computer image before starting the stack. Validate the merge with `bash infra/sandboxes/native-execution/check-compose.sh`.

Retain the existing computer provider connection. Both the API and Worker use it; its service credential never enters a computer or a user's execution settings. The Supervisor's private execution state stays under its existing data directory, outside computer homes. Supervisor shutdown or a lost process connection stops its CLI descendants; unfinished prompts are never automatically replayed.

Recreate the application services through the normal deployment, then use **Update computer** for existing computers. Their persistent homes and user installations remain available. New computers use the selected image immediately. A stopped computer is not started just to open settings.

## Model initialization

Use the existing authorized model-account connection and its protocol defaults:

```json
{
  "provider": "reseller",
  "origin": "https://accounts.example.com",
  "credential": "REPLACE_WITH_APPLICATION_CREDENTIAL",
  "baseUrl": "https://models.example.com/v1",
  "defaults": {
    "responses": "example-response-model",
    "anthropic-messages": "example-message-model",
    "chat-completions": "example-chat-model"
  }
}
```

These are exact model IDs supported by the corresponding protocol. A model appearing in `/models` alone does not certify protocol support. Missing defaults affect only the corresponding engine.

The Worker needs the application's existing public `BETTER_AUTH_URL` and shared `ENCRYPTION_KEY` for computer initialization. The computer must be able to reach that URL through its existing egress policy. Preparation writes a scoped launch capability into the eligible personal computer, rather than a model key. It preserves custom launchers, account files and CC Switch settings. Both a personal space's Team Computer and a dedicated computer are eligible; spaces shared with another person do not receive one member's personal credentials.

The authorized backend validates current account status, membership, computer ownership and credential generation at launch. Only an authentication failure attempts one key recovery; quota, rate limits, outages and denied authorization do not repeatedly rotate keys. A running model request is never restarted or replayed after an error.

## Execution and readiness

The image installs pinned official CLI distributions: Codex 0.167.0, Claude Code 2.1.286 and DSH 0.2.1-rc.2. Codex uses app-server JSON-RPC; Claude Code uses bidirectional stream-json; DSH uses ACP. Native sessions, context and tool loops belong to each CLI. The application handles task state, authorization and message persistence.

The Supervisor starts the CLI through Docker exec as the computer's ordinary user with an explicit environment. Computers retain their existing filesystem, network policy and capability restrictions. No Docker socket or deployment credentials are supplied to a CLI. A per-run subreaper cleans up detached tools when the run ends; stopping a run leaves the desktop and unrelated runs active.

Discovery checks current authorization, protocol defaults and the installed CLI version. No operator-written verification receipt is needed. Readiness does not claim that a paid model turn has already succeeded. Offline tests cover protocol contracts, authorization, process cleanup and recovery. Release acceptance should additionally exercise each real CLI/account: a model turn, an allowed or denied operation, native resume, and confirmed cancellation. Real model tests are opt-in and their cost is recorded separately.

Ordinary users select ready agents and models from existing settings on web, desktop and mobile. There is no service-address or token form. Unsupported computer providers do not expose native execution until their adapter implements it.
