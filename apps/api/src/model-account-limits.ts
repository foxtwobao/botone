import type { StoredModelSecret } from "@rakazo/adapters";
import type { ModelAccountLimits, ModelSettings } from "@rakazo/contracts";
import { MAX_MODEL_SETTINGS_PER_CONNECTION } from "@rakazo/contracts";

export function applyModelAccountLimits(
  secret: Extract<StoredModelSecret, { kind: "openai_compatible" }>,
  modelId: string,
  { reasoning, ...limits }: ModelAccountLimits,
) {
  if (!secret.enabledModelIds?.includes(modelId)) return null;
  const models = new Map(Object.entries(secret.models ?? {}));
  const previous = models.get(modelId);
  const editing =
    limits.contextWindow !== undefined ||
    limits.maxTokens !== undefined ||
    typeof reasoning === "boolean";
  const catalogReasoning = secret.defaultReasoningModelIds?.includes(modelId);
  const inherited: ModelSettings = editing
    ? {
        ...(!catalogReasoning && secret.reasoning !== undefined && { reasoning: secret.reasoning }),
        ...(secret.visionModelIds?.includes(modelId) && { images: true }),
        ...(secret.maxImagesPerPrompt !== undefined && {
          maxImagesPerPrompt: secret.maxImagesPerPrompt,
        }),
      }
    : {};
  const { contextWindow: _context, maxTokens: _output, ...other } = previous ?? inherited;
  const settings = { ...other, ...limits };
  if (reasoning === null) {
    delete settings.reasoning;
    if (Object.keys(settings).length && secret.reasoning && !catalogReasoning)
      settings.reasoning = true;
  } else if (reasoning !== undefined) settings.reasoning = reasoning;
  if (Object.keys(settings).length) {
    if (!previous && models.size >= MAX_MODEL_SETTINGS_PER_CONNECTION) return null;
    models.set(modelId, settings);
  } else models.delete(modelId);
  return { ...secret, models: Object.fromEntries(models) };
}
