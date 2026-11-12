import { createHash } from "node:crypto";

export const verificationChecks = ["file", "permission", "resume", "cancel", "isolation"] as const;
export function verificationBinding(profile: object) {
  // Discovery labels do not change credentials, grants, launch arguments or isolation.
  const { models: _models, ...execution } = profile as { models?: unknown };
  return createHash("sha256").update(JSON.stringify(execution)).digest("hex");
}
