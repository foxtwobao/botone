import { createHmac, timingSafeEqual } from "node:crypto";
import { z } from "zod";

const grantSchema = z
  .object({
    userId: z.string().min(1).max(256),
    spaceId: z.string().min(1).max(256),
    homeKey: z.string().min(1).max(256),
    credentialId: z.string().min(1).max(256),
    credentialCreatedAt: z.iso.datetime(),
  })
  .strict();
type Grant = z.infer<typeof grantSchema>;
const signature = (key: string, body: string) =>
  createHmac("sha256", key).update(`computer-model-initialization:v1:${body}`).digest();

/** A computer can read only its owner's already-authorized model connection. */
export function computerInitializationGrant(key: string, grant: Grant) {
  const body = Buffer.from(JSON.stringify(grantSchema.parse(grant))).toString("base64url");
  return `${body}.${signature(key, body).toString("base64url")}`;
}

export function readComputerInitializationGrant(key: string, token: string): Grant | null {
  try {
    if (token.length > 4096) return null;
    const [body, mac, extra] = token.split(".");
    if (!body || !mac || extra) return null;
    const actual = Buffer.from(mac, "base64url");
    const expected = signature(key, body);
    if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) return null;
    return grantSchema.parse(JSON.parse(Buffer.from(body, "base64url").toString()));
  } catch {
    return null;
  }
}
