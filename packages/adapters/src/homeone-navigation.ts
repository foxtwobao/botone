import { accountNavigationSchema } from "@rakazo/contracts";
import { readBoundedJsonResponse } from "@rakazo/core";
import { z } from "zod";

/** Public policy from the same source that supplies the portal's navigation module. */
export async function readHomeNavigation(origin: string, transport: typeof fetch = fetch) {
  const signal = AbortSignal.timeout(2_000);
  const response = await transport(new URL("/auth.json", origin), { redirect: "error", signal });
  if (!response.ok) throw new Error("Navigation unavailable");
  const body = z
    .object({
      navigationPolicy: z.object({
        defaults: z.object({
          v: z.literal(1),
          channel: z.literal(""),
          homeUrl: z.string(),
          rechargeUrl: z.string(),
        }),
        channels: z
          .array(z.object({ channel: z.string(), homeUrl: z.string(), rechargeUrl: z.string() }))
          .max(100)
          .optional(),
        productHosts: z.array(z.string()).max(100),
      }),
    })
    .parse(await readBoundedJsonResponse(response, 64 * 1024, signal));
  return accountNavigationSchema.parse({ cookieName: "one_nav", ...body.navigationPolicy });
}
