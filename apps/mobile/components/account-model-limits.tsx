import type { ModelCredential } from "@rakazo/contracts";
import {
  DEFAULT_MODEL_CONTEXT_WINDOW,
  DEFAULT_MODEL_MAX_TOKENS,
  MAX_MODEL_CONTEXT_WINDOW,
  MAX_MODEL_MAX_TOKENS,
} from "@rakazo/contracts";
import { connectionModels, credentialModelSettings, parseAccountModelLimits } from "@rakazo/core";
import { useMutation } from "@tanstack/react-query";
import { useState } from "react";
import { modelAccountClient } from "../lib/model-account-client";
import { useI18n } from "../lib/model-account-i18n";
import { queryClient } from "../lib/query/query";
import { LimitField } from "./models/model-connection-fields";
import { NativeActionButton } from "./native/native-action-button";
import { SettingsGroup, SettingsSwitch } from "./settings/settings-group";
import { MenuPicker } from "./ui/menu-picker";

export function AccountModelLimits({
  credential,
  refresh,
}: {
  credential: ModelCredential;
  refresh: () => Promise<void>;
}) {
  const { t } = useI18n();
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
  const save = useMutation(
    {
      mutationFn: async (reset: boolean) => {
        if (draft && (reset || limits))
          await modelAccountClient().saveLimits(
            credential.id,
            draft.id,
            limits && !reset ? limits : { reasoning: null },
          );
      },
      onSuccess: async () => {
        setDraft(undefined);
        await refresh();
      },
    },
    queryClient,
  );
  if (!models.length) return null;
  const selected = models.find((model) => model.id === draft?.id);
  return (
    <SettingsGroup
      footer={
        draft && !limits
          ? t("Enter positive whole numbers. Output must be below the context limit.")
          : save.isError
            ? t("Could not save model settings")
            : undefined
      }
    >
      <MenuPicker
        label={t("Model options")}
        placeholder={t("Choose a model")}
        choices={models.map(({ id }) => ({ key: id, label: id }))}
        value={selected?.id ?? ""}
        disabled={save.isPending}
        onChange={(id) => {
          const model = models.find((item) => item.id === id);
          if (!model) return;
          const settings = credentialModelSettings(credential, model.id);
          save.reset();
          setDraft({
            id,
            context: settings.contextWindow?.toString() ?? "",
            output: settings.maxTokens?.toString() ?? "",
            reasoning: settings.reasoning ?? false,
            initialReasoning: settings.reasoning ?? false,
          });
        }}
      />
      {selected && draft ? (
        <>
          <LimitField
            label={t("Context limit")}
            placeholder={String(DEFAULT_MODEL_CONTEXT_WINDOW)}
            value={draft.context}
            onChangeText={(context) => setDraft({ ...draft, context })}
            busy={save.isPending}
            maxLength={String(MAX_MODEL_CONTEXT_WINDOW).length}
          />
          <LimitField
            label={t("Maximum output tokens")}
            placeholder={String(DEFAULT_MODEL_MAX_TOKENS)}
            value={draft.output}
            onChangeText={(output) => setDraft({ ...draft, output })}
            busy={save.isPending}
            maxLength={String(MAX_MODEL_MAX_TOKENS).length}
          />
          <SettingsSwitch
            label={t("Supports thinking")}
            value={draft.reasoning}
            disabled={save.isPending}
            onChange={(reasoning) => setDraft({ ...draft, reasoning })}
          />
          <NativeActionButton
            label={t("Save")}
            disabled={!limits}
            busy={save.isPending}
            onPress={() => save.mutate(false)}
          />
          {selected.settings?.contextWindow ||
          selected.settings?.maxTokens ||
          selected.settings?.reasoning !== undefined ? (
            <NativeActionButton
              label={t("Restore defaults")}
              prominence="quiet"
              disabled={save.isPending}
              onPress={() => save.mutate(true)}
            />
          ) : null}
        </>
      ) : null}
    </SettingsGroup>
  );
}
