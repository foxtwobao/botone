// The most audio, in bytes, the transcribe route accepts.
// A file of its own, holding this one statement and nothing else: client builds read the limit
// from here as text and check that the whole file is this declaration, so a value hiding in a
// comment, a string or some other statement can never be read by mistake.
export const MAX_TRANSCRIBE_BYTES = 8 * 1024 * 1024;
