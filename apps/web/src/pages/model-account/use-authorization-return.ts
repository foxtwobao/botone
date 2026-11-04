import type { ModelAccountStatus } from "@rakazo/contracts";
import { modelAccountAuthorizationReason } from "@rakazo/core";
import { useEffect, useRef } from "react";
import { useSearchParams } from "react-router-dom";

export const AUTHORIZATION_RETURN_PARAM = "modelAccountAuthorization";

/** Remember a full-page authorization return without closing ordinary model settings. */
export function useAuthorizationReturn(
  status: ModelAccountStatus | undefined,
  onClose: () => void,
) {
  const [params, setParams] = useSearchParams();
  const needed = useRef(false);
  const complete = useRef(false);
  const closed = useRef(false);
  useEffect(() => {
    if (!status || closed.current) return;
    if (modelAccountAuthorizationReason(status)) {
      needed.current = true;
      return;
    }
    if (!status.connected) return;
    if (
      needed.current ||
      (params.has(AUTHORIZATION_RETURN_PARAM) && !params.has("modelAccountError"))
    )
      complete.current = true;
    if (!complete.current) return;
    if (params.has(AUTHORIZATION_RETURN_PARAM)) {
      const next = new URLSearchParams(params);
      next.delete(AUTHORIZATION_RETURN_PARAM);
      setParams(next, { replace: true });
      return;
    }
    closed.current = true;
    onClose();
  }, [onClose, params, setParams, status]);
}
