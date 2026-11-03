import { Trans, useLingui } from "@lingui/react/macro";
import type {
  ModelAccountConfig,
  ModelAccountErrorCode,
  ModelAccountStatus,
} from "@rakazo/contracts";
import { modelAccountErrorCodeSchema } from "@rakazo/contracts";
import { createModelAccountClient, ModelAccountClientError } from "@rakazo/core";
import { Button, SectionHeading } from "@rakazo/ui-web";
import { useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useRef, useState } from "react";
import { authClient } from "../lib/auth";
import { cancelSsoFlow, runSsoFlow } from "../lib/sso-flow";

const client = createModelAccountClient();
export function ModelAccount() {
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
      cancelSsoFlow();
      window.removeEventListener("focus", update);
      document.removeEventListener("visibilitychange", update);
    };
  }, [userId, refresh]);
  if (!config?.enabled) return null;
  const act = async (kind: "connect" | "revoke" | "refresh") => {
    const abort = new AbortController();
    actionAbort.current = abort;
    setBusy(true);
    setError(undefined);
    try {
      if (kind === "revoke") await client.revoke(abort.signal);
      else if (kind === "refresh") {
        await refresh(abort.signal);
        return;
      } else {
        setAuthorizing(true);
        const returnTo = window.location.href;
        const result = await runSsoFlow(
          async (_disableRedirect, callbackURL) => {
            const connected = await client.connect(callbackURL(returnTo), abort.signal);
            return { data: { url: connected.url }, error: null };
          },
          [returnTo],
          { popup: true, navigate: false },
        );
        if (result.error) {
          const code = modelAccountErrorCodeSchema.safeParse(result.error.code);
          throw new ModelAccountClientError(code.success ? code.data : "unavailable");
        }
      }
      abort.signal.throwIfAborted();
      await refresh(abort.signal);
      await queries.invalidateQueries();
    } catch (cause) {
      if (abort.signal.aborted) return;
      setError(cause instanceof ModelAccountClientError ? cause.code : "unavailable");
      await refresh(abort.signal).catch(() => undefined);
    } finally {
      if (!abort.signal.aborted) {
        setBusy(false);
        setAuthorizing(false);
      }
    }
  };
  const identityUnavailable = status?.linked === false || error === "link_required";
  const message =
    status?.recovery === "revocation_unknown"
      ? t`Disconnection pending confirmation.`
      : identityUnavailable
        ? t`Sign in with SSO to use the model account.`
        : error === "authorization_required"
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
  return (
    <section className="mb-6 space-y-3" data-model-account>
      <SectionHeading>
        <Trans>Model account</Trans>
      </SectionHeading>
      {balance ? <p className="text-sm text-muted-foreground">{balance}</p> : null}
      {message ? (
        <p role={error ? "alert" : "status"} className="text-sm text-muted-foreground">
          {message}
        </p>
      ) : null}
      <div className="flex flex-wrap gap-2">
        {!identityUnavailable &&
        status?.recovery !== "revocation_unknown" &&
        (!status?.connected || error === "authorization_required" || status?.recovery) ? (
          <Button
            size="sm"
            disabled={busy}
            onClick={() =>
              void act(status?.recovery === "authorization_unknown" ? "refresh" : "connect")
            }
          >
            {error === "authorization_required" ? (
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
        {authorizing ? (
          <Button size="sm" variant="outline" onClick={cancelSsoFlow}>
            <Trans>Cancel</Trans>
          </Button>
        ) : null}
        {status?.connected || status?.recovery === "revocation_unknown" ? (
          <Button size="sm" variant="outline" disabled={busy} onClick={() => void act("revoke")}>
            {status.recovery === "revocation_unknown" ? (
              <Trans>Retry disconnect</Trans>
            ) : (
              <Trans>Disconnect</Trans>
            )}
          </Button>
        ) : null}
        <Button size="sm" variant="ghost" disabled={busy} onClick={() => void act("refresh")}>
          <Trans>Refresh balance</Trans>
        </Button>
        <Button
          size="sm"
          variant="ghost"
          render={<a href={config.homeUrl} target="_blank" rel="noreferrer" />}
        >
          <Trans>Home</Trans>
        </Button>
        <Button
          size="sm"
          variant="ghost"
          render={<a href={config.rechargeUrl} target="_blank" rel="noreferrer" />}
        >
          <Trans>Recharge</Trans>
        </Button>
      </div>
    </section>
  );
}
