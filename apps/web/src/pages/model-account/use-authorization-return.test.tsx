// @vitest-environment jsdom
import type { ModelAccountStatus } from "@rakazo/contracts";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MemoryRouter, useLocation } from "react-router-dom";
import { expect, it, vi } from "vitest";
import { useAuthorizationReturn } from "./use-authorization-return";

it.each(["transition", "redirect", "failure", "settings"] as const)(
  "closes only confirmed authorization, %s",
  (scenario) => {
    vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
    const close = vi.fn();
    const host = document.body.appendChild(document.createElement("div"));
    const root = createRoot(host);
    function Page({ status }: { status: ModelAccountStatus }) {
      useAuthorizationReturn(status, close);
      return <output>{useLocation().search}</output>;
    }
    const url =
      "/chat?settings=models&keep=1" +
      (scenario === "redirect" || scenario === "failure" ? "&modelAccountAuthorization=1" : "") +
      (scenario === "failure" ? "&modelAccountError=unavailable" : "");
    const render = (status: ModelAccountStatus) =>
      act(() =>
        root.render(
          <MemoryRouter initialEntries={[url]}>
            <Page status={status} />
          </MemoryRouter>,
        ),
      );
    try {
      if (scenario === "transition") {
        render({ enabled: true, connected: true, recovery: "authorization_required" });
        expect(close).not.toHaveBeenCalled();
        render({ enabled: true, connected: false, recovery: "authorization_pending" });
        expect(close).not.toHaveBeenCalled();
      }
      render({ enabled: true, connected: true });
      expect(close).toHaveBeenCalledTimes(
        scenario === "transition" || scenario === "redirect" ? 1 : 0,
      );
      if (scenario === "redirect") expect(host.textContent).toBe("?settings=models&keep=1");
      render({ enabled: true, connected: true });
      expect(close).toHaveBeenCalledTimes(
        scenario === "transition" || scenario === "redirect" ? 1 : 0,
      );
    } finally {
      act(() => root.unmount());
      host.remove();
      vi.unstubAllGlobals();
    }
  },
);
