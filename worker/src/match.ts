// Which of TfL's disruptions touch the stretch of line you use.

import { clauses, wayIn, type Clause, type Family, type Section, type Way } from "./clauses.ts";
import { between, distances, heading, keyFor, place, spellings, type LineMap } from "./linemap.ts";
import type { LineStatus, StationDisruption } from "./tfl.ts";
import type { Alert, Direction, Issue, Segment, Severity } from "./types.ts";

type Bucket = "closed" | "part" | "delays" | "minor";

/** TfL's statusSeverity, by what it means for a ride. Good service, information and
 * National Rail's "special service" (a link to its site) aren't disruptions. */
const BUCKETS: Record<number, Bucket> = {
  1: "closed", 2: "closed", 4: "closed", 16: "closed", 20: "closed", // closed, suspended, planned closure, not running, service closed
  3: "part", 5: "part", 11: "part", // part suspended, part closure, part closed
  6: "delays", 7: "delays", 8: "delays", 15: "delays", 17: "delays", // severe, reduced service, bus service, diverted, issues reported
  9: "minor", 14: "minor", // minor delays, change of frequency
};

export const rank = (s: Severity) => ({ minor: 1, delays: 2, closed: 3 })[s];

export interface When {
  /** Live: what applies at this instant. */
  at?: number;
  /** Planned works overlapping any of these times you travel. */
  ranges?: { from: number; to: number }[];
}

export type LineMaps = Map<string, LineMap>;

/** `maps` places the stations TfL names in its words, for the lines that need it
 * (`linesToPlace`). Without one, trouble TfL doesn't list stations for counts everywhere. */
export function issuesFor(alert: Alert, lines: LineStatus[], stations: StationDisruption[], when: When, maps: LineMaps = new Map()): Issue[] {
  const found = new Map<string, Issue>();
  for (const segment of alert.segments) {
    for (const issue of [...lineIssues(alert, segment, lines, when, maps), ...stationIssues(alert, segment, stations, when, maps)]) {
      const seen = found.get(issue.signature);
      if (!seen || rank(issue.severity) > rank(seen.severity)) found.set(issue.signature, issue);
    }
  }
  return worstFirst(found);
}

const worstFirst = (found: Map<string, Issue>) => [...found.values()].sort((a, b) => rank(b.severity) - rank(a.severity) || (a.from ?? 0) - (b.from ?? 0));

/** Planned works on times you travel, each time judged the way it is ridden (a morning slot
 * "to Paddington", an evening one "to Reading"); one issue per disruption, the worst kept. */
export function issuesInRanges(alert: Alert, lines: LineStatus[], stations: StationDisruption[], ranges: { from: number; to: number; direction?: Direction }[], maps: LineMaps = new Map()): Issue[] {
  const byWay = new Map<Direction, { from: number; to: number }[]>();
  for (const r of ranges) {
    const way = r.direction ?? alert.direction ?? "both";
    byWay.set(way, [...(byWay.get(way) ?? []), r]);
  }
  const found = new Map<string, Issue>();
  for (const [direction, group] of byWay) {
    for (const issue of issuesFor({ ...alert, direction }, lines, stations, { ranges: group }, maps)) {
      const seen = found.get(issue.signature);
      if (!seen || rank(issue.severity) > rank(seen.severity) || (rank(issue.severity) === rank(seen.severity) && (issue.from ?? 0) < (seen.from ?? 0))) found.set(issue.signature, issue);
    }
  }
  return worstFirst(found);
}

/** The lines whose station order is needed to judge these alerts: TfL named sections in words
 * without listing stations, or said one way only to an alert that goes one way. */
export function linesToPlace(alerts: Alert[], lines: LineStatus[], stations: StationDisruption[]): string[] {
  const need = new Set<string>();
  for (const alert of alerts) {
    const oneWay = alert.direction === "out" || alert.direction === "back";
    for (const segment of alert.segments) {
      const id = segment.line.id;
      if (need.has(id) || !segment.stations.length) continue;
      for (const status of lines) {
        if (status.lineId !== id || !BUCKETS[status.severity]) continue;
        const said = clauses(status.reason);
        if ((!status.stops.length && said.some((c) => c.sections.length)) || (oneWay && said.some((c) => c.way))) need.add(id);
      }
      if (!oneWay) continue;
      const ends = new Set([...(segment.from?.id.split("|") ?? []), ...(segment.to?.id.split("|") ?? [])]);
      if (stations.some((d) => ends.has(d.stationId) && wayIn(d.description))) need.add(id);
    }
  }
  return [...need];
}

function applies(periods: { from: number; to: number }[], planned: boolean, when: When): { applies: boolean; from?: number } {
  if (when.ranges) {
    // Ahead of time, only planned works: live trouble now says nothing about tomorrow.
    if (!planned) return { applies: false };
    const hit = periods.find((p) => when.ranges!.some((r) => p.from < r.to && p.to > r.from));
    return { applies: !!hit, from: hit?.from };
  }
  const at = when.at ?? Date.now();
  return { applies: periods.length === 0 || periods.some((p) => p.from <= at && at <= p.to) };
}

const familyOf = (bucket: Bucket): Family => (bucket === "closed" || bucket === "part" ? "closure" : bucket);
const units = (said: Clause[]) => said.reduce((n, c) => n + Math.max(1, c.sections.length), 0);

function lineIssues(alert: Alert, segment: Segment, lines: LineStatus[], when: When, maps: LineMaps): Issue[] {
  // Each station may carry TfL's other ids for it ("910GLIVSTLL|910GLIVST").
  const ours = segment.stations.map((s) => s.split("|"));
  const map = maps.get(segment.line.id);
  const statuses = lines.filter((s) => s.lineId === segment.line.id);
  const issues = statuses.flatMap((status): Issue[] => {
    const bucket = BUCKETS[status.severity];
    if (!bucket) return [];
    const timing = applies(status.periods, status.planned, when);
    if (!timing.applies) return [];
    const said = clauses(status.reason);
    const family = familyOf(bucket);
    // A notice often comes as one status per severity, each with the whole text: this status's
    // own trouble is the clauses at its severity.
    const own = said.filter((c) => c.family === family);
    const title = `${segment.line.name}: ${status.summary.toLowerCase()}`;
    const signature = (severity: string | number, key: string) => `line:${status.lineId}:${severity}:${hash(status.planned ? status.reason + key : key)}`;
    const way = (c: Clause) => goesThatWay(alert, segment, c.way, map);

    if (status.stops.length) {
      if (bucket === "minor" && !alert.minorDelays) return [];
      if (own.length && !own.some(way)) return [];
      // TfL lists the stations a disruption covers.
      const stops = new Set(status.stops);
      const hit = ours.map((ids) => ids.some((id) => stops.has(id)));
      const touched = hit.filter(Boolean).length;
      if (ours.length && touched === 0) return [];
      let severity: Severity;
      if (family === "closure") {
        // Riding within a closed stretch (two of its stations) won't work; touching one end of it
        // usually still does, since the end station is served, but expect trouble.
        severity = !ours.length ? (bucket === "closed" ? "closed" : "delays") : touched >= 2 ? "closed" : "delays";
      } else {
        // Delays on a section that only meets yours at one station, and runs off elsewhere, aren't on your way.
        if (ours.length && !hit.some((h, i) => h && hit[i + 1]) && stops.size > 1) return [];
        severity = bucket as Severity;
      }
      const detail = own.length && units(own) < units(said) ? own.map((c) => c.text).join(" ") : clean(status.reason);
      return [{ signature: signature(status.severity, status.planned ? "" : [...status.stops].sort().join(",")), severity, line: segment.line.name, title, detail, from: timing.from }];
    }

    // No stations listed: TfL's words say where, if anywhere. Clauses at a severity no status of
    // this notice has go with the first status without stations, so each is judged once.
    const siblings = statuses.filter((s) => s.reason === status.reason && BUCKETS[s.severity]);
    const told = new Set(siblings.map((s) => familyOf(BUCKETS[s.severity])));
    const first = siblings.find((s) => !s.stops.length) === status;
    const take = said.filter((c) => c.family === family || (first && !told.has(c.family)));
    if (!take.length) {
      // Nowhere in particular: the whole line.
      if (bucket === "minor" && !alert.minorDelays) return [];
      return [{ signature: signature(status.severity, ""), severity: bucket === "closed" ? "closed" : bucket === "part" ? "delays" : bucket, line: segment.line.name, title, detail: clean(status.reason), from: timing.from }];
    }
    const whole = units(said) === 1;
    return take.flatMap((c): Issue[] => {
      const named = c.family === family ? title : `${segment.line.name}: ${c.phrase.toLowerCase()}`;
      const level: Severity = c.family === "closure" ? (bucket === "closed" ? "closed" : "delays") : c.family;
      const tag = c.family === family ? status.severity : c.family;
      // Trouble with no section named (or "on the rest of the line") counts anywhere on the line.
      if (!c.sections.length) return !way(c) ? [] : [{ signature: signature(tag, ""), severity: level, line: segment.line.name, title: named, detail: whole ? clean(status.reason) : c.text, from: timing.from }];
      return c.sections.flatMap((s, k): Issue[] => {
        // One way only applies to the section that says so ("and westbound between …").
        if (!goesThatWay(alert, segment, s.way, map)) return [];
        const detail = whole ? clean(status.reason) : c.sectionTexts[k];
        // By the section's names, so it's the same disruption with or without the line's order.
        const id = signature(tag, [...s.from, "|", ...s.to, ...(s.via ? ["via", s.via] : [])].map((n) => spellings(n)[0] ?? n).join("/"));
        const covered = map ? sectionStations(map, s) : undefined;
        // A name we can't find on the line: when unsure, tell.
        if (!covered) return [{ signature: id, severity: level, line: segment.line.name, title: named, detail, section: s, from: timing.from }];
        const keys = segment.stations.map((ids) => keyFor(map!, ids));
        // A station of yours the line no longer knows (renumbered since the alert was saved): unsure, tell.
        if (ours.length && keys.some((key) => !key)) return [{ signature: id, severity: level, line: segment.line.name, title: named, detail, section: s, from: timing.from }];
        let severity = level;
        if (ours.length) {
          const hit = keys.map((key) => !!key && covered.has(key));
          // Sharing track: two stations next to each other on your stretch are both inside it.
          if (hit.some((h, i) => h && hit[i + 1])) severity = c.family === "closure" ? "closed" : level;
          // A closure that ends where you get on or off: the station is served, but expect trouble.
          else if (c.family === "closure" && hit.some(Boolean)) severity = "delays";
          else return [];
        }
        return [{ signature: id, severity, line: segment.line.name, title: named, detail, section: s, from: timing.from }];
      });
    });
  });
  return issues.filter((i) => i.severity !== "minor" || alert.minorDelays);
}

/** Where on the line a section in TfL's words is; undefined when a name isn't on it. */
export function sectionStations(map: LineMap, s: Section): Set<string> | undefined {
  const ends = (names: string[]) => {
    const found = names.map((n) => place(map, n));
    return found.some((f) => !f.size) ? undefined : new Set(found.flatMap((f) => [...f]));
  };
  const a = ends(s.from), b = ends(s.to);
  if (!a || !b) return undefined;
  const via = s.via ? place(map, s.via) : undefined;
  // Every end named ("Reading and Abbey Wood / Shenfield") must reach one at the other end
  // along the line, or a branch would drop out unseen.
  const covered = new Set<string>();
  const reached = new Set<string>();
  for (const from of s.from) {
    for (const to of s.to) {
      const part = between(map, place(map, from), place(map, to), via);
      if (!part.size) continue;
      reached.add(`a:${from}`).add(`b:${to}`);
      for (const key of part) covered.add(key);
    }
  }
  if (s.from.some((n) => !reached.has(`a:${n}`)) || s.to.some((n) => !reached.has(`b:${n}`))) return undefined;
  return covered.size ? covered : undefined;
}

/** Whether trouble TfL says is one way only is on the way this alert goes. Both ways, wording
 * we can't resolve, or no map: yes. */
export function goesThatWay(alert: Alert, segment: Segment, way: Way | undefined, map: LineMap | undefined): boolean {
  if (!way || (alert.direction !== "out" && alert.direction !== "back")) return true;
  if (!map || !segment.from || !segment.to) return true;
  let a = keyFor(map, segment.from.id), b = keyFor(map, segment.to.id);
  if (!a || !b || a === b) return true;
  if (alert.direction === "back") [a, b] = [b, a];
  if (way.compass) {
    const h = heading(map, a, b, way.compass.axis);
    return h === 0 || h === way.compass.sign;
  }
  if (way.towards) {
    // Towards any of them; a place we can't find, or can't tell, is a yes.
    for (const name of way.towards) {
      const targets = place(map, name);
      if (!targets.size) return true;
      const far = distances(map, targets);
      const from = far.get(a), to = far.get(b);
      if (from === undefined || to === undefined || from === to || to < from) return true;
    }
    return false;
  }
  return true;
}

function stationIssues(alert: Alert, segment: Segment, stations: StationDisruption[], when: When, maps: LineMaps): Issue[] {
  const fromIds = segment.from?.id.split("|") ?? [], toIds = segment.to?.id.split("|") ?? [];
  const ends = new Set([...fromIds, ...toIds]);
  if (!ends.size) return [];
  return stations.flatMap((d): Issue[] => {
    if (!ends.has(d.stationId) || d.mode !== segment.mode) return [];
    if (d.lines.length && !d.lines.includes(segment.line.id)) return [];
    // A stretch with no service is listed against each of its stations; the line's own
    // status says it once, with the stations it covers.
    if (/no service|suspended/i.test(d.description)) return [];
    const timing = applies(d.from !== undefined && d.to !== undefined ? [{ from: d.from, to: d.to }] : [], d.planned, when);
    if (!timing.applies) return [];
    // Trains not calling one way still call the other way, and only matter if it's yours.
    const oneWay = /\b(west|east|north|south)bound\b/i.test(d.description);
    const closure = d.type === "Closure";
    // A station closed outright is closed both ways, whatever compass word its notice uses.
    if (!closure && !goesThatWay(alert, segment, wayIn(d.description), maps.get(segment.line.id))) return [];
    const name = fromIds.includes(d.stationId) ? segment.from!.name : toIds.includes(d.stationId) ? segment.to!.name : d.name;
    return [{
      signature: `stop:${d.stationId}:${hash(d.description)}`,
      severity: closure || !oneWay ? "closed" : "delays",
      line: segment.line.name,
      title: closure ? `${name} closed (${segment.line.name})` : `${name} part closed (${segment.line.name})`,
      detail: clean(d.description),
      from: timing.from,
    }];
  });
}

/** TfL opens with the line or station in capitals ("ELIZABETH LINE: …", "Canary Wharf: …"),
 * which the notification already says. */
export function clean(text: string): string {
  return text
    .replace(/^\s*[A-Z][A-Za-z0-9&'’() .-]{1,48}:\s+/, "")
    .replace(/\s+/g, " ")
    .trim();
}

/** FNV-1a, enough to tell one notice from another. */
export function hash(text: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 0x01000193) >>> 0;
  return h.toString(36);
}
