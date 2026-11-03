// @vitest-environment jsdom
import type { ReactNode } from "react";
import { act, useEffect } from "react";
import type { Root } from "react-dom/client";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { ModelAccount } from "../components/model-account";

const mocks = vi.hoisted(() => ({
  status: vi.fn(),
  connect: vi.fn(),
  balance: vi.fn(),
  openAuthSessionAsync: vi.fn(),
  t: (text: string) => text,
}));
vi.mock("@rakazo/core", async (original) => ({
  ...(await original<object>()),
  createModelAccountClient: () => ({
    config: async () => ({ enabled: true }),
    status: mocks.status,
    connect: mocks.connect,
    balance: mocks.balance,
  }),
}));
vi.mock("./api", () => ({
  authHeaders: async () => ({}),
  currentApiBase: () => "https://app.example.test",
}));
vi.mock("./server-headers", () => ({ fetchServer: vi.fn() }));
vi.mock("./session", () => ({ currentSessionGeneration: () => 1 }));
vi.mock("./i18n", () => ({ useI18n: () => ({ t: mocks.t }) }));
vi.mock("expo-router", () => ({
  useFocusEffect: (callback: () => () => void) => useEffect(callback, [callback]),
}));
vi.mock("expo-web-browser", () => ({ openAuthSessionAsync: mocks.openAuthSessionAsync }));
vi.mock("react-native", () => ({
  Alert: { alert: vi.fn() },
  Linking: { openURL: vi.fn() },
  View: ({ children }: { children?: ReactNode }) => <div>{children}</div>,
  AppState: { addEventListener: () => ({ remove: vi.fn() }) },
}));
vi.mock("../components/menu-picker", () => ({ MenuPickerMenu: () => null }));
vi.mock("../components/settings-group", () => ({
  SettingsGroup: ({ children, footer }: { children?: ReactNode; footer?: string }) => (
    <div>
      {children}
      {footer}
    </div>
  ),
  SettingsRow: () => null,
}));
vi.mock("../components/native-action-button", () => ({
  NativeActionButton: ({
    label,
    disabled,
    onPress,
  }: {
    label: string;
    disabled?: boolean;
    onPress: () => void;
  }) => (
    <button type="button" disabled={disabled} onClick={onPress}>
      {label}
    </button>
  ),
}));

let root: Root;
let container: HTMLDivElement;
beforeEach(() => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  vi.clearAllMocks();
  mocks.status.mockResolvedValue({
    enabled: true,
    linked: true,
    connected: false,
    recovery: "authorization_required",
  });
  mocks.balance.mockResolvedValue({ amount: "1.00", unit: "USD" });
  mocks.openAuthSessionAsync.mockResolvedValue({ type: "cancel" });
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
});
afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
  vi.unstubAllGlobals();
});

it("refreshes the original task after an uncertain authorization is recovered without opening a browser", async () => {
  mocks.status.mockResolvedValue({
    enabled: true,
    linked: true,
    connected: false,
    recovery: "authorization_unknown",
  });
  const changed = vi.fn();
  await act(async () => root.render(<ModelAccount resumeTask onChanged={changed} />));
  const button = container.querySelector("button")!;
  expect(button.textContent).toBe("Retry");
  expect(mocks.connect).not.toHaveBeenCalled();
  expect(mocks.openAuthSessionAsync).not.toHaveBeenCalled();
  mocks.status.mockResolvedValue({ enabled: true, linked: true, connected: true });
  await act(async () => button.click());
  expect(changed).toHaveBeenCalledOnce();
  expect(mocks.connect).not.toHaveBeenCalled();
  expect(mocks.openAuthSessionAsync).not.toHaveBeenCalled();
});

it("does not open authorization when its request returns after the task UI unmounts", async () => {
  let resolve!: (value: { connected: boolean; url: string }) => void;
  mocks.connect.mockImplementation(
    () =>
      new Promise((done) => {
        resolve = done;
      }),
  );
  const changed = vi.fn();
  await act(async () => root.render(<ModelAccount resumeTask onChanged={changed} />));
  await act(async () => container.querySelector("button")!.click());
  const signal = mocks.connect.mock.calls[0]![1] as AbortSignal;
  await act(async () => root.render(null));
  expect(signal.aborted).toBe(true);
  await act(async () =>
    resolve({ connected: false, url: "https://gateway.example.test/authorize" }),
  );
  expect(mocks.openAuthSessionAsync).not.toHaveBeenCalled();
  expect(changed).not.toHaveBeenCalled();
});
