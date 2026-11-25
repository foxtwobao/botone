// @vitest-environment jsdom

import { i18n } from "@lingui/core";
import type { ModelCredential } from "@rakazo/contracts";
import type { ReactNode } from "react";
import { act } from "react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { createQueryRoot } from "../../lib/query/query-root.test-support";

vi.mock("@lingui/react/macro", () => ({
  useLingui: () => ({
    t: (parts: TemplateStringsArray, ...values: string[]) =>
      parts.reduce((text, part, i) => text + part + (values[i] ?? ""), ""),
  }),
  Trans: ({ children }: { children?: ReactNode }) => children,
}));
const client = vi.hoisted(() => ({ saveLimits: vi.fn(async () => undefined) }));
vi.mock("@rakazo/core", async (original) => ({
  ...(await original<object>()),
  createModelAccountClient: () => client,
}));
vi.mock("@rakazo/ui-web", () => ({
  Button: ({
    children,
    onClick,
    disabled,
  }: {
    children: ReactNode;
    onClick?: () => void;
    disabled?: boolean;
  }) => (
    <button type="button" onClick={onClick} disabled={disabled}>
      {children}
    </button>
  ),
  ModelSettingsFields: ({
    thinkingLevel,
    thinkingLevels,
    onThinkingLevelChange,
  }: {
    thinkingLevel: string;
    thinkingLevels: { value: string; label: string }[];
    onThinkingLevelChange: (thinkingLevel: string) => void;
  }) => (
    <>
      <output>{thinkingLevels.find((option) => option.value === thinkingLevel)?.label}</output>
      {thinkingLevels.map((option) => (
        <button
          key={option.value}
          type="button"
          onClick={() => onThinkingLevelChange(option.value)}
        >
          {option.label}
        </button>
      ))}
    </>
  ),
  Select: ({
    children,
    value,
    onValueChange,
  }: {
    children: ReactNode;
    value: string | null;
    onValueChange: (value: string) => void;
  }) => (
    <select value={value ?? ""} onChange={(event) => onValueChange(event.target.value)}>
      {children}
    </select>
  ),
  SelectContent: ({ children }: { children: ReactNode }) => children,
  SelectItem: ({ value, children }: { value: string; children: ReactNode }) => (
    <option value={value}>{children}</option>
  ),
  SelectTrigger: () => null,
  SelectValue: () => null,
}));

import { AccountModelLimits } from "./AccountModelLimits";

/** One model keeps the boolean an older app saved; the other has nothing saved. */
const credential = {
  id: "external-fixture",
  provider: "openai-compatible",
  label: "Model account",
  hasKey: true,
  isDefault: true,
  apiProtocol: "responses",
  enabledModelIds: ["legacy-model", "fresh-model"],
  modelSettings: { "legacy-model": { reasoning: true, maxTokens: 2048 } },
} as ModelCredential;

let host: HTMLDivElement;
let root: ReturnType<typeof createQueryRoot>;

beforeEach(() => {
  i18n.load("en", {});
  i18n.activate("en");
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  host = document.body.appendChild(document.createElement("div"));
  root = createQueryRoot(host);
});
afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
  vi.unstubAllGlobals();
});

const button = (label: string) =>
  [...host.querySelectorAll("button")].find((node) => node.textContent === label);
const chooseModel = (id: string) =>
  act(async () => {
    const picker = host.querySelector<HTMLSelectElement>("select")!;
    picker.value = id;
    picker.dispatchEvent(new Event("change", { bubbles: true }));
  });

it("shows an older app's thinking switch as the default level, and saves it only once it changes", async () => {
  await act(async () =>
    root.render(<AccountModelLimits credential={credential} refresh={async () => {}} />),
  );
  await chooseModel("legacy-model");
  // Shown as the default effort, which a save leaves out until another level is chosen.
  expect(host.querySelector("output")?.textContent).toBe("Medium");
  await act(async () => button("Save")!.click());
  await vi.waitFor(() => expect(client.saveLimits).toHaveBeenCalledOnce());
  expect(client.saveLimits).toHaveBeenLastCalledWith("external-fixture", "legacy-model", {
    maxTokens: 2048,
  });
});

it("saves the level chosen for a model in place of the connection's default", async () => {
  const refresh = vi.fn(async () => undefined);
  await act(async () =>
    root.render(<AccountModelLimits credential={credential} refresh={refresh} />),
  );
  await chooseModel("fresh-model");
  expect(host.querySelector("output")?.textContent).toBe("Default");
  expect(button("Restore defaults")).toBeUndefined();
  await act(async () => button("High")!.click());
  await act(async () => button("Save")!.click());
  await vi.waitFor(() => expect(refresh).toHaveBeenCalledOnce());
  expect(client.saveLimits).toHaveBeenCalledOnce();
  expect(client.saveLimits).toHaveBeenLastCalledWith("external-fixture", "fresh-model", {
    thinkingLevel: "high",
  });
});
