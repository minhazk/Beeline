// Every two minutes, check active commutes and any subscriptions to London-wide strikes.
// The evening before, also check planned works on tomorrow's trips.

import { canPush, PushSetupError, send, type ApnsEnv, type TokenMemo } from "./apns.ts";
import { loadLineMaps } from "./linemap.ts";
import { issuesFor, issuesInRanges, linesToPlace, type LineMaps } from "./match.ts";
import { MAX_RETRIES, plannedStep, step, type DeviceState, type Ways } from "./policy.ts";
import { clearPush, issuesPush, plannedPush, probePush, strikePush, type Push } from "./push.ts";
import { londonStrikes } from "./strikes.ts";
import { activeWindows, dateKey, during, eachWay, localTime, PLANNED_CHECK_AT, travelRanges } from "./schedule.ts";
import { lineCatalog, lineChecks, stationChecks } from "./linechecks.ts";
import type { LineStatus, StationDisruption } from "./tfl.ts";
import type { Alert, Device, Direction } from "./types.ts";
import { reserved } from "./validate.ts";

export interface Env extends ApnsEnv {
  STATUS_LIMITER: RateLimit;
  APP_TOKEN?: string;
  TFL_APP_KEY?: string;
  /** How many phones may register (a var; default 100). */
  MAX_DEVICES?: string | number;
  /** The most pushes one run sends (a var; default 12, which fits Workers Free). */
  MAX_PUSHES_PER_RUN?: string | number;
  /** Local runs only: where recorded TfL answers are served. */
  TFL_BASE?: string;
}

interface Row {
  token: string;
  environment: Device["environment"];
  time_zone: string;
  alerts: string;
  strike_alerts: number;
  state: string;
  revision: string;
  enrollment_hash: string | null;
  updated_at: number;
}

type Loaded = Device & { strikeAlerts: boolean; state: DeviceState; revision: string; enrollment: string | null; updatedAt: number };

// A phone not heard from for this long (no registration, no push Apple took) is asked after, a
// few a run, with a push that shows nothing: Apple says when the app has gone from it, and then
// its token and the journeys it watched are no longer kept.
const HEARD_WITHIN = 30 * 24 * 3_600_000, PROBES_PER_RUN = 5;

// A push token APNs says isn't this app's is asked again after half an hour, then twice as long
// each time, up to a day; and forgotten after three refusals over a day, once another phone's
// push has gone out since (which shows the server's own push setup is not what's wrong).
const REFUSED_PAUSE = 30 * 60_000, REFUSED_PAUSE_MAX = 24 * 3_600_000;
const REFUSED_FORGET_AFTER = 24 * 3_600_000, REFUSED_FORGET_COUNT = 3;
/** The most pushes one run asks of APNs; the rest wait for the next run, which starts elsewhere.
 * Each costs a request to Apple and two or three to D1, and Workers Free allows an invocation
 * 50 of each: past that Apple could take a push whose telling could no longer be written down,
 * and it would be told again. Twelve leaves room for TfL and the run's own bookkeeping. On
 * Workers Paid (1000 of each) set MAX_PUSHES_PER_RUN higher, up to 250. */
export function maxPushes(env: Pick<Env, "MAX_PUSHES_PER_RUN">): number {
  const text = env.MAX_PUSHES_PER_RUN == null ? "" : String(env.MAX_PUSHES_PER_RUN).trim();
  if (!text) return 12;
  if (/^\d{1,3}$/.test(text) && Number(text) >= 1 && Number(text) <= 250) return Number(text);
  console.error("MAX_PUSHES_PER_RUN is not a whole number from 1 to 250; using 12");
  return 12;
}
const HOUR = 3_600_000;
// A run stops sending after a minute and a half, so it is over before the next begins; and
// should one still be going (or have died), the next leaves the phones to it for five minutes.
// Two runs reading the same phones at once would each tell them the same thing.
const RUN_BUDGET = 90_000, RUN_LEASE = 5 * 60_000;

/** D1 answers an invocation a set number of times (50 on Workers Free, 1000 on Paid), and a run
 * that asks past it has Apple take pushes it can then no longer write down as told. So the run
 * counts, and stops starting new work with room left for what's in hand and for giving its turn
 * back. A cap left at Free's twelve pushes is taken to mean Free. */
const queryBudget = (most: number) => (most > 12 ? 900 : 40);

/** What an invocation may spend on TfL and the edge cache. On Workers Free (taken from the push
 * cap left at twelve or under) an invocation has 50 requests in all: a run keeps back its pushes
 * and a few to spare; a request from the app has no pushes to make but one. */
export const tflRequests = (env: Pick<Env, "MAX_PUSHES_PER_RUN">, pushes: number) => ({ left: maxPushes(env) > 12 ? 900 : 50 - pushes - 6 });

/** `env` with every D1 statement counted. */
function counted(env: Env): { env: Env; queries: () => number } {
  let asked = 0;
  const DB = { prepare: (sql: string) => (asked++, env.DB.prepare(sql)) } as unknown as D1Database;
  return { env: { ...env, DB }, queries: () => asked };
}

/** A phone's kept state with when each disruption was last seen left out: what's left is what a
 * check decided. (Only the times themselves: an alert may be called "seen".) */
const substance = (state: DeviceState) => JSON.stringify(state, (key, value) => (key === "seen" && typeof value === "number" ? 0 : value));
/** Of the "last seen" times this check moved on, the oldest as it was kept before; undefined when
 * it moved none. Only those: an alert outside its times keeps an old one until it is next
 * checked, and that says nothing about how stale the ones in hand are. */
function oldestRefreshed(was: DeviceState, state: DeviceState): number | undefined {
  let oldest: number | undefined;
  for (const [id, alert] of Object.entries(state.alerts)) {
    for (const [signature, live] of Object.entries(alert?.live ?? {})) {
      const before = Object.hasOwn(was.alerts ?? {}, id) ? was.alerts[id]?.live?.[signature]?.seen : undefined;
      if (before === live.seen) continue;
      oldest = Math.min(oldest ?? Infinity, Number.isFinite(before) ? (before as number) : -Infinity);
    }
  }
  return oldest;
}
/** How stale a kept "last seen" may get before it is written again just to refresh it: well
 * inside the hour and a half a line's trouble is remembered for. */
const SEEN_REFRESH = 10 * 60_000;

/** What one run shares between its alerts and its silent probes. */
interface Run {
  /** D1 statements asked so far this invocation, and how many it may ask before stopping. */
  queries: () => number;
  budget: number;
  /** Pushes asked of APNs so far, and the most this run may ask. */
  asked: number;
  most: number;
  /** When a push last went out in each environment, as far as was read. */
  lastDelivered: Map<Device["environment"], number>;
  memo: TokenMemo;
  /** Where nothing more is worth asking: an APNs environment that refuses the topic or the
   * provider token, or "all" when no provider token can be made. */
  broken: Set<Device["environment"] | "all">;
  /** The environments a push went out in. */
  delivered: Set<Device["environment"]>;
  /** Phones a push was tried for or whose row was written, so their rows aren't as they were read. */
  touched: Set<string>;
  started: number;
}

const spent = (run: Run, environment: Device["environment"]) =>
  run.asked >= run.most || run.queries() >= run.budget || run.broken.has("all") || run.broken.has(environment) || Date.now() - run.started > RUN_BUDGET;

/** Counts a refusal of this phone's token, and says whether it is now the token's fault beyond
 * doubt: three refusals over a day, the last of them after a push went out to someone, the same
 * way, since the one before. Only then is the phone forgotten. */
async function refusedForGood(env: Env, run: Run, device: Loaded, now: number): Promise<boolean> {
  const state = device.state, previous = state.refused;
  state.refused = { first: previous?.first ?? now, last: now, count: (previous?.count ?? 0) + 1 };
  if (!previous || state.refused.count < REFUSED_FORGET_COUNT || now - state.refused.first < REFUSED_FORGET_AFTER) return false;
  if (!run.lastDelivered.has(device.environment)) {
    run.lastDelivered.set(device.environment, (await env.DB.prepare("SELECT updated_at FROM meta WHERE key = ?1").bind(deliveredKey(device.environment)).first<{ updated_at: number }>())?.updated_at ?? 0);
  }
  return run.delivered.has(device.environment) || run.lastDelivered.get(device.environment)! > previous.last;
}

/** Forgets a phone Apple says is gone, unless it registered after Apple last looked (then the
 * answer is about a token as it was before). Whether it was forgotten. */
async function forgetGone(env: Env, device: Loaded, since: number | undefined): Promise<boolean> {
  if (since !== undefined && device.updatedAt > since) return false;
  await env.DB.prepare("DELETE FROM devices WHERE token = ?1 AND revision = ?2").bind(device.token, device.revision).run();
  return true;
}

export const emptyState = (): DeviceState => ({ alerts: {}, planned: {} });

export async function loadDevices(env: Env): Promise<Loaded[]> {
  const { results } = await env.DB.prepare("SELECT token, environment, time_zone, alerts, strike_alerts, state, revision, enrollment_hash, updated_at FROM devices ORDER BY rowid").all<Row>();
  return results.flatMap((r): Loaded[] => {
    try {
      const alerts = JSON.parse(r.alerts) as Alert[];
      const state = JSON.parse(r.state) as Partial<DeviceState> | null;
      if (!Array.isArray(alerts) || typeof state !== "object" || Array.isArray(state)) throw new Error("not a registration");
      localTime(0, r.time_zone);
      // What each alert was told is kept by its id, so an id every object answers to is no alert.
      const known = alerts.filter((a) => typeof a?.id === "string" && !reserved(a.id));
      const kept: DeviceState = { ...emptyState(), ...state };
      // What the checks read without looking: the right kind of thing, or as if never kept.
      const record = (v: unknown) => v !== null && typeof v === "object" && !Array.isArray(v);
      if (!record(kept.alerts)) kept.alerts = {};
      if (!record(kept.planned)) kept.planned = {};
      if (kept.strikes !== undefined && !record(kept.strikes)) delete kept.strikes;
      if (kept.retries !== undefined && !record(kept.retries)) delete kept.retries;
      if (kept.refused !== undefined && !(record(kept.refused) && [kept.refused.first, kept.refused.last, kept.refused.count].every(Number.isFinite))) delete kept.refused;
      for (const key of ["heard", "revoked"] as const) if (kept[key] !== undefined && !Number.isFinite(kept[key])) delete kept[key];
      return [{ token: r.token, environment: r.environment, timeZone: r.time_zone, alerts: known, strikeAlerts: r.strike_alerts === 1, state: kept, revision: r.revision,
        enrollment: r.enrollment_hash ?? null, updatedAt: Number(r.updated_at) || 0 }];
    } catch {
      // One unreadable row must not stop every other phone's checks.
      console.error("unreadable registration skipped");
      return [];
    }
  });
}

/** The hashes of the invitations in APP_TOKEN now, as registrations keep them. */
async function invitationHashes(appToken: string | undefined): Promise<Set<string>> {
  const invites = (appToken ?? "").split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const hashes = await Promise.all(invites.map(async (invite) => {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(invite));
    return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
  }));
  return new Set(hashes);
}

/** How long an invitation must stay out of APP_TOKEN before its phone is removed. The secret is
 * replaced whole each time it is set, so a line left out by mistake looks just like a revocation:
 * a day leaves time to notice (the phone's own requests are refused at once either way). */
const REVOKED_GRACE = 24 * 3_600_000;

/** A phone admitted by an invitation that has been out of APP_TOKEN for a day is removed: it
 * could no longer change or remove its own registration. Phones from before invitations were
 * kept (no hash) stay. An APP_TOKEN with nothing in it is every invitation taken out: the
 * same day's grace, then every phone it admitted goes. */
async function removeRevoked(env: Env, devices: Loaded[], now: number): Promise<Loaded[]> {
  const current = await invitationHashes(env.APP_TOKEN);
  const kept: Loaded[] = [];
  // A few a run: every invitation taken out at once is a write for every phone, and the rest
  // of the run needs its share of what D1 will answer. The others are noted next run.
  let noted = 0;
  for (const device of devices) {
    const revoked = device.enrollment !== null && !current.has(device.enrollment);
    if (noted >= 8) {
      kept.push(device);
      continue;
    }
    try {
      if (revoked && device.state.revoked !== undefined && now - device.state.revoked >= REVOKED_GRACE) {
        noted++;
        await env.DB.prepare("DELETE FROM devices WHERE token = ?1 AND enrollment_hash = ?2").bind(device.token, device.enrollment).run();
        console.log("registration removed: its invitation was revoked");
        continue;
      }
      if (revoked !== (device.state.revoked !== undefined)) {
        noted++;
        if (revoked) device.state.revoked = now;
        else delete device.state.revoked;
        // The revision stays: nothing a phone or a push decides depends on this mark.
        await env.DB.prepare("UPDATE devices SET state = ?1 WHERE token = ?2 AND revision = ?3").bind(JSON.stringify(device.state), device.token, device.revision).run();
      }
    } catch (error) {
      console.error("could not note a revoked invitation", String(error));
    }
    kept.push(device);
  }
  return kept;
}

const refusedPause = (count: number) => Math.min(REFUSED_PAUSE * 2 ** Math.max(0, count - 1), REFUSED_PAUSE_MAX);

export async function runChecks(given: Env, now = Date.now()): Promise<{ devices: number; checked: number; sent: number }> {
  const { env, queries } = counted(given);
  const devices = await removeRevoked(env, await loadDevices(env), now);
  // Without the push key, key ID, team and topic nothing can be sent, so nothing is judged:
  // a disruption marked told that no phone heard about would never be told.
  if (!canPush(env)) {
    if (devices.length) console.error("pushes not configured: set APNS_KEY, APNS_KEY_ID, APNS_TEAM_ID and APNS_TOPIC");
    return { devices: devices.length, checked: 0, sent: 0 };
  }
  // A token APNs keeps refusing costs nothing between tries: no TfL request, no push.
  const waiting = (device: Loaded) => device.state.refused !== undefined && now - device.state.refused.last < refusedPause(device.state.refused.count);
  // Each run starts one phone further on, so a run cut short never leaves the same phones last;
  // and a further one each day, or with a number of phones that divides the day's runs the same
  // ones would come last at the same time every day.
  const tick = Math.floor(now / 120_000);
  const start = devices.length ? (tick + Math.floor(tick / 720)) % devices.length : 0;
  const work = [...devices.slice(start), ...devices.slice(0, start)].filter((device) => !waiting(device)).flatMap((device) => {
    // What a stored alert holds was checked when it was saved; one that reads wrongly now is
    // that phone's alone to lose a check over.
    try {
      const local = localTime(now, device.timeZone);
      return [{
        device,
        // Each alert as ridden now: the way of the time you're in (overlapping times that
        // disagree are both ways).
        live: device.alerts.flatMap((a) => {
          const windows = activeWindows(a, now, device.timeZone);
          return windows.length ? [{ alert: during(a, windows), base: a }] : [];
        }),
        planned: device.alerts.length > 0 && local.minutes >= PLANNED_CHECK_AT && device.state.plannedOn !== dateKey(local),
        today: dateKey(local),
        // Read here so an alert with no segments to read fails here, not for everyone below.
        segments: device.alerts.flatMap((a) => a.segments.map((segment) => segment.line.id)).length,
      }];
    } catch {
      console.error("unreadable registration skipped");
      return [];
    }
  });
  const live = work.flatMap((w) => w.live.map((l) => l.alert));
  const plannedAlerts = work.filter((w) => w.planned).flatMap((w) => w.device.alerts);
  const run: Run = { queries, budget: queryBudget(maxPushes(env)), asked: 0, most: maxPushes(env), lastDelivered: new Map(), memo: {}, broken: new Set(), delivered: new Set(), touched: new Set(), started: Date.now() };
  const quiet = () => work.map((w) => w.device).filter((device) => !run.touched.has(device.token));
  /** With nothing else to send: the quiet phones due asking after, under the same one-run-at-a-time
   * turn, taken only when there is one to ask. */
  const probeOnly = async () => {
    const due = dueProbes(quiet(), now);
    if (!due.length) return;
    const turn = await claimRun(env);
    if (turn === undefined) return;
    try {
      run.started = Date.now();
      await probeQuiet(env, due, now, run);
    } finally {
      await releaseRun(env, turn);
    }
    await noteDeliveries(env, run, now);
  };
  const tfl = { key: env.TFL_APP_KEY, ops: tflRequests(env, run.most) };
  const strikes = work.some(({ device }) => device.strikeAlerts) ? await londonStrikes(now, tfl) : [];
  if (!live.length && !plannedAlerts.length && !strikes.length) {
    await probeOnly();
    return { devices: devices.length, checked: 0, sent: 0 };
  }

  const segments = [...live, ...plannedAlerts].flatMap((a) => a.segments);
  // What the run may ask of TfL, counted so its pushes still have requests to go out on. What
  // is live now is asked of TfL itself (the cache keeps it less long than runs are apart).
  const liveNow = { ...tfl, uncached: true };
  let catalog = new Map<string, string>();
  try { if (segments.length) catalog = await lineCatalog(tfl); }
  catch {
    if (!strikes.length) {
      await probeOnly();
      return { devices: devices.length, checked: 0, sent: 0 };
    }
  }
  const [lineReport, stationReport] = await Promise.all([
    lineChecks(live.flatMap((a) => a.segments), catalog, liveNow),
    stationChecks(segments, liveNow),
  ]);
  const { lines } = lineReport, { stations } = stationReport;
  let checked = 0;

  // Only when TfL names a section in words, or says one way only: the line's stations in order.
  // Each way an alert's times go, too: which ways a disruption is on decides what's news.
  const ridden = [...live, ...work.flatMap((w) => w.live.flatMap((l) => eachWay(l.base)))];
  let maps: LineMaps;
  // Lines whose order there were no requests left to ask for: their alerts wait for the next run.
  const unplaced = new Set<string>();
  try {
    maps = await loadLineMaps(linesToPlace(ridden, lines, stations), tfl, now, unplaced);
  } catch (error) {
    // Without the lines' order a notice is told as it stands; each phone is still checked.
    console.error("line order unavailable", String(error));
    maps = new Map();
  }

  // One run at a time tells phones: the next, finding this one still at it, leaves them to it.
  const turn = await claimRun(env);
  if (turn === undefined) {
    console.error("the last run is still sending: this one leaves the phones to it");
    return { devices: devices.length, checked: 0, sent: 0 };
  }
  let sent = 0;
  // The sending budget is for sending: what TfL took to answer isn't taken out of it.
  run.started = Date.now();
  try {
    for (const { device, live: active, planned, today } of work) {
      if (!active.length && !planned && !(device.strikeAlerts && strikes.length)) continue;
      if (run.asked >= run.most || run.queries() >= run.budget || run.broken.has("all") || Date.now() - run.started > RUN_BUDGET) break;
      const before = JSON.stringify(device.state), decided = substance(device.state);
      const state = device.state;
      const retries = { ...(state.retries ?? {}) };
      // `stopped`: the registration changed or went, so nothing more is sent or saved for it.
      // `halted`: nothing more is sent this run, but what was decided so far is saved.
      let stopped = false, halted = false;

      /** Sends one push and keeps what it decided only once it's done with: sent, or refused for
       * good (logged loudly), or failed for a passing reason too often. A passing failure keeps the
       * previous state for that alert alone, so only that push is tried again next run. */
      const deliver = async (key: string, push: Push, commit: () => void): Promise<boolean> => {
        const current = await env.DB.prepare("SELECT 1 FROM devices WHERE token = ?1 AND revision = ?2").bind(device.token, device.revision).first();
        if (!current) {
          stopped = true;
          return false;
        }
        if (spent(run, device.environment)) {
          halted = true;
          return false;
        }
        run.asked++;
        run.touched.add(device.token);
        const result = await attempt(env, device.token, device.environment, push, now, run.memo);
        let outcome = result.outcome;
        if (outcome === "gone") {
          if (await forgetGone(env, device, result.goneSince)) {
            stopped = true;
            return false;
          }
          // Registered since Apple last found the token gone: tried again, like any passing failure.
          outcome = "retry";
        }
        if (outcome === "token") {
          halted = true;
          if (await refusedForGood(env, run, device, now)) {
            stopped = true;
            await env.DB.prepare("DELETE FROM devices WHERE token = ?1 AND revision = ?2").bind(device.token, device.revision).run();
            console.log("registration removed: APNs keeps refusing its push token");
          }
          return false;
        }
        if (outcome === "sent") {
          sent++;
          run.delivered.add(device.environment);
          delete state.refused;
          state.heard = now;
        }
        // The server's own setup, for every phone (no provider token) or for this phone's
        // environment (the topic, or the token as Apple reads it there): nothing more is asked
        // that would be answered the same.
        if (outcome === "setup" || outcome === "configuration") {
          halted = true;
          run.broken.add(outcome === "setup" ? "all" : device.environment);
          return false;
        }
        if (outcome === "retry" && (retries[key] ?? 0) + 1 < MAX_RETRIES) {
          retries[key] = (retries[key] ?? 0) + 1;
          return false;
        }
        if (outcome === "retry") console.error("push given up after retries", key);
        delete retries[key];
        commit();
        return true;
      };

      try {
        for (const { alert, base } of active) {
          if (stopped || halted) break;
          if (alert.segments.some((s) => catalog.get(s.line.id) !== s.mode || lineReport.missing.has(s.line.id) || stationReport.missing.has(s.mode) || unplaced.has(s.line.id))) continue;
          checked++;
          const issues = issuesFor(alert, lines, stations, { at: now }, maps);
          const told = Object.hasOwn(state.alerts, alert.id) ? state.alerts[alert.id] : undefined;
          const result = step(told, issues, now, waysFor(alert, base, lines, stations, now, maps));
          const commit = () => void (state.alerts[alert.id] = result.state);
          if (result.push?.kind === "issues") await deliver(alert.id, issuesPush(alert, result.push.issues, now), commit);
          else if (result.push?.kind === "clear") await deliver(alert.id, clearPush(alert, now), commit);
          else commit();
        }
        if (planned && !stopped && !halted) {
          let allDone = true;
          const tomorrow = device.alerts.map((alert) => ({ alert, ranges: travelRanges(alert, now, device.timeZone, 2, true) })).filter((t) => t.ranges.length);
          if (tomorrow.length) {
            const all = tomorrow.flatMap((t) => t.ranges);
            // To the hour, so phones with different times share TfL's answer rather than each ask.
            const range = { from: Math.floor(Math.min(...all.map((r) => r.from)) / HOUR) * HOUR, to: Math.ceil(Math.max(...all.map((r) => r.to)) / HOUR) * HOUR };
            const forecast = await lineChecks(tomorrow.flatMap((t) => t.alert.segments), catalog, tfl, range);
            const ahead = forecast.lines;
            const more = linesToPlace(tomorrow.flatMap((t) => eachWay(t.alert)), ahead, stations).filter((id) => !maps.has(id));
            for (const [id, map] of await loadLineMaps(more, tfl, now, unplaced)) maps.set(id, map);
            for (const { alert, ranges } of tomorrow) {
              if (stopped || halted) {
                allDone = false;
                break;
              }
              if (alert.segments.some((s) => catalog.get(s.line.id) !== s.mode || forecast.missing.has(s.line.id) || stationReport.missing.has(s.mode) || unplaced.has(s.line.id))) {
                allDone = false;
                continue;
              }
              const result = plannedStep(state.planned, alert.id, issuesInRanges(alert, ahead, stations, ranges, maps), now);
              const commit = () => void (state.planned = result.planned);
              if (result.fresh.length) allDone = (await deliver(`planned:${alert.id}`, plannedPush(alert, result.fresh, now), commit)) && allDone;
              else commit();
            }
          }
          // Tomorrow is settled only when every alert's planned works went out (or were given up on).
          if (allDone) state.plannedOn = today;
        }
        if (device.strikeAlerts && strikes.length) {
          const told = state.strikes ??= {};
          for (const [key, until] of Object.entries(told)) if (until <= now) delete told[key];
          for (const notice of strikes) {
            if (stopped || halted) break;
            if (notice.occurrences.every(key => told[key])) {
              // A live report may get a new validity period every few minutes.
              // Keep it remembered while TfL continues reporting the strike.
              if (notice.active) {
                for (const key of notice.occurrences) if (told[key] < now + HOUR) told[key] = now + 3 * HOUR;
              }
              continue;
            }
            await deliver(`strike:${notice.key}`, strikePush(notice, now), () => {
              for (const key of notice.occurrences) told[key] = notice.active ? now + 3 * HOUR : notice.expires + 86400_000;
            });
          }
        }
        // Forget alerts the phone no longer has.
        for (const id of Object.keys(state.alerts)) if (!device.alerts.some((a) => a.id === id)) delete state.alerts[id];
      } catch (error) {
        console.error("check failed", String(error));
      }
      if (stopped) continue;
      if (Object.keys(retries).length) state.retries = retries;
      else delete state.retries;
      // Trouble that is simply still there changes nothing but when it was last seen: that is
      // written every ten minutes, not every run, or every phone on a troubled line would cost
      // a write each run for as long as it lasted.
      const refreshed = substance(state) === decided ? oldestRefreshed(JSON.parse(before) as DeviceState, state) : undefined;
      // Not near the end of a time you travel: what's kept then is what the next time, an hour
      // or a day on, is judged against, and it must be when the trouble really was last seen.
      const ending = active.some(({ base }) => !activeWindows(base, now + SEEN_REFRESH + 4 * 60_000, device.timeZone).length);
      const onlySeen = refreshed !== undefined && now - refreshed < SEEN_REFRESH && !ending;
      if (JSON.stringify(state) !== before && !onlySeen) {
        // One phone's failed write is that phone's alone: the rest of the run goes on.
        run.touched.add(device.token);
        try {
          await env.DB.prepare("UPDATE devices SET state = ?1, revision = lower(hex(randomblob(16))) WHERE token = ?2 AND revision = ?3")
            .bind(JSON.stringify(state), device.token, device.revision).run();
        } catch (error) {
          console.error("could not save what was checked", String(error));
        }
      }
    }
    await probeQuiet(env, dueProbes(quiet(), now), now, run);
  } finally {
    await releaseRun(env, turn);
  }
  await noteDeliveries(env, run, now);
  return { devices: devices.length, checked, sent };
}

const deliveredKey = (environment: Device["environment"]) => `apns_ok:${environment}`;

/** When a push last went out in each APNs environment, at most hourly: what shows that a token
 * refused there is the token's fault, and not the server's setup for that environment. */
async function noteDeliveries(env: Env, run: Run, now: number): Promise<void> {
  for (const environment of run.delivered) {
    try {
      await env.DB.prepare(`INSERT INTO meta (key, value, updated_at) VALUES (?2, '', ?1)
        ON CONFLICT(key) DO UPDATE SET updated_at = ?1 WHERE meta.updated_at < ?1 - ${HOUR}`).bind(now, deliveredKey(environment)).run();
    } catch (error) {
      console.error("could not note the delivery", String(error));
    }
  }
}

/** Takes the run's turn at telling phones, unless another run took it within the lease. By the
 * clock, not `now`: this is about runs that really are going at once. */
async function claimRun(env: Env): Promise<number | undefined> {
  const at = Date.now();
  try {
    const claimed = await env.DB.prepare(`INSERT INTO meta (key, value, updated_at) VALUES ('cron_run', '', ?1)
      ON CONFLICT(key) DO UPDATE SET updated_at = ?1 WHERE meta.updated_at < ?1 - ${RUN_LEASE}`).bind(at).run();
    return claimed.meta?.changes ? at : undefined;
  } catch (error) {
    console.error("could not take the run's turn", String(error));
    return undefined;
  }
}

/** Gives back the turn this run took, and only that one: a run that outlasted its lease mustn't
 * give back the turn of the run that took over from it. */
async function releaseRun(env: Env, turn: number): Promise<void> {
  try {
    await env.DB.prepare("UPDATE meta SET updated_at = 0 WHERE key = 'cron_run' AND updated_at = ?1").bind(turn).run();
  } catch (error) {
    console.error("could not give the run's turn back", String(error));
  }
}

/** The quiet phones nothing has been heard from in a month, a few a run. */
const dueProbes = (quiet: Loaded[], now: number) => quiet.filter((d) => now - Math.max(d.updatedAt, d.state.heard ?? 0) > HEARD_WITHIN).slice(0, PROBES_PER_RUN);

/** Asks Apple after phones nothing has been heard from in a month, with a push that shows
 * nothing. Only phones this run did nothing else for, so their rows are as they were read; and
 * each only if it is still registered as read, so one removed meanwhile isn't pushed to. */
async function probeQuiet(env: Env, due: Loaded[], now: number, run: Run): Promise<void> {
  for (const device of due) {
    if (spent(run, device.environment)) continue;
    try {
      if (!(await env.DB.prepare("SELECT 1 FROM devices WHERE token = ?1 AND revision = ?2").bind(device.token, device.revision).first())) continue;
      run.asked++;
      const { outcome, goneSince } = await attempt(env, device.token, device.environment, probePush(), now, run.memo);
      if (outcome === "gone" && (await forgetGone(env, device, goneSince))) continue;
      // The server's own setup: every other phone there would be answered the same.
      if (outcome === "setup" || outcome === "configuration") {
        run.broken.add(outcome === "setup" ? "all" : device.environment);
        continue;
      }
      const state = device.state;
      // A token refused when asked after counts as it does when told something: a phone with
      // nothing to be told would otherwise keep its place, and its invitation, for good.
      if (outcome === "token" && (await refusedForGood(env, run, device, now))) {
        await env.DB.prepare("DELETE FROM devices WHERE token = ?1 AND revision = ?2").bind(device.token, device.revision).run();
        console.log("registration removed: APNs keeps refusing its push token");
        continue;
      }
      if (outcome === "sent") {
        run.delivered.add(device.environment);
        delete state.refused;
      }
      // Heard, or not answered for a reason that isn't the phone's: asked again in a month, or a day.
      state.heard = outcome === "sent" ? now : now - HEARD_WITHIN + 24 * HOUR;
      await env.DB.prepare("UPDATE devices SET state = ?1, revision = lower(hex(randomblob(16))) WHERE token = ?2 AND revision = ?3")
        .bind(JSON.stringify(state), device.token, device.revision).run();
    } catch (error) {
      console.error("could not ask after a quiet phone", String(error));
    }
  }
}

/** For an alert with any time going one way: the way ridden now, which ways each disruption on
 * the stretch is on, and how to read memory from before ways were kept. Nil for alerts that go
 * both ways at every time, which are judged as before. */
export function waysFor(alert: Alert, base: Alert, lines: LineStatus[], stations: StationDisruption[], now: number, maps: LineMaps): Ways | undefined {
  const going = eachWay(base).map((a) => a.direction!);
  if (!going.some((d) => d !== "both")) return undefined;
  const on = new Map<string, Direction[]>();
  for (const direction of ["out", "back"] as const) {
    for (const issue of issuesFor({ ...alert, direction }, lines, stations, { at: now }, maps)) on.set(issue.signature, [...(on.get(issue.signature) ?? []), direction]);
  }
  const way = alert.direction ?? "both";
  return {
    way,
    on,
    holds: way !== "both" && going.some((d) => d !== way),
    told: base.direction === "out" || base.direction === "back" ? [base.direction] : ["out", "back"],
  };
}

type Outcome = "sent" | "gone" | "retry" | "configuration" | "setup" | "token" | "refused";

/** What became of one push.
 * - "token": APNs refuses this phone's token alone (a wrong environment, or a made-up token):
 *   the notice stays pending, and the phone is asked again ever less often.
 * - "configuration": the server's setup for this APNs environment (the topic, the key as that
 *   environment reads it, a provider token Apple won't take or wants changed less often): the
 *   notice stays pending however long, and nothing more is asked there this run.
 * - "setup": no provider token could be made at all: the same, for every phone.
 * - "refused": this one notice Apple won't take (its payload or headers): not tried again. */
async function attempt(env: Env, token: string, environment: Device["environment"], push: Push, now: number, memo?: TokenMemo): Promise<{ outcome: Outcome; goneSince?: number }> {
  try {
    const result = await send(env, token, environment, push, now, memo);
    if (result.gone) {
      console.log("device gone", result.reason);
      return { outcome: "gone", goneSince: result.goneSince };
    }
    if (result.status === 200) return { outcome: "sent" };
    if (result.reason === "BadDeviceToken" || result.reason === "DeviceTokenNotForTopic") {
      console.error("APNs refused this phone's push token", result.reason);
      return { outcome: "token" };
    }
    // Every 403 is about the certificate or provider token, and so is being told to change the
    // provider token less often; the topic is the server's too.
    if (result.status === 403 || result.reason === "TooManyProviderTokenUpdates" || ["BadTopic", "TopicDisallowed", "MissingTopic", "MissingProviderToken"].includes(result.reason ?? "")) {
      console.error("Check APNs topic, environment and signing key", result.status, result.reason);
      return { outcome: "configuration" };
    }
    if (result.status === 429 || result.status >= 500) {
      console.error("APNs busy, will retry", result.status, result.reason);
      return { outcome: "retry" };
    }
    console.error("APNs REFUSED for good: check the push setup", result.status, result.reason);
    return { outcome: "refused" };
  } catch (error) {
    // A push key that can't sign is the server's setup: the notice waits, and is never given up on.
    if (error instanceof PushSetupError) {
      console.error("Check APNS_KEY, APNS_KEY_ID and APNS_TEAM_ID: no provider token could be made", error.message);
      return { outcome: "setup" };
    }
    console.error("push failed, will retry", String(error));
    return { outcome: "retry" };
  }
}
