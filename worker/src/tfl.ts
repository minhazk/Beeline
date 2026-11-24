// TfL's Unified API: line statuses (with the stations each disruption covers) and
// station closures. Free and keyless at this volume (50 requests a minute without a key).

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
const USER_AGENT = "Beeline Home alerts (personal journey planner)";

export function lineStatusURL(lineIds: string[], range?: { from: number; to: number }): string {
  const ids = [...new Set(lineIds)].sort().map(encodeURIComponent).join(",");
  const span = range ? `/${iso(range.from)}/to/${iso(range.to)}` : "";
  return `${BASE}/Line/${ids}/Status${span}?detail=true`;
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
export const useLocalTfL = (base: string | undefined) => void (localBase = base || undefined);

/** One TfL request, kept for `ttl` seconds at the edge so the app and the checks share it. */
export async function fetchTfL(url: string, ttl: number, appKey?: string, timeoutMs?: number): Promise<unknown> {
  if (localBase) url = url.replace(BASE, localBase);
  const cache = (globalThis as { caches?: CacheStorage }).caches;
  const edge = cache ? await cache.open("tfl") : undefined;
  const key = new Request(url);
  const hit = await edge?.match(key);
  if (hit) return hit.json();
  const target = appKey ? `${url}${url.includes("?") ? "&" : "?"}app_key=${encodeURIComponent(appKey)}` : url;
  const get = () => fetch(target, { headers: { "User-Agent": USER_AGENT, Accept: "application/json" }, ...(timeoutMs ? { signal: AbortSignal.timeout(timeoutMs) } : {}) });
  let response = await get();
  // Without a key, TfL limits each address, and Cloudflare's are shared: try once more.
  if (response.status === 429 && !appKey) {
    await new Promise((resolve) => setTimeout(resolve, 1500));
    response = await get();
  }
  if (!response.ok) throw new Error(`TfL ${response.status} for ${url}`);
  const body = await response.text();
  await edge?.put(key, new Response(body, { headers: { "Cache-Control": `max-age=${ttl}`, "Content-Type": "application/json" } }));
  return JSON.parse(body);
}

const time = (s: unknown): number | undefined => {
  if (typeof s !== "string" || s.startsWith("0001")) return undefined;
  const ms = Date.parse(/[zZ]|[+-]\d\d:?\d\d$/.test(s) ? s : `${s}Z`);
  return Number.isFinite(ms) ? ms : undefined;
};

type Json = Record<string, any>;

export function parseLineStatuses(json: unknown): LineStatus[] {
  if (!Array.isArray(json)) return [];
  return json.flatMap((line: Json) =>
    (line.lineStatuses ?? []).map((status: Json): LineStatus => ({
      lineId: line.id,
      lineName: line.name,
      severity: status.statusSeverity,
      summary: status.statusSeverityDescription ?? "",
      reason: status.reason ?? "",
      planned: status.disruption?.category === "PlannedWork",
      periods: (status.validityPeriods ?? []).flatMap((p: Json) => {
        const from = time(p.fromDate), to = time(p.toDate);
        return from !== undefined && to !== undefined && from <= to ? [{ from, to }] : [];
      }),
      stops: (status.disruption?.affectedStops ?? []).map((s: Json) => s.stationNaptan ?? s.naptanId ?? s.id).filter(Boolean),
    })),
  );
}

export function parseStationDisruptions(json: unknown): StationDisruption[] {
  if (!Array.isArray(json)) return [];
  return json.flatMap((d: Json): StationDisruption[] => {
    if (d.type !== "Closure" && d.type !== "Part Closure") return [];
    const stationId = d.stationAtcoCode ?? d.atcoCode;
    if (!stationId || !d.description) return [];
    return [{
      stationId,
      name: cleanName(d.commonName ?? ""),
      mode: d.mode ?? "",
      type: d.type,
      description: d.description,
      planned: d.appearance === "PlannedWork",
      from: time(d.fromDate),
      to: time(d.toDate),
      lines: (d.concernedLines ?? []).map((l: Json) => l.id).filter(Boolean),
    }];
  });
}

export function cleanName(name: string): string {
  return name.replace(/ (Underground|Rail|DLR) Station$| Station$/, "");
}
