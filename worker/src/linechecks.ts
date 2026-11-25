// Limit simultaneous TfL requests and track which lines actually answered before changing alert state.
import { fetchTfL, type TfLAccess, lineStatusesComplete, lineStatusURL, parseLineStatuses, parseStationDisruptions, stationDisruptionsComplete, stationDisruptionsURL } from "./tfl.ts";
import type { LineStatus, StationDisruption } from "./tfl.ts";
import type { Alert, Segment } from "./types.ts";
import { Invalid } from "./validate.ts";

export class TfLUnavailable extends Error {}

export async function inGroups<T>(items: T[], work: (item: T) => Promise<void>) {
  for (let i = 0; i < items.length; i += 3) await Promise.all(items.slice(i, i + 3).map(work));
}

/** A fixed endpoint and one-day edge cache shared by every phone, regardless of its watches. */
export async function lineCatalog(appKey?: string | TfLAccess): Promise<Map<string, string>> {
  const catalog = new Map<string, string>();
  try {
    // The catalog is the same all day and worth keeping, whoever asks.
    const data = await fetchTfL("https://api.tfl.gov.uk/Line/Mode/dlr,elizabeth-line,national-rail,overground,tram,tube", 86400, typeof appKey === "object" ? { ...appKey, uncached: false } : appKey, 6000);
    if (!Array.isArray(data)) throw new Error();
    for (const row of data) if (typeof row?.id === "string" && typeof row.modeName === "string") catalog.set(row.id, row.modeName);
    if (!catalog.size) throw new Error();
  } catch {
    throw new TfLUnavailable("TfL's line catalog is unavailable. Try again later.");
  }
  return catalog;
}

export function validateLines(alerts: Alert[], catalog: Map<string, string>) {
  if (alerts.some((a) => a.segments.some((s) => catalog.get(s.line.id) !== s.mode))) {
    throw new Invalid("Line or mode is not in TfL's line catalog");
  }
}

export async function lineChecks(segments: Segment[], catalog: Map<string, string>, appKey?: string | TfLAccess, range?: { from: number; to: number }) {
  const lines: LineStatus[] = [], missing = new Set<string>(), wanted = new Set<string>();
  for (const { mode, line } of segments) {
    if (catalog.get(line.id) === mode) wanted.add(line.id);
    else if (!catalog.has(line.id)) missing.add(line.id);
  }
  const byMode = new Map<string, string[]>();
  for (const [id, mode] of catalog) {
    const ids = byMode.get(mode) ?? [];
    ids.push(id);
    byMode.set(mode, ids);
  }
  // Canonical batches share cache entries between phones even if they watch different subsets.
  const batches: string[][] = [];
  for (const ids of byMode.values()) {
    ids.sort();
    for (let i = 0; i < ids.length; i += 12) {
      const batch = ids.slice(i, i + 12);
      if (batch.some((id) => wanted.has(id))) batches.push(batch);
    }
  }
  await inGroups(batches, async (ids) => {
    const needed = ids.filter((id) => wanted.has(id));
    try {
      const data = await fetchTfL(lineStatusURL(ids, range), range ? 900 : LIVE_TTL, appKey, 6000);
      if (!lineStatusesComplete(data)) throw new Error();
      const result = parseLineStatuses(data);
      const received = new Set(result.filter((s) => Number.isFinite(s.severity)).map((s) => s.lineId));
      // A planned-work query can legitimately return no entries. Current status explicitly
      // reports "Good Service"; an omitted line is unknown, so leave its previous state alone.
      if (!range) for (const id of needed) if (!received.has(id)) missing.add(id);
      lines.push(...result.filter((s) => wanted.has(s.lineId)));
    } catch {
      for (const id of needed) missing.add(id);
    }
  });
  return { lines, missing };
}

/** How long what's live now is kept for the app: just under the two minutes between its own
 * refreshes and a second try, so a status check that ran out of requests finds the first half
 * of its answers still there. (The scheduled checks ask TfL itself.) */
const LIVE_TTL = 110;

export async function stationChecks(segments: Segment[], appKey?: string | TfLAccess) {
  const stations: StationDisruption[] = [], missing = new Set<string>();
  await inGroups([...new Set(segments.map((s) => s.mode))], async (mode) => {
    try {
      const data = await fetchTfL(stationDisruptionsURL([mode]), LIVE_TTL, appKey, 6000);
      if (!stationDisruptionsComplete(data)) throw new Error();
      stations.push(...parseStationDisruptions(data));
    } catch { missing.add(mode); }
  });
  return { stations, missing };
}
