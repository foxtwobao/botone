// The voice surface of the offline fixture server (M7): the RPCs the Voice settings page reads
// and writes, voice/prepare, and the two /api/voice routes with a byte body. Every provider id,
// key and voice here is a fake probe. Mounted from spike-sse-server.mjs, the server's one daemon.
import { bearer, json, rpcError } from "./fixture-http.mjs";

let state = null;

/** A silent clip a few seconds long: a real player has something to hold, and a bar something
 *  to show while it plays. 8-bit mono at 8 kHz. */
function clipBytes() {
  const frames = 24_000;
  const wav = Buffer.alloc(44 + frames);
  wav.write("RIFF", 0);
  wav.writeUInt32LE(wav.length - 8, 4);
  wav.write("WAVEfmt ", 8);
  wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20);
  wav.writeUInt16LE(1, 22);
  wav.writeUInt32LE(8_000, 24);
  wav.writeUInt32LE(8_000, 28);
  wav.writeUInt16LE(1, 32);
  wav.writeUInt16LE(8, 34);
  wav.write("data", 36);
  wav.writeUInt32LE(frames, 40);
  wav.fill(0x80, 44);
  return wav;
}

export function resetVoice() {
  // An answer an earlier case left held still goes out, to a client that may be waiting for it.
  state?.releaseTranscribe?.();
  state = {
    connected: false,
    selfHosted: false,
    selfHostedUrl: "",
    voiceId: "",
    speechModel: "",
    // How many /api/voice/speak answers still work; null never fails.
    speechesLeft: null,
    transcribeText: "Fake dictated words",
    transcriptionFails: false,
    // The next transcription answer is held in flight until the suite releases it.
    holdNextTranscribe: false,
    releaseTranscribe: null,
    requests: [],
  };
}

const CATALOG = [
  {
    id: "fake-voice",
    name: "Fake Voice",
    description: "A fake hosted voice",
    transcribe: false,
    speechModel: true,
  },
  {
    id: "openai-compatible",
    name: "Self-hosted",
    description: "Any OpenAI-compatible speech server",
    transcribe: true,
    freeformVoice: true,
  },
];

const VOICES = [
  { id: "fake-voice-1", label: "Fake Voice One" },
  { id: "fake-voice-2", label: "Fake Voice Two" },
];

function credential() {
  return {
    id: "fake-credential",
    provider: state.selfHosted === true ? "openai-compatible" : "fake-voice",
    hasKey: true,
    isDefault: true,
    voiceId: state.voiceId,
    speechModel: state.speechModel,
    transcribe: state.selfHosted === true,
    endpoint: state.selfHosted === true ? (state.selfHostedUrl ?? "") : "",
    sttEndpoint: "",
    ttsModel: "",
    sttModel: "",
  };
}

function status() {
  return {
    configured: state.connected,
    ready: state.connected && Boolean(state.voiceId),
    // Only the self-hosted protocol transcribes in this fixture.
    transcribe: state.selfHosted === true,
    provider: state.connected
      ? state.selfHosted === true
        ? "openai-compatible"
        : "fake-voice"
      : null,
    voiceId: state.voiceId,
  };
}

/** The voice/* RPCs; true when this route answered. */
export function handleVoiceRpc(req, res, body) {
  if (!req.url.startsWith("/rpc/voice/")) return false;
  if (bearer(req) !== "fake-token") {
    rpcError(res, 401, "UNAUTHORIZED", "Session expired");
    return true;
  }
  const input = JSON.parse(body || "{}").json ?? {};
  state.requests.push({ path: req.url, input });
  switch (req.url) {
    case "/rpc/voice/catalog":
      json(res, 200, { json: CATALOG });
      return true;
    case "/rpc/voice/status":
      json(res, 200, { json: status() });
      return true;
    case "/rpc/voice/credentials":
      json(res, 200, { json: state.connected ? [credential()] : [] });
      return true;
    case "/rpc/voice/voices":
      json(res, 200, { json: VOICES });
      return true;
    case "/rpc/voice/connect":
      if (input.provider === "openai-compatible" && !String(input.baseUrl ?? "").trim()) {
        rpcError(res, 400, "BAD_REQUEST", "Enter a server URL.");
        return true;
      }
      state.connected = true;
      state.selfHosted = input.provider === "openai-compatible";
      state.selfHostedUrl = state.selfHosted === true ? String(input.baseUrl ?? "") : "";
      state.voiceId = String(input.voiceId ?? "") || "fake-voice-1";
      state.speechModel = String(input.speechModel ?? "");
      json(res, 200, { json: credential() });
      return true;
    case "/rpc/voice/disconnect":
      state.connected = false;
      state.voiceId = "";
      json(res, 200, { json: { ok: true } });
      return true;
    case "/rpc/voice/setVoice":
      state.voiceId = String(input.voiceId ?? "");
      json(res, 200, { json: status() });
      return true;
    case "/rpc/voice/setSpeechModel":
      state.speechModel = String(input.speechModel ?? "");
      json(res, 200, { json: credential() });
      return true;
    case "/rpc/voice/prepare": {
      const ready = status().ready;
      const utterances = ready
        ? String(input.text ?? "")
            .split(/(?<=[.!?。！？])\s*/u)
            .map((piece) => piece.trim())
            .filter(Boolean)
        : [];
      json(res, 200, { json: { ready, utterances } });
      return true;
    }
    default:
      rpcError(res, 404, "NOT_FOUND", "Not found");
      return true;
  }
}

/** The two /api/voice routes: JSON in, JSON or bytes out; true when this route answered. */
export function handleVoiceHttp(req, res, body) {
  if (req.url !== "/api/voice/speak" && req.url !== "/api/voice/transcribe") return false;
  if (bearer(req) !== "fake-token") {
    res.writeHead(401, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "Unauthorized" }));
    return true;
  }
  let input = {};
  try {
    input = JSON.parse(body || "{}");
  } catch {
    input = {};
  }
  state.requests.push({ path: req.url, input });
  if (req.url === "/api/voice/speak") {
    if (state.speechesLeft !== null) {
      if (state.speechesLeft <= 0) {
        res.writeHead(402, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: "Voice unavailable", code: "VOICE_OUT_OF_CREDIT" }));
        return true;
      }
      state.speechesLeft -= 1;
    }
    res.writeHead(200, { "content-type": "audio/wav", "cache-control": "no-store" });
    res.end(clipBytes());
    return true;
  }
  if (state.transcriptionFails) {
    res.writeHead(500, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "Could not transcribe that." }));
    return true;
  }
  if (!String(input.audioBase64 ?? "").trim()) {
    res.writeHead(400, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "Recording is empty." }));
    return true;
  }
  const answer = () => {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ text: state.transcribeText }));
  };
  // A held answer stays in flight until the suite releases it.
  if (state.holdNextTranscribe) {
    state.holdNextTranscribe = false;
    state.releaseTranscribe = answer;
    return true;
  }
  answer();
  return true;
}

/** The controls the suites script and read back: fake probes only. */
export function handleVoiceControl(req, res, body) {
  if (req.url === "/__voiceReset") {
    resetVoice();
    json(res, 200, { ok: true });
    return true;
  }
  if (req.url === "/__voiceState") {
    json(res, 200, {
      connected: state.connected,
      voiceId: state.voiceId,
      speechModel: state.speechModel,
      // The requests in arrival order, and what each of them carried.
      requests: state.requests.map((entry) => entry.path),
      inputs: state.requests.map((entry) => entry.input),
    });
    return true;
  }
  if (req.url === "/__voiceScript") {
    const input = body ? JSON.parse(body) : {};
    if (typeof input.speeches === "number") state.speechesLeft = input.speeches;
    if (typeof input.transcribeText === "string") state.transcribeText = input.transcribeText;
    if (typeof input.transcriptionFails === "boolean") {
      state.transcriptionFails = input.transcriptionFails;
    }
    if (input.holdTranscribe === true) state.holdNextTranscribe = true;
    if (input.releaseTranscribe === true) {
      const release = state.releaseTranscribe;
      state.releaseTranscribe = null;
      release?.();
    }
    json(res, 200, { ok: true });
    return true;
  }
  return false;
}

resetVoice();
