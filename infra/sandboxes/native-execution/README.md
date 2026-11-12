# Native execution service (Linux)

This composition root runs the first three external engine adapters. The built-in runtime stays the default. An external profile is selectable only after its pinned CLI version and the opt-in account verification pass. Installing a CLI alone does not enable it.

## Automatic personal environments

For ordinary users, deploy the optional service once and use automatic discovery instead of manually binding accounts. Both a personal space's Team Computer (shared by its bots) and a dedicated computer are eligible. The computer must belong to the user and the space must have no other members. Adding another member prevents further personal credential issuance and new managed dispatches, including copied launch capabilities. Existing CLI processes are not replayed or automatically restarted; already-issued credentials cannot be recalled from a running process. A shared space requires a separately administered shared account and explicit profiles.

The image workflow publishes two immutable artifacts beside the application image: `computer-sha-<commit>` and `execution-sha-<commit>`. Pull both from the same release. The computer image contains the CLIs; the execution image is an artifact extracted onto the Linux host, **not** a privileged Docker service. Local equivalents are:

```sh
docker build -t rakazo/computer infra/sandboxes/computer
docker build -t rakazo/computer:native-execution infra/sandboxes/native-execution
docker build --build-arg GIT_SHA="$(git rev-parse HEAD)" -f infra/sandboxes/native-execution/control.Dockerfile -t rakazo/execution .
```

Create a root-owned mode-0600 service configuration. The revision must match the artifact's real source commit. These values are placeholders:

```json
{
  "root": "/var/lib/rakazo/execution",
  "token": "REPLACE_WITH_64_RANDOM_HEXADECIMAL_CHARACTERS",
  "port": 9081,
  "managed": {
    "apiUrl": "https://app.example.com",
    "runtimeRevision": "REPLACE_WITH_THE_40_CHARACTER_RELEASE_COMMIT",
    "verification": {
      "spaceId": "example-space",
      "userId": "example-user",
      "computerId": "example-test-computer"
    }
  }
}
```

`verification` designates an authorized personal test computer for release acceptance only; normal users are discovered dynamically. Set the API's generic `EXECUTION_CONNECTION` to a private server-only JSON envelope:

```json
{
  "url": "http://execution.internal.example:9081",
  "token": "REPLACE_WITH_THE_SAME_RANDOM_SERVICE_TOKEN",
  "allowPrivateEndpoint": true
}
```

The daemon listens only on host loopback. For a containerized API, reach it through a restricted host-side reverse proxy with TLS, or an explicitly trusted private network endpoint. Private addresses require `allowPrivateEndpoint: true` even with TLS. Never expose the control endpoint to browsers, computers or the public network. The reverse proxy must also reject browser Origins; the daemon does so independently. The daemon calls only the authenticated environment endpoint on the API and receives scoped launch capabilities, not model keys or database credentials.

Include `infra/compose/docker-compose.execution.yml` after the existing Compose files, retain the existing `MODEL_ACCOUNT_CONNECTION` protocol defaults, and set `RAKAZO_COMPUTER_IMAGE` to the pinned prepared image. This overlay uses the existing supervisor; it does not grant host privileges to computers. Recreate the API/worker/supervisor through the normal rolling deployment, then update existing computers with **Update computer** to preserve their homes. Keep the old image and application release for rollback.

Install the host artifact with the actual supervisor home-storage directory:

```sh
sudo bash infra/sandboxes/native-execution/install-control.sh rakazo/execution /etc/rakazo/execution/configuration.json /var/lib/rakazo/homes
```

The installer checks the artifact revision, cgroup v2 and host utilities. It starts a new installation; upgrading installs the new unit without restarting an active service. Wait for its tasks to finish before restarting. Retain the old release, unit and private configuration for rollback. A restart marks unfinished native work lost and never replays prompts.

Before enabling an engine in each release, run the full opt-in verifier against the designated test computer. This makes real model calls and may incur charges. Use the installed release's Node binary and verifier:

```sh
sudo /opt/execution-releases/RELEASE/bin/node /opt/execution-releases/RELEASE/app/packages/adapters/dist/native-harness/verify-cli.js /etc/rakazo/execution/configuration.json codex --allow-workspace-test
sudo /opt/execution-releases/RELEASE/bin/node /opt/execution-releases/RELEASE/app/packages/adapters/dist/native-harness/verify-cli.js /etc/rakazo/execution/configuration.json claude --allow-workspace-test
sudo /opt/execution-releases/RELEASE/bin/node /opt/execution-releases/RELEASE/app/packages/adapters/dist/native-harness/verify-cli.js /etc/rakazo/execution/configuration.json deepseek --allow-workspace-test
```

A passing managed verifier writes a private runtime receipt for that exact release and CLI version. Every user's discovery and new dispatch still checks current ownership, membership, authorization, the live model catalog, actual CLI version and namespace isolation. It does not run the paid model suite for every user. Missing receipts keep the engine unverified. Restarting the daemon is not necessary after a managed receipt is written.

Opening a bot's advanced settings creates its computer connection idempotently, without starting a stopped computer or changing its selected agent. Ordinary users can select ready engines and retry unavailable environments on web, desktop and mobile. No administrator email list, user-by-user profile file or service token entry is required. Account disconnect/recreation, model-default changes and runtime upgrades fence old managed sessions; a normal key refresh preserves the authorization generation. Explicitly revoked execution connections are never silently recreated. Previously configured explicit connections continue to use the manual mode below.

## Install

Build the desktop image with its optional native-engine layer:

```sh
docker build -t rakazo/computer infra/sandboxes/computer
docker build -t rakazo/computer:native-execution infra/sandboxes/native-execution
```

For an existing custom desktop image, pass `--build-arg COMPUTER_IMAGE=your-desktop-image` to the second build. Set the existing supervisor setting `RAKAZO_COMPUTER_IMAGE=rakazo/computer:native-execution` and restart the supervisor. New computers use the prepared image; existing computers adopt it through **Update computer**, which preserves their home. Keep the previous image for rollback. This adds no changes to the base desktop Dockerfile.

The image installs Node 26.13.0 and the official pinned CLIs in `/usr/local`: Codex 0.167.0, Claude Code 2.1.286 and DSH 0.2.1-rc.2. Building it requires no model accounts or credentials. Login, configuration, native sessions and user-installed dependencies remain in each computer's persistent home. User installations in `$HOME/.local/bin` take precedence over image defaults; remove an old override only when intentionally adopting the image version. Native account verification is still required before a profile becomes selectable.

Login through the selected computer. Its existing writable filesystem, user home, installed software and egress policy are used for every native run. No separate execution image or account home is created.

### Initialize from an authorized model account

An existing external model-account connection can initialize a user's personally owned Docker computer, including the Team Computer in a space used only by that person. Add protocol defaults to its existing `MODEL_ACCOUNT_CONNECTION` configuration; these are exact model IDs from that account's catalog, not engine names:

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

The worker needs only the existing public `BETTER_AUTH_URL` and shared `ENCRYPTION_KEY`, not the account application's credentials. The URL must be reachable from the computer through its existing egress policy. Initialization does not open network access. Authorization prepares already-running eligible computers in that space; normal computer preparation handles new, resumed and replaced computers, including worker-started runs. Computers in spaces shared with another person, and another person's computer, never receive personal credentials automatically.

Preparation installs managed launchers in `~/.local/bin` without contacting a model service. They use the image's `/usr/local/bin` executables. Existing custom launchers are preserved. Native configuration, accounts, sessions and CC Switch files are not edited. The launchers store a mode-0600 capability bound to this computer, user, space and authorization record; the user model key is fetched only for a CLI process and is not written into the image or a new credential file. Disconnecting or deleting and recreating the authorization invalidates the old capability. Model-account authorization, computer ownership, membership and account status are checked on each launch.

Before starting a CLI, the backend validates the stored key against the configured catalog endpoint. Only HTTP 401 attempts one `keys/ensure` recovery. A different returned key must pass validation before it is saved. The same invalid key, denied authorization, quota/rate limits, transport failures and server errors do not cause repeated recovery or forced key rotation. A protocol default must belong to the user's catalog; unavailable defaults affect only that engine. Help and version checks work without a network connection. Existing native profile readiness and real protocol verification remain required.

This refreshes credentials before a new CLI process, including native resumed sessions. It never restarts or replays a running task after a mid-turn error. A gateway that rejects a key only on model requests, while accepting it on `/models`, cannot be diagnosed by the catalog preflight. A trusted account service must expose a structured authentication failure before recovery can be triggered safely.

The current launch adapter supports managed Docker computers on a Linux host. Other computer providers require a launch adapter before exposing a native profile. The host needs Docker, Node and util-linux (`nsenter` with `--join-cgroup`, `unshare`, `mount`, `setpriv`) on cgroup v2; the computer needs Node and util-linux too. The control service needs permission to enter the managed computer namespaces, join its resource group, and create a temporary scoped socket in its home. With systemd filesystem protection, allow writes to the granted computer homes, private journal, and cgroup filesystem. Native engines run as its non-root user with no capabilities, supplementary groups or inherited deployment environment.

The application provisions the selected computer through its existing lifecycle before a new native run. The launcher resolves the current managed container by its space and persistent home grant, so replacing a container does not leave a stale container identifier. A stopped computer is not started directly by Docker: doing so would bypass network restoration. Start the computer before initial account verification and daemon readiness checks. Keep the control journal outside every computer mount.

The configured workspace must already exist beneath the computer home. It is also mounted as `/workspace` for protocol compatibility; both paths refer to the same persistent files. Several engines on the same selected computer intentionally share its home, installations, network and workspace. Native account files are never published through the workspace attachment bridge.

Create a private configuration file (mode 0600). The following identifiers and values are placeholders:

```json
{
  "root": "/var/lib/execution/control",
  "token": "REPLACE_WITH_64_RANDOM_HEXADECIMAL_CHARACTERS",
  "port": 9081,
  "profiles": [
    {
      "id": "personal-account",
      "revision": 1,
      "label": "Personal account",
      "spaceId": "example-space",
      "userIds": ["example-user"],
      "computerId": "example-computer",
      "engine": "codex",
      "computer": {
        "homeKey": "example-computer-home",
        "workspace": "/home/user/shared"
      }
    }
  ]
}
```

`engine` also accepts `claude` and `deepseek`. Native credentials must be installed in the selected computer home. An administrator can instead grant a compatible model connection with `modelConnection: { url, apiKey, model }` on the private profile. Translation stays in the adapters; deployment/database credentials are never inherited. For DSH, configure its native provider route in the computer home and use `provider/model` as the model identifier. A configured key remains unverified until real execution succeeds.

Profiles may publish `models: [{ id, label }]` as the models available through their account. Clients offer these in a model picker beside the profile default and retain any previously saved model. This discovery metadata contains no credentials and does not change the verified execution boundary; account, connection and launch changes still invalidate verification. Keep the list limited to models supported by that engine and account.

Switching an execution profile or model while tasks are unfinished asks the user to stop and switch. The backend validates the destination, waits for native process termination, and cancels only that bot’s work, including its work in shared threads. Cancellation leaves the saved settings unchanged on failure, and a concurrent new task must be stopped before the change can be saved.

Networking uses the selected computer's existing egress policy. Do not grant host networking, privileged containers, host PID access, Docker sockets or management mounts. A private model connection needs an explicit narrowly scoped network grant; installing a native CLI does not relax the computer's network policy. Apply resource limits to the managed computer and control service; execution starts immediately without an application-wide job queue.

## Verify and start

Run from the repository with the privileges required for the configured namespace:

```sh
pnpm exec tsx packages/adapters/src/native-harness/verify-cli.ts /path/to/private-configuration.json personal-account --allow-workspace-test
pnpm exec tsx packages/adapters/src/native-harness/daemon.ts /path/to/private-configuration.json
```

Codex uses `never` approvals with network-enabled `externalSandbox` on every turn, including resumed sessions. Commands have the same ordinary-user filesystem access as the desktop, including persistent user installs. System directories retain their normal operating-system permissions. The computer remains isolated from the host. Platform bridge effects keep their separate approvals.

Each run has a private mount and PID namespace within the selected computer. Its small trusted namespace init supplies protocol pipes and a scoped permission socket, drops privileges for the CLI, and terminates all descendants when stopped, including detached children. It does not supply host deployment credentials. The desktop and other runs keep running.

The verifier makes real model calls and may incur charges. It writes uniquely named test files, allows their test operations, verifies approval denial (or an ordinary-user system-directory denial without a prompt for Codex), resumes the original native session, and confirms a running timestamp writer stops. It also checks the real process boundary for hidden control files, deployment environment and a separate PID namespace. It does not grade free-form replies. A new profile remains unavailable until all checks pass; the verifier never writes a success receipt for skipped checks. Keep operator receipts private. Changing the profile's grant, account, model connection or isolation configuration invalidates the receipt. Increment the revision when replacing an environment or account.

For production bundles, build the daemon and verifier with `scripts/build-server.mjs` and copy `permission-proxy.mjs` and `computer-runner.mjs` beside the resulting entry points. Keep the previous application release available when applying the additive database migration.

Bind the service from the bot's **Agent → Connection** settings as an administrator. Use TLS for a remote endpoint; **Private network** explicitly authorizes an internal endpoint. Only the granted user's profiles on that bot's computer are returned. Ordinary users cannot submit host commands. Mobile clients select existing connections; administrators prepare and bind environments outside mobile.

## Supported boundary

The adapters own native tool execution, permissions, questions and sessions. Process observations never run a second copy of a tool in the application. The platform bridge exposes bot-scoped memory lookup, authorized bot messages and approval-gated workspace attachments (regular files up to 1 MiB). Attachments reuse the existing encrypted artifact storage and chat authorization. Other application tools are unavailable. Unsupported media, helper/messaging entry points and pinned built-in-model runs fail before dispatch. Group, user and scheduled work use the same dispatch boundary when their authorization scope is compatible.

Messages added during execution retain the existing next-turn queue. Native live steering is not exposed by the clients yet. Images and other incoming attachments are rejected for these profiles. Usage events distinguish run totals from native session totals; unavailable counts and prices remain null. A disconnected client does not cancel a process; lease expiry, explicit Stop and revocation terminate it. A service restart marks unfinished work as lost and never replays its prompt automatically. Existing approvals cannot be delivered to a replacement process.

## Validated baseline

Each configured account must pass the real CLI verifier against its selected computer. Verification receipts and deployment/account details stay private. Offline protocol conformance alone does not certify an installed CLI or account.

Codex and Claude Code forward single native questions; DSH does not advertise a question capability. Multiple-question forms, credential forms and URL elicitation are declined. The offline protocol tests cover those boundaries separately from model output quality.

Offline conformance, PostgreSQL authorization/recovery tests and browser approval tests run without hosted model credentials. Real account verification and native mobile device validation are separate acceptance steps; do not advertise unverified engines or platforms as supported.
