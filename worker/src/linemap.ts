import { inGroups } from "./linechecks.ts";
// A line's stations in order, branches and all, from TfL's Line/{id}/Route/Sequence/all: enough
// to place the stations TfL names in its notices ("between Paddington and Heathrow Terminals")
// and to tell which way "westbound" or "towards Heathrow" is for a stretch you ride.

import { fetchTfL, routeSequenceURL } from "./tfl.ts";

export interface Place {
  /** TfL's ids for it: a hub's platforms and the stops on each route. */
  ids: string[];
  /** Normalised spellings ("paddington", "london paddington"). */
  names: string[];
  lat: number;
  lon: number;
}

export interface LineMap {
  lineId: string;
  /** Each station by its key (TfL's hub, or the stop when it has none). */
  places: Map<string, Place>;
  /** Any of TfL's ids to its station's key. */
  keyOf: Map<string, string>;
  /** Each of TfL's service patterns, as station keys in order. */
  routes: string[][];
}

type Json = Record<string, any>;

export function parseLineMap(lineId: string, json: unknown): LineMap | undefined {
  const body = (json ?? {}) as Json;
  const stops: Json[] = [...(body.stopPointSequences ?? []).flatMap((s: Json) => s.stopPoint ?? []), ...(body.stations ?? [])];
  const places = new Map<string, Place & { points: [number, number][] }>();
  const keyOf = new Map<string, string>();
  for (const stop of stops) {
    if (typeof stop.id !== "string") continue;
    const key: string = stop.topMostParentId ?? stop.id;
    const place = places.get(key) ?? { ids: [], names: [], lat: 0, lon: 0, points: [] };
    places.set(key, place);
    if (!place.ids.includes(stop.id)) place.ids.push(stop.id);
    for (const name of spellings(stop.name ?? "")) if (!place.names.includes(name)) place.names.push(name);
    if (Number.isFinite(stop.lat) && Number.isFinite(stop.lon) && (stop.lat || stop.lon)) place.points.push([stop.lat, stop.lon]);
    keyOf.set(stop.id, key);
  }
  const routes = (body.orderedLineRoutes ?? []).map((r: Json) =>
    (r.naptanIds ?? []).map((id: string) => keyOf.get(id) ?? id).filter((k: string, i: number, all: string[]) => k !== all[i - 1]),
  ).filter((r: string[]) => r.length > 1);
  if (!routes.length) return undefined;
  const onRoutes = new Set(routes.flat());
  const kept = new Map<string, Place>();
  for (const [key, place] of places) {
    if (!onRoutes.has(key)) continue;
    const n = place.points.length || 1;
    kept.set(key, {
      ids: place.ids,
      names: place.names,
      lat: place.points.reduce((s, p) => s + p[0], 0) / n,
      lon: place.points.reduce((s, p) => s + p[1], 0) / n,
    });
  }
  for (const id of [...keyOf.keys()]) if (!kept.has(keyOf.get(id)!)) keyOf.delete(id);
  return { lineId, places: kept, keyOf, routes };
}

/** "Hayes & Harlington Rail Station" → "hayes and harlington"; also without "london" and without
 * what's in brackets, so "Edgware Road (Circle Line)" answers to "Edgware Road". */
export function spellings(name: string): string[] {
  const base = name
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/['’`]/g, "")
    .replace(/\b(underground|rail|dlr|tram|national|overground|station|stations)\b/g, " ")
    .replace(/\bterminals\b/g, "terminal");
  const tidy = (s: string) => s.replace(/[^a-z0-9]+/g, " ").trim();
  const forms = [tidy(base), tidy(base.replace(/\([^)]*\)/g, " "))];
  for (const form of [...forms]) if (form.startsWith("london ") && form.length > 10) forms.push(form.slice(7));
  return [...new Set(forms.filter(Boolean))];
}

/** The stations a name in TfL's words means: exact first, else every station whose name starts
 * with it ("Heathrow" → all three). Empty when it can't be placed. */
export function place(map: LineMap, name: string): Set<string> {
  const asked = spellings(name);
  const found = new Set<string>();
  for (const [key, p] of map.places) if (p.names.some((n) => asked.includes(n))) found.add(key);
  if (found.size) return found;
  for (const q of asked) {
    if (q.length < 4) continue;
    for (const [key, p] of map.places) if (p.names.some((n) => n.startsWith(`${q} `))) found.add(key);
  }
  return found;
}

/** Every station on a route between any of `a` and any of `b`, through `via` when given. */
export function between(map: LineMap, a: Set<string>, b: Set<string>, via?: Set<string>): Set<string> {
  const section = new Set<string>();
  const add = (routes: string[][]) => {
    for (const route of routes) {
      for (let i = 0; i < route.length; i++) {
        if (!a.has(route[i])) continue;
        for (let j = 0; j < route.length; j++) {
          if (i === j || !b.has(route[j])) continue;
          for (let k = Math.min(i, j); k <= Math.max(i, j); k++) section.add(route[k]);
        }
      }
    }
  };
  if (via?.size) add(map.routes.filter((r) => r.some((k) => via.has(k))));
  if (!section.size) add(map.routes);
  return section;
}

/** The station one of TfL's ids ("910GLIVSTLL|910GLIVST") belongs to. */
export function keyFor(map: LineMap, ids: string): string | undefined {
  for (const id of ids.split("|")) {
    const key = map.keyOf.get(id) ?? (map.places.has(id) ? id : undefined);
    if (key) return key;
  }
  return undefined;
}

/** Stops along the line from any of `targets` to each station. */
export function distances(map: LineMap, targets: Set<string>): Map<string, number> {
  const next = new Map<string, Set<string>>();
  for (const route of map.routes) {
    for (let i = 1; i < route.length; i++) {
      (next.get(route[i - 1]) ?? next.set(route[i - 1], new Set()).get(route[i - 1])!).add(route[i]);
      (next.get(route[i]) ?? next.set(route[i], new Set()).get(route[i])!).add(route[i - 1]);
    }
  }
  const far = new Map<string, number>([...targets].map((t) => [t, 0]));
  let edge = [...targets];
  while (edge.length) {
    const ahead: string[] = [];
    for (const key of edge) {
      for (const n of next.get(key) ?? []) {
        if (far.has(n)) continue;
        far.set(n, far.get(key)! + 1);
        ahead.push(n);
      }
    }
    edge = ahead;
  }
  return far;
}

/** Whether riding from `a` to `b` is east (1) or west (-1), north or south, as TfL names a
 * line's directions: by each service pattern through both, end to end, and only when the ride
 * itself moves that way too. 0 (unsure) when the patterns disagree, run mostly across that
 * axis, or the ride moves the other way. */
export function heading(map: LineMap, a: string, b: string, axis: "ew" | "ns"): 0 | 1 | -1 {
  const signs = new Set<number>();
  for (const route of map.routes) {
    const i = route.indexOf(a), j = route.indexOf(b);
    if (i < 0 || j < 0 || i === j) continue;
    const first = map.places.get(route[0]), last = map.places.get(route.at(-1)!);
    if (!first || !last) continue;
    const dLat = last.lat - first.lat, dLon = (last.lon - first.lon) * Math.cos((first.lat * Math.PI) / 180);
    const along = axis === "ew" ? dLon : dLat, across = axis === "ew" ? dLat : dLon;
    // Mostly the other way, or a loop back to where it started: no answer from this one.
    if (Math.abs(along) < 0.005 || Math.abs(along) < Math.abs(across) * 0.5) continue;
    signs.add(Math.sign(along) * (j > i ? 1 : -1));
  }
  if (signs.size !== 1) return 0;
  const sign = [...signs][0] as 1 | -1;
  // A line that doubles back (the Circle) can run west end to end while this ride runs east:
  // when the ride itself moves the other way along that axis at all (more than a few tens of
  // metres), unsure. Bends like the District's Wimbledon branch come out unsure too.
  const from = map.places.get(a), to = map.places.get(b);
  if (from && to) {
    const along = axis === "ew" ? (to.lon - from.lon) * Math.cos((from.lat * Math.PI) / 180) : to.lat - from.lat;
    if (Math.abs(along) >= 0.0003 && Math.sign(along) !== sign) return 0;
  }
  return sign;
}

/** A line's stations change rarely: kept a week at the edge, and six hours in this isolate so a
 * notice that lasts all evening isn't re-read from the cache every two minutes. */
export const SEQUENCE_TTL = 7 * 24 * 3600;
const held = new Map<string, { map: LineMap; at: number }>();
/** A line TfL didn't answer for: not asked again for ten minutes. */
const failed = new Map<string, number>();

/** The maps for these lines. One that can't be had is left out, and its trouble counts as now. */
export async function loadLineMaps(ids: string[], appKey?: string, now = Date.now()): Promise<Map<string, LineMap>> {
  const maps = new Map<string, LineMap>();
  await inGroups([...new Set(ids)], async (id) => {
    const kept = held.get(id);
    if (kept && now - kept.at < 6 * 3600_000) return void maps.set(id, kept.map);
    if (now - (failed.get(id) ?? -Infinity) < 10 * 60_000) return;
    try {
      // Every push waits on this: a TfL that hangs is a TfL that failed.
      const map = parseLineMap(id, await fetchTfL(routeSequenceURL(id), SEQUENCE_TTL, appKey, 4000));
      if (!map) return;
      held.set(id, { map, at: now });
      maps.set(id, map);
    } catch (error) {
      failed.set(id, now);
      console.error("line order unavailable", id, String(error));
    }
  });
  return maps;
}

/** For tests. */
export const forgetLineMaps = () => (held.clear(), failed.clear());
