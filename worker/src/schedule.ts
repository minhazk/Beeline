// Local time for each phone's time zone, without a date library: Intl knows the zones.

import type { Alert, Direction, TimeWindow } from "./types.ts";

export interface LocalTime {
  year: number;
  month: number;
  day: number;
  weekday: number; // ISO, 1 is Monday
  minutes: number; // after local midnight
}

const WEEKDAYS: Record<string, number> = { Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 };
const formatters = new Map<string, Intl.DateTimeFormat>();

export function localTime(ms: number, timeZone: string): LocalTime {
  let format = formatters.get(timeZone);
  if (!format) {
    format = new Intl.DateTimeFormat("en-GB", {
      timeZone, hourCycle: "h23", weekday: "short", year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric",
    });
    // Zones are canonical before they get here; this only bounds what an isolate can hold.
    if (formatters.size >= 600) formatters.clear();
    formatters.set(timeZone, format);
  }
  const parts = Object.fromEntries(format.formatToParts(new Date(ms)).map((p) => [p.type, p.value]));
  return {
    year: Number(parts.year), month: Number(parts.month), day: Number(parts.day),
    weekday: WEEKDAYS[parts.weekday] ?? 1,
    minutes: Number(parts.hour) * 60 + Number(parts.minute),
  };
}

/** The instant a local wall-clock time happens. */
export function instant(year: number, month: number, day: number, minutes: number, timeZone: string): number {
  const wall = Date.UTC(year, month - 1, day, 0, minutes);
  let guess = wall;
  // Two passes settle the offset either side of a clock change.
  for (let i = 0; i < 2; i++) {
    const t = localTime(guess, timeZone);
    const seen = Date.UTC(t.year, t.month - 1, t.day, 0, t.minutes);
    guess += wall - seen;
  }
  return guess;
}

export function dateKey(t: Pick<LocalTime, "year" | "month" | "day">): string {
  return `${t.year}-${String(t.month).padStart(2, "0")}-${String(t.day).padStart(2, "0")}`;
}

/** The alert's times you are inside now. A window may run past midnight (end before start). */
export function activeWindows(alert: Alert, ms: number, timeZone: string): TimeWindow[] {
  const now = localTime(ms, timeZone);
  const yesterday = now.weekday === 1 ? 7 : now.weekday - 1;
  return alert.windows.filter(({ start, end }) =>
    end > start
      ? alert.days.includes(now.weekday) && now.minutes >= start && now.minutes < end
      : (alert.days.includes(now.weekday) && now.minutes >= start) || (alert.days.includes(yesterday) && now.minutes < end),
  );
}

export const isActive = (alert: Alert, ms: number, timeZone: string) => activeWindows(alert, ms, timeZone).length > 0;

/** The way a time is ridden: its own, else the alert's, else both. */
export const wayOf = (alert: Alert, window?: TimeWindow): Direction => window?.direction ?? alert.direction ?? "both";

/** Several times at once (overlapping, or all of them): one way if they agree, else both. */
export function together(ways: Direction[]): Direction {
  const distinct = new Set(ways);
  return distinct.size === 1 ? [...distinct][0] : "both";
}

/** The alert as ridden during these times, all of them when none are given: what `issuesFor`
 * and `linesToPlace` read. */
export function during(alert: Alert, windows: TimeWindow[] = alert.windows): Alert {
  return { ...alert, direction: together((windows.length ? windows : alert.windows).map((w) => wayOf(alert, w))) };
}

/** One copy of the alert for each way its times go: which lines' station order to load. */
export function eachWay(alert: Alert): Alert[] {
  const ways = new Set(alert.windows.map((w) => wayOf(alert, w)));
  if (!ways.size) ways.add(wayOf(alert));
  return [...ways].map((direction) => ({ ...alert, direction }));
}

export interface TravelRange {
  from: number;
  to: number;
  /** The way that time is ridden. */
  direction: Direction;
}

/** Each time you travel over the next `days` days, from local midnight today, as instants. */
export function travelRanges(alert: Alert, ms: number, timeZone: string, days: number, skipToday = false): TravelRange[] {
  const today = localTime(ms, timeZone);
  const ranges: TravelRange[] = [];
  for (let offset = skipToday ? 1 : 0; offset < days; offset++) {
    const date = new Date(Date.UTC(today.year, today.month - 1, today.day + offset));
    const weekday = date.getUTCDay() === 0 ? 7 : date.getUTCDay();
    if (!alert.days.includes(weekday)) continue;
    const [y, m, d] = [date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate()];
    for (const window of alert.windows) {
      const { start, end } = window;
      const from = instant(y, m, d, start, timeZone);
      const to = instant(y, m, d, end > start ? end : end + 24 * 60, timeZone);
      if (to > ms) ranges.push({ from, to, direction: wayOf(alert, window) });
    }
  }
  return ranges.sort((a, b) => a.from - b.from);
}

/** Planned works for tomorrow are told once, the evening before. */
export const PLANNED_CHECK_AT = 19 * 60;
