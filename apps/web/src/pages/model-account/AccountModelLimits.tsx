import { Trans, useLingui } from "@lingui/react/macro";
import type { ModelCredential } from "@rakazo/contracts";
import { DEFAULT_MODEL_CONTEXT_WINDOW, DEFAULT_MODEL_MAX_TOKENS } from "@rakazo/contracts";
import {
  connectionModels,
  createModelAccountClient,
  credentialModelSettings,
  parseAccountModelLimits,
} from "@rakazo/core";
import {
  Button,
  Checkbox,
  Field,
  FieldLabel,
  ModelSettingsFields,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@rakazo/ui-web";
import { useMutation } from "@tanstack/react-query";
import { useId, useState } from "react";

export function AccountModelLimits({
  credential,
  refresh,
}: {
  credential: ModelCredential;
  refresh: () => Promise<void>;
}) {
  const { t } = useLingui();
  const reasoningId = useId();
  const models = connectionModels(credential, []);
  const [draft, setDraft] = useState<{
    id: string;
    context: string;
    output: string;
    reasoning: boolean;
    initialReasoning: boolean;
  }>();
  const limits =
    draft &&
    parseAccountModelLimits(
      draft.context,
      draft.output,
      draft.reasoning === draft.initialReasoning ? undefined : draft.reasoning,
    );
  const save = useMutation({
    mutationFn: async (reset: boolean) => {
      if (draft && (reset || limits))
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
          save.reset();
          setDraft({
            id: model.id,
            context: settings.contextWindow?.toString() ?? "",
            output: settings.maxTokens?.toString() ?? "",
            reasoning: settings.reasoning ?? false,
            initialReasoning: settings.reasoning ?? false,
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
          />
          <Field orientation="horizontal" className="mt-3">
            <FieldLabel htmlFor={reasoningId}>{t`Supports thinking`}</FieldLabel>
            <Checkbox
              id={reasoningId}
              checked={draft.reasoning}
              onCheckedChange={(reasoning) => setDraft({ ...draft, reasoning: reasoning === true })}
              disabled={save.isPending}
            />
          </Field>
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
            selected.settings?.reasoning !== undefined ? (
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
