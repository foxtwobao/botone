// S1 probe: defensive JSON decoding in ArkTS — explicit field reads plus runtime type
// checks, no any/unknown and no unchecked cast of the payload. The Phase 1 contract
// decoders follow this style.

export interface HealthOutput {
  ok: boolean;
  version: string;
}

export function decodeHealth(text: string): HealthOutput | null {
  let parsed: object;
  try {
    parsed = JSON.parse(text);
  } catch {
    return null;
  }
  const envelope = parsed as Record<string, Object>;
  const json: Object | undefined = envelope['json'];
  if (json === undefined || json === null) {
    return null;
  }
  const body = json as Record<string, Object>;
  const ok: Object | undefined = body['ok'];
  const version: Object | undefined = body['version'];
  if (typeof ok !== 'boolean' || typeof version !== 'string') {
    return null;
  }
  const result: HealthOutput = { ok: ok, version: version };
  return result;
}
