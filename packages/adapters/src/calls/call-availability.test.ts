import type { PrismaClient } from "@rakazo/db";
import { afterEach, describe, expect, it, vi } from "vitest";
import { canReceiveBotCall } from "./call-availability.js";

describe("canReceiveBotCall", () => {
  afterEach(() => vi.unstubAllEnvs());

  it.each([
    { flag: "true", bridge: undefined, available: true },
    { flag: undefined, bridge: "fixture-bridge-secret-for-bot-calls", available: true },
    { flag: "false", bridge: "fixture-bridge-secret-for-bot-calls", available: false },
    { flag: undefined, bridge: " ", available: false },
  ])("checks peripheral delivery when the flag is $flag", async ({ flag, bridge, available }) => {
    vi.stubEnv("PERIPHERAL_CALLS_ENABLED", flag);
    vi.stubEnv("PERIPHERAL_BRIDGE_SECRET", bridge);
    const findFirst = vi.fn().mockResolvedValue(null);
    const prisma = { userVoiceCredential: { findFirst } } as unknown as Pick<
      PrismaClient,
      "userVoiceCredential"
    >;

    await expect(canReceiveBotCall(prisma, "user-1")).resolves.toBe(available);
    expect(findFirst).toHaveBeenCalledTimes(available ? 0 : 1);
  });
});
