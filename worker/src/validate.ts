// The app's alerts, checked before they're stored: shapes and sizes, nothing trusted.

import type { Alert, Environment, Segment, TimeWindow } from "./types.ts";

export class Invalid extends Error {}

const str = (v: unknown, max: number, what: string): string => {
  if (typeof v !== "string" || !v.length || v.length > max) throw new Invalid(`${what} must be text up to ${max} characters`);
  return v;
};

const id = (v: unknown, what: string) => {
  const s = str(v, 64, what);
  // Line ids go into TfL URL paths: dots alone ("..") would climb out of /Line/.
  if (!/^[A-Za-z0-9._-]+$/.test(s) || /^\.+$/.test(s)) throw new Invalid(`${what} has unexpected characters`);
  return s;
};

/** A TfL station id, with its other ids after "|". */
const stationId = (v: unknown, what: string) => {
  const s = str(v, 200, what);
  if (!/^[A-Za-z0-9._-]+(\|[A-Za-z0-9._-]+)*$/.test(s)) throw new Invalid(`${what} has unexpected characters`);
  return s;
};

const list = <T>(v: unknown, max: number, what: string, each: (x: unknown) => T): T[] => {
  if (!Array.isArray(v) || v.length > max) throw new Invalid(`${what} must be a list of up to ${max}`);
  return v.map(each);
};

const MODES = new Set(["tube", "dlr", "elizabeth-line", "overground", "tram", "national-rail"]);

export function segment(v: unknown): Segment {
  const s = (v ?? {}) as Record<string, any>;
  const station = (x: unknown, what: string) => {
    const o = (x ?? {}) as Record<string, unknown>;
    return { id: stationId(o.id, `${what} id`), name: str(o.name, 120, `${what} name`) };
  };
  const mode = str(s.mode, 32, "mode");
  if (!MODES.has(mode)) throw new Invalid(`unknown mode ${mode}`);
  return {
    line: { id: id(s.line?.id, "line id"), name: str(s.line?.name, 80, "line name") },
    mode,
    from: s.from == null ? undefined : station(s.from, "from"),
    to: s.to == null ? undefined : station(s.to, "to"),
    stations: list(s.stations ?? [], 200, "stations", (x) => stationId(x, "station")),
  };
}

function window(v: unknown): TimeWindow {
  const w = (v ?? {}) as Record<string, unknown>;
  const minute = (x: unknown) => {
    if (!Number.isInteger(x) || (x as number) < 0 || (x as number) >= 24 * 60) throw new Invalid("times are minutes after midnight");
    return x as number;
  };
  const start = minute(w.start), end = minute(w.end);
  if (start === end) throw new Invalid("a time can't start and end together");
  // Missing stays missing (the alert's way); a word we don't know is both ways.
  if (w.direction === undefined || w.direction === null) return { start, end };
  return { start, end, direction: w.direction === "out" || w.direction === "back" ? w.direction : "both" };
}

export function alerts(v: unknown): Alert[] {
  const result = list(v, 30, "alerts", (x): Alert => {
    const a = (x ?? {}) as Record<string, unknown>;
    const days = list(a.days, 7, "days", (d) => {
      if (!Number.isInteger(d) || (d as number) < 1 || (d as number) > 7) throw new Invalid("days are 1 (Monday) to 7");
      return d as number;
    });
    return {
      id: id(a.id, "alert id"),
      name: str(a.name, 120, "name"),
      days: [...new Set(days)].sort(),
      windows: list(a.windows, 8, "windows", window),
      minorDelays: a.minorDelays !== false,
      segments: list(a.segments, 8, "segments", segment),
      // Anything else, a newer build's word included, is both ways: when unsure, tell.
      direction: a.direction === "out" || a.direction === "back" ? a.direction : "both",
      ...(a.liveActivity === true ? { liveActivity: true } : {}),
    };
  });
  if (result.some((a) => !a.segments.length || !a.days.length || !a.windows.length)) throw new Invalid("Each alert needs a line and scheduled travel times");
  if (new Set(result.flatMap((a) => a.segments.map((s) => s.line.id))).size > 48) throw new Invalid("An install can watch up to 48 distinct lines");
  return result;
}

/** What a Live Activity follows: a line from where you board to where you get off. */
export function follow(v: unknown): Segment {
  const s = segment(v);
  if (!s.from || !s.to || s.from.id === s.to.id) throw new Invalid("A Live Activity needs the station you board at and the one you get off at");
  return { line: s.line, mode: s.mode, from: s.from, to: s.to, stations: [] };
}

/** When a Live Activity ends (seconds since 1970): ahead, and at most eight hours, as long as
 * iOS keeps one. */
export function ends(v: unknown, now: number): number {
  if (typeof v !== "number" || !Number.isFinite(v) || v * 1000 <= now) throw new Invalid("ends must be a time ahead, in seconds since 1970");
  return Math.min(Math.round(v * 1000), now + 8 * 3600_000);
}

export function environment(v: unknown): Environment {
  if (v !== "sandbox" && v !== "production") throw new Invalid("environment is sandbox or production");
  return v;
}

export function timeZone(v: unknown): string {
  const zone = str(v, 64, "timeZone");
  try {
    new Intl.DateTimeFormat("en-GB", { timeZone: zone });
  } catch {
    throw new Invalid(`unknown time zone ${zone}`);
  }
  return zone;
}

/** Each install's own secret (X-Device-Secret): random, generated on the phone. */
export function deviceSecret(v: string | undefined): string {
  if (!v || !/^[A-Za-z0-9_-]{32,128}$/.test(v)) throw new Invalid("missing or malformed device secret");
  return v;
}

export function deviceToken(v: string): string {
  if (!/^[0-9a-f]{64,200}$/i.test(v)) throw new Invalid("not a device token");
  return v.toLowerCase();
}
