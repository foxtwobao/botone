// Ported verbatim from packages/core/src/account/email-typo.ts (the differential test
// apps/harmony/contract/email-typo.test.ts pins the port to the original). Same tables, same
// distance, same decisions; only the syntax moves to ArkTS (const arrays, no Set literals).
const KNOWN_DOMAINS: string[] = [
  'gmail.com',
  'icloud.com',
  'outlook.com',
  'hotmail.com',
  'yahoo.com',
  'proton.me',
  'protonmail.com',
  'qq.com',
  '163.com',
  '126.com',
  'live.com',
  'me.com',
  'msn.com',
  'aol.com',
  'googlemail.com',
  'foxmail.com',
  'ymail.com',
  'gmx.com',
  'mail.com',
  'email.com',
];

const COM_TYPOS: string[] = ['con', 'cmo', 'ocm', 'vom', 'xom', 'dom', 'cpm', 'comm', 'coom', 'come'];

function inList(list: string[], value: string): boolean {
  return list.includes(value);
}

/** Optimal string alignment distance: edits plus adjacent swaps. */
function editDistance(a: string, b: string): number {
  const width = b.length + 1;
  const cells: number[] = new Array((a.length + 1) * width).fill(0);
  const at = (i: number, j: number): number => cells[i * width + j] ?? 0;
  for (let i = 0; i <= a.length; i++) {
    for (let j = 0; j <= b.length; j++) {
      let value = Math.max(i, j);
      if (i > 0 && j > 0) {
        const cost = a[i - 1] === b[j - 1] ? 0 : 1;
        value = Math.min(at(i - 1, j) + 1, at(i, j - 1) + 1, at(i - 1, j - 1) + cost);
        if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) {
          value = Math.min(value, at(i - 2, j - 2) + 1);
        }
      }
      cells[i * width + j] = value;
    }
  }
  return at(a.length, b.length);
}

function splitDomain(domain: string): string[] {
  const dot = domain.lastIndexOf('.');
  return dot < 0 ? [domain, ''] : [domain.slice(0, dot), domain.slice(dot + 1)];
}

function replaceAll(value: string, from: string): string {
  return value.split(from).join('');
}

function correctedDomain(domain: string): string | null {
  if (domain.length > 253 || inList(KNOWN_DOMAINS, domain)) {
    return null;
  }
  const parts = splitDomain(domain);
  const name = parts[0];
  const rawTld = parts[1];
  const tld = inList(COM_TYPOS, rawTld) ? 'com' : rawTld;
  for (const known of KNOWN_DOMAINS) {
    const knownParts = splitDomain(known);
    const knownName = knownParts[0];
    const knownTld = knownParts[1];
    if (replaceAll(domain, '.') === replaceAll(known, '.')) {
      return known;
    }
    // Short names sit one edit from real domains (gm.com, ge.com), so only longer ones are fuzzy.
    if (knownName.length < 5) {
      continue;
    }
    if (name === knownName && editDistance(tld, knownTld) <= 1) {
      return known;
    }
    // Typos rarely hit the first letter, while lookalike real domains (cloud.com) often differ there.
    if (tld === knownTld && name[0] === knownName[0] && editDistance(name, knownName) <= 1) {
      return known;
    }
  }
  return tld === rawTld ? null : `${name}.com`;
}

/** A likely intended address when the domain looks mistyped, e.g. `a@gmial.com` → `a@gmail.com`. */
export function suggestEmailCorrection(email: string): string | null {
  const trimmed = email.trim();
  const at = trimmed.lastIndexOf('@');
  if (at < 1) {
    return null;
  }
  const domain = correctedDomain(trimmed.slice(at + 1).toLowerCase());
  return domain !== null ? `${trimmed.slice(0, at + 1)}${domain}` : null;
}
