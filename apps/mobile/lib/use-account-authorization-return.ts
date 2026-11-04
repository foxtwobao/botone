import type { ModelAccountStatus } from "@rakazo/contracts";
import { modelAccountAuthorizationReason } from "@rakazo/core";
import { useRouter } from "expo-router";
import { useEffect, useRef } from "react";

/** Return through the existing stack, or Home when setup was the app's first screen. */
export function useAccountAuthorizationReturn(status: ModelAccountStatus | undefined) {
  const router = useRouter();
  const needed = useRef(false);
  useEffect(() => {
    if (!status) return;
    if (modelAccountAuthorizationReason(status)) {
      needed.current = true;
      return;
    }
    if (!status.connected || !needed.current) return;
    needed.current = false;
    if (router.canGoBack()) router.back();
    else router.replace("/");
  }, [router, status]);
}
