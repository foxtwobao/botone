// Bot voice assignment (M7): a port of mobile's lib/voice/voice-assignment.ts. Bots start at a
// stable, bot-specific offset into the voice list and share a voice only once every one is taken,
// so the same bot keeps its voice as the list changes. Pure; pinned by the layer-2 voice fixture.
export function pickUnusedVoice(voices: string[], taken: Set<string>, botId: string): string {
  let hash = 0;
  for (const char of botId) {
    hash = (hash * 31 + (char.codePointAt(0) ?? 0)) >>> 0;
  }
  const start = hash % voices.length;
  for (let offset = 0; offset < voices.length; offset += 1) {
    const voice = voices[(start + offset) % voices.length];
    if (voice && !taken.has(voice)) {
      return voice;
    }
  }
  return voices[start] ?? '';
}
