import type { SandboxProvider } from "@rakazo/adapter-kit";
import type { PrismaClient } from "@rakazo/db";
import { getLogger } from "@rakazo/logging";
import { computerInitializationGrant } from "./initialization-auth.js";
import { computerInitializationProgram } from "./initialization-program.js";

export interface ComputerInitializationConnection {
  url: string;
  signingKey: string;
}

/** Wrap only the provider preparation boundary; all unrelated provider methods keep their receiver. */
export function withComputerModelInitialization(
  sandbox: SandboxProvider,
  prisma: PrismaClient,
  connection: ComputerInitializationConnection,
): SandboxProvider {
  const url = new URL("/api/model-account/computer", connection.url);
  if (
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    !(
      url.protocol === "https:" ||
      (url.protocol === "http:" && ["127.0.0.1", "localhost"].includes(url.hostname))
    )
  )
    throw new Error("invalid_initialization_endpoint");
  return new Proxy(sandbox, {
    get(target, property) {
      if (property !== "prepare") {
        const value = Reflect.get(target, property);
        return typeof value === "function" ? value.bind(target) : value;
      }
      return async (...args: Parameters<SandboxProvider["prepare"]>) => {
        const [computer, context] = args;
        await target.prepare(...args);
        if (computer.kind !== "docker") return;
        const owned = await prisma.computer.findFirst({
          where: {
            homeKey: computer.botId,
            spaceId: context.spaceId,
            userId: context.userId,
            scope: "dedicated",
          },
        });
        if (!owned) return;
        const credential = await prisma.userModelCredential.findFirst({
          where: {
            userId: context.userId,
            id: { startsWith: "external-" },
          },
          select: { id: true, createdAt: true },
          orderBy: { updatedAt: "desc" },
        });
        if (!credential) return;
        const token = computerInitializationGrant(connection.signingKey, {
          userId: context.userId,
          spaceId: context.spaceId,
          homeKey: owned.homeKey,
          credentialId: credential.id,
          credentialCreatedAt: credential.createdAt.toISOString(),
        });
        let code: number | undefined;
        for await (const event of target.execute(
          computer,
          {
            argv: [
              "/usr/local/bin/node",
              "--input-type=module",
              "--eval",
              computerInitializationProgram,
            ],
            env: {
              COMPUTER_MODEL_INITIALIZATION: JSON.stringify({ url: url.href, token }),
              COMPUTER_MODEL_PROGRAM: computerInitializationProgram,
            },
            timeoutMs: 30_000,
          },
          context,
        )) {
          if (event.type === "exit") code = event.code;
        }
        if (code !== 0) getLogger().warn("computer.model_initialization_failed");
      };
    },
  });
}
