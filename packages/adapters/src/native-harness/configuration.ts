import { readFile, stat } from "node:fs/promises";
import { ExecutionModelsSchema } from "@rakazo/contracts";
import { z } from "zod";
import { executionOwnerSchema } from "./managed-configuration.js";

export const engineVersions = {
  codex: "0.167.0",
  claude: "2.1.286",
  deepseek: "0.2.1-rc.2",
} as const;
export const daemonConfigurationSchema = z
  .object({
    root: z.string().min(1),
    token: z.string().regex(/^[a-f0-9]{64}$/),
    hostname: z.literal("127.0.0.1").default("127.0.0.1"),
    port: z.number().int().min(1024).max(65535),
    managed: z
      .object({
        apiUrl: z
          .string()
          .url()
          .refine((value) => {
            const url = new URL(value);
            return (
              !url.username &&
              !url.password &&
              !url.search &&
              !url.hash &&
              url.pathname === "/" &&
              (url.protocol === "https:" ||
                (url.protocol === "http:" && url.hostname === "127.0.0.1"))
            );
          }),
        runtimeRevision: z.string().regex(/^[a-f0-9]{40}$/),
        verification: executionOwnerSchema.optional(),
      })
      .strict()
      .optional(),
    profiles: z
      .array(
        z
          .object({
            id: z.string().regex(/^[a-z0-9][a-z0-9-]{0,63}$/),
            revision: z.number().int().positive(),
            label: z.string().min(1).max(100),
            models: ExecutionModelsSchema.optional(),
            spaceId: z.string().min(1),
            userIds: z.array(z.string().min(1)).min(1),
            computerId: z.string().min(1),
            engine: z.enum(["codex", "claude", "deepseek"]),
            availability: z.literal("stopped").optional(),
            defaultModel: z.string().min(1).max(256).optional(),
            initialization: z
              .object({ url: z.string().url(), token: z.string().min(1) })
              .strict()
              .optional(),
            computer: z
              .object({
                homeKey: z.string().min(1),
                workspace: z.string().startsWith("/"),
              })
              .strict(),
            modelConnection: z
              .object({
                url: z.string().url(),
                apiKey: z.string().min(1),
                model: z.string().min(1),
              })
              .strict()
              .optional(),
          })
          .strict(),
      )
      .max(1000)
      .default([]),
  })
  .strict()
  .refine(
    (value) => !value.managed || value.profiles.length === 0,
    "Managed discovery replaces static profiles",
  );

export async function readDaemonConfiguration(configurationFile: string) {
  const info = await stat(configurationFile);
  if ((info.mode & 0o077) !== 0 || ![0, process.getuid?.()].includes(info.uid))
    throw new Error("unsafe_execution_configuration");
  return daemonConfigurationSchema.parse(JSON.parse(await readFile(configurationFile, "utf8")));
}
