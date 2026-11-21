// S3 spike source: a minimal SSE-over-POST server for the requestInStream smoke test.
// Run on the host: node scripts/spike-sse-server.mjs [port]; the emulator reaches it at
// http://10.0.2.2:<port>. /sse splits one frame across writes; /sse-cut closes mid-frame.
import { createServer } from "node:http";

const port = Number(process.argv[2] ?? 8787);

createServer((req, res) => {
  if (req.method !== "POST") {
    res.writeHead(405).end();
    return;
  }
  let body = "";
  req.on("data", (chunk) => {
    body += chunk;
  });
  req.on("end", () => {
    console.log(`${req.url} body=${body}`);
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
    if (req.url === "/sse-cut") {
      res.write('data: {"json":{"type":"cut"}}\n');
      setTimeout(() => res.destroy(), 300);
      return;
    }
    res.write('data: {"json":{"type":"probe","seq":1}}\n\n');
    setTimeout(() => {
      res.write('data: {"json":{"type":"split"');
      setTimeout(() => {
        res.write(',"seq":2}}\n\n');
        res.write('data: {"json":{"type":"heartbeat"}}\n\n');
        setTimeout(() => {
          res.write('data: {"json":{"type":"done"}}\n\n');
          res.end();
        }, 300);
      }, 200);
    }, 200);
  });
}).listen(port, () => console.log(`SSE spike server on :${port}`));
