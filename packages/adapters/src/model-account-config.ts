import { createHash } from "node:crypto";
import { z } from "zod";
import { parseModelSecret } from "./pi-oauth.js";
import { ResellerModelAccountProvider } from "./reseller-model-account.js";

const origin = z.url().refine((value) => {
  const url = new URL(value);
  return (
    url.protocol === "https:" &&
    !url.username &&
    !url.password &&
    !url.search &&
    !url.hash &&
    url.pathname === "/"
  );
});
const link = z.url().refine((value) => {
  const url = new URL(value);
  return url.protocol === "https:" && !url.username && !url.password;
});
const schema = z.object({
  provider: z.literal("reseller"),
  origin,
  credential: z.string().min(1),
  authorizationOrigins: z.array(origin).min(1),
  homeUrl: link,
  rechargeUrl: link,
  modelId: z.string().trim().min(1),
  model: z.record(z.string(), z.unknown()),
});

export function configuredModelAccount(value: string | undefined) {
  if (!value?.trim()) return undefined;
  try {
    const config = schema.parse(JSON.parse(value));
    const model = parseModelSecret(JSON.stringify(config.model));
    if (
      model.kind !== "openai_compatible" ||
      model.apiKey ||
      model.externalAccount ||
      model.headers
    )
      throw new Error();
    const url = new URL(model.baseUrl);
    if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash)
      throw new Error();
    model.enabledModelIds = [...new Set([config.modelId, ...(model.enabledModelIds ?? [])])];
    return {
      provider: new ResellerModelAccountProvider(config),
      credentialVersion: createHash("sha256").update(config.credential).digest("hex"),
      model,
      modelId: config.modelId,
      homeUrl: config.homeUrl,
      rechargeUrl: config.rechargeUrl,
    };
  } catch {
    throw new Error("Invalid MODEL_ACCOUNT_CONNECTION configuration");
  }
}
