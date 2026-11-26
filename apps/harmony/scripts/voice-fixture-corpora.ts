// The voice fixture's corpora (M7): the inputs each recorded section runs on — the speakable
// and utterance texts, the locale and speaker tags, the auto-speak and plan inputs, the bot-voice
// listings, the assignment pools and the block-speech cases. Dev-time code: nothing here ships.

export const SPEAKABLE_DOCS = [
  "",
  " ",
  "Plain sentence. Another one! Is it?",
  "e.g. one. Two! Next?",
  "```ts\nconst a = 1;\nconsole.log(a);\n```",
  "```python\nprint('hi')\n```",
  "```\nplain\n```",
  "```js\nunfinished",
  "~~~sh\necho hi\n~~~",
  "![alt text](https://example.test/a.png) next ![x](img.png) last ![](https://example.test/b.png)",
  "[label](https://example.test) and <https://example.test/x> then https://example.test/y?z=1 http://a.test/c.",
  "| a | b |\n| --- | --- |\n| 1 | 2 |\n\nafter",
  "| a | b |\n|---|---|\n| 1 | 2 |",
  "Use `npm install` now and `this inline code is far longer than forty characters, for sure` ok",
  "# Heading one\n## Heading two!\n####### seven\n### 3.5",
  "---\n***\n___\ntext",
  "- item one\n* item two\n+ item three\n1. first\n2) second\n> quoted line\n>another",
  "**bold** and __strong__ and *em* and _em_ and snake_case and 2*3 and a*b*c and * unclosed",
  "~~gone~~ stays",
  "- [ ] open task\n- [x] done task",
  "See src/a/b/file.ts and a/very/long/path/x.ts and /usr/bin/node and package.json",
  "emoji \u{1F600} → ✓ ✔️ done",
  "line one\nline two\n\n\nline three",
  "spaces   before , and . punctuation  , . ",
  "中文句子。第二句！第三句？3．5元",
  "日本語の文。次の文！",
  "混合 mix 中英 words.",
  "e.g. i.e. etc. vs. Dr. Mr. Mrs. Ms. No. approx. end",
  "3.14 and 1,000.50",
  "```ts\nconst a = 1;\n``` after code",
  "a\n```\nb\n```\nc",
  "*starts* mid*dle* **both**",
  "a_b_c and a _b_ c and (_x_) and 2_3",
  "x https://example.test.\n| table |\n|---|\n| cell |",
  "- [ ] no space",
  `a very long path ${"segment/".repeat(90)}file.txt end`,
];

export function utteranceInputs(): string[] {
  return [
    "",
    "Ok.",
    "Ok. Yes. Sure.",
    "Ok. Yes. Sure. This is a much longer sentence that stands entirely on its own here.",
    "第一句。第二句。",
    "第一句。第二句。这是一句很长很长的话，足够单独成段。",
    "Mixed. 中英混排。 And more.",
    "a".repeat(400),
    "中".repeat(350),
    "\u{1F600}".repeat(200),
    `a\u{1F600}`.repeat(200),
    "e\u0301".repeat(200),
    "\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}".repeat(40),
    "\u{1F1E8}\u{1F1F3}".repeat(100),
    "\u{0915}\u{094D}\u200D\u{0937}".repeat(110),
    "one, two, three, four, five, six, seven, eight, nine, ten, eleven, twelve, thirteen, fourteen, fifteen, sixteen",
    "one; two; three; four; five; six; seven; eight; nine; ten; eleven; twelve; thirteen; fourteen; fifteen; sixteen",
    "one — two — three — four — five — six — seven — eight — nine — ten — eleven — twelve — thirteen",
    `${"word ".repeat(70)}end`,
    `${"词".repeat(200)}。${"another ".repeat(40)}`,
  ];
}

export function blockSpeechCases(): { blocks: unknown[]; expected: string }[] {
  return [
    { blocks: [], expected: "" },
    { blocks: [{ kind: "text", text: "Hello there" }], expected: "Hello there" },
    { blocks: [{ kind: "steps", steps: [{ label: "Reading", count: 2 }] }], expected: "" },
    {
      blocks: [
        { kind: "progress", text: "Running a command", activity: true },
        { kind: "progress", text: "Here is what I found." },
      ],
      expected: "Here is what I found.",
    },
    { blocks: [{ kind: "meta", text: "meta line" }], expected: "meta line" },
    {
      blocks: [{ kind: "ask", text: "Allow access?", detail: "details" }],
      expected: "Allow access?",
    },
    {
      blocks: [
        { kind: "cloud_agent", title: "Agent", status: "running", prUrl: "https://example.test/1" },
      ],
      expected: "Agent: running https://example.test/1",
    },
    { blocks: [{ kind: "cloud_agent", title: "Agent", status: "done" }], expected: "Agent: done" },
    { blocks: [{ kind: "computer", text: "Screen shared" }], expected: "Screen shared" },
    {
      blocks: [{ kind: "subagent", name: "Helper", status: "running", task: "explore the repo" }],
      expected: "Helper is working on explore the repo",
    },
    { blocks: [{ kind: "subagent", name: "Helper", status: "failed" }], expected: "Helper failed" },
    {
      blocks: [{ kind: "subagent", name: "Helper", status: "done", result: "All good" }],
      expected: "All good",
    },
    { blocks: [{ kind: "subagent", name: "Helper", status: "done" }], expected: "Helper finished" },
    {
      blocks: [
        {
          kind: "card",
          lines: [
            { k: "Files", v: "3" },
            { k: "Size", v: "1 MB" },
          ],
        },
      ],
      expected: "Files: 3. Size: 1 MB",
    },
    {
      blocks: [{ kind: "image", artifactId: "a1", name: "a.png", mimeType: "image/png" }],
      expected: "",
    },
    {
      blocks: [
        { kind: "steps", steps: [{ label: "Thinking", count: 1 }] },
        { kind: "text", text: "First" },
        { kind: "card", lines: [{ k: "k", v: "v" }] },
        { kind: "text", text: "   " },
        { kind: "file", artifactId: "a2", name: "a.txt", mimeType: "text/plain", size: 3 },
      ],
      expected: "First\nk: v\n   ",
    },
  ];
}

export const SPEAKERS: Array<string | null | undefined> = [
  undefined,
  null,
  "",
  " ",
  "es_ar",
  "en-US-u-mu-celsius",
  "zh-Hant-TW",
  "de",
  "de-AT",
  "es-419",
  "fr-CA",
  "en-GB",
  "pt",
  "pt-br",
  "ja-JP",
  "hi-IN",
  "en",
  "es",
  "FR-fr",
  "tr",
  "xx-YY",
  "zh",
  "zh-CN",
  "EN-us",
  "es-419-x-foo",
  "he-IL-u-ca-hebrew",
  "pt_PT",
  "en-oxendict",
  "de-1996",
];
export const SPEECH_LOCALES = [
  "en",
  "de",
  "es",
  "fr",
  "he",
  "hi",
  "ja",
  "ko",
  "nl",
  "pl",
  "pt-BR",
  "ru",
  "th",
  "tr",
  "zh-CN",
  "zh-TW",
];
export const SUPPORTED = [
  [],
  ["zh-CN"],
  ["en-US", "en-GB"],
  ["es-ES", "es-MX"],
  ["de-DE"],
  ["en-US", "es-MX", "zh-CN", "fr-FR", "fr-CA"],
  ["en-us", "ES-mx"],
  ["es-419"],
];

type SpeechLocale = Parameters<typeof core.speechLocaleTag>[0];

export function autoSpeakInputs() {
  const text = (id: string, body: string) => ({
    id,
    role: "bot" as const,
    blocks: [{ kind: "text" as const, text: body }],
  });
  const base = {
    botId: "bot-1",
    autoSpeak: true,
    callActive: false,
    focused: true,
    snapshotReady: true,
    lastSpokenBotId: "bot-1" as string | null,
    lastSpokenMessageId: "msg-1" as string | null,
    runStatus: "completed" as string | null,
    messages: [text("msg-1", "Earlier."), text("msg-2", "Hello from the bot.")],
  };
  return [
    {
      name: "opening a bot seeds the latest reply",
      input: { ...base, lastSpokenBotId: null, lastSpokenMessageId: null },
    },
    { name: "waits until the snapshot is this bot's", input: { ...base, snapshotReady: false } },
    { name: "seeds while auto-speak is off", input: { ...base, autoSpeak: false } },
    { name: "waits while not focused", input: { ...base, focused: false } },
    { name: "waits while a run is in flight: running", input: { ...base, runStatus: "running" } },
    { name: "waits while a run is in flight: queued", input: { ...base, runStatus: "queued" } },
    { name: "waits while a run is in flight: leased", input: { ...base, runStatus: "leased" } },
    { name: "seeds while a call is active", input: { ...base, callActive: true } },
    {
      name: "seeds while a call is active even with a run in flight",
      input: { ...base, callActive: true, runStatus: "running" },
    },
    { name: "speaks a finished reply not spoken yet", input: base },
    {
      name: "does not speak the same reply twice",
      input: { ...base, lastSpokenMessageId: "msg-2" },
    },
    {
      name: "marks an empty reply spoken without playing it",
      input: { ...base, messages: [text("msg-2", "   ")] },
    },
    {
      name: "no messages at all",
      input: { ...base, lastSpokenBotId: null, lastSpokenMessageId: null, messages: [] },
    },
    {
      name: "the last message is the user's",
      input: {
        ...base,
        messages: [
          text("msg-1", "Earlier."),
          { id: "msg-3", role: "user", blocks: [{ kind: "text", text: "Question" }] },
        ],
      },
    },
    { name: "no run status", input: { ...base, runStatus: null, lastSpokenMessageId: "msg-1" } },
    {
      name: "a tool-only reply",
      input: {
        ...base,
        messages: [
          text("msg-1", "Earlier."),
          {
            id: "msg-2",
            role: "bot",
            blocks: [{ kind: "steps", steps: [{ label: "Thinking", count: 1 }] }],
          },
        ],
      },
    },
  ];
}

export function planInputs() {
  const out: {
    name: string;
    purpose: "call" | "dictation";
    device: "on" | "off" | "throws";
    available: boolean;
    status: "ready" | "transcribes" | "neither" | "transcribe only" | "fails";
    ready: boolean;
    transcribe: boolean;
  }[] = [];
  const statuses = [
    ["ready", true, false],
    ["transcribes", true, true],
    ["neither", false, false],
    ["transcribe only", false, true],
  ] as const;
  for (const purpose of ["call", "dictation"] as const) {
    for (const device of ["on", "off", "throws"] as const) {
      for (const available of [true, false]) {
        for (const [status, ready, transcribe] of statuses) {
          out.push({
            name: `${purpose}, device ${device}, recognizer ${available}, ${status}`,
            purpose,
            device,
            available,
            status,
            ready,
            transcribe,
          });
        }
      }
    }
  }
  out.push(
    {
      name: "dictation, device on, recognizer off, status fails",
      purpose: "dictation",
      device: "on",
      available: false,
      status: "fails",
      ready: false,
      transcribe: false,
    },
    {
      name: "call, device off, recognizer on, status fails",
      purpose: "call",
      device: "off",
      available: true,
      status: "fails",
      ready: false,
      transcribe: false,
    },
  );
  return out;
}

export function botVoiceCases() {
  const voice = (identifier: string, language: string, over: Record<string, unknown> = {}) => ({
    identifier,
    language,
    ...over,
  });
  return [
    {
      name: "android keeps only explicitly local voices",
      platform: "android" as const,
      locale: "en-US",
      region: null,
      voices: [
        voice("en-US-language", "en-US"),
        voice("en-us-x-iob-network", "en-US"),
        voice("en-us-x-iob-local", "en-US"),
        voice("remote-local", "en-US", { localService: false }),
        voice("requires-local", "en-US", { requiresNetwork: true }),
        voice("network-local", "en-US"),
        voice("named-local", "en-US", { name: "Network voice" }),
      ],
      bots: ["bot-a"],
    },
    {
      name: "novelty names are left out",
      platform: "ios" as const,
      locale: "en-US",
      region: null,
      voices: ["Bubbles", "Zarvox", "Bad News", "Bells", "Albert", "Junior", "Ralph"].map((name) =>
        voice(`com.apple.voice.${name}`, "en-US"),
      ),
      bots: ["bot-a"],
    },
    {
      name: "the device language decides, not the interface language",
      platform: "ios" as const,
      locale: "de-DE",
      region: "DE",
      voices: [voice("english", "en-US"), voice("german", "de-DE")],
      bots: ["bot-a"],
    },
    {
      name: "neither a network voice nor one for another language",
      platform: "ios" as const,
      locale: "en-US",
      region: "US",
      voices: [voice("en-us-x-iob-network", "en-US"), voice("de-de-x-deb-local", "de-DE")],
      bots: ["bot-a"],
    },
    {
      name: "four voices for six bots, then a bot returning keeps its voice",
      platform: "ios" as const,
      locale: "en-US",
      region: "US",
      voices: [
        voice("en-us-x-iob-local", "en-US"),
        voice("en-us-x-iog-local", "en-US"),
        voice("en-us-x-iol-local", "en-US"),
        voice("en-us-x-iom-local", "en-US"),
      ],
      bots: ["bot-a", "bot-b", "bot-c", "bot-d", "bot-e", "bot-f", "bot-a"],
    },
    {
      name: "the device's own region first, then the language's main region",
      platform: "ios" as const,
      locale: "es-AR",
      region: "AR",
      voices: [voice("es-es-1", "es-ES"), voice("es-mx-1", "es-MX"), voice("es-us-1", "es-US")],
      bots: ["bot-a", "bot-b"],
    },
    {
      name: "a higher-quality voice is handed out first",
      platform: "ios" as const,
      locale: "en-US",
      region: "US",
      voices: [
        voice("en-us-x-iob-local", "en-US", { quality: "Default" }),
        voice("en-us-x-iog-local", "en-US", { quality: "Enhanced" }),
        voice("en-us-x-iol-local", "en-US", { quality: "Premium" }),
      ],
      bots: ["bot-a", "bot-b"],
    },
    {
      name: "another language's voices are the last resort",
      platform: "ios" as const,
      locale: "en-US",
      region: "US",
      voices: [voice("de-de-x-deb-local", "de-DE"), voice("fr-fr-x-fra-local", "fr-FR")],
      bots: ["bot-a"],
    },
    {
      name: "a voice that was removed frees the bot to take another",
      platform: "ios" as const,
      locale: "en-US",
      region: "US",
      voices: [voice("en-us-x-iob-local", "en-US"), voice("en-us-x-iog-local", "en-US")],
      bots: ["bot-a", "bot-b", "bot-c"],
    },
  ];
}
