import type { StoredModelSecret } from "@rakazo/adapters";
import type { ModelAccountLimits, ModelSettings } from "@rakazo/contracts";
import { MAX_MODEL_SETTINGS_PER_CONNECTION } from "@rakazo/contracts";
import { accountModelThinkingLevel } from "@rakazo/core";

export function applyModelAccountLimits(
  secret: Extract<StoredModelSecret, { kind: "openai_compatible" }>,
  modelId: string,
  { reasoning, thinkingLevel: requested, ...limits }: ModelAccountLimits,
) {
  if (!secret.enabledModelIds?.includes(modelId)) return null;
  const models = new Map(Object.entries(secret.models ?? {}));
  const previous = models.get(modelId);
  const thinkingLevel = accountModelThinkingLevel({ reasoning, thinkingLevel: requested });
  const editing =
    limits.contextWindow !== undefined ||
    limits.maxTokens !== undefined ||
    (thinkingLevel !== undefined && thinkingLevel !== null);
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
  if (thinkingLevel === null) {
    delete settings.reasoning;
    delete settings.thinkingLevel;
    if (Object.keys(settings).length && secret.reasoning && !catalogReasoning)
      settings.reasoning = true;
  } else if (thinkingLevel !== undefined) {
    // "off" is only the capability switched off, as the model settings form saves it.
    settings.reasoning = thinkingLevel !== "off";
    if (thinkingLevel === "off") delete settings.thinkingLevel;
    else settings.thinkingLevel = thinkingLevel;
  }
  if (Object.keys(settings).length) {
    if (!previous && models.size >= MAX_MODEL_SETTINGS_PER_CONNECTION) return null;
    models.set(modelId, settings);
  } else models.delete(modelId);
  return { ...secret, models: Object.fromEntries(models) };
}
