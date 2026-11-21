import { describe, expect, it, vi } from "vitest";
import { LarkFeishuProvider } from "./feishu-provider.js";

const state = vi.hoisted(() => ({ code: 99991672 as unknown, msg: "upstream" as unknown }));
vi.mock("@larksuiteoapi/node-sdk", () => ({
  Client: class {
    async request() {
      throw { response: { status: 400, data: { code: state.code, msg: state.msg } } };
    }
  },
  Domain: { Feishu: "https://open.feishu.cn", Lark: "https://open.larksuite.com" },
  LoggerLevel: { error: 0 },
}));

const config = {
  appId: "cli_synthetic",
  appSecret: "synthetic",
  domain: "feishu" as const,
  identity: "app" as const,
  name: "Feishu",
};
const signal = new AbortController().signal;

describe("feishu provider error classification", () => {
  it.each([
    [99991672, "forbidden"],
    [99991400, "rate_limited"],
    [12345, "unavailable"],
  ])("maps upstream code %s to %s", async (code, expected) => {
    state.code = code;
    const provider = new LarkFeishuProvider(config);
    await expect(provider.createDoc({ title: "x" }, signal)).rejects.toMatchObject({
      code: expected,
    });
  });

  it("surfaces Feishu's official permission-application link on a denial", async () => {
    state.code = 99991672;
    state.msg =
      "Access denied. 点击链接申请并开通任一权限即可：https://open.feishu.cn/app/cli_synthetic/auth?q=docx:document&token_type=user";
    const provider = new LarkFeishuProvider(config);
    await expect(provider.createDoc({ title: "x" }, signal)).rejects.toMatchObject({
      code: "forbidden",
      permissionUrl:
        "https://open.feishu.cn/app/cli_synthetic/auth?q=docx:document&token_type=user",
    });
  });
});
