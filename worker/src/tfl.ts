// TfL's Unified API: line statuses (with the stations each disruption covers) and
// station closures. Free. Without a key TfL allows each address 50 requests a minute, and a
// Worker's addresses are shared with the rest of Cloudflare, so a deployed one needs TFL_APP_KEY.

export interface LineStatus {
  lineId: string;
  lineName: string;
  severity: number; // TfL's statusSeverity: 10 is good service
  summary: string; // "Part Closure"
  reason: string;
  planned: boolean;
  periods: { from: number; to: number }[];
  stops: string[]; // station ids the disruption covers; empty when TfL means the whole line
}

export interface StationDisruption {
  stationId: string;
  name: string;
  mode: string;
  type: string; // "Closure" or "Part Closure" (information notices are dropped)
  description: string;
  planned: boolean;
  from?: number;
  to?: number;
  lines: string[]; // line ids it concerns, when TfL says
}

const BASE = "https://api.tfl.gov.uk";
const USER_AGENT = "Beeline alerts (personal journey planner)";

export function lineStatusURL(lineIds: string[], range?: { from: number; to: number }, detail = true): string {
  const ids = [...new Set(lineIds)].sort().map(encodeURIComponent).join(",");
  const span = range ? `/${iso(range.from)}/to/${iso(range.to)}` : "";
  return `${BASE}/Line/${ids}/Status${span}?detail=${detail}`;
}

/** Every service pattern on a line, both ways, with each station's ids, names and position. */
export function routeSequenceURL(lineId: string): string {
  return `${BASE}/Line/${encodeURIComponent(lineId)}/Route/Sequence/all`;
}

export function stationDisruptionsURL(modes: string[]): string {
  return `${BASE}/StopPoint/Mode/${[...new Set(modes)].sort().join(",")}/Disruption`;
}

const iso = (ms: number) => new Date(ms).toISOString().slice(0, 19);

/** Local runs only (`wrangler dev --var TFL_BASE:http://localhost:…`): recorded answers instead
 * of TfL. Never set in production. */
let localBase: string | undefined;
export function useLocalTfL(base: string | undefined) {
  // Every TfL request, with the app key, goes to this address: only ever this machine.
  localBase = base && /^http:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/.test(base) ? base : undefined;
  if (base && !localBase) console.error("TFL_BASE ignored: it may only be http://localhost or http://127.0.0.1 with a port");
}

/** How a caller asks TfL: with its key and, for an invocation that must keep count, what it can
 * still afford. Workers Free allows an invocation 50 requests, and each look in the edge cache
 * and each save to it is one of them: a run that spent them all on TfL would have none left
 * for Apple. */
export interface TfLAccess {
  key?: string;
  /** Requests (TfL's and the cache's) this invocation may still make; counted down as they are. */
  ops?: { left: number };
  /** Ask TfL itself, and keep nothing: for the checks' own look at what's live now, which is
   * older than the cache keeps anything by the time they next run. */
  uncached?: boolean;
}

/** The invocation has no requests left to spend on TfL. What it couldn't ask is left unknown,
 * and what it did ask is in the cache for the next try. */
export class OutOfRequests extends Error {}

/** One TfL request, kept for `ttl` seconds at the edge so the app and the checks share it.
 * (Answers are shared through that cache only: a request still under way belongs to the
 * invocation that started it, and can't be waited on from another.) */
export function fetchTfL(url: string, ttl: number, access?: string | TfLAccess, timeoutMs?: number): Promise<unknown> {
  const asked: TfLAccess = typeof access === "object" ? access : { key: access };
  // Recorded answers are served by something that is not TfL: the key is TfL's alone, and the
  // request goes nowhere that address sends it on to.
  const local = localBase !== undefined;
  if (localBase) url = url.replace(BASE, localBase);
  return ask(url, ttl, local ? { ...asked, key: undefined } : asked, timeoutMs, local);
}

async function ask(url: string, ttl: number, access: TfLAccess, timeoutMs: number | undefined, local: boolean): Promise<unknown> {
  const appKey = access.key;
  const spend = (requests: number) => {
    if (!access.ops) return;
    if (access.ops.left < requests) throw new OutOfRequests(`no requests left for ${url}`);
    access.ops.left -= requests;
  };
  const cache = access.uncached ? undefined : (globalThis as { caches?: CacheStorage }).caches;
  const edge = cache ? await cache.open("tfl") : undefined;
  const key = new Request(url);
  if (edge) spend(1);
  const hit = await edge?.match(key);
  if (hit) return hit.json();
  // TfL itself, and the save that follows.
  spend(edge ? 2 : 1);
  // Carries the key, so it's never logged or put in an error: `url` is.
  const target = appKey ? `${url}${url.includes("?") ? "&" : "?"}app_key=${encodeURIComponent(appKey)}` : url;
  const get = () => fetch(target, { headers: { "User-Agent": USER_AGENT, Accept: "application/json" }, ...(local ? { redirect: "manual" as const } : {}),
    ...(timeoutMs ? { signal: AbortSignal.timeout(timeoutMs) } : {}) });
  let body: string;
  try {
    let response = await get();
    // TfL limits each key and each keyless address (Cloudflare's are shared): wait as long as it
    // asks, then try once more.
    if (response.status === 429) {
      spend(1);
      await new Promise((resolve) => setTimeout(resolve, retryDelay(response.headers.get("Retry-After"))));
      response = await get();
    }
    if (!response.ok) throw new TfLRefused(response.status, url);
    // Only an answer of a size TfL's really are is read at all.
    body = await limitedText(response, MAX_ANSWER, url);
  } catch (error) {
    // Out of requests is this invocation's own limit, not TfL failing.
    if (!(error instanceof OutOfRequests)) {
      const { pathname, search } = new URL(url);
      console.warn("TfL request failed:", error instanceof TfLRefused ? error.status : (error as Error)?.name ?? String(error), pathname + search);
    }
    throw error;
  }
  // And only one that reads as JSON is kept for everyone else.
  const parsed: unknown = JSON.parse(body);
  await edge?.put(key, new Response(body, { headers: { "Cache-Control": `max-age=${ttl}`, "Content-Type": "application/json" } }));
  return parsed;
}

/** The reply's text, read as it comes and given up on once it is past `max` bytes (or says it
 * will be), so an answer that never ends is never all held. */
async function limitedText(response: Response, max: number, url: string): Promise<string> {
  const tooLarge = () => new Error(`TfL answer too large for ${url}`);
  if (Number(response.headers.get("content-length")) > max) {
    await response.body?.cancel();
    throw tooLarge();
  }
  if (!response.body) return "";
  const reader = response.body.getReader(), decoder = new TextDecoder();
  let text = "", size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) {
      await reader.cancel();
      throw tooLarge();
    }
    text += decoder.decode(value, { stream: true });
  }
  return text + decoder.decode();
}

/** Every line of a mode with full detail is a few hundred KB. */
const MAX_ANSWER = 6_000_000;
const text = (v: unknown): string => (typeof v === "string" ? v : "");
const items = (v: unknown): Json[] => (Array.isArray(v) ? v.filter((x) => x !== null && typeof x === "object") : []);

class TfLRefused extends Error {
  status: number;
  constructor(status: number, url: string) {
    super(`TfL ${status} for ${url}`);
    this.status = status;
  }
}

/** TfL's Retry-After in whole seconds, held to 1–3 s so a phone isn't kept waiting; 1.5 s when it
 * doesn't say. */
export function retryDelay(header: string | null): number {
  const seconds = /^\d+$/.test(header?.trim() ?? "") ? Number(header) : NaN;
  return Number.isFinite(seconds) ? Math.min(3, Math.max(1, seconds)) * 1000 : 1500;
}

const time = (s: unknown): number | undefined => {
  if (typeof s !== "string" || s.startsWith("0001")) return undefined;
  const ms = Date.parse(/[zZ]|[+-]\d\d:?\d\d$/.test(s) ? s : `${s}Z`);
  return Number.isFinite(ms) ? ms : undefined;
};

type Json = Record<string, any>;

export function parseLineStatuses(json: unknown): LineStatus[] {
  // What TfL sends is read field by field: a shape it never sent before is a line left unknown,
  // never text or a number of the wrong kind further in.
  return items(json).flatMap((line) => {
    if (typeof line.id !== "string") return [];
    return items(line.lineStatuses).map((status): LineStatus => ({
      lineId: line.id,
      lineName: text(line.name),
      severity: typeof status.statusSeverity === "number" ? status.statusSeverity : NaN,
      summary: text(status.statusSeverityDescription),
      reason: text(status.reason) || text(status.disruption?.description),
      planned: status.disruption?.category === "PlannedWork",
      periods: items(status.validityPeriods).flatMap((p) => {
        const from = time(p.fromDate), to = time(p.toDate);
        return from !== undefined && to !== undefined && from <= to ? [{ from, to }] : [];
      }),
      stops: items(status.disruption?.affectedStops).map((s) => s.stationNaptan ?? s.naptanId ?? s.id).filter((id): id is string => typeof id === "string" && id.length > 0),
    }));
  });
}

export function parseStationDisruptions(json: unknown): StationDisruption[] {
  return items(json).flatMap((d): StationDisruption[] => {
    if (d.type !== "Closure" && d.type !== "Part Closure") return [];
    const stationId = text(d.stationAtcoCode) || text(d.atcoCode), description = text(d.description);
    if (!stationId || !description) return [];
    return [{
      stationId,
      name: cleanName(text(d.commonName)),
      mode: text(d.mode),
      type: d.type,
      description,
      planned: d.appearance === "PlannedWork",
      from: time(d.fromDate),
      to: time(d.toDate),
      lines: items(d.concernedLines).map((l) => l.id).filter((id): id is string => typeof id === "string" && id.length > 0),
    }];
  });
}

/** Whether TfL's line answer reads as one throughout. A row that doesn't isn't dropped and the
 * rest believed: what it would have said (a closure, say) is not known, so neither is the batch. */
export function lineStatusesComplete(json: unknown): boolean {
  const record = (v: unknown): v is Json => v !== null && typeof v === "object" && !Array.isArray(v);
  // When a status applies is what places planned works on the times you travel.
  // TfL writes "no date" as year 1; any other date has to be one that can be read, or the
  // status would be kept with no time it applies to, and never matched to a journey.
  const date = (v: unknown) => typeof v === "string" && (v.startsWith("0001") || time(v) !== undefined);
  // And one that ends before it begins is no time at all.
  const ordered = (p: Json) => { const from = time(p.fromDate), to = time(p.toDate); return from === undefined || to === undefined || from <= to; };
  const periods = (v: unknown) => v === undefined || v === null || (Array.isArray(v) && v.every((p) => record(p) && date(p.fromDate) && date(p.toDate) && ordered(p)));
  return Array.isArray(json) && json.every((line) => record(line) && typeof line.id === "string" && Array.isArray(line.lineStatuses)
    && line.lineStatuses.every((status: unknown) => record(status) && typeof status.statusSeverity === "number" && periods(status.validityPeriods)));
}

/** The same for station notices: each says what kind it is, and every closure has its station
 * and its words. */
export function stationDisruptionsComplete(json: unknown): boolean {
  return Array.isArray(json) && json.every((d) => d !== null && typeof d === "object" && typeof d.type === "string"
    && ((d.type !== "Closure" && d.type !== "Part Closure") || (Boolean(text(d.stationAtcoCode) || text(d.atcoCode)) && Boolean(text(d.description)))));
}

export function cleanName(name: string): string {
  return name.replace(/ (Underground|Rail|DLR) Station$| Station$/, "");
}
