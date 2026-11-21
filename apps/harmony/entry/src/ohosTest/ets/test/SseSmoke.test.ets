// S3 spike: requestInStream against a local SSE source (scripts/spike-sse-server.mjs on the
// host, reached through the emulator's QEMU gateway 10.0.2.2). Records chunk boundaries,
// POST framing and abrupt-close behavior; conclusions live in docs/m0-spike.md.
// The server cuts a multi-byte UTF-8 character mid-byte across two writes, so the
// reassembled text proves streaming decode across chunk boundaries, not just chunk counts.
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { describe, expect, it } from '@ohos/hypium';

const BASE = 'http://10.0.2.2:8787';
const DOMAIN = 0x0000;

interface Capture {
  code: number;
  chunkSizes: number[];
  text: string;
}

function streamOnce(path: string, accept: string = 'text/event-stream'): Promise<Capture> {
  const request = http.createHttp();
  const decoder = util.TextDecoder.create('utf-8');
  const capture: Capture = { code: 0, chunkSizes: [], text: '' };
  request.on('dataReceive', (data: ArrayBuffer) => {
    capture.chunkSizes.push(data.byteLength);
    capture.text += decoder.decodeToString(new Uint8Array(data), { stream: true });
  });
  // dataEnd can fire before the requestInStream promise delivers the status code,
  // so wait for both rather than reading the code inside the dataEnd callback.
  const ended = new Promise<void>((resolve: Function) => {
    request.on('dataEnd', () => resolve());
  });
  const coded = request.requestInStream(`${BASE}${path}`, {
    method: http.RequestMethod.POST,
    header: { 'content-type': 'application/json', 'accept': accept },
    extraData: '{"json":{}}',
    connectTimeout: 8000,
    readTimeout: 15000,
  }).then((code: number) => {
    capture.code = code;
  });
  return Promise.all([ended, coded]).then((): Capture => {
    request.destroy();
    return capture;
  });
}

export default function sseSmoke() {
  describe('SseSmoke', () => {
    it('post_streams_lf_frames_and_split_chunks', 0, async () => {
      const capture = await streamOnce('/sse');
      hilog.info(DOMAIN, 'S3', 'code=%{public}d chunks=%{public}s', capture.code,
        JSON.stringify(capture.chunkSizes));
      hilog.info(DOMAIN, 'S3', 'text=%{public}s', capture.text);
      expect(capture.code).assertEqual(200);
      expect(capture.text).assertContain('data: {"json":{"type":"probe","seq":1}}');
      // The server cuts 鸿 (E9 B8 BF) after its first byte across two writes: the full
      // frame below only reassembles if streaming UTF-8 decode spans chunk boundaries.
      expect(capture.text).assertContain('data: {"json":{"type":"split","seq":2,"text":"鸿蒙"}}');
      expect(capture.text).assertContain('data: {"json":{"type":"heartbeat"}}');
      expect(capture.text).assertContain('data: {"json":{"type":"done"}}');
      expect(capture.text.includes('\uFFFD')).assertFalse();
      expect(capture.chunkSizes.length > 0).assertTrue();
    });

    it('wrong_accept_header_is_rejected', 0, async () => {
      const capture = await streamOnce('/sse', 'application/json');
      expect(capture.code).assertEqual(400);
    });

    it('abrupt_close_rejects_partial_transfer', 0, async () => {
      const request = http.createHttp();
      const decoder = util.TextDecoder.create('utf-8');
      const chunkSizes: number[] = [];
      let text = '';
      request.on('dataReceive', (data: ArrayBuffer) => {
        chunkSizes.push(data.byteLength);
        text += decoder.decodeToString(new Uint8Array(data), { stream: true });
      });
      let message = '';
      try {
        await request.requestInStream(`${BASE}/sse-cut`, {
          method: http.RequestMethod.POST,
          header: { 'content-type': 'application/json', 'accept': 'text/event-stream' },
          extraData: '{"json":{}}',
          connectTimeout: 8000,
          readTimeout: 15000,
        });
      } catch (err) {
        message = (err as Error).message;
      }
      request.destroy();
      hilog.info(DOMAIN, 'S3', 'cut error=%{public}s chunks=%{public}s text=%{public}s',
        message, JSON.stringify(chunkSizes), text);
      // Observed on API 26 Beta1: an abrupt close rejects the requestInStream promise
      // (curl "Transferred a partial file"); the realtime layer must treat it as a disconnect.
      expect(message).assertContain('partial');
    });
  });
}
