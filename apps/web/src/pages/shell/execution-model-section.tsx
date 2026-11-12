import type { ComponentProps } from "react";
import { ExecutionSettings } from "../../components/ExecutionSettings";
import { ModelSection } from "./bot-settings-sections";

export function ExecutionModelSection({
  botId,
  ...props
}: ComponentProps<typeof ModelSection> & { botId: string }) {
  return (
    <ExecutionSettings botId={botId}>
      {(model) => (
        <ModelSection
          {...props}
          {...(model
            ? {
                choices: model.choices,
                value: model.value,
                onModelChange: model.onChange,
                thinkingOptions: [],
                onOpenConnections: undefined,
              }
            : {})}
        />
      )}
    </ExecutionSettings>
  );
}
