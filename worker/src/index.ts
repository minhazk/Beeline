// Beeline alerts: the app registers its push token with the lines you use and when, and
// asks what TfL says about them now. The checks run on a cron (checks.ts).

import { Hono, type Context } from "hono";
import { bodyLimit } from "hono/body-limit";
import { canPush, send } from "./apns.ts";
import { emptyState, runChecks, type Env } from "./checks.ts";
import { loadLineMaps } from "./linemap.ts";
import { issuesFor, issuesInRanges, linesToPlace } from "./match.ts";
import { issuesPush, lineList } from "./push.ts";
import { activeWindows, during, eachWay, travelRanges } from "./schedule.ts";
import { useLocalTfL } from "./tfl.ts";
import { lineCatalog, lineChecks, stationChecks, TfLUnavailable, validateLines } from "./linechecks.ts";
import type { Alert, Issue } from "./types.ts";
import * as valid from "./validate.ts";

type AppEnv = { Bindings: Env; Variables: { enrollmentHash: string } };
const app = new Hono<AppEnv>();

// Whether pushes can go out and TfL is asked with a key, so a missing setting shows; never the
// values themselves.
app.get("/health", (c) => c.json({ ok: true, pushes: canPush(c.env), tflKey: Boolean(c.env.TFL_APP_KEY) }));

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

/** The same enrollment has one edge quota even when many addresses use it. */
async function limitFetches(c: Context<AppEnv>) {
  if (!c.env.STATUS_LIMITER) throw new TfLUnavailable("The alert server is missing its request limiter.");
  if (!(await c.env.STATUS_LIMITER.limit({ key: c.get("enrollmentHash") })).success) throw new TooManyRequests();
}
class TooManyRequests extends Error {}

app.put("/v1/devices/:token", async (c) => {
  const token = valid.deviceToken(c.req.param("token"));
  const hash = await ownerHash(c);
  const enrollment = c.get("enrollmentHash");
  const body = (await c.req.json().catch(() => ({}))) as Record<string, unknown>;
  const alerts = valid.alerts(body.alerts);
  if (!alerts.length) throw new valid.Invalid("A registration needs at least one scheduled alert");
  await limitFetches(c);
  validateLines(alerts, await lineCatalog(c.env.TFL_APP_KEY));
  // One statement: a phone already stored is updated; a new one only while there's room, so
  // two registrations at once can't both take the last place.
  const result = await c.env.DB.prepare(
    `INSERT INTO devices (token, environment, time_zone, alerts, state, updated_at, secret_hash, revision, enrollment_hash)
     SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, lower(hex(randomblob(16))), ?9
     WHERE EXISTS (SELECT 1 FROM devices WHERE token = ?1) OR (SELECT COUNT(*) FROM devices) < ?8
     ON CONFLICT(token) DO UPDATE SET environment = ?2, time_zone = ?3, alerts = ?4, updated_at = ?6, revision = excluded.revision
     WHERE devices.secret_hash = excluded.secret_hash
     ON CONFLICT(enrollment_hash) DO NOTHING`,
  ).bind(token, valid.environment(body.environment), valid.timeZone(body.timeZone), JSON.stringify(alerts), JSON.stringify(emptyState()), Date.now(), hash, maxDevices(c.env), enrollment).run();
  if (!result.meta?.changes) {
    await rejectOtherOwner(c.env.DB, token, hash);
    if (await c.env.DB.prepare("SELECT 1 FROM devices WHERE enrollment_hash = ?1 AND token != ?2").bind(enrollment, token).first()) {
      return c.json({ error: "This invitation already has a phone. Remove its old registration or use a new invitation." }, 409);
    }
    return c.json({ error: "This alert server has no room for another phone" }, 503);
  }
  return c.json({ ok: true, alerts: alerts.length });
});

app.delete("/v1/devices/:token", async (c) => {
  const token = valid.deviceToken(c.req.param("token"));
  const hash = await ownerHash(c);
  const result = await c.env.DB.prepare("DELETE FROM devices WHERE token = ?1 AND secret_hash = ?2").bind(token, hash).run();
  if (!result.meta?.changes) await rejectOtherOwner(c.env.DB, token, hash);
  return c.json({ ok: true });
});

/** What TfL says about each alert now, and planned works on the times you travel this week.
 * Alerts TfL couldn't answer for are listed in `unchecked` and left out of `alerts`, so no build
 * shows them as good service. */
app.post("/v1/status", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as Record<string, unknown>;
  const alerts = valid.alerts(body.alerts);
  const timeZone = valid.timeZone(body.timeZone ?? "Europe/London");
  await limitFetches(c);
  return c.json(await status(c.env, alerts, timeZone, Date.now()));
});

/** A real notification to this phone: what's wrong now, or what one will look like. */
app.post("/v1/devices/:token/test", async (c) => {
  const token = valid.deviceToken(c.req.param("token"));
  const hash = await ownerHash(c);
  const row = await c.env.DB.prepare("SELECT environment, time_zone, alerts, revision FROM devices WHERE token = ?1 AND secret_hash = ?2")
    .bind(token, hash).first<{ environment: "sandbox" | "production"; time_zone: string; alerts: string; revision: string }>();
  if (!row) {
    await rejectOtherOwner(c.env.DB, token, hash);
    return c.json({ error: "This phone isn't registered yet" }, 404);
  }
  const alerts = JSON.parse(row.alerts) as Alert[];
  if (!alerts.length) return c.json({ error: "No alerts to test" }, 400);
  const now = Date.now();
  await limitFetches(c);
  // What's wrong now if TfL answers; the point is proving delivery, so not if it doesn't.
  const statuses = await status(c.env, alerts, row.time_zone, now).then((s) => s.alerts, () => []);
  const withIssues = statuses.find((s) => s.issues.length);
  // Good service is said only of a line TfL answered for.
  const known = withIssues ?? statuses[0];
  const alert = alerts.find((a) => a.id === (known?.id ?? alerts[0].id))!;
  const good = known ? `Good service on ${lineList(alert)} now. ` : "";
  const issues: Issue[] = withIssues?.issues.map((i) => ({ ...i, signature: "test", line: "", from: undefined })) ?? [
    { signature: "test", severity: "delays", line: "", title: "Test: alerts are on", detail: `${good}A closure or delay will come through like this.` },
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

async function status(env: Env, alerts: Alert[], timeZone: string, now: number) {
  const checkedAt = new Date(now).toISOString();
  const segments = alerts.flatMap((a) => a.segments);
  if (!segments.length) return { checkedAt, alerts: alerts.map((a) => ({ id: a.id, issues: [], upcoming: [] })), unchecked: [] };
  const catalog = await lineCatalog(env.TFL_APP_KEY);
  validateLines(alerts, catalog);
  const hasPlannedTimes = alerts.some((a) => travelRanges(a, now, timeZone, 8).length);
  // All requests during this hour share the same lookahead, including overnight commutes.
  const hour = Math.floor(now / 3_600_000) * 3_600_000;
  const [current, stops, planned] = await Promise.all([
    lineChecks(segments, catalog, env.TFL_APP_KEY),
    stationChecks(segments, env.TFL_APP_KEY),
    hasPlannedTimes ? lineChecks(segments, catalog, env.TFL_APP_KEY, { from: hour, to: hour + 9 * 86400_000 }) : undefined,
  ]);
  // One line or mode TfL didn't answer for costs only the alerts that ride it.
  const unchecked = new Set(alerts.filter((a) => a.segments.some((s) => current.missing.has(s.line.id) || stops.missing.has(s.mode))));
  if (alerts.every((a) => !a.segments.length || unchecked.has(a))) throw new TfLUnavailable("TfL couldn't be reached just now. Try again in a minute.");
  const checked = alerts.filter((a) => !unchecked.has(a));
  const lines = current.lines, stations = stops.stations, ahead = planned?.lines ?? [];
  const ways = checked.flatMap(eachWay);
  const maps = await loadLineMaps([...new Set([...linesToPlace(ways, lines, stations), ...linesToPlace(ways, ahead, stations)])], env.TFL_APP_KEY);
  const shown = (issues: Issue[]) => issues.map(({ severity, title, detail, from }) => ({ severity, title, detail, from: from && new Date(from).toISOString() }));
  return {
    checkedAt,
    alerts: checked.map((alert) => {
      // Now: the way of the time you're in; outside your times, every way any of them goes, so
      // nothing a time would show is hidden.
      const live = issuesFor(during(alert, activeWindows(alert, now, timeZone)), lines, stations, { at: now }, maps);
      const liveText = new Set(live.map((i) => i.detail));
      const ranges = travelRanges(alert, now, timeZone, 8);
      // Planned works TfL didn't give are unknown, not none.
      if (ranges.length && alert.segments.some((s) => planned?.missing.has(s.line.id))) {
        return { id: alert.id, issues: shown(live), upcoming: [], upcomingUnknown: true };
      }
      const upcoming = issuesInRanges(alert, ahead, stations, ranges, maps).filter((i) => !liveText.has(i.detail));
      return { id: alert.id, issues: shown(live), upcoming: shown(upcoming) };
    }),
    unchecked: alerts.filter((a) => unchecked.has(a)).map((a) => a.id),
  };
}

let toldNoKey = false;
/** Once per isolate, so a deployment without a key says why its checks fail. */
function warnWithoutKey(env: Env) {
  if (env.TFL_APP_KEY || env.TFL_BASE || toldNoKey) return;
  toldNoKey = true;
  console.warn("TFL_APP_KEY is not set: TfL rate-limits Cloudflare's shared addresses, so line checks will fail");
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
  fetch: (request: Request, env: Env, ctx: ExecutionContext) => (useLocalTfL(env.TFL_BASE), warnWithoutKey(env), app.fetch(request, env, ctx)),
  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext) {
    useLocalTfL(env.TFL_BASE);
    warnWithoutKey(env);
    ctx.waitUntil(runChecks(env).then((r) => r.checked && console.log("checked", JSON.stringify(r))));
  },
} satisfies ExportedHandler<Env>;
