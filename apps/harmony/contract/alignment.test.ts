// M0 wiring smoke: the dev-only workspace edges resolve and every package the Phase 1
// ArkTS code ports from is reachable by name. The layer-1 snapshots and layer-2 behavior
// fixtures (design §4.3) grow from these imports in M1/M3; keeping them real is what the
// import-boundaries unused rule and the changed-areas devDep assertion pin.
import {
  buildIdAt,
  CLIENT_BUILD_HEADER,
  CLIENT_UPDATE_REQUIRED_STATUS,
  formatClientBuild,
  parseClientBuild,
} from "@rakazo/contracts";
import { IDLE_TIMEOUT_MS } from "@rakazo/core";
import { messages as en } from "@rakazo/i18n/locales/en/messages.po";
import { normalizeApiBase } from "@rakazo/mobile/lib/api/endpoint.js";
import { darkTokens, lightTokens } from "@rakazo/ui-tokens";
import { describe, expect, it } from "vitest";

describe("harmony workspace alignment", () => {
  it("pins the update-required status the rpc layer ports", () => {
    expect(CLIENT_UPDATE_REQUIRED_STATUS).toBe(426);
  });

  it("names the build in the shape the server's handshake accepts", () => {
    // Phase 1 reuses the mobile build series: gen-client-build.ts stamps buildIdAt(new Date())
    // and the ArkTS net layer sends `mobile/<id>` under this header on every RPC.
    const build = buildIdAt(new Date());
    const header = formatClientBuild("mobile", build);
    expect(CLIENT_BUILD_HEADER).toBe("x-rakazo-client-build");
    expect(parseClientBuild(header)).toEqual({ kind: "mobile", build });
  });

  it("pins the half-open idle timeout the realtime layer ports", () => {
    expect(IDLE_TIMEOUT_MS).toBe(45_000);
  });

  it("reads the mobile palette, not the web overrides", () => {
    expect(lightTokens.background).not.toBe(darkTokens.background);
  });

  it("loads the english catalog the i18n codegen compiles", () => {
    expect(Object.keys(en).length).toBeGreaterThan(0);
  });

  it("normalizes a server address like the mobile reference", () => {
    expect(normalizeApiBase("example.com")).toEqual({ ok: true, url: "https://example.com" });
  });
});
