// Beeline Home alerts: the app registers its push token with the lines you use and when, and
// asks what TfL says about them now. The checks run on a cron (checks.ts).

import { Hono, type Context } from "hono";
import { bodyLimit } from "hono/body-limit";
import { canPush, send } from "./apns.ts";
import { emptyState, runChecks, type Env } from "./checks.ts";
import { loadLineMaps } from "./linemap.ts";
import { issuesFor, issuesInRanges, linesToPlace } from "./match.ts";
import { issuesPush, lineList } from "./push.ts";
import { activeWindows, during, eachWay, travelRanges } from "./schedule.ts";
import { fetchTfL, lineStatusURL, useLocalTfL, parseLineStatuses, parseStationDisruptions, stationDisruptionsURL } from "./tfl.ts";
import type { Alert, Issue } from "./types.ts";
import * as valid from "./validate.ts";

const app = new Hono<{ Bindings: Env }>();

// Whether pushes can go out, so a missing push setting shows; never which values are set.
app.get("/health", (c) => c.json({ ok: true, pushes: canPush(c.env) }));

// Nothing is told before the token passes: no version, no setup, no counts.
app.use("/v1/*", async (c, next) => {
  const expected = c.env.APP_TOKEN;
  const given = c.req.header("authorization")?.replace(/^Bearer /, "") ?? "";
  if (!expected || !(await same(given, expected))) return c.json({ error: "Not allowed" }, 401);
  await next();
});

// The largest real registration is a few KB; this stops anyone posting megabytes to parse.
app.use("/v1/*", bodyLimit({ maxSize: 256 * 1024, onError: (c) => c.json({ error: "Too large" }, 413) }));

/** Each install sends its own secret with its token. The registration that first stores a
 * phone keeps the secret's hash, and only that install can change, test or remove it after.
 * A stored phone without one (none are left) can't be claimed by whoever asks next. */
async function owner(c: Context<{ Bindings: Env }>, token: string): Promise<{ hash: string; stored: boolean }> {
  const secret = valid.deviceSecret(c.req.header("x-device-secret"));
  const hash = await sha256(secret);
  const row = await c.env.DB.prepare("SELECT secret_hash FROM devices WHERE token = ?1").bind(token).first<{ secret_hash: string | null }>();
  if (row && (!row.secret_hash || !(await same(row.secret_hash, hash)))) throw new NotOwner();
  return { hash, stored: Boolean(row) };
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

app.put("/v1/devices/:token", async (c) => {
  const token = valid.deviceToken(c.req.param("token"));
  const { hash } = await owner(c, token);
  const body = (await c.req.json().catch(() => ({}))) as Record<string, unknown>;
  const alerts = valid.alerts(body.alerts);
  // One statement: a phone already stored is updated; a new one only while there's room, so
  // two registrations at once can't both take the last place.
  const result = await c.env.DB.prepare(
    `INSERT INTO devices (token, environment, time_zone, alerts, state, updated_at, secret_hash)
     SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7
     WHERE EXISTS (SELECT 1 FROM devices WHERE token = ?1) OR (SELECT COUNT(*) FROM devices) < ?8
     ON CONFLICT(token) DO UPDATE SET environment = ?2, time_zone = ?3, alerts = ?4, updated_at = ?6`,
  ).bind(token, valid.environment(body.environment), valid.timeZone(body.timeZone), JSON.stringify(alerts), JSON.stringify(emptyState()), Date.now(), hash, maxDevices(c.env)).run();
  if (!result.meta?.changes) return c.json({ error: "This alert server has no room for another phone" }, 503);
  return c.json({ ok: true, alerts: alerts.length });
});

app.delete("/v1/devices/:token", async (c) => {
  const token = valid.deviceToken(c.req.param("token"));
  await owner(c, token);
  await c.env.DB.prepare("DELETE FROM devices WHERE token = ?1").bind(token).run();
  return c.json({ ok: true });
});

/** What TfL says about each alert now, and planned works on the times you travel this week. */
app.post("/v1/status", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as Record<string, unknown>;
  const alerts = valid.alerts(body.alerts);
  const timeZone = valid.timeZone(body.timeZone ?? "Europe/London");
  return c.json(await status(c.env, alerts, timeZone, Date.now()));
});

/** A real notification to this phone: what's wrong now, or what one will look like. */
app.post("/v1/devices/:token/test", async (c) => {
  const token = valid.deviceToken(c.req.param("token"));
  await owner(c, token);
  const row = await c.env.DB.prepare("SELECT environment, time_zone, alerts FROM devices WHERE token = ?1").bind(token).first<{ environment: "sandbox" | "production"; time_zone: string; alerts: string }>();
  if (!row) return c.json({ error: "This phone isn't registered yet" }, 404);
  const alerts = JSON.parse(row.alerts) as Alert[];
  if (!alerts.length) return c.json({ error: "No alerts to test" }, 400);
  const now = Date.now();
  // What's wrong now if TfL answers; the point is proving delivery, so not if it doesn't.
  const statuses = await status(c.env, alerts, row.time_zone, now).then((s) => s.alerts, () => []);
  const withIssues = statuses.find((s) => s.issues.length);
  const alert = alerts.find((a) => a.id === (withIssues?.id ?? alerts[0].id))!;
  const issues: Issue[] = withIssues?.issues.map((i) => ({ ...i, signature: "test", line: "", from: undefined })) ?? [
    { signature: "test", severity: "delays", line: "", title: "Test: alerts are on", detail: `Good service on ${lineList(alert)} now. A closure or delay will come through like this.` },
  ];
  if (!canPush(c.env)) return c.json({ error: "The alert server has no push key yet, so it can't send notifications." }, 503);
  const result = await send(c.env, token, row.environment, { ...issuesPush(alert, issues, now), collapseId: `${alert.id}-test` }, now);
  return c.json(result, result.status === 200 ? 200 : 502);
});

app.onError((error, c) => {
  if (error instanceof valid.Invalid) return c.json({ error: error.message }, 400);
  if (error instanceof NotOwner) return c.json({ error: "This phone is registered by another install of Beeline Home" }, 403);
  console.error(error);
  return c.json({ error: "Something went wrong" }, 500);
});

async function status(env: Env, alerts: Alert[], timeZone: string, now: number) {
  const segments = alerts.flatMap((a) => a.segments);
  if (!segments.length) return { checkedAt: new Date(now).toISOString(), alerts: alerts.map((a) => ({ id: a.id, issues: [], upcoming: [] })) };
  const ids = segments.map((s) => s.line.id);
  const week = alerts.flatMap((a) => travelRanges(a, now, timeZone, 8));
  // From the start of the hour, so the same request repeats and the edge cache answers it.
  const hour = Math.floor(now / 3_600_000) * 3_600_000;
  const [lines, stations, ahead] = await Promise.all([
    fetchTfL(lineStatusURL(ids), 60, env.TFL_APP_KEY).then(parseLineStatuses),
    fetchTfL(stationDisruptionsURL(segments.map((s) => s.mode)), 60, env.TFL_APP_KEY).then(parseStationDisruptions),
    week.length
      ? fetchTfL(lineStatusURL(ids, { from: hour, to: Math.max(...week.map((r) => r.to)) }), 900, env.TFL_APP_KEY)
          .then(parseLineStatuses, (error) => (console.error("planned works unavailable", String(error)), []))
      : Promise.resolve([]),
  ]);
  const ways = alerts.flatMap(eachWay);
  const maps = await loadLineMaps([...new Set([...linesToPlace(ways, lines, stations), ...linesToPlace(ways, ahead, stations)])], env.TFL_APP_KEY);
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

async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function same(a: string, b: string): Promise<boolean> {
  const [x, y] = await Promise.all([a, b].map((s) => crypto.subtle.digest("SHA-256", new TextEncoder().encode(s))));
  return crypto.subtle.timingSafeEqual(x, y);
}

export default {
  fetch: (request: Request, env: Env, ctx: ExecutionContext) => (useLocalTfL(env.TFL_BASE), app.fetch(request, env, ctx)),
  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext) {
    useLocalTfL(env.TFL_BASE);
    ctx.waitUntil(runChecks(env).then((r) => r.checked && console.log("checked", JSON.stringify(r))));
  },
} satisfies ExportedHandler<Env>;
