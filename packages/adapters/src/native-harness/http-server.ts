import { randomUUID, timingSafeEqual } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import path from "node:path";
import type { NativeExecutionProvider } from "@rakazo/adapter-kit";
import {
  executionAttachSchema,
  executionControlSchema,
  executionResponseSchema,
  executionStartSchema,
  executionSteerSchema,
  executionStopSchema,
  executionToolResultSchema,
} from "./wire.js";

const MAX_BODY_BYTES = 2 * 1024 * 1024;

/** Reverse-proxy with TLS when connecting from another machine. No browser origins or cookies. */
export async function startNativeExecutionServer(options: {
  root: string;
  token: string;
  provider: NativeExecutionProvider;
  profiles: Array<{
    id: string;
    revision: number;
    spaceId: string;
    userIds: string[];
    computerId: string;
    label: string;
    engineVersion: string;
    defaultModel?: string;
    models?: Array<{ id: string; label: string }>;
    status: "missing" | "unsupported" | "unauthenticated" | "unverified" | "ready";
  }>;
  port?: number;
  hostname?: string;
}) {
  if (!/^[a-f0-9]{64}$/.test(options.token))
    throw new Error("Invalid execution service credential");
  const identityFile = path.join(options.root, "identity");
  if (!existsSync(identityFile))
    writeFileSync(identityFile, randomUUID(), { mode: 0o600, flag: "wx" });
  const identity = readFileSync(identityFile, "utf8").trim();
  const secret = Buffer.from(`Bearer ${options.token}`);
  const server = createServer(async (request, response) => {
    const credential = Buffer.from(request.headers.authorization ?? "");
    response.setHeader("cache-control", "no-store");
    if (
      request.headers.origin ||
      credential.length !== secret.length ||
      !timingSafeEqual(credential, secret)
    ) {
      response.writeHead(401).end();
      return;
    }
    if (request.method === "GET" && request.url === "/describe") {
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify({ id: identity, profiles: options.profiles }));
      return;
    }
    // Losing the private journal produces a new service identity. Old dispatches cannot run there.
    if (request.headers["x-execution-service-id"] !== identity) {
      response.writeHead(409).end();
      return;
    }
    if (request.method !== "POST") {
      response.writeHead(404).end();
      return;
    }
    try {
      const chunks: Buffer[] = [];
      let size = 0;
      for await (const chunk of request) {
        size += chunk.length;
        if (size > MAX_BODY_BYTES) {
          response.writeHead(413).end();
          return;
        }
        chunks.push(chunk);
      }
      const input: unknown = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      let result: unknown;
      switch (request.url) {
        case "/stop":
          if (!options.provider.stop) throw new Error("Unsupported stop");
          await options.provider.stop(executionStopSchema.parse(input));
          result = { stopped: true };
          break;
        case "/tool-result":
          if (!options.provider.toolResult) throw new Error("Unsupported tool bridge");
          result = await options.provider.toolResult(executionToolResultSchema.parse(input));
          break;
        case "/start":
          result = await options.provider.start(executionStartSchema.parse(input));
          break;
        case "/attach":
          result = await options.provider.attach(executionAttachSchema.parse(input));
          break;
        case "/respond":
          result = await options.provider.respond(executionResponseSchema.parse(input));
          break;
        case "/cancel":
          await options.provider.cancel(executionControlSchema.parse(input));
          result = { stopped: true };
          break;
        case "/steer":
          result = await options.provider.steer(executionSteerSchema.parse(input));
          break;
        default:
          response.writeHead(404).end();
          return;
      }
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify(result));
    } catch {
      // Do not forward CLI errors, submitted arguments or schema diagnostics across the control channel.
      response.writeHead(409).end(JSON.stringify({ error: "Execution request rejected" }));
    }
  });
  server.requestTimeout = 15_000;
  server.headersTimeout = 10_000;
  server.maxHeadersCount = 16;
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(options.port ?? 0, options.hostname ?? "127.0.0.1", () => {
      server.removeListener("error", reject);
      resolve();
    });
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("Execution service unavailable");
  return {
    identity,
    port: address.port,
    async close() {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}
