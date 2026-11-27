// Dictated words in a draft (M7): the merge rule of mobile's composer
// (components/composer/thread-composer.tsx, showDictation). Words follow the text that was there
// when the microphone opened. Live words never overwrite an edit made meanwhile; a provider's
// one-off transcript joins the edited text. Pure: the layer-2 voice fixture runs the real rule and
// this port replays it.

export class DraftDictation {
  /** The draft when the microphone opened; null while no dictation is open. */
  private base: string | null = null;
  /** What this dictation last left in the draft. */
  private dictated: string = '';

  /** The microphone opens on the draft as it is now. */
  open(draft: string): void {
    this.base = draft;
    this.dictated = draft;
  }

  get isOpen(): boolean {
    return this.base !== null;
  }

  /**
   * The draft after `words` arrive (none with '' undoes what the dictation put there), or null
   * when there is nothing to write: live words over an edit, or no dictation open.
   */
  show(draft: string, words: string, final: boolean = false): string | null {
    let base = this.base;
    if (base === null) {
      return null;
    }
    if (draft !== this.dictated) {
      if (!final) {
        return null;
      }
      base = draft;
    }
    const next = !words ? base : base.trim() ? `${base.trimEnd()} ${words}` : words;
    this.dictated = next;
    return next;
  }

  /** True while the draft still shows exactly what this dictation put there. */
  owns(draft: string): boolean {
    return this.base !== null && draft === this.dictated;
  }

  close(): void {
    this.base = null;
  }
}
