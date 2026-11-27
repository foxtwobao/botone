// @vitest-environment jsdom
import { i18n } from "@lingui/core";
import type { ModelCredential } from "@rakazo/contracts";
import type { ReactNode } from "react";
import { act, createElement } from "react";
import type { Root } from "react-dom/client";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

const client = vi.hoisted(() => ({ saveLimits: vi.fn(async () => undefined) }));
vi.mock("../model-account-client", () => ({ modelAccountClient: () => client }));
vi.mock("../model-account-i18n", () => ({
  useI18n: () => ({ locale: "en", t: (message: string) => message }),
}));
vi.mock("../query/query", async () => {
  const { QueryClient } = await import("@tanstack/react-query");
  return { queryClient: new QueryClient() };
});
vi.mock("../../components/models/model-connection-fields", () => ({ LimitField: () => null }));
vi.mock("../../components/native/native-action-button", () => ({
  NativeActionButton: ({
    label,
    onPress,
    disabled,
  }: {
    label?: string;
    onPress: () => void;
    disabled?: boolean;
  }) => createElement("button", { type: "button", onClick: onPress, disabled }, label),
}));
vi.mock("../../components/native/native-symbol", () => ({ NativeSymbol: () => null }));
vi.mock("../../components/settings/settings-group", () => ({
  SettingsGroup: ({ children }: { children?: ReactNode }) => createElement("div", {}, children),
}));
vi.mock("../../components/ui/row-accessories", () => ({ Chevron: () => null }));
// A native menu becomes its title and one button per action, pressed for the chosen one.
vi.mock("@expo/ui/community/menu", () => ({
  MenuView: ({
    actions,
    onPressAction,
    title,
    children,
  }: {
    actions: { id: string; title: string; state?: string }[];
    onPressAction: (event: { nativeEvent: { event: string } }) => void;
    title: string;
    children?: ReactNode;
  }) =>
    createElement(
      "div",
      { "aria-label": title },
      children,
      actions.map((action) =>
        createElement(
          "button",
          {
            key: action.id,
            type: "button",
            "aria-pressed": action.state === "on",
            onClick: () => onPressAction({ nativeEvent: { event: action.id } }),
          },
          action.title,
        ),
      ),
    ),
}));
vi.mock("../native/native", () => ({
  native: new Proxy({}, { get: (_target, name) => String(name) }),
  useResolvedAppearance: () => "light",
  useMobileTokens: () => ({}),
  useThemedStyles: (createStyles: () => unknown) => createStyles(),
}));
vi.mock("react-native", () => {
  const view = ({ children }: { children?: ReactNode }) => createElement("div", {}, children);
  return {
    StyleSheet: { create: (styles: unknown) => styles },
    Pressable: view,
    View: view,
    Text: view,
  };
});

import { AccountModelLimits } from "../../components/account-model-limits";

/** One model keeps the boolean an older app saved; the other has nothing saved. */
const credential = {
  id: "external-fixture",
  provider: "openai-compatible",
  label: "Model account",
  hasKey: true,
  isDefault: true,
  apiProtocol: "responses",
  enabledModelIds: ["legacy-model", "fresh-model"],
  modelSettings: { "legacy-model": { reasoning: true } },
} as ModelCredential;

let container: HTMLDivElement;
let root: Root;

// The shared level labels read the active catalog.
i18n.load("en", {});
i18n.activate("en");

beforeEach(() => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
});
afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
  vi.unstubAllGlobals();
});

const button = (scope: Element, name: string) =>
  [...scope.querySelectorAll("button")].find((entry) => entry.textContent === name)!;
const choice = (menu: string, name: string) =>
  button(container.querySelector(`[aria-label="${menu}"]`)!, name);
async function open(credential: ModelCredential, refresh: () => Promise<void>) {
  await act(async () => root.render(createElement(AccountModelLimits, { credential, refresh })));
}

it("shows an older app's thinking switch as the default level", async () => {
  await open(credential, async () => undefined);
  await act(async () => choice("Model options", "legacy-model").click());
  expect(choice("Thinking", "Medium").getAttribute("aria-pressed")).toBe("true");
});

it("shows the switch an older app turned off as Off", async () => {
  const switchedOff = {
    ...credential,
    modelSettings: { ...credential.modelSettings, "fresh-model": { reasoning: false } },
  } as ModelCredential;
  await open(switchedOff, async () => undefined);
  await act(async () => choice("Model options", "fresh-model").click());
  expect(choice("Thinking", "Off").getAttribute("aria-pressed")).toBe("true");
});

it("saves the thinking level chosen for a model in place of the connection's default", async () => {
  const refresh = vi.fn(async () => undefined);
  await open(credential, refresh);
  await act(async () => choice("Model options", "fresh-model").click());
  expect(choice("Thinking", "Default").getAttribute("aria-pressed")).toBe("true");
  await act(async () => choice("Thinking", "High").click());
  await act(async () => button(container, "Save").click());
  await vi.waitFor(() => expect(refresh).toHaveBeenCalledOnce());
  expect(client.saveLimits).toHaveBeenCalledOnce();
  expect(client.saveLimits).toHaveBeenLastCalledWith("external-fixture", "fresh-model", {
    thinkingLevel: "high",
  });
});
