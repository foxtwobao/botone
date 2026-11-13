import { Trans, useLingui } from "@lingui/react/macro";
import type { DesktopHostSelection } from "@rakazo/contracts";
import { Button, NativeSelect, NativeSelectOption } from "@rakazo/ui-web";
import { useId } from "react";

export function HostExecutionTarget({
  selection,
  busy,
  onChange,
}: {
  selection: DesktopHostSelection;
  busy: boolean;
  onChange(target: "workspace" | "computer"): Promise<void>;
}) {
  const id = useId();
  const { t } = useLingui();
  return (
    <div className="space-y-2">
      <label className="text-label font-medium text-muted-foreground" htmlFor={id}>
        <Trans>Work on</Trans>
      </label>
      <NativeSelect
        id={id}
        className="w-full"
        value={selection.target}
        disabled={busy}
        onChange={(event) =>
          void onChange(event.target.value === "computer" ? "computer" : "workspace")
        }
      >
        <NativeSelectOption value="workspace">
          <Trans>Local workspace</Trans>
        </NativeSelectOption>
        <NativeSelectOption value="computer">
          <Trans>Computer</Trans>
        </NativeSelectOption>
      </NativeSelect>
      {selection.target === "workspace" ? (
        <Button
          variant="outline"
          size="sm"
          disabled={busy}
          title={selection.workspace}
          aria-label={t`Change workspace`}
          onClick={() => void onChange("workspace")}
        >
          {selection.workspace.split(/[\\/]/).filter(Boolean).at(-1) || t`Choose workspace`}
        </Button>
      ) : null}
    </div>
  );
}
