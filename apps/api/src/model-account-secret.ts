import type { StoredModelSecret } from "@rakazo/adapters";
import { parseModelSecret, serializeModelSecret } from "@rakazo/adapters";

type Binding = { accountId: string; binding: string };

function accountBinding(value: unknown): Binding | null {
  if (
    !value ||
    typeof value !== "object" ||
    !("accountId" in value) ||
    typeof value.accountId !== "string" ||
    !value.accountId ||
    !("binding" in value) ||
    typeof value.binding !== "string" ||
    !value.binding
  )
    return null;
  return { accountId: value.accountId, binding: value.binding };
}

/** Binding metadata is used only by account management. Model execution reads an ordinary key. */
export function parseModelAccountSecret(plaintext: string) {
  const secret = parseModelSecret(plaintext);
  return {
    secret,
    binding: accountBinding(
      secret.kind === "openai_compatible" ? JSON.parse(plaintext).externalAccount : undefined,
    ),
  };
}

export function serializeModelAccountSecret(
  secret: Extract<StoredModelSecret, { kind: "openai_compatible" }>,
  binding: Binding,
): string {
  return JSON.stringify({
    ...JSON.parse(serializeModelSecret(secret)),
    externalAccount: { accountId: binding.accountId, binding: binding.binding },
  });
}
