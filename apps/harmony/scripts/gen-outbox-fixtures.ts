// Layer-2 fixture generator for the outbox (B3): the send-failure classification as mobile
// thread-feedback.ts:434-447 decides it. REPLICATED, not imported: the real function closes over
// module state (screens, echoes, session pins) and React bindings, so it cannot run standalone;
// the quoted branch below is pinned to those source lines and the two helpers it calls (core's
// isServerUnreachable / isModelRequiredSendError) are imported for real. The ArkTS port replays
// these rows under hypium. The limits are mobile's pinned values (thread-feedback.ts:173,
// outbox-disk.ts:77); the port test asserts the port's constants equal them.
import { isModelRequiredSendError, isServerUnreachable } from "@rakazo/core";

/** The error shape the classification reads: mobile's rpc errors carry status, a cause chain,
 *  a TimeoutError name for timeouts, and network-failure codes for transport loss. */
interface FakeSendError {
  status?: number;
  message: string;
  name?: string;
  code?: string;
  cause?: { status: number };
}

function makeError(spec: FakeSendError): Error {
  const error = new Error(spec.message);
  if (spec.name !== undefined) error.name = spec.name;
  if (spec.code !== undefined) (error as { code?: string }).code = spec.code;
  if (spec.status !== undefined) (error as { status?: number }).status = spec.status;
  if (spec.cause !== undefined) {
    (error as { cause?: unknown }).cause = spec.cause;
  }
  return error;
}

interface SendCaseSpec {
  name: string;
  status?: number;
  transport?: boolean;
  timedOut?: boolean;
  message?: string;
  causeStatus?: number;
}

/** thread-feedback.ts:434-447 verbatim (minus the password-change clause, which HarmonyOS has
 *  no flow for yet): offline → queued; a 4xx the server meant for this message and no missing
 *  model → refused; everything else retryable → failed. */
function classifyMobile(error: Error, sendStatus: number | undefined): string {
  const status = (error as { status?: number }).status;
  const offline = isServerUnreachable(error) || sendStatus === 429;
  return offline
    ? "queued"
    : !isModelRequiredSendError(error) &&
        status &&
        status >= 400 &&
        status < 500 &&
        ![408, 409, 425, 426, 429].includes(status)
      ? "refused"
      : "failed";
}

const CASES: SendCaseSpec[] = [
  { name: "transport-lost", transport: true },
  { name: "timeout", timedOut: true },
  { name: "gateway-502", status: 502 },
  { name: "gateway-503", status: 503 },
  { name: "gateway-504", status: 504 },
  { name: "rate-limited-429", status: 429 },
  { name: "unauthorized-401", status: 401 },
  { name: "forbidden-403", status: 403 },
  { name: "bad-request-400", status: 400 },
  { name: "timeout-status-408", status: 408 },
  { name: "conflict-409", status: 409 },
  { name: "conflict-409-image", status: 409, message: "This model cannot read images." },
  { name: "teaching-425", status: 425 },
  { name: "update-426", status: 426 },
  { name: "server-fault-500", status: 500 },
  { name: "server-fault-501", status: 501 },
  { name: "no-response" },
  { name: "cause-status-500", causeStatus: 500 },
  { name: "model-required-400", status: 400, message: "Connect a model to start a run." },
  { name: "model-required-403", status: 403, message: "Connect a model to start a run." },
];

export function generateOutboxFixture() {
  const classify = CASES.map((spec) => {
    const error = makeError({
      status: spec.status,
      message: spec.message ?? "",
      name: spec.timedOut ? "TimeoutError" : undefined,
      code: spec.transport ? "ECONNRESET" : undefined,
      cause: spec.causeStatus !== undefined ? { status: spec.causeStatus } : undefined,
    });
    const mobileStatus = (error as { status?: number }).status;
    const sendStatus = mobileStatus ?? (error as { cause?: { status?: number } }).cause?.status;
    // The port's RpcError carries one numeric status (0 when no response arrived) and boolean
    // transport/timedOut flags, so the row records what the port feeds its classifier.
    const portStatus = mobileStatus ?? sendStatus ?? 0;
    return {
      name: spec.name,
      status: portStatus,
      transport: spec.transport === true,
      timedOut: spec.timedOut === true,
      message: spec.message ?? "",
      expected: classifyMobile(error, sendStatus),
    };
  });
  return {
    constants: { maxEntries: 20, maxBytes: 50 * 1024 * 1024 },
    classify,
  };
}
