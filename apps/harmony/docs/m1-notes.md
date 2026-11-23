# M1 notes — network base + sign-in

Stacked on `harmony/m0-scaffold` (M0). Scope: design §7.2 M1 + the M0 hand-over items
(contract decoders + layer-1 snapshots, net layer, SessionStore/asset/pending sign-out,
ServerStore, SignInPage/ServerPage/me page, tokens+i18n codegen + CI step, real-backend SSE
smoke, emulator screenshots), plus the fix round for the independent verification report
(`.harmony-plan/m1-verify.md`): probe-first server switching, procedure-bound layer-1
snapshots, the repository-checks boundary, the client-build handshake, zh-TW ICU fixtures
and the server-page declutter. All product code lives under `apps/harmony/`; the other
touched files are `.github/workflows/harmony.yml` (codegen step),
`scripts/checks/import-boundaries.test.mjs` (the dev-boundary rule, see below) and the
automatic `pnpm-lock.yaml` (see "Upstream files").

Environment: DevEco 26.0.1.290 / API 26 Beta1, `devecocli` 1.3.0-stable, `devphone` emulator
(127.0.0.1:5557, guest reaches host at 10.0.2.2). Builds unsigned unless a local signing config
is injected (S2); the committed `build-profile.json5` keeps `signingConfigs: []`.

## What landed

- **Contract subset + layer-1 snapshots** (`scripts/contract-manifest.ts`,
  `contract/snapshots.test.ts`, `contract/snapshots/*.json`). Every RPC view projects its
  consumed fields from the REAL `appContract` procedure's output schema (`health` whole, `me`
  picked, `spaces/list` current identity); auth capabilities is better-auth REST, so its view
  picks from `authCapabilitiesSchema` directly. Views are exported with `z.toJSONSchema`,
  normalized (sorted keys, no description/title/$schema) and pinned; any diff fails (review Q8).
  Regenerate with `HARMONY_UPDATE_SNAPSHOTS=1`. Because the views are projections, both a type
  mutation and a procedure rebind go red — verified by mutation experiments below. The manifest
  and the fixture generator live under `scripts/` because they are dev-time codegen inputs, not
  shipped code (the import-boundaries dev boundary, below).
- **Layer-2 behavior fixtures** (`scripts/gen-fixtures.ts`, `contract/fixtures.test.ts`,
  `contract/fixtures/*.json`): retry-policy, endpoint normalization + private-host classification
  + probe, byte-level SSE (drives the REAL mobile `subscribeThread` with scripted chunks, incl.
  CRLF-not-a-boundary, multi-data-line rejoin, 16MB frame budget boundaries, UTF-8 across chunks,
  EOF tail drop, 45s idle), and ICU evaluation against `@lingui/core` over the real en/zh-CN/zh-TW
  catalogs (98 cases per locale: every plural message at four counts plus the interpolation set).
  Regenerate with `HARMONY_UPDATE_FIXTURES=1`. The same JSON is embedded into
  `entry/src/ohosTest/ets/test/fixtures.generated.ets` (gitignored) by codegen and replayed under
  hypium, so TS and ArkTS agree value-for-value.
- **net layer** (`entry/src/main/ets/net/`): `retry` (core retry-policy port), `errors`
  (RpcError + user-error/auth-error copy port), `endpoint` (normalize + private-network host
  subset + health probe), `http` (unary transport, total deadline, byte caps, lowercase headers,
  no cookies, redirects refused), `rpc` (bearer+Space+client-build headers, generation pinning,
  the two 401 branches, 426→update handler, retry-after), `sse` (pure LF-LF parser +
  requestInStream wrapper with the 45s no-chunk idle rule), `session` (asset token + generation +
  in-memory invalidation gate + single-Space cache), `asset-store`, `server-headers`,
  `saved-servers` (≤5), `sign-out` (record-before-clear, provisional→promote, connectivity-window
  retries, 30d retire), `server-store` (serialized switch transaction, probe-first — below),
  `auth` (better-auth REST, token extraction order, generation-guarded save, revocation on lost
  race), `client-build` (the build handshake header, below).
- **Server switching keeps the signed-in page** (`server-store.ets`, `app/app-state.ets`).
  The transaction records the old session's revocation provisionally, then probes the new
  address WHILE THE OLD SESSION STAYS ACTIVE; only a successful probe clears the session and
  commits. A failed probe changes nothing — address, credentials and the account page all stay
  — and settles the provisional record so it never revokes the session in use (a token a
  sign-in replaced during the probe keeps its record for delivery). A sign-in during the probe
  bumps the generation and aborts the switch before the clear, mirroring mobile's
  `api-server.ts` transaction. Failures after the clear still roll back address + session.
  The app-state session listener is symmetric: an empty token shows sign-in, a token arriving
  while sign-in is shown (sign-in, or a rollback restore) loads the account again.
- **i18n** (`i18n/icu.ets` ICU-lite, `i18n/i18n.ets` catalog load + `t`): codegen compiles the real
  lingui catalogs through lingui's own `parsePoFile` (C-1 — no hand-rolled PO parser) to
  `rawfile/i18n/{en,zh-CN,zh-TW}.json`. Missing translation falls back to the msgid; missing
  interpolation value renders empty (lingui parity). One harmony-only string
  (`i18n/harmony-strings.ets`, SSO-only-server notice) is declared centrally; everything else
  reuses catalog msgids. No `intl:extract`, no `.po` edits.
- **UI** (`features/signin`, `features/server`, `features/me`, `uikit`, `app/app-state.ets`,
  `pages/Index.ets`): Navigation + NavPathStack; capabilities-driven SignInPage (password +
  email-OTP when offered, sign-up, OTP auto-register, forgot-password via resetUrl in the system
  browser); ServerPage (normalize→probe→switch, recent servers, default); minimal me page
  (account name/email + default Space name + server, no raw ids). Tokens come from the generated
  mobile palette; appearance follows the system color mode. ServerPage declutter (verification
  suggestion): the recent list never repeats the current address (it has its own card), and
  removing a saved server is a long-press context menu (native `Menu`/`MenuItem`), not a button
  on every row.
- **codegen + CI**: `scripts/gen-tokens.ts` (CSS #RRGGBBAA → ArkUI #AARRGGBB), `gen-i18n.ts`,
  `gen-client-build.ts` (tsx, because it imports the contracts barrel), `embed-fixtures.ts`,
  run by `pnpm --filter @rakazo/harmony harmony:codegen`; harmony.yml installs workspace dev
  deps and runs codegen before the unsigned build.

## ArkTS 1.1 constraints hit (S1 follow-up)

- The V2 class decorator is `@ObservedV2` (not `@ObsV2`); `@Trace` only inside it.
- Non-empty object literals must target a declared class/interface; `Record<string, T>` literals
  with entries are rejected (`arkts-no-untyped-obj-literals`) — build them by key assignment
  (`const r: Record<string,Object> = {}; r['k']=v;`). Empty `{}` literals are accepted.
- Passing a concrete `RpcError` where a parameter is typed `Error` triggers
  `arkts-no-structural-typing`; the SSE error path is typed `RpcError` end-to-end instead.
- `@ohos.url` strips a trailing dot (`localhost.` → `localhost`); WHATWG keeps it and the
  private-network allow predicates match exactly, so `endpoint.normalizeApiBase` restores the dot
  from the raw authority (pinned by the endpoint fixture).
- `preferences.getPreferences` rejects the hypium delegator's context; its
  `.getApplicationContext()` works. Tests use that; the app uses the UIAbility context.
- `aa test -s key value` stores the raw flag as the parameter key (`"-s realBase"`); the
  real-backend smoke reads both forms.
- `asset.update` takes (query, attributesToUpdate) — two maps, not one.
- `MenuItem` colors its label with `contentFontColor`, not the universal `fontColor`.

## Test results

- TS alignment (vitest, no SDK): `apps/harmony/contract` 4 files / 17 tests pass
  (workspace alignment 6, layer-1 snapshots 5, layer-2 fixtures 4, codegen color 2).
- hypium on emulator (fixture servers on host ports 8787+8788): **54/54 pass, 0 fail, 0 error**
  (retry/endpoint/SSE-parser/ICU/decode fixture replays, asset round-trip, session+sign-out
  safety, RPC/auth/switch against the fixture server incl. the page-state and client-build
  fixtures, SSE transport incl. the ~45s idle case, M0 S3/S4 spikes). Run: start both
  `scripts/spike-sse-server.mjs` instances, install signed entry+ohosTest HAPs,
  `hdc shell aa test -b com.botone.app -m entry_test -s unittest OpenHarmonyTestRunner
  -s timeout 180000`.
- hypium with the real backend (`-s realBase http://10.0.2.2:3110 -s realEmail … -s realPassword …`):
  **54/54 pass** including `RealBackendSmoke` (evidence below).
- `pnpm checks`: **152/152 pass** (was 151/152; the fix is below).

## Drift-detection mutation experiments

Layer 1 (each applied to the real contract, run, then reverted; `git status` clean afterwards):

1. `health.version` string → number in `account-rpc.ts`: `snapshot health` fails on the type
   diff (1 failed / 4 passed). Before the projection fix this mutation stayed green.
2. `me` procedure rebind `oc.output(MeSchema)` → `oc.output(AppBootstrapSchema)`: the projection
   itself fails loudly (`Unrecognized key: "userId"`), the suite goes red at collection.
3. `health` rebind to a same-key schema with one extra required field: `snapshot health` fails
   on the shape diff (1 failed / 4 passed).

Page-state fixture: reintroducing the old clear-before-probe line in `changeServer` makes
`failed_switch_keeps_the_account_page` fail with `expect signIn equals me` (3 failures total);
with the probe-first transaction the suite is 54/54. The fixture drives the real `AppState`
session listener, so it pins the page, not just the stored address/credentials.

## Real-backend smoke (S3 formal close-out, M1 DoD)

Ran against a REAL self-hosted API started from this worktree (`pnpm dev` with `API_PORT=3110`;
managed `rakazo-dev-postgres`; the emulator reaches it at http://10.0.2.2:3110). A throwaway
account (`harmony-m1-fix@example.com`, fake password) was created via `/api/auth/sign-up/email`.
`RealBackendSmoke` (opt-in via `-s realBase/realEmail/realPassword`) passed end-to-end:

```
real health ok: http://10.0.2.2:3110
real me: harmony-m1-fix@example.com
real space: Personal
real SSE first stream events=7      <- notifications/subscribe opening signals incl. roster
real SSE reconnect events=7         <- closed and reopened; catch-up on reconnect
real backend smoke complete         <- sign-out cleared the session
```

What this proves about the real SSE endpoint: the stream opens, the client closes it
explicitly, reopens it and receives the opening signals again (reconnect catch-up). It is
**not** evidence of automatic reconnect after a network fault — that belongs to the M2/M3
stream state machine. Heartbeat filtering and fault-disconnect behavior have fixture evidence
(the byte-level SSE fixture and the ~45s idle transport case), not real-network evidence; the
smoke runs in well under the server's 20s heartbeat period. Without `-s realBase` the suite
logs a loud skip and asserts nothing (an offline run must not pretend the smoke happened).

UI loop verified by hand on the emulator against the same real server, including the
verification report's repro: sign in → me page (Harmony M1 Fix / Personal) → server page →
save unreachable `http://10.0.2.2:9` → 「无法连接到该服务器」 with the current address unchanged
→ system back lands on the ACCOUNT page, no restart and no re-login. Long-press a recent row
→ native 「移除」 menu → the row disappears. Sign out → SignInPage. Screenshots:
`screenshots/m1-server.png`, `m1-signin.png`, `m1-me.png` (recaptured this round).

Note: the dev server has email-OTP and password-reset disabled, so the captured SignInPage shows
the password form only; the fixture-server suites cover the emailCode/resetUrl branches.

## Repository checks fix (151/152 → 152/152)

`imported workspace packages are declared dependencies` flagged harmony's devDeps because the
check counted every non-test file as shipped code, including the contract manifest, the fixture
generator and the codegen scripts — none of which run on a device. Fix (the check-side option,
kept universal): `scripts/checks/import-boundaries.test.mjs` now treats files under any
`scripts/` directory as dev-time code for the shipped-usage computation (`isBuildScript`), the
same boundary the lazy-import rule already used; the fix hint says devDependencies suffice for
tests or build scripts. Positive/negative cases added: a build script may use a devDependency,
an undeclared package is still undeclared from a script. No feature or provider names in the
rule. On the harmony side the two dev-time helpers moved next to the other generators:
`contract/manifest.ts` → `scripts/contract-manifest.ts`, `contract/fixtures.ts` →
`scripts/gen-fixtures.ts` (the design's name for it); the tests import them from there. Nothing
was added to harmony runtime dependencies — the HAP still ships no mobile code.

## Client build identity (verification suggestion)

Decision: **Phase 1 reuses the mobile build series.** `scripts/gen-client-build.ts` stamps
`buildIdAt(new Date())` (the contract's own format) at codegen time, right before the HAP build;
`net/client-build.ets` sends `x-rakazo-client-build: mobile/<id>` on every RPC (via
`authHeaders`, so pinned SSE contexts carry it too) and on sign-out delivery, matching where
mobile sends it. Rationale: zero upstream contract changes — the server's existing
`RAKAZO_MIN_CLIENT_BUILD` mobile gate applies to harmony builds immediately, and an unnamed
client would never be refused. Trade-off accepted for Phase 1: harmony cannot be gated
separately from mobile. A harmony-specific kind needs an upstream `CLIENT_KINDS` entry —
**Phase 2 upstream PR list: add `harmony` to `CLIENT_KINDS` in
`packages/contracts/src/clients/client-build.ts` (+ its parse/format/minimum tests), then switch
the generator and header to it.** Coverage: the alignment test pins the header name and that
`parseClientBuild` accepts the generated shape; the fixture server records every
`x-rakazo-client-build` it receives and `rpc_names_the_client_build` asserts `mobile/<14 digits>`
arrived on a real RPC.

## Upstream files

- `.github/workflows/harmony.yml`: added pnpm install + `harmony:codegen` before the unsigned
  build (the M1 hand-over). No other workflow logic changed.
- `scripts/checks/import-boundaries.test.mjs`: the universal dev-boundary rule + its two fixture
  cases and the fix-hint wording (this round; small localized diff, no feature special-casing).
- `pnpm-lock.yaml`: automatic. M1 adds harmony devDeps `@lingui/core`, `@lingui/format-po`
  (codegen + ICU fixtures) and `expo-secure-store` (so `vi.mock` resolves from the harmony test);
  the lockfile delta is only the `apps/harmony` importer plus those packages' transitive closure.
  This is the design's sanctioned "+1 auto" file (M0 already carried the harmony importer).
  `gen-client-build.ts` runs through the root's existing `tsx` devDependency (the same pattern
  as `packages/ui-tokens`' generate script), so this round adds no dependency.

## Left for M2+

- S5 CI runner verification (Linux headless first, then hosted macOS) + the
  `HARMONY_CMDLINE_TOOLS_*` repository variables; the codegen step is wired but the hosted build
  has not produced an artifact yet.
- Real-device acceptance (M0/M1 DoD remains real-device; emulator used here as instructed).
- Upstream PR: `harmony` client kind in `CLIENT_KINDS` (see the client-build decision).
- M2 roster stream + QueryCache + inbox; M3 reducer port + consent gate; the layer-2 reducer and
  consent fixtures grow there. Automatic SSE reconnect after a network fault is the M2/M3 stream
  state machine, not M1.
- The me page is minimal by design; M2 replaces it with the inbox.
