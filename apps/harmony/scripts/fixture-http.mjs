// Response helpers shared by the fixture server's modules.
export function json(res, status, value, headers = {}) {
  res.writeHead(status, { "content-type": "application/json", ...headers });
  res.end(JSON.stringify(value));
}

export function rpcError(res, status, code, message, headers = {}) {
  json(res, status, { json: { code, status, message } }, headers);
}

export function bearer(req) {
  const header = req.headers.authorization ?? "";
  return header.startsWith("Bearer ") ? header.slice(7) : "";
}
