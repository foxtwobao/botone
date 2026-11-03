import { Trans, useLingui } from "@lingui/react/macro";
import type {
  ModelAccountConfig,
  ModelAccountErrorCode,
  ModelAccountStatus,
} from "@rakazo/contracts";
import { modelAccountErrorCodeSchema } from "@rakazo/contracts";
import {
  createModelAccountClient,
  ModelAccountClientError,
  resolveAccountNavigation,
} from "@rakazo/core";
import {
  Button,
  SectionHeading,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@rakazo/ui-web";
import { useQueryClient } from "@tanstack/react-query";
import type { MouseEvent } from "react";
import { useCallback, useEffect, useRef, useState } from "react";
import { authClient } from "../lib/auth";
import { cancelSsoFlow, runSsoFlow } from "../lib/sso-flow";

const client = createModelAccountClient();
export function ModelAccount({
  resumeTask = false,
  required = false,
  onChanged,
}: {
  resumeTask?: boolean;
  required?: boolean;
  onChanged?: () => void | Promise<void>;
}) {
  const { t } = useLingui();
  const userId = authClient.useSession().data?.user.id;
  const queries = useQueryClient();
  const [config, setConfig] = useState<ModelAccountConfig>();
  const [status, setStatus] = useState<ModelAccountStatus>();
  const [balance, setBalance] = useState<string>();
  const [error, setError] = useState<ModelAccountErrorCode>();
  const [busy, setBusy] = useState(false);
  const [authorizing, setAuthorizing] = useState(false);
  const actionAbort = useRef<AbortController | null>(null);
  const refresh = useCallback(
    async (signal?: AbortSignal) => {
      const latest = await client.status(signal);
      if (signal?.aborted) return;
      setStatus(latest);
      if (latest.recovery !== "authorization_unknown" && latest.recovery !== "revocation_unknown")
        setError((previous) => (previous === "result_unknown" ? undefined : previous));
      if (latest.linked === false) {
        setBalance(undefined);
        return;
      }
      try {
        const value = await client.balance(signal);
        if (!signal?.aborted) setBalance(`${value.amount} ${value.unit}`);
      } catch {
        if (!signal?.aborted) setBalance(t`Balance unavailable`);
      }
    },
    [t],
  );
  useEffect(() => {
    const abort = new AbortController();
    setBusy(false);
    setAuthorizing(false);
    setConfig(undefined);
    setStatus(undefined);
    setBalance(undefined);
    setError(undefined);
    const update = () => {
      if (document.visibilityState === "hidden") return;
      void client
        .config(abort.signal)
        .then(async (value) => {
          if (abort.signal.aborted) return;
          setConfig(value);
          if (value.enabled) await refresh(abort.signal);
        })
        .catch((error) => {
          if (!abort.signal.aborted)
            setError(error instanceof ModelAccountClientError ? error.code : "unavailable");
        });
    };
    update();
    window.addEventListener("focus", update);
    document.addEventListener("visibilitychange", update);
    return () => {
      abort.abort();
      actionAbort.current?.abort();
      window.removeEventListener("focus", update);
      document.removeEventListener("visibilitychange", update);
    };
  }, [userId, refresh]);
  if (!config?.enabled)
    return required && (config || error) ? (
      <p role="alert" className="text-sm text-destructive">
        <Trans>Model account unavailable</Trans>
      </p>
    ) : null;
  const navigation = resolveAccountNavigation(config, document.cookie, window.location.hostname);
  const updateNavigationLink =
    (kind: "homeUrl" | "rechargeUrl") => (event: MouseEvent<HTMLAnchorElement>) => {
      const latest = resolveAccountNavigation(config, document.cookie, window.location.hostname);
      if (!latest) event.preventDefault();
      else event.currentTarget.href = latest[kind];
    };
  const act = async (
    kind: "connect" | "revoke" | "refresh" | "models" | "protocol",
    protocol?: "chat-completions" | "responses",
  ) => {
    const abort = new AbortController();
    actionAbort.current = abort;
    setBusy(true);
    setError(undefined);
    try {
      if (kind === "protocol" && protocol) await client.settings(protocol, abort.signal);
      else if (kind === "models") await client.refreshModels(abort.signal);
      else if (kind === "revoke") await client.revoke(abort.signal);
      else if (kind !== "refresh") {
        setAuthorizing(true);
        const returnTo = window.location.href;
        const result = await runSsoFlow(
          async (_disableRedirect, callbackURL) => {
            const connected = await client.connect(callbackURL(returnTo), abort.signal);
            return { data: { url: connected.url }, error: null };
          },
          [returnTo],
          { popup: true, navigate: false, signal: abort.signal },
        );
        if (result.error) {
          const code = modelAccountErrorCodeSchema.safeParse(result.error.code);
          throw new ModelAccountClientError(code.success ? code.data : "unavailable");
        }
      }
      abort.signal.throwIfAborted();
      await refresh(abort.signal);
      await queries.invalidateQueries();
      await onChanged?.();
    } catch (cause) {
      if (abort.signal.aborted) return;
      setError(cause instanceof ModelAccountClientError ? cause.code : "unavailable");
      await refresh(abort.signal).catch(() => undefined);
    } finally {
      if (!abort.signal.aborted) {
        setBusy(false);
        setAuthorizing(false);
      }
      if (actionAbort.current === abort) actionAbort.current = null;
    }
  };
  const identityUnavailable = status?.linked === false || error === "link_required";
  const message =
    status?.recovery === "revocation_unknown"
      ? t`Disconnection pending confirmation.`
      : identityUnavailable
        ? t`Sign in with SSO to use the model account.`
        : error && error !== "authorization_required" && error !== "result_unknown"
          ? t`Model account unavailable`
          : error === "authorization_required" || status?.recovery === "authorization_required"
            ? t`Authorize the model account to continue.`
            : error === "result_unknown" || status?.recovery === "authorization_unknown"
              ? t`Could not confirm authorization. Try again.`
              : status?.recovery === "authorization_pending"
                ? authorizing
                  ? t`Complete authorization in the opened window.`
                  : t`Authorization incomplete.`
                : error
                  ? t`Model account unavailable`
                  : null;
  if (resumeTask) {
    return (
      <div className="mt-2 space-y-2" data-model-account>
        <Button
          size="sm"
          disabled={busy || identityUnavailable}
          onClick={() =>
            void act(
              status?.recovery === "revocation_unknown"
                ? "revoke"
                : status?.recovery === "authorization_unknown"
                  ? "refresh"
                  : "connect",
            )
          }
        >
          {status?.recovery === "revocation_unknown" ? (
            <Trans>Retry disconnect</Trans>
          ) : status?.recovery === "authorization_unknown" ? (
            <Trans>Retry</Trans>
          ) : (
            <Trans>Authorize and continue</Trans>
          )}
        </Button>
        {authorizing ? (
          <Button size="sm" variant="ghost" onClick={cancelSsoFlow}>
            <Trans>Cancel</Trans>
          </Button>
        ) : null}
        {message &&
        (error ||
          identityUnavailable ||
          authorizing ||
          status?.recovery === "revocation_unknown" ||
          status?.recovery === "authorization_unknown") ? (
          <p role={error ? "alert" : "status"} className="text-sm text-muted-foreground">
            {message}
          </p>
        ) : null}
      </div>
    );
  }
  return (
    <section className="mb-6 space-y-3" data-model-account>
      <SectionHeading>
        <Trans>Model account</Trans>
      </SectionHeading>
      {status?.connected && !message ? (
        <p role="status" className="text-sm">
          <Trans>Connected to TokenONE</Trans>
        </p>
      ) : null}
      {balance ? <p className="text-sm text-muted-foreground">{balance}</p> : null}
      {message ? (
        <p role={error ? "alert" : "status"} className="text-sm text-muted-foreground">
          {message}
        </p>
      ) : null}
      {status?.connected ? (
        <Select
          value={status.apiProtocol ?? "chat-completions"}
          items={[
            { value: "chat-completions", label: "Chat Completions" },
            { value: "responses", label: "Responses" },
          ]}
          onValueChange={(value) => {
            if (value !== "chat-completions" && value !== "responses") return;
            void act("protocol", value);
          }}
          disabled={busy}
        >
          <SelectTrigger aria-label={t`API protocol`}>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="chat-completions">Chat Completions</SelectItem>
            <SelectItem value="responses">Responses</SelectItem>
          </SelectContent>
        </Select>
      ) : null}
      <div className="flex flex-wrap gap-2">
        {!identityUnavailable &&
        status?.recovery !== "revocation_unknown" &&
        (!status?.connected ||
          error === "authorization_required" ||
          status?.recovery === "authorization_required" ||
          status?.recovery) ? (
          <Button
            size="sm"
            disabled={busy}
            onClick={() =>
              void act(status?.recovery === "authorization_unknown" ? "refresh" : "connect")
            }
          >
            {error === "authorization_required" || status?.recovery === "authorization_required" ? (
              <Trans>Authorize again</Trans>
            ) : status?.recovery === "authorization_unknown" || error === "result_unknown" ? (
              <Trans>Retry</Trans>
            ) : status?.recovery === "authorization_pending" ? (
              <Trans>Authorize again</Trans>
            ) : (
              <Trans>Use model account</Trans>
            )}
          </Button>
        ) : null}
        {status?.connected ? (
          <Button size="sm" variant="ghost" disabled={busy} onClick={() => void act("models")}>
            <Trans>Refresh models</Trans>
          </Button>
        ) : null}
        {authorizing ? (
          <Button size="sm" variant="outline" onClick={cancelSsoFlow}>
            <Trans>Cancel</Trans>
          </Button>
        ) : null}
        {status?.recovery === "revocation_unknown" ? (
          <Button size="sm" variant="outline" disabled={busy} onClick={() => void act("revoke")}>
            <Trans>Retry disconnect</Trans>
          </Button>
        ) : null}
        <Button size="sm" variant="ghost" disabled={busy} onClick={() => void act("refresh")}>
          <Trans>Refresh balance</Trans>
        </Button>
        {navigation ? (
          <>
            <Button
              size="sm"
              variant="ghost"
              nativeButton={false}
              role="link"
              render={
                <a
                  href={navigation.homeUrl}
                  target="_blank"
                  rel="noreferrer"
                  onClick={updateNavigationLink("homeUrl")}
                  onAuxClick={updateNavigationLink("homeUrl")}
                />
              }
            >
              <Trans>Home</Trans>
            </Button>
            <Button
              size="sm"
              variant="ghost"
              nativeButton={false}
              role="link"
              render={
                <a
                  href={navigation.rechargeUrl}
                  target="_blank"
                  rel="noreferrer"
                  onClick={updateNavigationLink("rechargeUrl")}
                  onAuxClick={updateNavigationLink("rechargeUrl")}
                />
              }
            >
              <Trans>Recharge</Trans>
            </Button>
          </>
        ) : null}
      </div>
    </section>
  );
}
