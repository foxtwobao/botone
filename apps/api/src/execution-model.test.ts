import type { Actor } from "@rakazo/contracts";
import { describe, expect, it, vi } from "vitest";
import { botsCanRunWithoutDefaultModel } from "./execution-model.js";
import type { RouterDeps } from "./router.js";

const actor = { spaceId: "space", userId: "owner" } as Actor;

function fixture(nativeIds: string[]) {
  const findNative = vi.fn(async (_input: unknown) => nativeIds.map((id) => ({ id })));
  const findBots = vi.fn(async ({ where }: { where: { id: { in: string[] } } }) =>
    where.id.in.map(() => ({ modelProvider: null, modelId: null, thinkingLevel: null })),
  );
  const deps = {
    prisma: {
      bot: {
        findMany: (input: Parameters<typeof findBots>[0]) =>
          "executionConfiguration" in input.where ? findNative(input) : findBots(input),
      },
    },
  } as unknown as RouterDeps;
  return { deps, findNative, findBots };
}

describe("execution model preflight", () => {
  it("allows native-only sends without built-in model credentials and scopes the connection lookup", async () => {
    const { deps, findNative } = fixture(["native"]);
    expect(await botsCanRunWithoutDefaultModel(deps, actor, ["native"])).toBe(true);
    expect(findNative).toHaveBeenCalledWith({
      where: {
        id: { in: ["native"] },
        spaceId: actor.spaceId,
        executionConfiguration: {
          spaceId: actor.spaceId,
          userId: actor.userId,
          connection: { revokedAt: null },
        },
      },
      select: { id: true },
    });
  });

  it("still requires credentials for built-in bots in a mixed group", async () => {
    const { deps, findBots } = fixture(["native"]);
    expect(await botsCanRunWithoutDefaultModel(deps, actor, ["native", "built-in"])).toBe(false);
    expect(findBots).toHaveBeenCalledWith(
      expect.objectContaining({ where: { id: { in: ["built-in"] }, spaceId: actor.spaceId } }),
    );
  });

  it("does not exempt a bot whose native connection lookup returned no usable configuration", async () => {
    const { deps } = fixture([]);
    expect(await botsCanRunWithoutDefaultModel(deps, actor, ["unavailable"])).toBe(false);
  });
});
