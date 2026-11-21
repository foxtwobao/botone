// S3 spike source: a minimal SSE-over-POST server for the requestInStream smoke test.
// Run on the host: node scripts/spike-sse-server.mjs [port]; the emulator reaches it at
// http://10.0.2.2:<port>. /sse splits one frame across writes, cutting a multi-byte
// UTF-8 character mid-byte; /sse-cut closes mid-frame. Requests without
// Accept: text/event-stream are answered with 400.
import { createServer } from "node:http";

const port = Number(process.argv[2] ?? 8787);

// 鸿 is U+9E3F (UTF-8 E9 B8 BF); cutting after its first byte forces one character to
// span two writes, so the client must reassemble UTF-8 across chunk boundaries.
const splitFrame = Buffer.from('data: {"json":{"type":"split","seq":2,"text":"鸿蒙"}}\n\n');
const cut = splitFrame.indexOf("鸿") + 1;

createServer((req, res) => {
  if (req.method !== "POST") {
    res.writeHead(405).end();
    return;
  }
  if (req.headers.accept !== "text/event-stream") {
    res.writeHead(400).end();
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
  });
}).listen(port, () => console.log(`SSE spike server on :${port}`));
