import { createModelAccountClient } from "@rakazo/core";

const client = createModelAccountClient();
export const modelAccountConfigQuery = {
  queryKey: ["model-account-config"],
  queryFn: () => client.config(),
};
export const modelAccountStatusQuery = (userId: string | undefined) => ({
  queryKey: ["model-account-status", userId],
  queryFn: ({ signal }: { signal: AbortSignal }) => client.status(signal),
  enabled: Boolean(userId),
});
