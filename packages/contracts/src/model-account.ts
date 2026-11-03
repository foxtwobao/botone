import { z } from "zod";

const link = z.url().refine((value) => {
  const url = new URL(value);
  return url.protocol === "https:" && !url.username && !url.password;
});
export const accountNavigationSchema = z.object({
  cookieName: z.string(),
  defaults: z.object({ homeUrl: link, rechargeUrl: link }),
  channels: z
    .array(z.object({ channel: z.string(), homeUrl: link, rechargeUrl: link }))
    .default([]),
  productHosts: z.array(z.string()).default([]),
});
export const modelAccountConfigSchema = z.discriminatedUnion("enabled", [
  z.object({ enabled: z.literal(false) }),
  z.object({
    enabled: z.literal(true),
    navigation: accountNavigationSchema.optional(),
  }),
]);
export const modelAccountStatusSchema = z.object({
  enabled: z.boolean(),
  connected: z.boolean(),
  linked: z.boolean().optional(),
  apiProtocol: z.enum(["chat-completions", "responses"]).optional(),
  recovery: z
    .enum([
      "authorization_required",
      "authorization_pending",
      "authorization_unknown",
      "revocation_unknown",
    ])
    .optional(),
});
export const modelAccountBalanceSchema = z.object({
  amount: z.string().regex(/^-?\d+\.\d{2}$/),
  unit: z.enum(["USD", "CNY", "QUOTA"]),
});
export const modelAccountConnectSchema = z.object({ connected: z.boolean(), url: link.optional() });
export type ModelAccountConfig = z.infer<typeof modelAccountConfigSchema>;
export type ModelAccountStatus = z.infer<typeof modelAccountStatusSchema>;

export const modelAccountErrorCodeSchema = z.enum([
  "link_required",
  "authorization_required",
  "result_unknown",
  "login_required",
  "forbidden",
  "disabled",
  "unavailable",
]);
export type ModelAccountErrorCode = z.infer<typeof modelAccountErrorCodeSchema>;

export const modelAccountSettingsSchema = z
  .object({ apiProtocol: z.enum(["chat-completions", "responses"]) })
  .strict();
