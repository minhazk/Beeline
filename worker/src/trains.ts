// The next trains from one station on one line, from TfL's live predictions: what a next-train
// Live Activity shows. The tube, DLR and trams have arrival predictions (Line/{id}/Arrivals); the
// Elizabeth line and the Overground have departure boards with the timetable, delays and
// cancellations (StopPoint/{id}/ArrivalDepartures). Both say where each train ends, and the
// line's station order (linemap.ts) says whether it calls where you get off on the way.

import { keyFor, type LineMap } from "./linemap.ts";
import { fetchTfL } from "./tfl.ts";
import type { Segment } from "./types.ts";

const BASE = "https://api.tfl.gov.uk";

/** The modes TfL has live times for, by station: the ones a next-train Live Activity can follow. */
export const FOLLOWED_MODES = new Set(["tube", "dlr", "elizabeth-line", "overground", "tram"]);

/** One train leaving the station, as TfL gives it. */
export interface Prediction {
  /** When it leaves (ms): the live estimate where there is one. */
  at: number;
  /** The timetable's time, for boards that have one (ms). */
  scheduled?: number;
  cancelled: boolean;
  /** Where it ends: TfL's id for the station. */
  destination?: string;
  platform: string;
}

/** What the Live Activity shows of a train. */
export interface Train {
  /** Seconds since 1970, as the app decodes it. */
  at: number;
  cancelled: boolean;
  /** Minutes behind the timetable, when it's at least one. */
  late?: number;
}

const boards = (mode: string) => mode === "elizabeth-line" || mode === "overground";

export function trainsURL(lineId: string, mode: string, stopId: string): string {
  const stop = encodeURIComponent(stopId), line = encodeURIComponent(lineId);
  return boards(mode) ? `${BASE}/StopPoint/${stop}/ArrivalDepartures?lineIds=${line}` : `${BASE}/Line/${line}/Arrivals/${stop}`;
}

const time = (s: unknown): number | undefined => {
  if (typeof s !== "string" || !s || s.startsWith("0001")) return undefined;
  const ms = Date.parse(/[zZ]|[+-]\d\d:?\d\d$/.test(s) ? s : `${s}Z`);
  return Number.isFinite(ms) ? ms : undefined;
};

type Json = Record<string, any>;

/** Line/{id}/Arrivals: when each train is expected, nothing about the timetable. */
export function parseArrivals(json: unknown): Prediction[] {
  if (!Array.isArray(json)) return [];
  return json.flatMap((a: Json): Prediction[] => {
    const at = time(a.expectedArrival);
    if (at === undefined) return [];
    return [{ at, cancelled: false, destination: a.destinationNaptanId || undefined, platform: String(a.platformName ?? "") }];
  });
}

/** StopPoint/{id}/ArrivalDepartures: the timetable, the estimate and whether it runs. Trains that
 * end here have no departure and are left out. */
export function parseDepartures(json: unknown): Prediction[] {
  if (!Array.isArray(json)) return [];
  return json.flatMap((d: Json): Prediction[] => {
    const scheduled = time(d.scheduledTimeOfDeparture);
    if (scheduled === undefined) return [];
    const cancelled = d.departureStatus === "Cancelled";
    const at = cancelled ? scheduled : time(d.estimatedTimeOfDeparture) ?? scheduled;
    return [{ at, scheduled, cancelled, destination: d.destinationNaptanId || undefined, platform: String(d.platformName ?? "") }];
  });
}

/** Whether a train from `from` that ends at `destination` calls at `to` on the way, on any of the
 * line's service patterns. Undefined when the destination isn't on the line at all. */
export function callsAt(map: LineMap, from: string, to: string, destination: string): boolean | undefined {
  const end = keyFor(map, destination);
  if (!end) return undefined;
  return map.routes.some((route) => {
    const i = route.indexOf(from), j = route.indexOf(to), k = route.indexOf(end);
    if (i < 0 || j < 0 || k < 0 || i === j) return false;
    return i < j ? j <= k : j >= k;
  });
}

/** The trains you can still catch that call where you get off, soonest first. A train whose
 * destination TfL doesn't say ("Check front of train") counts when it's on a platform the
 * others going your way use. */
export function nextTrains(predictions: Prediction[], follow: Segment, map: LineMap, now: number, count = 4): Train[] {
  const from = follow.from && keyFor(map, follow.from.id), to = follow.to && keyFor(map, follow.to.id);
  if (!from || !to) return [];
  const known: Prediction[] = [], unsure: Prediction[] = [];
  for (const p of predictions) {
    if (p.at < now - 30_000) continue;
    const calls = p.destination ? callsAt(map, from, to, p.destination) : undefined;
    if (calls) known.push(p);
    else if (calls === undefined) unsure.push(p);
  }
  const platforms = new Set(known.map((p) => p.platform).filter(Boolean));
  const ours = [...known, ...unsure.filter((p) => p.platform && platforms.has(p.platform))].sort((a, b) => a.at - b.at);
  const trains: Train[] = [], kept: Prediction[] = [];
  for (const p of ours) {
    // Predictions sometimes list one train twice, under two vehicle ids: the same end, platform
    // and timetabled time within half a minute is one train.
    if (kept.some((k) => k.destination === p.destination && k.platform === p.platform && k.scheduled === p.scheduled && Math.abs(k.at - p.at) < 30_000)) continue;
    kept.push(p);
    const late = p.scheduled !== undefined && !p.cancelled ? Math.round((p.at - p.scheduled) / 60_000) : 0;
    trains.push({ at: Math.round(p.at / 1000), cancelled: p.cancelled, ...(late >= 1 ? { late } : {}) });
    if (trains.length >= count) break;
  }
  return trains;
}

/** One station's trains on one line, kept 20 seconds at the edge so every Live Activity there,
 * and the app asking at the same moment, share one request. */
export async function predictions(lineId: string, mode: string, stopIds: string, appKey?: string): Promise<Prediction[]> {
  // A station's ids, the one on the line's routes first ("910GPADTLL|910GPADTON").
  const [stop] = stopIds.split("|");
  const json = await fetchTfL(trainsURL(lineId, mode, stop), 20, appKey, 5000);
  return boards(mode) ? parseDepartures(json) : parseArrivals(json);
}
