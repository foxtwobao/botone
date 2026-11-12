import { Trans, useLingui } from "@lingui/react/macro";
import type { BotExecutionConfiguration } from "@rakazo/contracts";
import type { ChatModelChoice } from "@rakazo/core";
import {
  Button,
  Checkbox,
  Dialog,
  DialogContent,
  DialogTitle,
  Input,
  NativeSelect,
  NativeSelectOption,
} from "@rakazo/ui-web";
import { useQuery } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { useId, useState } from "react";
import { useSpaceQueries } from "../lib/query";
import { useSpaceRpc } from "../lib/space-rpc";
import { errorCode, errorText } from "../lib/user-error";
import { ConfirmDialog } from "./ConfirmDialog";

/** Advanced configuration stays beside the model it replaces. Electron shares this screen. */
export function ExecutionSettings({
  botId,
  children,
}: {
  botId: string;
  children: (
    model: {
      choices: readonly ChatModelChoice[];
      value: string;
      onChange: (key: string) => void;
    } | null,
  ) => ReactNode;
}) {
  const { t } = useLingui();
  const ids = useId();
  const rpc = useSpaceRpc();
  const queries = useSpaceQueries();
  const list = useQuery(queries.executions.list.queryOptions({ input: { botId } }));
  const saved = useQuery(queries.executions.get.queryOptions({ input: { botId } }));
  const me = useQuery(queries.me.queryOptions({ input: {} }));
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const [pending, setPending] = useState<{ configuration: BotExecutionConfiguration | null }>();
  const options = (list.data ?? []).flatMap((connection) =>
    connection.profiles
      .filter((profile) => profile.status === "ready")
      .map((profile) => ({
        key: JSON.stringify([connection.id, profile.id, profile.revision]),
        label:
          (list.data ?? [])
            .flatMap((item) => item.profiles)
            .filter((item) => item.status === "ready" && item.label === profile.label).length > 1
            ? `${connection.label} / ${profile.label}`
            : profile.label,
        profile,
        configuration: {
          connectionId: connection.id,
          profileId: profile.id,
          revision: profile.revision,
          model: null,
        },
      })),
  );
  const value = saved.data
    ? JSON.stringify([saved.data.connectionId, saved.data.profileId, saved.data.revision])
    : "";
  const profile = options.find((option) => option.key === value)?.profile;
  const models = new Map((profile?.models ?? []).map((model) => [model.id, model.label]));
  for (const model of [profile?.defaultModel, saved.data?.model]) {
    if (model && !models.has(model)) models.set(model, model);
  }
  async function save(configuration: BotExecutionConfiguration | null, stopActiveRuns = false) {
    if (busy) return;
    setBusy(true);
    setError(undefined);
    try {
      await rpc.executions.configure({ botId, configuration, stopActiveRuns });
      setPending(undefined);
      await saved.refetch();
    } catch (error) {
      if (errorCode(error) === "CONFLICT" && !stopActiveRuns) setPending({ configuration });
      else setError(errorText(error));
    } finally {
      setBusy(false);
    }
  }
  return (
    <>
      {options.length || saved.data || me.data?.isAdmin ? (
        <div className="space-y-2">
          <div className="flex items-center justify-between">
            <label className="text-label font-medium text-muted-foreground" htmlFor={ids}>
              <Trans>Agent</Trans>
            </label>
            {me.data?.isAdmin ? (
              <Button variant="ghost" size="sm" onClick={() => setOpen(true)}>
                <Trans>Connection</Trans>
              </Button>
            ) : null}
          </div>
          <NativeSelect
            className="w-full"
            id={ids}
            value={value}
            disabled={busy}
            onChange={(event) => {
              const option = options.find((option) => option.key === event.target.value);
              if (!event.target.value || option) void save(option?.configuration ?? null);
            }}
          >
            <NativeSelectOption value="">
              <Trans>Built-in</Trans>
            </NativeSelectOption>
            {saved.data && !options.some((o) => o.key === value) ? (
              <NativeSelectOption value={value}>
                <Trans>Unavailable</Trans>
              </NativeSelectOption>
            ) : null}
            {options.map((option) => (
              <NativeSelectOption key={option.key} value={option.key}>
                {option.label}
              </NativeSelectOption>
            ))}
          </NativeSelect>
          {error && !pending ? (
            <p role="alert" className="text-body-sm text-destructive">
              {error}
            </p>
          ) : null}
        </div>
      ) : null}
      <fieldset disabled={busy} className="min-w-0">
        {children(
          saved.data
            ? {
                choices: [
                  {
                    key: "",
                    label: profile?.defaultModel
                      ? `${t`Default`} (${models.get(profile.defaultModel) ?? profile.defaultModel})`
                      : t`Default`,
                  },
                  ...[...models].map(([key, label]) => ({ key, label })),
                ],
                value: saved.data.model ?? "",
                onChange: (model) => void save({ ...saved.data!, model: model || null }),
              }
            : null,
        )}
      </fieldset>
      <ConfirmDialog
        open={pending !== undefined}
        title={t`Stop current tasks?`}
        description={t`Unfinished tasks will stop before the new agent settings are applied.`}
        confirmLabel={t`Stop and switch`}
        variant="default"
        busy={busy}
        error={error}
        onCancel={() => {
          setPending(undefined);
          setError(undefined);
        }}
        onConfirm={() => {
          if (pending) void save(pending.configuration, true);
        }}
      />
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent>
          <DialogTitle>
            <Trans>Connection</Trans>
          </DialogTitle>
          {(list.data ?? []).map((connection) => (
            <div key={connection.id} className="flex items-center justify-between gap-3">
              <div>
                <span>
                  {connection.label}
                  {connection.online ? "" : t` · Offline`}
                </span>
                {connection.profiles.map((profile) => (
                  <p key={profile.id} className="text-body-sm text-muted-foreground">
                    {profile.label} ·{" "}
                    {profile.status === "ready"
                      ? t`Ready`
                      : profile.status === "missing"
                        ? t`Not installed`
                        : profile.status === "unsupported"
                          ? t`Unsupported version`
                          : profile.status === "unauthenticated"
                            ? t`Sign in required`
                            : t`Verification required`}
                  </p>
                ))}
              </div>
              <Button
                variant="ghost"
                size="sm"
                disabled={busy}
                onClick={async () => {
                  setBusy(true);
                  try {
                    await rpc.executions.revoke({ id: connection.id });
                    await list.refetch();
                  } catch (error) {
                    setError(errorText(error));
                  } finally {
                    setBusy(false);
                  }
                }}
              >
                <Trans>Revoke</Trans>
              </Button>
            </div>
          ))}
          <form
            className="space-y-3"
            onSubmit={async (event) => {
              event.preventDefault();
              const fields = new FormData(event.currentTarget);
              setBusy(true);
              setError(undefined);
              try {
                await rpc.executions.connect({
                  botId,
                  label: String(fields.get("label")),
                  url: String(fields.get("url")),
                  token: String(fields.get("token")),
                  privateEndpoint: fields.get("privateEndpoint") === "on",
                });
                await list.refetch();
                setOpen(false);
              } catch (error) {
                setError(errorText(error));
              } finally {
                setBusy(false);
              }
            }}
          >
            <Input
              name="label"
              aria-label={t`Name`}
              placeholder={t`Name`}
              required
              maxLength={100}
            />
            <Input
              name="url"
              type="url"
              aria-label={t`Service address`}
              placeholder="https://execution.example.com"
              required
            />
            <Input
              name="token"
              type="password"
              autoComplete="off"
              aria-label={t`Access token`}
              placeholder={t`Access token`}
              required
            />
            <label htmlFor={`${ids}-private`} className="flex items-center gap-2 text-body-sm">
              <Checkbox id={`${ids}-private`} name="privateEndpoint" />
              <Trans>Private network</Trans>
            </label>
            {error ? (
              <p role="alert" className="text-destructive">
                {error}
              </p>
            ) : null}
            <Button disabled={busy} type="submit">
              <Trans>Connect</Trans>
            </Button>
          </form>
        </DialogContent>
      </Dialog>
    </>
  );
}
