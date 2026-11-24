// Server address rules, ported from apps/mobile/lib/api/endpoint.ts and the private-network
// subset of packages/contracts/src/clients/network-host.ts (fixture-aligned). Errors are the
// catalog msgids; the UI translates them. http is allowed only on the person's own network.
import { url } from '@kit.ArkTS';
import { postJson, parseJsonObject } from './http';

export const API_PROBE_TIMEOUT_MS = 8_000;
export const MAX_API_PROBE_RESPONSE_BYTES = 64 * 1024;
/** No hosted default: this fork is self-hosted, so the local dev API is the fallback (mobile parity). */
export const LOCAL_API = 'http://127.0.0.1:3100';

export interface EndpointResult {
  ok: boolean;
  url: string;
  error: string;
}

function endpointError(error: string): EndpointResult {
  const result: EndpointResult = { ok: false, url: '', error: error };
  return result;
}

export function defaultApiBase(): string {
  const parsed = normalizeApiBase(LOCAL_API);
  return parsed.ok ? parsed.url : LOCAL_API;
}

/** The raw hostname from the authority, before any URL normalization (keeps a trailing dot). */
function rawHostname(withScheme: string): string {
  const rest = withScheme.replace(/^[a-z][a-z0-9+.-]*:\/\//i, '');
  const authority = rest.split(/[/?#]/)[0];
  const at = authority.lastIndexOf('@');
  const hostPort = at === -1 ? authority : authority.slice(at + 1);
  if (hostPort.startsWith('[')) {
    const close = hostPort.indexOf(']');
    return close === -1 ? hostPort : hostPort.slice(0, close + 1);
  }
  const colon = hostPort.lastIndexOf(':');
  return colon === -1 ? hostPort : hostPort.slice(0, colon);
}

export function normalizeApiBase(input: string): EndpointResult {
  const trimmed = input.trim();
  if (!trimmed) {
    return endpointError('Enter a server URL');
  }
  const withScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
  let parsed: url.URL;
  try {
    parsed = url.URL.parseURL(withScheme);
  } catch (err) {
    return endpointError('That doesn’t look like a URL');
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    return endpointError('Use an http or https URL');
  }
  if (!parsed.hostname) {
    return endpointError('That URL is missing a host');
  }
  // The kit's URL strips a trailing dot ("localhost." → "localhost"); WHATWG keeps it, and the
  // private-network allow predicates match names exactly, so restore it from the raw input.
  const raw = rawHostname(withScheme).toLowerCase();
  const trailingDot = raw.endsWith('.') && !parsed.hostname.endsWith('.');
  const hostname = trailingDot ? `${parsed.hostname}.` : parsed.hostname;
  if (parsed.protocol === 'http:' && !isPrivateNetworkHost(hostname)) {
    return endpointError('Public servers need https://. HTTP only works on your local network.');
  }
  let host = parsed.host;
  if (trailingDot) {
    if (host.startsWith('[')) {
      const close = host.indexOf(']');
      host = `${host.slice(0, close)}.${host.slice(close)}`;
    } else {
      const colon = host.lastIndexOf(':');
      host = colon === -1 ? `${host}.` : `${host.slice(0, colon)}.${host.slice(colon)}`;
    }
  }
  const result: EndpointResult = { ok: true, url: `${parsed.protocol}//${host}`, error: '' };
  return result;
}

export function displayApiHost(apiBase: string): string {
  try {
    return url.URL.parseURL(apiBase).host;
  } catch (err) {
    return apiBase;
  }
}

/** The host, with http:// kept so a plain-http server never reads like its https twin. */
export function displaySavedServer(apiBase: string): string {
  return apiBase.startsWith('http://') ? apiBase : displayApiHost(apiBase);
}

/** POST /rpc/health expecting {json:{ok:true}}; 8s deadline, 64KB cap. */
export async function probeApiBase(input: string, headers: Record<string, string>): Promise<EndpointResult> {
  const parsed = normalizeApiBase(input);
  if (!parsed.ok) {
    return parsed;
  }
  const requestHeaders: Record<string, string> = {};
  for (const key of Object.keys(headers)) {
    requestHeaders[key] = headers[key];
  }
  requestHeaders['content-type'] = 'application/json';
  requestHeaders['origin'] = 'rakazo://';
  try {
    const response = await postJson(`${parsed.url}/rpc/health`, requestHeaders, '{"json":{}}',
      API_PROBE_TIMEOUT_MS, MAX_API_PROBE_RESPONSE_BYTES);
    if (response.status < 200 || response.status >= 300) {
      return endpointError('That URL did not look like a Rakazo server');
    }
    const body = parseJsonObject(response.body);
    const json = body !== null ? body['json'] : undefined;
    const ok = json !== undefined && json !== null && typeof json === 'object'
      ? (json as Record<string, Object>)['ok']
      : undefined;
    if (body === null || body['error'] !== undefined || ok !== true) {
      return endpointError('That URL did not look like a Rakazo server');
    }
    return parsed;
  } catch (err) {
    return endpointError('Could not reach that server');
  }
}

// ---------------------------------------------------------- private network hosts

interface IpRange {
  network: number;
  mask: number;
}

function ipv4(value: string): number {
  const parsed = parseIpv4(value);
  if (parsed === null) {
    throw new Error(`Invalid IPv4 constant ${value}`);
  }
  return parsed;
}

function ranges(entries: [string, number][]): IpRange[] {
  return entries.map((entry): IpRange => {
    const prefix = entry[1];
    const range: IpRange = {
      network: ipv4(entry[0]),
      mask: prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0,
    };
    return range;
  });
}

/** Ranges a person's own network uses: loopback, RFC 1918, and CGNAT (Tailscale). */
const PRIVATE_NETWORK_IPV4: IpRange[] = ranges([
  ['10.0.0.0', 8],
  ['100.64.0.0', 10],
  ['127.0.0.0', 8],
  ['172.16.0.0', 12],
  ['192.168.0.0', 16],
]);

const CLOUD_METADATA_IPV4: number[] = [
  ipv4('169.254.169.254'),
  ipv4('169.254.170.2'),
  ipv4('100.100.100.200'),
];
/** AWS IMDS over IPv6, fd00:ec2::254. */
const AWS_IMDS_IPV6: number[] = [0xfd00, 0x0ec2, 0, 0, 0, 0, 0, 0x0254];

function inRanges(value: number, list: IpRange[]): boolean {
  for (const range of list) {
    if (((value & range.mask) >>> 0) === range.network) {
      return true;
    }
  }
  return false;
}

/** Lowercase, unbracketed (one trailing dot is kept: allow predicates match names exactly). */
function canonical(hostname: string): string {
  return hostname.toLowerCase().replace(/^\[|\]$/g, '');
}

function parseIpv4(value: string): number | null {
  const match = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(value);
  if (match === null) {
    return null;
  }
  let result = 0;
  for (let i = 1; i <= 4; i += 1) {
    const octet = match[i];
    // Leading zeros read as octal in some parsers, so they are not an IP literal here.
    if (octet.length > 1 && octet.startsWith('0')) {
      return null;
    }
    const number = Number(octet);
    if (number > 255) {
      return null;
    }
    result = result * 256 + number;
  }
  return result;
}

function parseIpv6(value: string): number[] | null {
  if (!value.includes(':')) {
    return null;
  }
  // A zone (fe80::1%en0) scopes the address to an interface; it does not change its class.
  const zone = value.indexOf('%');
  const address = zone === -1 ? value : value.slice(0, zone);
  if (zone !== -1 && !/^[0-9a-z._~-]+$/.test(value.slice(zone + 1))) {
    return null;
  }
  const halves = address.split('::');
  if (halves.length > 2) {
    return null;
  }
  const parts: string[][] = halves.map((half): string[] => half === '' ? [] : half.split(':'));
  const tail = parts[parts.length - 1];
  const last = tail.length > 0 ? tail[tail.length - 1] : '';
  if (tail.length > 0 && last.includes('.')) {
    const v4 = parseIpv4(last);
    if (v4 === null) {
      return null;
    }
    tail.splice(-1, 1, (v4 >>> 16).toString(16), (v4 & 0xffff).toString(16));
  }
  const groups: number[] = [];
  for (const part of parts) {
    for (const piece of part) {
      if (!/^[0-9a-f]{1,4}$/.test(piece)) {
        return null;
      }
      groups.push(Number.parseInt(piece, 16));
    }
  }
  if (halves.length === 1) {
    return groups.length === 8 ? groups : null;
  }
  if (groups.length > 7) {
    return null;
  }
  const left = parts[0].length;
  const result: number[] = [];
  for (let i = 0; i < left; i += 1) {
    result.push(groups[i]);
  }
  for (let i = 0; i < 8 - groups.length; i += 1) {
    result.push(0);
  }
  for (let i = left; i < groups.length; i += 1) {
    result.push(groups[i]);
  }
  return result;
}

function group(v6: number[], index: number): number {
  return index < v6.length ? v6[index] : 0;
}

function isUnspecifiedPrefix(v6: number[], count: number): boolean {
  for (let i = 0; i < count; i += 1) {
    if (group(v6, i) !== 0) {
      return false;
    }
  }
  return true;
}

function isIpv6Loopback(v6: number[]): boolean {
  return isUnspecifiedPrefix(v6, 7) && group(v6, 7) === 1;
}

function lowIpv4(v6: number[]): number {
  return group(v6, 6) * 0x10000 + group(v6, 7);
}

/** ::ffff:0:0/96 only. */
function mappedIpv4(v6: number[]): number | null {
  return isUnspecifiedPrefix(v6, 5) && group(v6, 5) === 0xffff ? lowIpv4(v6) : null;
}

/** Every IPv6 form that carries an IPv4 destination. */
function embeddedIpv4(v6: number[]): number | null {
  const mapped = mappedIpv4(v6);
  if (mapped !== null) {
    return mapped;
  }
  // ::/96 IPv4-compatible (deprecated).
  if (isUnspecifiedPrefix(v6, 6)) {
    return lowIpv4(v6);
  }
  // 64:ff9b::/96 NAT64 well-known prefix.
  if (group(v6, 0) === 0x64 && group(v6, 1) === 0xff9b && isUnspecifiedPrefix(v6.slice(2, 6), 4)) {
    return lowIpv4(v6);
  }
  // 2002::/16 6to4: the IPv4 address is the next 32 bits.
  if (group(v6, 0) === 0x2002) {
    return group(v6, 1) * 0x10000 + group(v6, 2);
  }
  return null;
}

/** 4 or 6 for an IP literal, 0 for anything else. */
export function ipVersion(host: string): number {
  const value = canonical(host);
  if (parseIpv4(value) !== null) {
    return 4;
  }
  return parseIpv6(value) === null ? 0 : 6;
}

function isCloudMetadataAddress(address: string): boolean {
  const value = canonical(address);
  const v4 = parseIpv4(value);
  if (v4 !== null) {
    return CLOUD_METADATA_IPV4.includes(v4);
  }
  const v6 = parseIpv6(value);
  if (v6 === null) {
    return false;
  }
  let isAws = true;
  for (let i = 0; i < 8; i += 1) {
    if (group(v6, i) !== AWS_IMDS_IPV6[i]) {
      isAws = false;
      break;
    }
  }
  if (isAws) {
    return true;
  }
  const embedded = embeddedIpv4(v6);
  return embedded !== null && CLOUD_METADATA_IPV4.includes(embedded);
}

/**
 * An address on the person's own network. Link-local and cloud metadata are excluded: those
 * ranges host metadata services and are never a legitimate server address. IPv4-mapped IPv6
 * is not accepted — nobody types a server that way.
 */
export function isPrivateNetworkAddress(address: string): boolean {
  const value = canonical(address);
  if (isCloudMetadataAddress(value)) {
    return false;
  }
  const v4 = parseIpv4(value);
  if (v4 !== null) {
    return inRanges(v4, PRIVATE_NETWORK_IPV4);
  }
  const v6 = parseIpv6(value);
  if (v6 === null) {
    return false;
  }
  return isIpv6Loopback(v6) || (group(v6, 0) & 0xfe00) === 0xfc00;
}

function isLocalhostOrLoopbackIp(hostname: string): boolean {
  const host = canonical(hostname);
  if (host === 'localhost') {
    return true;
  }
  const v4 = parseIpv4(host);
  if (v4 !== null) {
    return (v4 >>> 24) === 127;
  }
  const v6 = parseIpv6(host);
  return v6 !== null && isIpv6Loopback(v6);
}

/** This machine: localhost, *.localhost (RFC 6761), 127.0.0.0/8, or ::1. */
export function isLoopbackHost(hostname: string): boolean {
  const host = canonical(hostname);
  return isLocalhostOrLoopbackIp(host) || host.endsWith('.localhost');
}

/**
 * This machine or the person's LAN: loopback hosts, .local mDNS names, and private-network IP
 * literals. Where cleartext HTTP to a self-hosted server is acceptable.
 */
export function isPrivateNetworkHost(hostname: string): boolean {
  const host = canonical(hostname);
  if (isLoopbackHost(host) || host.endsWith('.local')) {
    return true;
  }
  return ipVersion(host) !== 0 && isPrivateNetworkAddress(host);
}
