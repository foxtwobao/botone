// ICU-lite (design §6.6): {name} interpolation, {name, plural, …} and {name, select, …} with
// nested branches, # substitution and ICU apostrophe quoting — the subset the real catalogs use
// (en has ~40 plurals, no number/date formats). Fixture-aligned against @lingui/core evaluation.
// Anything it cannot parse renders the raw message rather than throwing: copy must never crash
// a screen.

const pluralRulesCache: Map<string, Intl.PluralRules> = new Map();

function pluralRules(locale: string, ordinal: boolean): Intl.PluralRules {
  const key = ordinal ? `${locale}/ordinal` : locale;
  let rules = pluralRulesCache.get(key);
  if (rules === undefined) {
    if (ordinal) {
      const options: Intl.PluralRulesOptions = { type: 'ordinal' };
      rules = new Intl.PluralRules(locale, options);
    } else {
      rules = new Intl.PluralRules(locale);
    }
    pluralRulesCache.set(key, rules);
  }
  return rules;
}

const numberFormatCache: Map<string, Intl.NumberFormat> = new Map();

/** lingui renders the plural # with locale number grouping (en 1,000; de 1.000). */
function numberFormat(locale: string): Intl.NumberFormat {
  let format = numberFormatCache.get(locale);
  if (format === undefined) {
    format = new Intl.NumberFormat(locale);
    numberFormatCache.set(locale, format);
  }
  return format;
}

class IcuParser {
  private text: string;
  private pos: number = 0;
  private values: Record<string, Object>;
  private locale: string;
  /** The # value of the innermost plural branch; null outside any plural (a negative count is a
   * real value, so -1 cannot be the sentinel). */
  private hashValue: number | null = null;

  constructor(text: string, values: Record<string, Object>, locale: string) {
    this.text = text;
    this.values = values;
    this.locale = locale;
  }

  parse(): string {
    return this.message(false);
  }

  private peek(): string {
    return this.pos < this.text.length ? this.text.charAt(this.pos) : '';
  }

  /** Text up to the matching close brace (when nested) or the end; placeholders evaluate. */
  private message(nested: boolean): string {
    let out = '';
    while (this.pos < this.text.length) {
      const ch = this.peek();
      if (nested && ch === '}') {
        break;
      }
      if (ch === '{') {
        this.pos += 1;
        out += this.placeholder();
        continue;
      }
      if (ch === "'") {
        out += this.quote();
        continue;
      }
      const hash = this.hashValue;
      if (ch === '#' && hash !== null) {
        out += numberFormat(this.locale).format(hash);
        this.pos += 1;
        continue;
      }
      out += ch;
      this.pos += 1;
    }
    return out;
  }

  /** ICU quoting: '' is a literal quote; a quote before { } # escapes that one character.
   * shortcut: only single-character escapes, not full ICU quoted sections — no shipped catalog
   * message quotes a special (all 85 apostrophes are ordinary contractions like "can't"); upgrade
   * to section quoting if a future catalog entry needs "'{name}'" to render literally. */
  private quote(): string {
    const next = this.pos + 1 < this.text.length ? this.text.charAt(this.pos + 1) : '';
    if (next === "'") {
      this.pos += 2;
      return "'";
    }
    if (next === '{' || next === '}' || next === '#') {
      this.pos += 2;
      return next;
    }
    this.pos += 1;
    return "'";
  }

  private token(stopChars: string): string {
    let out = '';
    while (this.pos < this.text.length) {
      const ch = this.peek();
      if (stopChars.includes(ch)) {
        break;
      }
      out += ch;
      this.pos += 1;
    }
    return out.trim();
  }

  private placeholder(): string {
    const name = this.token(',}');
    if (this.peek() === '}') {
      this.pos += 1;
      return this.valueText(name);
    }
    if (this.peek() !== ',') {
      return `{${name}`;
    }
    this.pos += 1;
    const type = this.token(',}');
    if (type !== 'plural' && type !== 'select' && type !== 'selectordinal') {
      // number/date and friends are not in the catalogs; show the value, keep the type visible.
      const rest = this.token('}');
      if (this.peek() === '}') {
        this.pos += 1;
      }
      return this.valueText(name) + (rest ? ` (${type})` : '');
    }
    if (this.peek() !== ',') {
      return `{${name}, ${type}}`;
    }
    this.pos += 1;
    return this.branches(name, type === 'plural' || type === 'selectordinal', type === 'selectordinal');
  }

  private valueText(name: string): string {
    const value: Object | undefined = this.values[name];
    // lingui renders a missing value as empty, not as the raw placeholder.
    if (value === undefined || value === null) {
      return '';
    }
    return String(value);
  }

  /** Branch list of a plural/select: pick one, evaluate it, skip the rest structurally. */
  private branches(name: string, plural: boolean, ordinal: boolean): string {
    const raw: Object | undefined = this.values[name];
    const count = typeof raw === 'number' ? raw as number : Number(raw);
    let offset = 0;
    this.skipSpace();
    // plural allows "offset:N" before the branches.
    if (this.text.startsWith('offset:', this.pos)) {
      this.pos += 'offset:'.length;
      offset = Number(this.token(' \t\n{,}')) || 0;
    }
    // ICU picks the category on the OFFSET count; an exact =N key still matches the raw count.
    const selected = plural ? this.pluralCategory(count - offset, ordinal)
      : raw === undefined ? '' : String(raw);
    let chosen = '';
    let other = '';
    let hasChosen = false;
    let hasOther = false;
    while (this.pos < this.text.length) {
      this.skipSpace();
      if (this.peek() === '}') {
        this.pos += 1;
        break;
      }
      const key = this.token('{');
      if (this.peek() !== '{') {
        break;
      }
      this.pos += 1;
      const isMatch = plural ? key === `=${count}` || key === selected : key === selected;
      const previousHash: number | null = this.hashValue;
      let braceConsumed = false;
      if (isMatch && !hasChosen) {
        if (plural) {
          this.hashValue = count - offset;
        }
        chosen = this.message(true);
        hasChosen = true;
      } else if (key === 'other' && !hasOther) {
        if (plural) {
          this.hashValue = count - offset;
        }
        other = this.message(true);
        hasOther = true;
      } else {
        this.skipBraced();
        braceConsumed = true;
      }
      this.hashValue = previousHash;
      // message(true) stops before the branch's close brace; skipBraced already consumed it.
      if (!braceConsumed && this.peek() === '}') {
        this.pos += 1;
      }
    }
    return hasChosen ? chosen : other;
  }

  private pluralCategory(count: number, ordinal: boolean): string {
    if (!Number.isFinite(count)) {
      return 'other';
    }
    return pluralRules(this.locale, ordinal).select(count);
  }

  private skipSpace(): void {
    while (this.pos < this.text.length && /\s/.test(this.peek())) {
      this.pos += 1;
    }
  }

  /** Skip a { … } block without evaluating it, respecting nesting and quotes. */
  private skipBraced(): void {
    let depth = 1;
    while (this.pos < this.text.length && depth > 0) {
      const ch = this.peek();
      if (ch === "'") {
        const next = this.pos + 1 < this.text.length ? this.text.charAt(this.pos + 1) : '';
        this.pos += next === "'" || next === '{' || next === '}' || next === '#' ? 2 : 1;
        continue;
      }
      if (ch === '{') {
        depth += 1;
      } else if (ch === '}') {
        depth -= 1;
      }
      this.pos += 1;
    }
  }
}

/** Evaluate an ICU message; on any structural surprise the raw message is returned unchanged. */
export function formatIcu(message: string, values: Record<string, Object>, locale: string): string {
  if (!message.includes('{')) {
    return message;
  }
  try {
    return new IcuParser(message, values, locale).parse();
  } catch (err) {
    return message;
  }
}
