import { expect, it } from "vitest";
import { nativeLaunchArguments } from "./launch-arguments.js";
import { startRequest } from "./protocol.test-support.js";

it("preserves desktop account settings unless a model connection was explicitly granted", () => {
  const profile = {
    engine: "codex" as const,
    computer: { homeKey: "home", workspace: "/home/user/shared" },
  };
  const args = nativeLaunchArguments(profile, startRequest());
  expect(args.at(-1)).toBe("app-server");
  expect(args.join(" ")).not.toContain("model_provider=");
  const granted = nativeLaunchArguments(
    {
      ...profile,
      modelConnection: {
        url: "https://model.example.test/v1",
        apiKey: "fake-private-key",
        model: "test-model",
      },
    },
    startRequest(),
  );
  expect(granted.join(" ")).toContain('model_provider="granted"');
  expect(granted.join(" ")).not.toContain("fake-private-key");
});
