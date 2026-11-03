import { MAX_ENABLED_MODEL_IDS } from "@rakazo/contracts";
import { readBoundedJsonResponse } from "@rakazo/core";
import { z } from "zod";

/** The endpoint is pinned by deployment configuration; never accept a client URL here. */
export async function discoverModelAccountModels(
  baseUrl: string,
  apiKey: string,
  transport: typeof fetch = fetch,
) {
  const signal = AbortSignal.timeout(5_000);
  const response = await transport(`${baseUrl.replace(/\/+$/, "")}/models`, {
    headers: { authorization: `Bearer ${apiKey}` },
    redirect: "error",
    signal,
  });
  if (!response.ok) throw new Error("Model catalog unavailable");
  const result = z
    .object({
      data: z.array(z.object({ id: z.string().trim().min(1).max(256) })).max(MAX_ENABLED_MODEL_IDS),
    })
    .parse(await readBoundedJsonResponse(response, 2 * 1024 * 1024, signal));
  return [...new Set(result.data.map((model) => model.id))];
}
