import type { SecretStore } from "@rakazo/adapter-kit";
import type { ExecutionConnection } from "@rakazo/db";
import { HttpNativeExecutionProvider } from "./http-client.js";

export async function executionConnectionClient(
  secrets: SecretStore,
  connection: Pick<ExecutionConnection, "id" | "identity" | "secretRef" | "revokedAt">,
) {
  if (connection.revokedAt) throw new Error("execution_connection_revoked");
  const saved = JSON.parse(await secrets.load(connection.secretRef, connection.id)) as {
    url: string;
    token: string;
    allowPrivateEndpoint?: boolean;
  };
  return new HttpNativeExecutionProvider({ ...saved, identity: connection.identity });
}
