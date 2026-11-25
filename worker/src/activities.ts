// Next-train Live Activities. The app registers each one's push token with what it follows (a
// line, the station you board at and the one you get off at) and when it ends. Every minute the
// server asks TfL for that station's trains and pushes the next few when they change, and ends it
// when its time is up. At a saved line's travel times it starts one itself, with the phone's
// push-to-start token. Times tick on the phone between pushes; a push is only for news: a train
// gone, a new estimate, a cancellation, trouble on the way.

import { canPush, send, type Sent, type TokenMemo } from "./apns.ts";
import { maxPushes, tflRequests, type Env } from "./checks.ts";
import { inGroups, lineCatalog, lineChecks, stationChecks } from "./linechecks.ts";
import { keyFor, loadLineMaps, type LineMap } from "./linemap.ts";
import { issuesFor } from "./match.ts";
import type { Push } from "./push.ts";
import { activeWindows, instant, localTime, wayOf } from "./schedule.ts";
import { FOLLOWED_MODES, nextTrains, predictions, type Prediction, type Train } from "./trains.ts";
import type { LineStatus, StationDisruption, TfLAccess } from "./tfl.ts";
import type { Alert, Environment, Segment, TimeWindow } from "./types.ts";

/** What the Live Activity shows, as the app's NextTrainAttributes.ContentState decodes it.
 * BeelineTests/Fixtures/next-train-contract.json is the example both sides test against. */
export interface ContentState {
  trains: Train[];
  /** Trouble on the way, in a few words: "Severe delays". */
  notice?: string;
  /** Seconds since 1970. */
  updated: number;
  live: boolean;
}

/** The Live Activity's fixed part, for one the server starts (NextTrainAttributes). */
export interface Attributes {
  key: string;
  line: string;
  symbol: string;
  color?: string;
  stop: string;
  towards?: string;
  follow: Segment;
  /** Seconds since 1970. */
  ends: number;
}

const sec = (ms: number) => Math.floor(ms / 1000);
const MINUTE = 60_000;

// MARK: What to show

/** The stations between where you board and where you get off, in order, as an alert's
 * segment lists them, so trouble on the way is judged as alerts judge it. */
export function withStations(follow: Segment, map: LineMap): Segment {
  const from = follow.from && keyFor(map, follow.from.id), to = follow.to && keyFor(map, follow.to.id);
  if (!from || !to) return follow;
  let best: string[] | undefined;
  for (const route of map.routes) {
    const i = route.indexOf(from), j = route.indexOf(to);
    if (i < 0 || j < 0 || i === j) continue;
    const run = i < j ? route.slice(i, j + 1) : route.slice(j, i + 1).reverse();
    if (!best || run.length < best.length) best = run;
  }
  if (!best) return follow;
  return { ...follow, stations: best.map((key) => map.places.get(key)?.ids.join("|") ?? key) };
}

/** "Central line: severe delays" → "Severe delays"; a station's closure keeps its name. */
export function shortNotice(title: string, lineName: string): string {
  const text = title.startsWith(`${lineName}: `) ? title.slice(lineName.length + 2) : title;
  const said = text.charAt(0).toUpperCase() + text.slice(1);
  return said.length > 40 ? `${said.slice(0, 39).trimEnd()}…` : said;
}

/** Everything needed to say what each of these follows shows now: one request per station and
 * line for the trains, the line's station order, and TfL's status for trouble on the way, within
 * what the invocation may still ask (`tfl`). A follow whose trains TfL didn't give comes back
 * undefined, and keeps what it last showed. */
export async function lookup(env: Env, follows: Segment[], now: number, tfl: TfLAccess): Promise<(follow: Segment) => ContentState | undefined> {
  const maps = await loadLineMaps(follows.map((f) => f.line.id), tfl, now);
  const boards = new Map<string, Prediction[]>();
  const at = (f: Segment) => `${f.line.id}|${f.mode}|${f.from?.id}`;
  await inGroups([...new Map(follows.map((f) => [at(f), f])).values()], async (f) => {
    try { boards.set(at(f), await predictions(f.line.id, f.mode, f.from!.id, tfl)); }
    catch (error) { console.error("trains unavailable", f.line.id, String(error)); }
  });
  let lines: LineStatus[] = [], stations: StationDisruption[] = [];
  try {
    const catalog = await lineCatalog(tfl);
    [lines, stations] = await Promise.all([
      lineChecks(follows, catalog, tfl).then((r) => r.lines),
      stationChecks(follows, tfl).then((r) => r.stations),
    ]);
  } catch {
    // Trouble is extra: the trains still go out without it.
  }
  return (follow) => {
    const map = maps.get(follow.line.id), board = boards.get(at(follow));
    if (!map || !board) return undefined;
    const segment = withStations(follow, map);
    const ride: Alert = { id: "live", name: "", days: [1, 2, 3, 4, 5, 6, 7], windows: [{ start: 0, end: 1439 }], minorDelays: true, segments: [segment], direction: "out" };
    const [issue] = issuesFor(ride, lines, stations, { at: now }, maps);
    return {
      trains: nextTrains(board, follow, map, now),
      ...(issue ? { notice: shortNotice(issue.title, follow.line.name) } : {}),
      updated: sec(now),
      live: true,
    };
  };
}

/** Whether what's shown has changed enough to push, and how urgently: 10 when the train you're
 * after has gone or moved or been cancelled; 5 for the later ones, delays and trouble; none when
 * it's the same. A push sets when the phone next looks again (`stale-date`), so one goes out each
 * time the first train leaves. */
export function urgency(before: ContentState | undefined, after: ContentState, now: number): 0 | 5 | 10 {
  if (!before) return 10;
  const [gone] = before.trains;
  if (gone && gone.at * 1000 <= now) return 10;
  const same = (a?: Train, b?: Train) =>
    !!a && !!b && Math.abs(a.at - b.at) < 60 && a.cancelled === b.cancelled && (a.late ?? 0) === (b.late ?? 0);
  const [a, b] = [before.trains.slice(0, 3), after.trains.slice(0, 3)];
  if (!same(a[0], b[0]) && (a.length || b.length)) return 10;
  if (a.length !== b.length || a.some((t, i) => !same(t, b[i])) || before.notice !== after.notice) return 5;
  return 0;
}

/** When the phone should stop trusting what it shows: just after the first train leaves, or
 * in ten minutes when there's none. */
export function staleDate(state: ContentState, now: number): number {
  const first = state.trains.find((t) => t.at * 1000 > now);
  return Math.min(first ? first.at + 30 : sec(now) + 600, sec(now) + 15 * 60);
}

export function updatePush(state: ContentState, priority: 5 | 10, now: number): Push {
  return {
    type: "liveactivity",
    payload: { aps: { timestamp: sec(now), event: "update", "content-state": state, "stale-date": staleDate(state, now) } },
    priority,
    expiration: sec(now) + 120,
  };
}

export function endPush(state: ContentState | undefined, now: number): Push {
  return {
    type: "liveactivity",
    payload: { aps: { timestamp: sec(now), event: "end", "content-state": state ?? { trains: [], updated: sec(now), live: false }, "dismissal-date": sec(now) } },
    priority: 10,
    expiration: sec(now) + 3600,
  };
}

export function startPush(attributes: Attributes, state: ContentState, now: number): Push {
  return {
    type: "liveactivity",
    payload: {
      aps: {
        timestamp: sec(now),
        event: "start",
        "attributes-type": "NextTrainAttributes",
        attributes,
        "content-state": state,
        "stale-date": staleDate(state, now),
        // Starting one needs an alert; no sound, so it lights the screen and no more.
        alert: { title: `${attributes.line} from ${attributes.stop}`, body: attributes.towards ? `Next trains to ${attributes.towards}` : "Next trains" },
      },
    },
    priority: 10,
    expiration: sec(now) + 300,
  };
}

// MARK: Starting at your travel times

/** "Central line" → "Central", as the line's pill says it. */
export const pillName = (name: string) => name.replace(/ line$/i, "");

/** The SF Symbol the app draws for the mode (LegMode.symbol). */
export function symbolFor(mode: string): string {
  if (mode === "tube") return "tram.fill.tunnel";
  if (mode === "dlr" || mode === "tram") return "tram.fill";
  return "train.side.front.car";
}

// TfL's line colours, as the app's LineColors has them, for a Live Activity the server starts.
const COLOURS: Record<string, string> = {
  bakerloo: "B36305", central: "E32017", circle: "FFD300", district: "00782A", "hammersmith-city": "F3A9BB",
  jubilee: "A0A5A9", metropolitan: "9B0056", northern: "2B2B2B", piccadilly: "1C3F94", victoria: "0098D4",
  "waterloo-city": "95CDBA", elizabeth: "6950A1", dlr: "00A4A7", liberty: "61686B", lioness: "FFA32B",
  mildmay: "2E86F0", suffragette: "59C274", weaver: "A0457A", windrush: "EF4D5E", tram: "5FB526",
};
const MODE_COLOURS: Record<string, string> = { tube: "1C3F94", overground: "EE7C0E", "elizabeth-line": "6950A1", dlr: "00A4A7", tram: "5FB526" };
export const colourFor = (lineId: string, mode: string) => COLOURS[lineId] ?? MODE_COLOURS[mode];

/** What a time of a saved line follows: its first stretch going out, its last coming back. Nil
 * for a whole-line alert, which has no station to board at, or a line TfL has no times for. */
export function followFor(alert: Alert, window: TimeWindow): Segment | undefined {
  const back = wayOf(alert, window) === "back";
  const segment = back ? alert.segments.at(-1) : alert.segments[0];
  if (!segment?.from || !segment.to || !FOLLOWED_MODES.has(segment.mode)) return undefined;
  return { line: segment.line, mode: segment.mode, from: back ? segment.to : segment.from, to: back ? segment.from : segment.to, stations: [] };
}

/** When the time you're in started and ends (ms), today's or, after midnight, yesterday's. */
export function span(window: TimeWindow, now: number, timeZone: string): { from: number; to: number } {
  const t = localTime(now, timeZone);
  const overnight = window.end <= window.start;
  const day = overnight && t.minutes < window.end ? t.day - 1 : t.day;
  return {
    from: instant(t.year, t.month, day, window.start, timeZone),
    to: instant(t.year, t.month, day, overnight ? window.end + 1440 : window.end, timeZone),
  };
}

export function attributesFor(alert: Alert, follow: Segment, ends: number): Attributes {
  const colour = colourFor(follow.line.id, follow.mode);
  return {
    key: `alert:${alert.id}`,
    line: pillName(follow.line.name),
    symbol: symbolFor(follow.mode),
    ...(colour ? { color: colour } : {}),
    stop: follow.from!.name,
    towards: follow.to!.name,
    follow,
    ends: sec(ends),
  };
}

interface StartRow {
  token: string;
  environment: Environment;
  time_zone: string;
  alerts: string;
  start_token: string;
  started: string;
}

interface Due {
  device: StartRow;
  alert: Alert;
  follow: Segment;
  occurrence: string;
  ends: number;
}

/** Saved lines set to start a Live Activity, whose travel time has begun and has more than ten
 * minutes left, and that haven't had one this time. */
export function dueStarts(devices: StartRow[], now: number): Due[] {
  return devices.flatMap((device) => {
    const alerts = JSON.parse(device.alerts) as Alert[];
    const started = JSON.parse(device.started || "{}") as Record<string, string>;
    return alerts.flatMap((alert) => {
      if (!alert.liveActivity) return [];
      for (const window of activeWindows(alert, now, device.time_zone)) {
        const { from, to } = span(window, now, device.time_zone);
        const occurrence = String(from);
        const follow = followFor(alert, window);
        if (!follow || started[alert.id] === occurrence || to - now < 10 * MINUTE) continue;
        return [{ device, alert, follow, occurrence, ends: to }];
      }
      return [];
    });
  });
}

// MARK: Every minute

interface ActivityRow {
  token: string;
  environment: Environment;
  follow: string;
  ends_at: number;
  state: string;
}

const parse = (state: string): ContentState | undefined => {
  try { return state ? (JSON.parse(state) as ContentState) : undefined; } catch { return undefined; }
};

/** A token APNs will never take again: the activity ended on the phone, or the app was deleted. */
const dead = (r: Sent) => r.gone || r.status === 410 || r.reason === "BadDeviceToken";

export async function runActivities(env: Env, now = Date.now()): Promise<{ followed: number; sent: number; started: number; ended: number }> {
  const result = { followed: 0, sent: 0, started: 0, ended: 0 };
  // Without the push key nothing can be shown, so nothing is asked of TfL.
  if (!canPush(env)) return result;
  const { results: rows } = await env.DB.prepare("SELECT token, environment, follow, ends_at, state FROM activities").all<ActivityRow>();
  const { results: devices } = await env.DB.prepare(
    "SELECT token, environment, time_zone, alerts, start_token, started FROM devices WHERE start_token IS NOT NULL",
  ).all<StartRow>();
  // Workers Free gives an invocation 50 requests and 50 D1 queries: at most `maxPushes` pushes a
  // run (ends, updates and starts together), the rest the next minute, and TfL what's left.
  let pushes = maxPushes(env);
  const memo: TokenMemo = {};
  const due = dueStarts(devices, now).slice(0, pushes);
  if (!rows.length && !due.length) return result;

  const live: (ActivityRow & { followed: Segment })[] = [];
  for (const row of rows) {
    if (row.ends_at > now) {
      live.push({ ...row, followed: JSON.parse(row.follow) as Segment });
      continue;
    }
    if (pushes <= 0) continue;
    pushes--;
    // Its time is up: off the Lock Screen, and forgotten whether or not APNs took it.
    await env.DB.prepare("DELETE FROM activities WHERE token = ?1 AND ends_at = ?2").bind(row.token, row.ends_at).run();
    try { await send(env, row.token, row.environment, endPush(parse(row.state), now), now, memo); } catch {}
    result.ended++;
  }
  if (!live.length && !due.length) return result;

  const tfl = { key: env.TFL_APP_KEY, ops: tflRequests(env, maxPushes(env)) };
  const show = await lookup(env, [...live.map((r) => r.followed), ...due.map((d) => d.follow)], now, tfl);

  for (const row of live) {
    const state = show(row.followed);
    if (!state) continue;
    result.followed++;
    const priority = urgency(parse(row.state), state, now);
    if (!priority || pushes <= 0) continue;
    pushes--;
    try {
      const sent = await send(env, row.token, row.environment, updatePush(state, priority, now), now, memo);
      if (dead(sent)) {
        await env.DB.prepare("DELETE FROM activities WHERE token = ?1").bind(row.token).run();
        continue;
      }
      if (sent.status !== 200) {
        console.error("Live Activity update refused", sent.status, sent.reason);
        continue;
      }
      result.sent++;
      await env.DB.prepare("UPDATE activities SET state = ?1 WHERE token = ?2 AND ends_at = ?3")
        .bind(JSON.stringify(state), row.token, row.ends_at).run();
    } catch (error) {
      console.error("Live Activity update failed", String(error));
    }
  }

  for (const start of due) {
    const state = show(start.follow);
    if (!state || pushes <= 0) continue;
    pushes--;
    const { device } = start;
    try {
      const sent = await send(env, device.start_token, device.environment, startPush(attributesFor(start.alert, start.follow, start.ends), state, now), now, memo);
      if (dead(sent)) {
        await env.DB.prepare("UPDATE devices SET start_token = NULL WHERE token = ?1 AND start_token = ?2").bind(device.token, device.start_token).run();
        continue;
      }
      if (sent.status !== 200) {
        console.error("Live Activity start refused", sent.status, sent.reason);
        continue;
      }
      result.started++;
      // Read again: another start for the same phone may have been recorded meanwhile.
      const current = await env.DB.prepare("SELECT started FROM devices WHERE token = ?1").bind(device.token).first<{ started: string }>();
      const started = { ...(JSON.parse(current?.started || "{}") as Record<string, string>), [start.alert.id]: start.occurrence };
      for (const id of Object.keys(started)) if (!(JSON.parse(device.alerts) as Alert[]).some((a) => a.id === id)) delete started[id];
      await env.DB.prepare("UPDATE devices SET started = ?1 WHERE token = ?2").bind(JSON.stringify(started), device.token).run();
    } catch (error) {
      console.error("Live Activity start failed", String(error));
    }
  }
  return result;
}
