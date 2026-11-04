// @vitest-environment jsdom
import type { ModelAccountStatus } from "@rakazo/contracts";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { expect, it, vi } from "vitest";

const navigation = vi.hoisted(() => ({ canGoBack: vi.fn(), back: vi.fn(), replace: vi.fn() }));
vi.mock("expo-router", () => ({ useRouter: () => navigation }));

import { useAccountAuthorizationReturn } from "./use-account-authorization-return";

it.each([true, false])("automatically returns on success with back stack=%s", (canGoBack) => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  vi.clearAllMocks();
  navigation.canGoBack.mockReturnValue(canGoBack);
  const host = document.body.appendChild(document.createElement("div"));
  const root = createRoot(host);
  function Page({ status }: { status: ModelAccountStatus }) {
    useAccountAuthorizationReturn(status);
    return null;
  }
  const render = (status: ModelAccountStatus) => act(() => root.render(<Page status={status} />));
  try {
    render({ enabled: true, connected: true });
    expect(navigation.canGoBack).not.toHaveBeenCalled();
    render({ enabled: true, connected: true, recovery: "authorization_required" });
    render({ enabled: true, connected: false, recovery: "authorization_pending" });
    expect(navigation.canGoBack).not.toHaveBeenCalled();
    render({ enabled: true, connected: true });
    expect(navigation.back).toHaveBeenCalledTimes(canGoBack ? 1 : 0);
    expect(navigation.replace).toHaveBeenCalledTimes(canGoBack ? 0 : 1);
    if (!canGoBack) expect(navigation.replace).toHaveBeenCalledWith("/");
    render({ enabled: true, connected: true });
    expect(navigation.canGoBack).toHaveBeenCalledOnce();
  } finally {
    act(() => root.unmount());
    host.remove();
    vi.unstubAllGlobals();
  }
});
