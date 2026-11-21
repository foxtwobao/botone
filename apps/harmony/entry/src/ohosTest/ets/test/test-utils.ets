// Shared replay helpers: canonical JSON for cross-language comparison (the TS fixture and the
// ArkTS port must agree on values, not key order), and fixture chunk expansion.
import { util } from '@kit.ArkTS';

export function stableJson(value: Object | null): string {
  if (value === null || typeof value !== 'object') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    const items: string[] = [];
    for (const item of value as Object[]) {
      items.push(stableJson(item));
    }
    return `[${items.join(',')}]`;
  }
  const record = value as Record<string, Object>;
  const keys = Object.keys(record).sort();
  const parts: string[] = [];
  for (const key of keys) {
    parts.push(`${JSON.stringify(key)}:${stableJson(record[key])}`);
  }
  return `{${parts.join(',')}}`;
}

/** A fixture chunk: either base64 bytes or a repeated fill byte (the oversized-frame cases). */
export function expandChunk(spec: Record<string, Object>): Uint8Array {
  const fill = spec['fill'];
  if (typeof fill === 'string') {
    const count = spec['count'];
    const size = typeof count === 'number' ? count as number : 0;
    return new Uint8Array(size).fill((fill as string).charCodeAt(0));
  }
  const b64 = spec['b64'];
  return new util.Base64Helper().decodeSync(typeof b64 === 'string' ? b64 as string : '');
}

export function recordOf(json: string): Record<string, Object> {
  return JSON.parse(json) as Record<string, Object>;
}

export function arrayOf(json: string): Object[] {
  return JSON.parse(json) as Object[];
}

export function stringField(record: Record<string, Object>, key: string): string {
  const value = record[key];
  return typeof value === 'string' ? value as string : '';
}

export function numberField(record: Record<string, Object>, key: string): number {
  const value = record[key];
  return typeof value === 'number' ? value as number : 0;
}

export function boolField(record: Record<string, Object>, key: string): boolean {
  return record[key] === true;
}