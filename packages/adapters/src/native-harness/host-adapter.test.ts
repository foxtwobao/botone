import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { hostDisabledFeatures } from "@rakazo/native-runtime/host-policy";
import { afterEach, describe, expect, it } from "vitest";
import {
  HOST_ENGINE_VERSION,
  hostEnvironment,
  hostFilesystemOverride,
  hostLaunchArguments,
  hostMcpOverride,
  resolveHostExecutable,
} from "./host-adapter.js";

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});
function fixture() {
  const root = realpathSync(mkdtempSync(path.join(tmpdir(), "native-cli-discovery-")));
  roots.push(root);
  return root;
}
function file(root: string, relative: string) {
  const target = path.join(root, relative);
  mkdirSync(path.dirname(target), { recursive: true });
  writeFileSync(target, "offline executable fixture");
  return target;
}

describe("native host admission", () => {
  it.each([false, true])(
    "adds only the per-run sandbox label to readOnly=%s permissions",
    (readOnly) => {
      const override = hostFilesystemOverride("fixture", readOnly, {
        allow: "/System/Library/fixture-allow",
        deny: "/System/Library/fixture-deny",
      });
      expect(override).toBe(
        `permissions.fixture.filesystem={":root"="${readOnly ? "deny" : "read"}",":minimal"="read",":workspace_roots"={"."="${readOnly ? "read" : "write"}"},"/System/Library/fixture-allow"="read","/System/Library/fixture-deny"="deny"}`,
      );
    },
  );
  it("quotes MCP names as TOML value keys instead of dotted override paths", () => {
    expect(hostMcpOverride(["plain", "server.with.dots", 'quoted"name'])).toBe(
      'mcp_servers={"plain"={enabled=false},"server.with.dots"={enabled=false},"quoted\\"name"={enabled=false}}',
    );
    expect(() => hostMcpOverride(Array(257).fill("server"))).toThrow("configuration_not_confirmed");
  });
  it("passes only the native account's environment and excludes server secrets and shell hooks", () => {
    expect(
      hostEnvironment({
        Path: "/fixture/bin",
        HOME: "/fixture/home",
        CODEX_HOME: "/fixture/account",
        SystemRoot: "C:\\Windows",
        DATABASE_URL: "fake-database-secret",
        NODE_OPTIONS: "--import=fake-hook",
        BASH_ENV: "/fake-hook",
        OPENAI_API_KEY: "fake-server-key",
        RAKAZO_LOCAL_ACCESS_TOKEN: "fake-product-token",
        OTEL_EXPORTER_OTLP_HEADERS: "fake-export-secret",
      }),
    ).toEqual({
      PATH: "/fixture/bin",
      HOME: "/fixture/home",
      CODEX_HOME: "/fixture/account",
      SYSTEMROOT: "C:\\Windows",
    });
  });

  it("disables native side channels before initialization and pins the tested protocol", () => {
    expect(HOST_ENGINE_VERSION).toBe("0.167.0");
    const args = hostLaunchArguments();
    for (const feature of hostDisabledFeatures)
      expect(args.join(" ")).toContain(`--disable ${feature}`);
    expect(args).toContain("notify=[]");
    expect(args).toContain("allow_login_shell=false");
    expect(args.at(-1)).toBe("app-server");
  });

  it("finds a Windows native binary in a directory with spaces and Unicode", async () => {
    const root = fixture();
    const executable = file(root, path.join("安装 path", "codex.exe"));
    expect(
      await resolveHostExecutable({
        platform: "win32",
        arch: "x64",
        home: root,
        env: { Path: path.dirname(executable) },
      }),
    ).toBe(executable);
  });

  it("never executes a Windows shell shim or searches the current directory from an empty PATH entry", async () => {
    const root = fixture();
    file(root, "codex.cmd");
    file(root, "codex.bat");
    expect(
      await resolveHostExecutable({
        platform: "win32",
        home: root,
        env: { PATH: `${root};;relative`, APPDATA: root },
      }),
    ).toBeUndefined();
  });

  it.each(["x64", "arm64"])(
    "finds the official npm optional native package for %s without reading shim code",
    async (arch) => {
      const root = fixture();
      const suffix = arch === "arm64" ? "arm64" : "x64";
      const triplet = arch === "arm64" ? "aarch64-pc-windows-msvc" : "x86_64-pc-windows-msvc";
      const executable = file(
        root,
        path.join(
          "node_modules",
          "@openai",
          "codex",
          "node_modules",
          "@openai",
          `codex-win32-${suffix}`,
          "vendor",
          triplet,
          "codex",
          "codex.exe",
        ),
      );
      expect(
        await resolveHostExecutable({
          platform: "win32",
          arch,
          home: root,
          env: { PATH: root, APPDATA: root },
        }),
      ).toBe(executable);
    },
  );
});
