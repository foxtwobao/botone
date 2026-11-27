// The auth surface of the offline fixture server (M1 + the sign-in alignment PR): better-auth's
// credentials, email-OTP and social flows, capabilities, password reset, and get-session. The
// email drives each branch so a test needs no config endpoint; every credential here is a fake
// probe. Mounted from spike-sse-server.mjs, the server's one daemon.
import { bearer, json, rpcError } from "./fixture-http.mjs";

// The revocation log the sign-out route appends to and /__state reports; spike-sse-server's
// reset clears it through resetAuth().
export const signOuts = [];
// What the SSO and reset flows were asked for, so tests can pin the wire shape.
export const ssoStarts = [];
export const resetEmails = [];

export function resetAuth() {
  signOuts.length = 0;
  ssoStarts.length = 0;
  resetEmails.length = 0;
}

export function handleAuth(req, res, body) {
  const input = body ? JSON.parse(body) : {};
  // Routes match on the pathname alone, never the query string.
  const path = new URL(req.url, `http://${req.headers.host ?? "localhost"}`).pathname;
  if (path === "/api/auth/capabilities" && req.method === "GET") {
    return json(res, 200, {
      passwordAuth: true,
      passwordReset: true,
      resetUrl: "https://example.com/reset",
      emailCode: true,
      sso: null,
      providers: [],
    });
  }
  if (path === "/api/auth/get-session" && req.method === "GET") {
    // The SSO flow reads who its issued bearer belongs to before keeping it.
    if (bearer(req) !== "fake-token") return rpcError(res, 401, "UNAUTHORIZED", "Session expired");
    return json(res, 200, { user: { id: "user-fake" } });
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
    if (input.password === "codey") {
      // A server echoing an unknown code into the message field: the client shows its own copy.
      return json(res, 401, { code: "example_failure", message: "example_failure" });
    }
    return json(res, 401, {
      code: "INVALID_LOGIN_CREDENTIALS",
      message: "Invalid email or password",
    });
  }
  if (path === "/api/auth/sign-up/email") {
    if (String(input.email).startsWith("verify")) return json(res, 200, { token: null });
    return json(res, 200, {}, { "set-auth-token": "fake-token" });
  }
  if (path === "/api/auth/email-otp/send-verification-otp") {
    if (input.email === "slow@example.com") {
      // A send that is still in flight while a test switches servers (the race window the
      // page's staleness guard closes).
      setTimeout(() => json(res, 200, {}), 400);
      return;
    }
    return json(res, 200, {});
  }
  if (path === "/api/auth/sign-in/email-otp") {
    if (input.otp === "123456") return json(res, 200, {}, { "set-auth-token": "fake-token" });
    return json(res, 400, { code: "INVALID_OTP", message: "Invalid code" });
  }
  if (path === "/api/auth/sign-in/social") {
    ssoStarts.push({
      provider: input.provider,
      disableRedirect: input.disableRedirect === true,
      skipProxy: req.headers["x-skip-oauth-proxy"] === "true",
      callbackURL: input.callbackURL ?? "",
      errorCallbackURL: input.errorCallbackURL ?? "",
    });
    // The provider id drives the branch so a test needs no config endpoint; the good path is
    // an https authorization URL plus the state cookie the incognito jar must receive.
    if (input.provider === "insecure") {
      return json(res, 200, { url: "http://id.example.com/authorize?state=abc" });
    }
    if (input.provider === "nostate") {
      return json(
        res,
        200,
        { url: "https://id.example.com/authorize" },
        { "set-cookie": "better-auth.oauth_state=abc; Path=/" },
      );
    }
    return json(
      res,
      200,
      { url: "https://id.example.com/authorize?state=abc&client_id=fake" },
      { "set-cookie": "__Secure-better-auth.oauth_state=abc%3Adef; Path=/; HttpOnly" },
    );
  }
  if (path === "/api/auth/request-password-reset") {
    if (String(input.email) === "fail@example.com") {
      return json(res, 400, { code: "VALIDATION_ERROR", message: "[body.email] nope" });
    }
    resetEmails.push({ email: input.email, redirectTo: input.redirectTo });
    return json(res, 200, {});
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
