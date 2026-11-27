import { Trans, useLingui } from "@lingui/react/macro";
import type { ModelCredential, ThinkingLevel } from "@rakazo/contracts";
import { DEFAULT_MODEL_CONTEXT_WINDOW, DEFAULT_MODEL_MAX_TOKENS } from "@rakazo/contracts";
import {
  accountModelThinkingLevel,
  connectionModels,
  createModelAccountClient,
  credentialModelSettings,
  modelSettingsThinkingLevels,
  parseAccountModelLimits,
} from "@rakazo/core";
import { thinkingLevelLabel } from "@rakazo/i18n/thinking-level";
import {
  Button,
  ModelSettingsFields,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@rakazo/ui-web";
import { useMutation } from "@tanstack/react-query";
import { useState } from "react";

export function AccountModelLimits({
  credential,
  refresh,
}: {
  credential: ModelCredential;
  refresh: () => Promise<void>;
}) {
  const { t } = useLingui();
  const models = connectionModels(credential, []);
  const [draft, setDraft] = useState<{
    id: string;
    context: string;
    output: string;
    /** The level the model thinks at when nobody picks one; null follows the connection. */
    thinkingLevel: ThinkingLevel | null;
    initialThinkingLevel: ThinkingLevel | null;
  }>();
  const limits =
    draft &&
    parseAccountModelLimits(
      draft.context,
      draft.output,
      draft.thinkingLevel === draft.initialThinkingLevel ? undefined : draft.thinkingLevel,
    );
  const save = useMutation({
    mutationFn: async (reset: boolean) => {
      if (draft && (reset || limits))
        // Servers that predate the level refuse its key; a null switch clears the level on both.
        await createModelAccountClient().saveLimits(
          credential.id,
          draft.id,
          limits && !reset ? limits : { reasoning: null },
        );
    },
    onSuccess: async () => {
      setDraft(undefined);
      await refresh();
    },
  });
  if (!models.length) return null;
  const selected = models.find((model) => model.id === draft?.id);
  return (
    <div className="grid gap-3">
      <Select
        value={selected?.id ?? null}
        disabled={save.isPending}
        onValueChange={(id) => {
          const model = models.find((item) => item.id === id);
          if (!model) return;
          const settings = credentialModelSettings(credential, model.id);
          const thinkingLevel =
            accountModelThinkingLevel(model.settings, credential, model.id) ?? null;
          save.reset();
          setDraft({
            id: model.id,
            context: settings.contextWindow?.toString() ?? "",
            output: settings.maxTokens?.toString() ?? "",
            thinkingLevel,
            initialThinkingLevel: thinkingLevel,
          });
        }}
      >
        <SelectTrigger aria-label={t`Model options`}>
          <SelectValue placeholder={t`Model options`} />
        </SelectTrigger>
        <SelectContent>
          {models.map(({ id }) => (
            <SelectItem key={id} value={id}>
              {id}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      {selected && draft ? (
        <>
          <ModelSettingsFields
            disabled={save.isPending}
            contextWindow={draft.context}
            contextWindowLabel={t`Context limit`}
            contextWindowPlaceholder={String(DEFAULT_MODEL_CONTEXT_WINDOW)}
            onContextWindowChange={(context) => setDraft({ ...draft, context })}
            maxTokens={draft.output}
            maxTokensLabel={t`Maximum output tokens`}
            maxTokensPlaceholder={String(DEFAULT_MODEL_MAX_TOKENS)}
            onMaxTokensChange={(output) => setDraft({ ...draft, output })}
            capabilities
            thinkingLevel={draft.thinkingLevel ?? "default"}
            thinkingLevels={[
              { value: "default", label: t`Default` },
              ...modelSettingsThinkingLevels(credential, undefined).map((level) => ({
                value: level,
                label: thinkingLevelLabel(level),
              })),
            ]}
            onThinkingLevelChange={(thinkingLevel) =>
              setDraft({
                ...draft,
                thinkingLevel: thinkingLevel === "default" ? null : thinkingLevel,
              })
            }
            thinkingLabel={t`Thinking`}
          />
          {!limits ? (
            <p role="alert">
              <Trans>Enter positive whole numbers. Output must be below the context limit.</Trans>
            </p>
          ) : null}
          {save.isError ? (
            <p role="alert">
              <Trans>Could not save model settings</Trans>
            </p>
          ) : null}
          <div className="flex gap-2">
            <Button disabled={!limits || save.isPending} onClick={() => save.mutate(false)}>
              <Trans>Save</Trans>
            </Button>
            {selected.settings?.contextWindow ||
            selected.settings?.maxTokens ||
            selected.settings?.reasoning !== undefined ||
            selected.settings?.thinkingLevel !== undefined ? (
              <Button variant="ghost" disabled={save.isPending} onClick={() => save.mutate(true)}>
                <Trans>Restore defaults</Trans>
              </Button>
            ) : null}
          </div>
        </>
      ) : null}
    </div>
  );
}
