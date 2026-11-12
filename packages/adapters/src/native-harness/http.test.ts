import { createServer } from "node:http";
import { startRequest } from "@rakazo/native-runtime/testing";
import { expect, it } from "vitest";
import { HttpNativeExecutionProvider } from "./http-client.js";

it("uses the existing provider path, credentials and scope, and binds the discovered service identity", async () => {
  const identity = "00000000-0000-4000-8000-000000000001";
  const calls: string[] = [];
  const server = createServer(async (req, res) => {
    calls.push(req.url!);
    expect(req.headers.authorization).toBe("Bearer fixture-provider-token");
    expect(req.headers["x-rakazo-space-id"]).toBe("fixture-space");
    if (req.url?.endsWith("/describe")) res.end(JSON.stringify({ id: identity, profiles: [] }));
    else {
      expect(req.headers["x-execution-service-id"]).toBe(identity);
      res.end(
        JSON.stringify({
          generation: identity,
          state: "running",
          capabilities: {
            images: false,
            resume: true,
            steer: false,
            permissions: true,
            questions: true,
            tools: false,
          },
          frames: [],
          nextSequence: 0,
        }),
      );
    }
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("test_server");
    const client = new HttpNativeExecutionProvider({
      url: `http://127.0.0.1:${address.port}`,
      token: "fixture-provider-token",
      path: "/computers/container/execution",
      headers: { "x-rakazo-space-id": "fixture-space" },
    });
    expect((await client.describe()).id).toBe(identity);
    expect((await client.start(startRequest())).state).toBe("running");
    expect(calls).toEqual([
      "/computers/container/execution/describe",
      "/computers/container/execution/start",
    ]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

it("rejects redirects, oversized responses and cancellation on the trusted provider route", async () => {
  let mode: "redirect" | "large" = "redirect";
  const calls: string[] = [];
  const server = createServer((req, res) => {
    calls.push(req.url!);
    if (mode === "redirect") res.writeHead(302, { location: "/unexpected" }).end();
    else res.end("x".repeat(5 * 1024 * 1024 + 1));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("test_server");
    const client = new HttpNativeExecutionProvider({
      url: `http://127.0.0.1:${address.port}`,
      token: "fixture-provider-token",
      path: "/computers/container/execution",
    });
    await expect(client.describe()).rejects.toThrow();
    expect(calls).toEqual(["/computers/container/execution/describe"]);
    mode = "large";
    await expect(client.describe()).rejects.toThrow("Response is too large");
    const abort = new AbortController();
    abort.abort(new Error("fixture-cancelled"));
    await expect(client.describe(abort.signal)).rejects.toThrow("fixture-cancelled");
    expect(calls).toHaveLength(2);
  } finally {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});
