// Outbox fixture controls (B3): the failure script the threads/send handler consults, and the
// dropped-response arm that emulates a server that committed a send but whose response never
// arrived. Lives here to keep spike-sse-server.mjs at its size.
import { json } from "./fixture-http.mjs";

// The next threads/send answers with this {status, code, message} instead of running (a 429
// rate limit, a 403 refusal, a 500 fault). One shot: taken on the first send.
let sendFailure = null;

// The next threads/send commits fully (events pushed, receipt deduplicated) but destroys the
// connection instead of answering, so the client sees a transport error for a durable send.
let dropNextSendResponse = false;

export function resetOutbox() {
  sendFailure = null;
  dropNextSendResponse = false;
}

/** The failure spec the next threads/send must answer with, or null. */
export function takeSendFailureSpec() {
  const spec = sendFailure;
  sendFailure = null;
  return spec;
}

/** True when the next threads/send must commit and then drop its response. */
export function takeDropSendResponse() {
  const drop = dropNextSendResponse;
  dropNextSendResponse = false;
  return drop;
}

/** The fixture's control route; false when the request is not one of them. */
export function handleOutboxControl(req, res, body) {
  if (req.url === "/__outboxControl") {
    const input = JSON.parse(body || "{}");
    sendFailure = input.failNextSend ?? null;
    json(res, 200, { ok: true });
    return true;
  }
  if (req.url === "/__threadDropSendResponse") {
    dropNextSendResponse = true;
    json(res, 200, { ok: true });
    return true;
  }
  return false;
}
