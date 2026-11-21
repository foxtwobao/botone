# M1 notes — network base + sign-in

Stacked on `harmony/m0-scaffold` (M0). Scope: design §7.2 M1 + the M0 hand-over items
(contract decoders + layer-1 snapshots, net layer, SessionStore/asset/pending sign-out,
ServerStore, SignInPage/ServerPage/me page, tokens+i18n codegen + CI step, real-backend SSE
smoke, emulator screenshots). All product code lives under `apps/harmony/`; the only other
touched files are `.github/workflows/harmony.yml` (codegen step) and the automatic
`pnpm-lock.yaml` (see "Upstream files" below).

Environment: DevEco 26.0.1.290 / API 26 Beta1, `devecocli` 1.3.0-stable, `devphone` emulator
(127.0.0.1:5557, guest reaches host at 10.0.2.2). Builds unsigned unless a local signing config
is injected (S2); the committed `build-profile.json5` keeps `signingConfigs: []`.

## What landed

- **Contract subset + layer-1 snapshots** (`contract/manifest.ts`, `contract/snapshots.test.ts`,
  `contract/snapshots/*.json`). The M1 consumed views (health whole; me picked; spaces/list
  current identity; auth capabilities picked) are exported with `z.toJSONSchema`, normalized
  (sorted keys, no description/title/$schema) and pinned. Any diff fails (review Q8). Regenerate
  with `HARMONY_UPDATE_SNAPSHOTS=1`. The views are tied to the real `appContract` procedures so a
  wiring change also goes red.
- **Layer-2 behavior fixtures** (`contract/fixtures.ts`, `fixtures.test.ts`, `fixtures/*.json`):
  retry-policy, endpoint normalization + private-host classification + probe, byte-level SSE
  (drives the REAL mobile `subscribeThread` with scripted chunks, incl. CRLF-not-a-boundary,
  multi-data-line rejoin, 16MB frame budget boundaries, UTF-8 across chunks, EOF tail drop,
  45s idle), and ICU evaluation against `@lingui/core` over the real en/zh-CN catalogs.
  Regenerate with `HARMONY_UPDATE_FIXTURES=1`. The same JSON is embedded into
  `entry/src/ohosTest/ets/test/fixtures.generated.ets` (gitignored) by codegen and replayed under
  hypium, so TS and ArkTS agree value-for-value.
- **net layer** (`entry/src/main/ets/net/`): `retry` (core retry-policy port), `errors`
  (RpcError + user-error/auth-error copy port), `endpoint` (normalize + private-network host
  subset + health probe), `http` (unary transport, total deadline, byte caps, lowercase headers,
  no cookies, redirects refused), `rpc` (bearer+Space headers, generation pinning, the two 401
  branches, 426→update handler, retry-after), `sse` (pure LF-LF parser + requestInStream wrapper
  with the 45s no-chunk idle rule), `session` (asset token + generation + in-memory invalidation
  gate + single-Space cache), `asset-store`, `server-headers`, `saved-servers` (≤5),
  `sign-out` (record-before-clear, provisional→promote, connectivity-window retries, 30d retire),
  `server-store` (serialized switch transaction with rollback), `auth` (better-auth REST,
  token extraction order, generation-guarded save, revocation on lost race).
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
  mobile palette; appearance follows the system color mode.
- **codegen + CI**: `scripts/gen-tokens.ts` (CSS #RRGGBBAA → ArkUI #AARRGGBB), `gen-i18n.ts`,
  `embed-fixtures.ts`, run by `pnpm --filter @rakazo/harmony harmony:codegen`; harmony.yml now
  installs workspace dev deps and runs codegen before the unsigned build.

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

## Test results

- TS alignment (vitest, no SDK): `apps/harmony/contract` 4 files / 16 tests pass
  (workspace alignment 5, layer-1 snapshots 5, layer-2 fixtures 4, codegen color 2).
- hypium on emulator (fixture servers on host ports 8787+8788): **52/52 pass, 0 fail, 0 error**
  (retry/endpoint/SSE-parser/ICU/decode fixture replays, asset round-trip, session+sign-out
  safety, RPC/auth/switch against the fixture server, SSE transport incl. the ~45s idle case,
  M0 S3/S4 spikes). Run: start both `scripts/spike-sse-server.mjs` instances, install signed
  entry+ohosTest HAPs, `hdc shell aa test -b com.botone.app -m entry_test -s unittest
  OpenHarmonyTestRunner -s timeout 180000`.
- `pnpm checks`: see below (run before push).

## Real-backend smoke (S3 formal close-out, M1 DoD)

Ran against a REAL self-hosted API (`pnpm dev`, API on host 127.0.0.1:3100, reached from the
emulator at http://10.0.2.2:3100; managed `rakazo-dev-postgres`). A throwaway account
(`harmony-smoke@example.com`, fake password) was created via `/api/auth/sign-up/email`.
`RealBackendSmoke` (opt-in via `-s realBase/realEmail/realPassword`) passed end-to-end:

```
real health ok: http://10.0.2.2:3100
real me: harmony-smoke@example.com
real space: Personal
real SSE first stream events=7      <- notifications/subscribe opening signals incl. roster
real SSE reconnect events=7         <- closed and reopened; catch-up on reconnect
real backend smoke complete         <- sign-out cleared the session
```

So POST + LF framing + heartbeat-skip + clean close + reconnect were exercised against the real
`notifications/subscribe` SSE endpoint, not just the M0 fixture. Without `-s realBase` the suite
logs a loud skip and asserts nothing (an offline run must not pretend the smoke happened).

UI loop also verified by hand on the emulator against the same real server:
ServerPage → switch to saved `10.0.2.2:3100` → SignInPage (capabilities-driven) → sign in →
me page (Harmony Smoke / Personal) → sign out → back to SignInPage. Screenshots:
`screenshots/m1-server.png`, `m1-signin.png`, `m1-me.png`.

Note: the dev server has email-OTP and password-reset disabled, so the captured SignInPage shows
the password form only; the fixture-server suites cover the emailCode/resetUrl branches.

## Upstream files

- `.github/workflows/harmony.yml`: added pnpm install + `harmony:codegen` before the unsigned
  build (the M1 hand-over). No other workflow logic changed.
- `pnpm-lock.yaml`: automatic. M1 adds harmony devDeps `@lingui/core`, `@lingui/format-po`
  (codegen + ICU fixtures) and `expo-secure-store` (so `vi.mock` resolves from the harmony test);
  the lockfile delta is only the `apps/harmony` importer plus those packages' transitive closure.
  This is the design's sanctioned "+1 auto" file (M0 already carried the harmony importer); no
  upstream source file is hand-edited.

## Left for M2+

- S5 CI runner verification (Linux headless first, then hosted macOS) + the
  `HARMONY_CMDLINE_TOOLS_*` repository variables; the codegen step is wired but the hosted build
  has not produced an artifact yet.
- Real-device acceptance (M0 DoD remains real-device; emulator used here as instructed).
- M2 roster stream + QueryCache + inbox; M3 reducer port + consent gate; the layer-2 reducer and
  consent fixtures grow there.
- The me page is minimal by design; M2 replaces it with the inbox.
