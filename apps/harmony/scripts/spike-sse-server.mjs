// Offline fixture server for the instrumented suites. Run on the host:
// node scripts/spike-sse-server.mjs [port]; the emulator reaches it at http://10.0.2.2:<port>.
//
// M0 S3 routes (unchanged): /sse splits one frame across writes, cutting a multi-byte UTF-8
// character mid-byte; /sse-cut closes mid-frame; a wrong Accept header is answered 400.
//
// M1 routes: a wire-format-faithful fake of the RPC/auth surface the net layer ports —
// health, me (401 by bearer/space), spaces/list, error/timeout/oversize branches, better-auth
// sign-in token shapes, capabilities, and sign-out with a delivery log at GET /__state.
// All credentials here are fake probes, never real ones.
import { createServer } from "node:http";

const port = Number(process.argv[2] ?? 8787);

// 鸿 is U+9E3F (UTF-8 E9 B8 BF); cutting after its first byte forces one character to
// span two writes, so the client must reassemble UTF-8 across chunk boundaries.
const splitFrame = Buffer.from('data: {"json":{"type":"split","seq":2,"text":"鸿蒙"}}\n\n');
const cut = splitFrame.indexOf("鸿") + 1;

const signOuts = [];
const ME = {
  userId: "user-fake",
  email: "ada@example.com",
  name: "Ada",
  spaceId: "space-fake",
  needsModel: false,
  defaultProvider: null,
  defaultModel: null,
};

function json(res, status, value, headers = {}) {
  res.writeHead(status, { "content-type": "application/json", ...headers });
  res.end(JSON.stringify(value));
}

function rpcError(res, status, code, message, headers = {}) {
  json(res, status, { json: { code, status, message } }, headers);
}

function bearer(req) {
  const header = req.headers.authorization ?? "";
  return header.startsWith("Bearer ") ? header.slice(7) : "";
}

function handleRpc(req, res, body) {
  const path = req.url;
  const token = bearer(req);
  const space = req.headers["x-rakazo-space-id"] ?? "";
  if (path === "/rpc/health") {
    const mode = req.headers["x-test-health"] ?? "ok";
    if (mode === "bad") return json(res, 200, { json: { ok: false } });
    if (mode === "error") return json(res, 200, { error: { message: "nope" } });
    if (mode === "html") {
      res.writeHead(200, { "content-type": "text/html" });
      return res.end("<html>proxy</html>");
    }
    if (mode === "404") return rpcError(res, 404, "NOT_FOUND", "Not found");
    return json(res, 200, { json: { ok: true, version: "fake-1.0.0" } });
  }
  if (path === "/rpc/me") {
    if (token !== "fake-token") return rpcError(res, 401, "UNAUTHORIZED", "Session expired");
    if (space === "space-stale") return rpcError(res, 401, "UNAUTHORIZED", "Space inaccessible");
    return json(res, 200, { json: ME });
  }
  if (path === "/rpc/spaces/list") {
    if (token !== "fake-token") return rpcError(res, 401, "UNAUTHORIZED", "Session expired");
    if (space === "space-stale") return rpcError(res, 401, "UNAUTHORIZED", "Space inaccessible");
    return json(res, 200, { json: { current: { id: "space-fake", name: "Ada’s Space" } } });
  }
  if (path === "/rpc/error500")
    return rpcError(res, 500, "INTERNAL", "Server fault", { "retry-after": "2" });
  if (path === "/rpc/update426")
    return rpcError(res, 426, "CLIENT_UPDATE_REQUIRED", "Update required");
  if (path === "/rpc/proxy502") {
    res.writeHead(502, { "content-type": "text/html" });
    return res.end("<html>bad gateway</html>");
  }
  if (path === "/rpc/notjson") {
    res.writeHead(200, { "content-type": "text/html" });
    return res.end("<html>not json</html>");
  }
  if (path === "/rpc/slow") return setTimeout(() => json(res, 200, { json: {} }), 12_000);
  if (path === "/rpc/big") return json(res, 200, { json: { pad: "x".repeat(17 * 1024 * 1024) } });
  if (path === "/rpc/echo") return json(res, 200, { json: JSON.parse(body || "{}").json ?? {} });
  return rpcError(res, 404, "NOT_FOUND", "Not found");
}

function handleAuth(req, res, body) {
  const input = body ? JSON.parse(body) : {};
  const path = req.url;
  if (path === "/api/auth/capabilities" && req.method === "GET") {
    return json(res, 200, {
      passwordAuth: true,
      passwordReset: true,
      resetUrl: "https://example.com/reset",
      emailCode: true,
      sso: null,
    });
  }
  if (req.method !== "POST") return json(res, 405, {});
  if (path === "/api/auth/sign-in/email") {
    if (input.password === "good") {
      // Header wins over the body token; both are present to pin the extraction order.
      return json(res, 200, { token: "body-token" }, { "set-auth-token": "fake-token" });
    }
    if (input.password === "cookie") {
      return json(
        res,
        200,
        {},
        { "set-cookie": "better-auth.session_token=cookie-token; Path=/; HttpOnly" },
      );
    }
    if (input.password === "body") return json(res, 200, { token: "body-token" });
    return json(res, 401, {
      code: "INVALID_LOGIN_CREDENTIALS",
      message: "Invalid email or password",
    });
  }
  if (path === "/api/auth/sign-up/email") {
    if (String(input.email).startsWith("verify")) return json(res, 200, { token: null });
    return json(res, 200, {}, { "set-auth-token": "fake-token" });
  }
  if (path === "/api/auth/email-otp/send-verification-otp") return json(res, 200, {});
  if (path === "/api/auth/sign-in/email-otp") {
    if (input.otp === "123456") return json(res, 200, {}, { "set-auth-token": "fake-token" });
    return json(res, 400, { code: "INVALID_OTP", message: "Invalid code" });
  }
  if (path === "/api/auth/sign-out") {
    const token = bearer(req);
    signOuts.push(token);
    console.log(`sign-out token=${token}`);
    if (token === "retry-token") return json(res, 500, {});
    if (token === "gone-token") return json(res, 401, {});
    return json(res, 200, {});
  }
  return json(res, 404, {});
}

function handleSse(req, res) {
  if (req.headers.accept !== "text/event-stream") {
    res.writeHead(400).end();
    return;
  }
  res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
  if (req.url === "/sse-cut") {
    res.write('data: {"json":{"type":"cut"}}\n');
    setTimeout(() => res.destroy(), 300);
    return;
  }
  if (req.url === "/sse-idle") {
    // One frame, then silence: the client's 45s idle rule must end the stream.
    res.write('data: {"json":{"type":"probe","seq":1}}\n\n');
    return;
  }
  res.write('data: {"json":{"type":"probe","seq":1}}\n\n');
  setTimeout(() => {
    res.write(splitFrame.subarray(0, cut));
    setTimeout(() => {
      res.write(splitFrame.subarray(cut));
      res.write('data: {"json":{"type":"heartbeat"}}\n\n');
      setTimeout(() => {
        res.write('data: {"json":{"type":"done"}}\n\n');
        res.end();
      }, 300);
    }, 200);
  }, 200);
}

createServer((req, res) => {
  let body = "";
  req.on("data", (chunk) => {
    body += chunk;
  });
  req.on("end", () => {
    console.log(`${req.method} ${req.url}`);
    if (req.url === "/__state") {
      return json(res, 200, { signOuts });
    }
    if (req.url === "/__reset") {
      signOuts.length = 0;
      return json(res, 200, {});
    }
    if (req.url.startsWith("/rpc/")) return handleRpc(req, res, body);
    if (req.url.startsWith("/api/auth/")) return handleAuth(req, res, body);
    if (req.url.startsWith("/sse")) {
      if (req.method !== "POST") {
        res.writeHead(405).end();
        return;
      }
      return handleSse(req, res);
    }
    res.writeHead(404).end();
  });
}).listen(port, () => console.log(`fixture server on :${port}`));
