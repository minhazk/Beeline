// Beeline alerts: the app registers its push token with the lines you use and when, and
// asks what TfL says about them now. The checks run on a cron (checks.ts).

import { Hono, type Context } from "hono";
import { bodyLimit } from "hono/body-limit";
import { canPush, send } from "./apns.ts";
import { emptyState, runChecks, tflRequests, type Env } from "./checks.ts";
import { loadLineMaps } from "./linemap.ts";
import { issuesFor, issuesInRanges, linesToPlace } from "./match.ts";
import { issuesPush, lineList } from "./push.ts";
import { activeWindows, during, eachWay, travelRanges } from "./schedule.ts";
import { useLocalTfL } from "./tfl.ts";
import { lineCatalog, lineChecks, stationChecks, TfLUnavailable, validateLines } from "./linechecks.ts";
import type { Alert, Issue } from "./types.ts";
import * as valid from "./validate.ts";

type AppEnv = { Bindings: Env; Variables: { enrollmentHash: string; arrived: number } };
const app = new Hono<AppEnv>();

// When each request reached the server, before anything is awaited for it (a body still being
// uploaded, TfL): the order a phone's registrations and removals are applied in, whichever
// happens to finish first.
app.use("*", async (c, next) => {
  c.set("arrived", Date.now());
  await next();
});

// Whether pushes can go out, so a missing push setting shows; never which values are set.
app.get("/health", (c) => c.json({ ok: true, pushes: canPush(c.env) }));

// Nothing is told before the token passes: no version, no setup, no counts.
app.use("/v1/*", async (c, next) => {
  const invites = (c.env.APP_TOKEN ?? "").split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const given = /^Bearer (\S+)$/i.exec(c.req.header("authorization") ?? "")?.[1];
  if (!given || !invites.length) return c.json({ error: "Not allowed" }, 401);
  const fingerprint = await digest(given);
  const invitations = await Promise.all(invites.map(digest));
  if (!invitations.some((invite) => crypto.subtle.timingSafeEqual(fingerprint, invite))) return c.json({ error: "Not allowed" }, 401);
  c.set("enrollmentHash", hex(fingerprint));
  await next();
});

// Every request an invitation makes is counted before its body is read or D1 is asked anything
// on its behalf: one that will be refused costs the same as one that won't.
app.use("/v1/*", async (c, next) => {
  await limitFetches(c);
  await next();
});

// The largest real registration is a few KB; this stops anyone posting megabytes to parse.
app.use("/v1/*", bodyLimit({ maxSize: 256 * 1024, onError: (c) => c.json({ error: "Too large" }, 413) }));

function ownerHash(c: Context<AppEnv>): Promise<string> {
  return sha256(valid.deviceSecret(c.req.header("x-device-secret")));
}

/** A guarded operation already failed. This lookup only chooses the error to report. */
async function rejectOtherOwner(db: D1Database, token: string, hash: string): Promise<void> {
  const row = await db.prepare("SELECT 1 FROM devices WHERE token = ?1 AND secret_hash IS NOT ?2").bind(token, hash).first();
  if (row) throw new NotOwner();
}

class NotOwner extends Error {}

/** However many phones the token's holders register, D1 and the cron's pushes stay bounded.
 * Unset is 100; "0" closes the server to new phones; anything but digits is a mistake, logged. */
export function maxDevices(env: Pick<Env, "MAX_DEVICES">): number {
  // wrangler passes an unquoted var as a number.
  const text = env.MAX_DEVICES == null ? "" : String(env.MAX_DEVICES).trim();
  if (!text) return 100;
  if (/^\d{1,6}$/.test(text)) return Number(text);
  console.error("MAX_DEVICES is not a whole number; using 100");
  return 100;
}

/** What one invitation may ask in a minute, everywhere at once. The edge limiter counts in each
 * Cloudflare location on its own, so an invitation used through many of them would multiply what
 * is asked of TfL; this count is the one place they all meet. */
export const REQUESTS_PER_MINUTE = 30;
/** And in a day. The app asks a few hundred times on its busiest day; a client stuck asking, or
 * an invitation put to other use, would otherwise write D1 through its daily allowance (each
 * request is counted there) and take the server from everyone until midnight. */
export const REQUESTS_PER_DAY = 1500;

/** And from every invitation together, in a day: each request counted is rows written, and D1's
 * daily allowance on Workers Free is the checks' too. */
export const REQUESTS_PER_DAY_ALL = 12_000;

/** The same enrollment has one edge quota even when many addresses use it. A request refused
 * here writes nothing: the days' counts are read first, the minute's only moves while it has
 * room, and the days' are added to only once the request is through. */
async function limitFetches(c: Context<AppEnv>) {
  if (!c.env.STATUS_LIMITER) throw new TfLUnavailable("The alert server is missing its request limiter.");
  const enrollment = c.get("enrollmentHash");
  if (!(await c.env.STATUS_LIMITER.limit({ key: enrollment })).success) throw new TooManyRequests();
  const minute = Math.floor(c.get("arrived") / 60_000), day = Math.floor(c.get("arrived") / 86400_000);
  const own = `rated:${enrollment}:${day}`, all = `rated:all:${day}`;
  const { results } = await c.env.DB.prepare("SELECT key, value FROM meta WHERE key = ?1 OR key = ?2").bind(own, all).all<{ key: string; value: string }>();
  const count = (key: string) => Number(results.find((row) => row.key === key)?.value ?? 0);
  if (count(own) >= REQUESTS_PER_DAY || count(all) >= REQUESTS_PER_DAY_ALL) throw new TooManyRequests();
  // A row for each minute, so a count written late for the minute before can't reopen this one's.
  const used = await c.env.DB.prepare(
    `INSERT INTO meta (key, value, updated_at) VALUES (?1, '1', ?2)
     ON CONFLICT(key) DO UPDATE SET value = CAST(CAST(meta.value AS INTEGER) + 1 AS TEXT) WHERE CAST(meta.value AS INTEGER) < ?3
     RETURNING value`,
  ).bind(`rate:${enrollment}:${minute}`, minute, REQUESTS_PER_MINUTE).first<{ value: string }>();
  // Once the minute is full nothing more is written for it.
  if (!used) throw new TooManyRequests();
  await c.env.DB.prepare(
    `INSERT INTO meta (key, value, updated_at) VALUES (?1, '1', ?3), (?2, '1', ?3)
     ON CONFLICT(key) DO UPDATE SET value = CAST(CAST(meta.value AS INTEGER) + 1 AS TEXT)`,
  ).bind(own, all, day).run();
  // What's past goes with the first request of a new minute: earlier minutes' and days' counts,
  // and removals noted long enough ago. Once a minute at most, so a burst doesn't read them all
  // on every request.
  if (used.value === "1") {
    await c.env.DB.prepare("DELETE FROM meta WHERE key >= 'rate:' AND key < 'rate;' AND updated_at < ?1").bind(minute - 1).run();
    await c.env.DB.prepare("DELETE FROM meta WHERE key >= 'rated:' AND key < 'rated;' AND updated_at < ?1").bind(day).run();
    await c.env.DB.prepare("DELETE FROM meta WHERE key >= 'gone:' AND key < 'gone;' AND updated_at < ?1").bind(c.get("arrived") - REMOVAL_MEMORY).run();
  }
}
class TooManyRequests extends Error {}

/** Where an install's last removal is noted, for a while: by its secret, so nobody else's removal
 * (they'd need the secret) can keep a phone from registering, and whichever of its push tokens
 * the removal was for: a registration this install sent before it, for any token, is too late. */
const removalKey = (hash: string) => `gone:${hash}`;
const REMOVAL_MEMORY = 10 * 60_000;

app.put("/v1/devices/:token", async (c) => {
  // A removal that arrived after this, and was done first, still wins; so does a newer change.
  const arrived = c.get("arrived");
  const token = valid.deviceToken(c.req.param("token"));
  const hash = await ownerHash(c);
  const enrollment = c.get("enrollmentHash");
  const body = valid.body(await c.req.json().catch(() => ({})));
  const alerts = valid.alerts(body.alerts);
  if (!alerts.length) throw new valid.Invalid("A registration needs at least one scheduled alert");
  const environment = valid.environment(body.environment), timeZone = valid.timeZone(body.timeZone);
  validateLines(alerts, await lineCatalog({ key: c.env.TFL_APP_KEY, ops: tflRequests(c.env, 0) }));
  // The order of arrival is only kept for as long as removals are remembered: a request that has
  // been on its way longer than that (an upload that crawled) is asked to come again.
  if (Date.now() - arrived > REMOVAL_MEMORY / 2) return c.json({ error: "That took too long to arrive. Save the alerts again.", code: "late" }, 409);
  const removal = removalKey(hash);
  // A fresh registration is a fresh try: APNs' earlier refusals of this phone are forgotten, and
  // so is a day's notice its old invitation was under (the one it uses now was just accepted).
  const freshState = "CASE WHEN json_valid(devices.state) THEN json_remove(devices.state, '$.refused', '$.revoked') ELSE devices.state END";
  // The same install (its secret) with a new push token, after a reinstall or a restore to a new
  // phone: its registration under this invitation moves to the new token, or the invitation would
  // stay taken by a token nothing can reach or remove. Moved with everything this request says,
  // in one statement, so the row is never the new token with the old phone's settings; moved,
  // not removed and added, so its place is kept on a full server; and only a registration older
  // than this request, so one sent before a newer token registered can't take its place late.
  await c.env.DB.prepare(
    `UPDATE devices SET token = ?3, environment = ?6, time_zone = ?7, alerts = ?8, updated_at = ?4, revision = lower(hex(randomblob(16))), state = ${freshState}
     WHERE enrollment_hash = ?1 AND secret_hash = ?2 AND token != ?3 AND updated_at < ?4
       AND NOT EXISTS (SELECT 1 FROM devices WHERE token = ?3)
       AND NOT EXISTS (SELECT 1 FROM meta WHERE key = ?5 AND updated_at >= ?4)`,
  ).bind(enrollment, hash, token, arrived, removal, environment, timeZone, JSON.stringify(alerts)).run();
  // One statement: a phone already stored is updated; a new one only while there's room, so
  // two registrations at once can't both take the last place. `updated_at` is when the request
  // arrived: an older change that finishes after a newer one changes nothing.
  const result = await c.env.DB.prepare(
    `INSERT INTO devices (token, environment, time_zone, alerts, state, updated_at, secret_hash, revision, enrollment_hash)
     SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, lower(hex(randomblob(16))), ?9
     WHERE (EXISTS (SELECT 1 FROM devices WHERE token = ?1) OR (SELECT COUNT(*) FROM devices) < ?8)
       AND NOT EXISTS (SELECT 1 FROM meta WHERE key = ?10 AND updated_at >= ?6)
     ON CONFLICT(token) DO UPDATE SET environment = ?2, time_zone = ?3, alerts = ?4, updated_at = ?6, revision = excluded.revision,
       state = ${freshState},
       -- The invitation used now is the one kept. A phone from before invitations keeps none
       -- when another phone already holds this one (they shared it, as phones then did).
       enrollment_hash = CASE WHEN EXISTS (SELECT 1 FROM devices AS other WHERE other.enrollment_hash = excluded.enrollment_hash AND other.token != excluded.token)
         THEN devices.enrollment_hash ELSE excluded.enrollment_hash END
     WHERE devices.secret_hash = excluded.secret_hash AND devices.updated_at <= ?6
       -- A phone moving to an invitation another phone holds is refused, not left on its old
       -- one: that one may be about to be taken out, and the phone with it.
       AND (devices.enrollment_hash IS NULL OR devices.enrollment_hash = excluded.enrollment_hash
         OR NOT EXISTS (SELECT 1 FROM devices AS other WHERE other.enrollment_hash = excluded.enrollment_hash AND other.token != excluded.token))
     ON CONFLICT(enrollment_hash) DO NOTHING`,
  ).bind(token, environment, timeZone, JSON.stringify(alerts), JSON.stringify(emptyState()), arrived, hash, maxDevices(c.env), enrollment, removal).run();
  if (!result.meta?.changes) {
    await rejectOtherOwner(c.env.DB, token, hash);
    if (await c.env.DB.prepare("SELECT 1 FROM meta WHERE key = ?1 AND updated_at >= ?2").bind(removal, arrived).first()) {
      return c.json({ error: "This phone's alerts were removed while they were being saved. Save them again to turn them back on.", code: "removed" }, 409);
    }
    if (await c.env.DB.prepare("SELECT 1 FROM devices WHERE token = ?1 AND updated_at > ?2").bind(token, arrived).first()) {
      return c.json({ error: "A newer change to this phone's alerts was already saved.", code: "newer" }, 409);
    }
    if (await c.env.DB.prepare("SELECT 1 FROM devices WHERE enrollment_hash = ?1 AND token != ?2").bind(enrollment, token).first()) {
      // The code says which refusal this is: without one the app takes it for a server from before
      // registrations moved with their phone, and removes its old token to make room.
      return c.json({ error: "This invitation already has a phone. Remove its old registration or use a new invitation.", code: "invitation_taken" }, 409);
    }
    return c.json({ error: "This alert server has no room for another phone" }, 503);
  }
  // Whether a notification could be sent now, so the app doesn't show alerts as on when the
  // server has no push key yet.
  return c.json({ ok: true, alerts: alerts.length, pushes: canPush(c.env) });
});

app.delete("/v1/devices/:token", async (c) => {
  const arrived = c.get("arrived");
  const token = valid.deviceToken(c.req.param("token"));
  const hash = await ownerHash(c);
  // A registration sent before this, still waiting on TfL, must not bring the phone back after.
  // The note only ever moves forward: a removal that finishes late doesn't put an earlier time
  // over a later one's.
  await c.env.DB.prepare("INSERT INTO meta (key, value, updated_at) VALUES (?1, '', ?2) ON CONFLICT(key) DO UPDATE SET updated_at = max(meta.updated_at, ?2)")
    .bind(removalKey(hash), arrived).run();
  // And a registration that arrived after this isn't this removal's to take away.
  const result = await c.env.DB.prepare("DELETE FROM devices WHERE token = ?1 AND secret_hash = ?2 AND updated_at <= ?3").bind(token, hash, arrived).run();
  if (!result.meta?.changes) await rejectOtherOwner(c.env.DB, token, hash);
  return c.json({ ok: true });
});

/** What TfL says about each alert now, and planned works on the times you travel this week. */
app.post("/v1/status", async (c) => {
  const body = valid.body(await c.req.json().catch(() => ({})));
  const alerts = valid.alerts(body.alerts);
  const timeZone = valid.timeZone(body.timeZone ?? "Europe/London");
  return c.json(await status(c.env, alerts, timeZone, Date.now()));
});

/** A real notification to this phone: what's wrong now, or what one will look like. */
app.post("/v1/devices/:token/test", async (c) => {
  const token = valid.deviceToken(c.req.param("token"));
  const hash = await ownerHash(c);
  const row = await c.env.DB.prepare("SELECT environment, time_zone, alerts, revision, updated_at FROM devices WHERE token = ?1 AND secret_hash = ?2")
    .bind(token, hash).first<{ environment: "sandbox" | "production"; time_zone: string; alerts: string; revision: string; updated_at: number }>();
  if (!row) {
    await rejectOtherOwner(c.env.DB, token, hash);
    return c.json({ error: "This phone isn't registered yet" }, 404);
  }
  const alerts = JSON.parse(row.alerts) as Alert[];
  if (!alerts.length) return c.json({ error: "No alerts to test" }, 400);
  const now = Date.now();
  // What's wrong now if TfL answers; the point is proving delivery, so not if it doesn't.
  const statuses = await status(c.env, alerts, row.time_zone, now, 1).then((s) => s.alerts, () => []);
  const withIssues = statuses.find((s) => s.issues.length);
  const alert = alerts.find((a) => a.id === (withIssues?.id ?? alerts[0].id))!;
  const issues: Issue[] = withIssues?.issues.map((i) => ({ ...i, signature: "test", line: "", from: undefined })) ?? [
    { signature: "test", severity: "delays", line: "", title: "Test: alerts are on", detail: `Good service on ${lineList(alert)} now. A closure or delay will come through like this.` },
  ];
  if (!canPush(c.env)) return c.json({ error: "The alert server has no push key yet, so it can't send notifications." }, 503);
  const current = await c.env.DB.prepare("SELECT revision FROM devices WHERE token = ?1 AND secret_hash = ?2")
    .bind(token, hash).first<{ revision: string }>();
  if (!current) {
    await rejectOtherOwner(c.env.DB, token, hash);
    return c.json({ error: "This phone isn't registered yet" }, 404);
  }
  if (current.revision !== row.revision) return c.json({ error: "These alerts changed. Try the test again." }, 409);
  const result = await send(c.env, token, row.environment, { ...issuesPush(alert, issues, now), collapseId: `${alert.id}-test` }, now);
  // Apple says the app is gone from that phone: so is its registration, unless it registered
  // after Apple last looked.
  if (result.gone && (result.goneSince === undefined || row.updated_at <= result.goneSince)) {
    await c.env.DB.prepare("DELETE FROM devices WHERE token = ?1 AND secret_hash = ?2 AND revision = ?3").bind(token, hash, row.revision).run();
  }
  return c.json(result, result.status === 200 ? 200 : 502);
});

app.onError((error, c) => {
  if (error instanceof TooManyRequests) return c.json({ error: "Try again in a minute" }, 429, { "Retry-After": "60" });
  if (error instanceof TfLUnavailable) return c.json({ error: error.message }, 503);
  if (error instanceof valid.Invalid) return c.json({ error: error.message }, 400);
  if (error instanceof NotOwner) return c.json({ error: "This phone is registered by another install of Beeline" }, 403);
  console.error(error);
  return c.json({ error: "Something went wrong" }, 500);
});

async function status(env: Env, alerts: Alert[], timeZone: string, now: number, pushes = 0) {
  // What this request may ask of TfL and the cache: one that needs more than an invocation has
  // is answered "try again", and finds what it did get still kept when it does.
  const tfl = { key: env.TFL_APP_KEY, ops: tflRequests(env, pushes) };
  const segments = alerts.flatMap((a) => a.segments);
  if (!segments.length) return { checkedAt: new Date(now).toISOString(), alerts: alerts.map((a) => ({ id: a.id, issues: [], upcoming: [] })) };
  const catalog = await lineCatalog(tfl);
  validateLines(alerts, catalog);
  const hasPlannedTimes = alerts.some((a) => travelRanges(a, now, timeZone, 8).length);
  // All requests during this hour share the same lookahead, including overnight commutes.
  const hour = Math.floor(now / 3_600_000) * 3_600_000;
  const [current, stops, planned] = await Promise.all([
    lineChecks(segments, catalog, tfl),
    stationChecks(segments, tfl),
    hasPlannedTimes ? lineChecks(segments, catalog, tfl, { from: hour, to: hour + 9 * 86400_000 }) : undefined,
  ]);
  if (current.missing.size || stops.missing.size || planned?.missing.size) {
    throw new TfLUnavailable("TfL could not check every line. Try again later.");
  }
  const lines = current.lines, stations = stops.stations, ahead = planned?.lines ?? [];
  const ways = alerts.flatMap(eachWay);
  const unplaced = new Set<string>();
  const maps = await loadLineMaps([...new Set([...linesToPlace(ways, lines, stations), ...linesToPlace(ways, ahead, stations)])], tfl, Date.now(), unplaced);
  // No requests left to ask where on its line a notice applies: said to try again, not guessed.
  if (unplaced.size) throw new TfLUnavailable("TfL could not check every line. Try again in a moment.");
  const shown = (issues: Issue[]) => issues.map(({ severity, title, detail, from }) => ({ severity, title, detail, from: from && new Date(from).toISOString() }));
  return {
    checkedAt: new Date(now).toISOString(),
    alerts: alerts.map((alert) => {
      // Now: the way of the time you're in; outside your times, every way any of them goes, so
      // nothing a time would show is hidden.
      const live = issuesFor(during(alert, activeWindows(alert, now, timeZone)), lines, stations, { at: now }, maps);
      const liveText = new Set(live.map((i) => i.detail));
      const upcoming = issuesInRanges(alert, ahead, stations, travelRanges(alert, now, timeZone, 8), maps).filter((i) => !liveText.has(i.detail));
      return { id: alert.id, issues: shown(live), upcoming: shown(upcoming) };
    }),
  };
}

function digest(text: string): Promise<ArrayBuffer> {
  return crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
}

function hex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256(text: string): Promise<string> {
  return hex(await digest(text));
}

export default {
  fetch: (request: Request, env: Env, ctx: ExecutionContext) => (useLocalTfL(env.TFL_BASE), app.fetch(request, env, ctx)),
  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext) {
    useLocalTfL(env.TFL_BASE);
    ctx.waitUntil(runChecks(env).then((r) => r.checked && console.log("checked", JSON.stringify(r))));
  },
} satisfies ExportedHandler<Env>;
