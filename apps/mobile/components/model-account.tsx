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
import { useFocusEffect } from "expo-router";
import { useCallback, useRef, useState } from "react";
import { Alert, AppState, Linking, View } from "react-native";
import { authHeaders, currentApiBase } from "../lib/api";
import { useI18n } from "../lib/i18n";
import { fetchServer } from "../lib/server-headers";
import { currentSessionGeneration } from "../lib/session";
import { MenuPickerMenu } from "./menu-picker";
import { SettingsGroup, SettingsRow } from "./settings-group";

function client() {
  const base = currentApiBase();
  const generation = currentSessionGeneration();
  return createModelAccountClient(async (url, init) => {
    const headers = new Headers(await authHeaders());
    if (base !== currentApiBase() || generation !== currentSessionGeneration())
      throw new Error("Account changed");
    new Headers(init?.headers).forEach((value, key) => {
      headers.set(key, value);
    });
    headers.set("origin", "rakazo://");
    const response = await fetchServer(url, { ...init, headers }, base);
    if (base !== currentApiBase() || generation !== currentSessionGeneration())
      throw new Error("Account changed");
    return response;
  }, `${base}/api/model-account`);
}

export function ModelAccount({ onChanged }: { onChanged: () => void }) {
  const { t } = useI18n();
  const [config, setConfig] = useState<ModelAccountConfig>();
  const [status, setStatus] = useState<ModelAccountStatus>();
  const [balance, setBalance] = useState<string>();
  const [error, setError] = useState<ModelAccountErrorCode>();
  const [busy, setBusy] = useState(false);
  const actionAbort = useRef<AbortController | null>(null);
  const refresh = useCallback(
    async (api: ReturnType<typeof client>, signal?: AbortSignal) => {
      const latest = await api.status(signal);
      if (signal?.aborted) return;
      setStatus(latest);
      if (latest.recovery !== "authorization_unknown" && latest.recovery !== "revocation_unknown")
        setError((previous) => (previous === "result_unknown" ? undefined : previous));
      if (latest.linked === false) {
        setBalance(undefined);
        return;
      }
      try {
        const funds = await api.balance(signal);
        if (!signal?.aborted) setBalance(`${funds.amount} ${funds.unit}`);
      } catch {
        if (!signal?.aborted) setBalance(t("Balance unavailable"));
      }
    },
    [t],
  );
  useFocusEffect(
    useCallback(() => {
      const abort = new AbortController();
      setBusy(false);
      setConfig(undefined);
      setStatus(undefined);
      setBalance(undefined);
      setError(undefined);
      const api = client();
      const update = () => {
        void api
          .config(abort.signal)
          .then(async (value) => {
            if (abort.signal.aborted) return;
            setConfig(value);
            if (value.enabled) await refresh(api, abort.signal);
          })
          .catch((cause) => {
            if (!abort.signal.aborted)
              setError(cause instanceof ModelAccountClientError ? cause.code : "unavailable");
          });
      };
      update();
      const subscription = AppState.addEventListener("change", (state) => {
        if (state === "active") update();
      });
      return () => {
        abort.abort();
        actionAbort.current?.abort();
        subscription.remove();
      };
    }, [refresh]),
  );
  if (!config?.enabled) return null;
  const navigation = resolveAccountNavigation(config);
  const act = async (
    kind: "connect" | "revoke" | "refresh" | "models" | "protocol",
    protocol?: "chat-completions" | "responses",
  ) => {
    const abort = new AbortController();
    actionAbort.current = abort;
    setBusy(true);
    setError(undefined);
    const api = client();
    try {
      if (kind === "protocol" && protocol) await api.settings(protocol, abort.signal);
      else if (kind === "models") await api.refreshModels(abort.signal);
      else if (kind === "revoke") await api.revoke(abort.signal);
      else if (kind === "refresh") {
        await refresh(api, abort.signal);
        return;
      } else {
        const result = await api.connect(undefined, abort.signal);
        if (result.url) {
          const { openAuthSessionAsync } = await import("expo-web-browser");
          const authorization = await openAuthSessionAsync(
            result.url,
            "rakazo://model-authorization",
          );
          if (authorization.type === "success") {
            const code = modelAccountErrorCodeSchema.safeParse(
              new URL(authorization.url).searchParams.get("error"),
            );
            if (code.success) throw new ModelAccountClientError(code.data);
          }
        }
      }
      abort.signal.throwIfAborted();
      await refresh(api, abort.signal);
      onChanged();
    } catch (cause) {
      if (abort.signal.aborted) return;
      setError(cause instanceof ModelAccountClientError ? cause.code : "unavailable");
      await refresh(api, abort.signal).catch(() => undefined);
    } finally {
      if (!abort.signal.aborted) setBusy(false);
    }
  };
  const identityUnavailable = status?.linked === false || error === "link_required";
  const message =
    status?.recovery === "revocation_unknown"
      ? t("Disconnection pending confirmation.")
      : error === "result_unknown" || status?.recovery === "authorization_unknown"
        ? t("Could not confirm authorization. Try again.")
        : error === "authorization_required" || status?.recovery === "authorization_required"
          ? t("Authorize the model account to continue.")
          : status?.recovery === "authorization_pending"
            ? t("Authorization incomplete.")
            : identityUnavailable
              ? t("Sign in with SSO to use the model account.")
              : error
                ? t("Model account unavailable")
                : undefined;
  return (
    <SettingsGroup label={t("Model account")} footer={message}>
      {!identityUnavailable &&
      status?.recovery !== "revocation_unknown" &&
      (!status?.connected ||
        error === "authorization_required" ||
        status?.recovery === "authorization_required" ||
        status?.recovery) ? (
        <SettingsRow
          title={
            error === "authorization_required" || status?.recovery === "authorization_required"
              ? t("Authorize again")
              : status?.recovery === "authorization_unknown" || error === "result_unknown"
                ? t("Retry")
                : status?.recovery === "authorization_pending"
                  ? t("Authorize again")
                  : t("Use model account")
          }
          disabled={busy}
          onPress={() =>
            void act(status?.recovery === "authorization_unknown" ? "refresh" : "connect")
          }
        />
      ) : null}
      {status?.connected ? (
        <SettingsRow
          title={t("Refresh models")}
          disabled={busy}
          onPress={() => void act("models")}
        />
      ) : null}
      {status?.connected || status?.recovery === "revocation_unknown" ? (
        <SettingsRow
          title={status.recovery === "revocation_unknown" ? t("Retry disconnect") : t("Disconnect")}
          destructive
          disabled={busy}
          onPress={() => void act("revoke")}
        />
      ) : null}
      {status?.connected ? (
        <MenuPickerMenu
          label={t("API protocol")}
          choices={[
            { key: "chat-completions", label: "Chat Completions" },
            { key: "responses", label: "Responses" },
          ]}
          value={status.apiProtocol ?? "chat-completions"}
          disabled={busy}
          onChange={(value) => {
            if (value === "responses" || value === "chat-completions") void act("protocol", value);
          }}
        >
          <View>
            <SettingsRow
              title={t("API protocol")}
              value={status.apiProtocol === "responses" ? "Responses" : "Chat Completions"}
              disabled={busy}
            />
          </View>
        </MenuPickerMenu>
      ) : null}
      <SettingsRow
        title={t("Refresh balance")}
        value={balance}
        disabled={busy}
        onPress={() => void act("refresh")}
      />
      {navigation ? (
        <>
          <SettingsRow
            title={t("Home")}
            onPress={() =>
              void Linking.openURL(navigation.homeUrl).catch(() =>
                Alert.alert(t("Could not continue")),
              )
            }
          />
          <SettingsRow
            title={t("Recharge")}
            onPress={() =>
              void Linking.openURL(navigation.rechargeUrl).catch(() =>
                Alert.alert(t("Could not continue")),
              )
            }
          />
        </>
      ) : null}
    </SettingsGroup>
  );
}
