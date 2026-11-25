import assert from "node:assert/strict";
import { timingSafeEqual } from "node:crypto";
import { afterEach, test } from "node:test";
import { attributesFor, dueStarts, followFor, runActivities, shortNotice, staleDate, startPush, updatePush, urgency, type ContentState } from "../src/activities.ts";
import type { Env } from "../src/checks.ts";
import worker from "../src/index.ts";
import { forgetLineMaps } from "../src/linemap.ts";
import type { Alert } from "../src/types.ts";
import { fixture, sqliteD1 } from "./helpers.ts";

(crypto.subtle as any).timingSafeEqual ??= (a: ArrayBuffer, b: ArrayBuffer) => timingSafeEqual(Buffer.from(a), Buffer.from(b));

/** The recordings' moment: 19:15:46 on Wednesday 25 November 2026. */
const NOW = Date.parse("2026-11-25T19:15:46Z");
const s = (ms: number) => Math.floor(ms / 1000);
const contract = () => fixture("next-train-contract.json");

const commute: Alert = {
  id: "commute", name: "Commute", days: [1, 2, 3, 4, 5], minorDelays: true, direction: "out", liveActivity: true,
  windows: [{ start: 19 * 60, end: 20 * 60 }, { start: 7 * 60 + 30, end: 9 * 60 + 30, direction: "back" }],
  segments: [
    { line: { id: "central", name: "Central line" }, mode: "tube", from: { id: "940GZZLURBG", name: "Redbridge" }, to: { id: "940GZZLULVT", name: "Liverpool Street" }, stations: [] },
    { line: { id: "elizabeth", name: "Elizabeth line" }, mode: "elizabeth-line", from: { id: "910GLIVSTLL|910GLIVST", name: "Liverpool Street" }, to: { id: "910GPADTLL", name: "Paddington" }, stations: [] },
  ],
};

const realFetch = globalThis.fetch;
afterEach(() => { globalThis.fetch = realFetch; forgetLineMaps(); });

test("what the server sends is what the app decodes", () => {
  const { attributes, "content-state": state } = contract();
  const follow = followFor(commute, commute.windows[0])!;
  assert.deepEqual(Object.keys(attributesFor(commute, follow, attributes.ends * 1000)).sort(), Object.keys(attributes).sort());
  assert.deepEqual({ ...attributesFor(commute, follow, attributes.ends * 1000), key: attributes.key }, attributes);
  const push = startPush(attributes, state, NOW).payload.aps as Record<string, any>;
  assert.equal(push["attributes-type"], "NextTrainAttributes", "the Swift type's name");
  assert.deepEqual(push["content-state"], state);
  assert.equal(push.alert.title, "Central from Redbridge");
  assert.equal(push["input-push-token"], 1, "or iOS gives the started one no token for updates");
});

test("a time going back follows the last stretch the other way; whole lines and buses follow nothing", () => {
  assert.deepEqual(followFor(commute, commute.windows[1]), {
    line: { id: "elizabeth", name: "Elizabeth line" }, mode: "elizabeth-line",
    from: { id: "910GPADTLL", name: "Paddington" }, to: { id: "910GLIVSTLL|910GLIVST", name: "Liverpool Street" }, stations: [],
  });
  assert.equal(followFor({ ...commute, segments: [{ line: { id: "central", name: "Central line" }, mode: "tube", stations: [] }] }, commute.windows[0]), undefined);
  assert.equal(followFor({ ...commute, segments: [{ ...commute.segments[0], mode: "national-rail" }] }, commute.windows[0]), undefined);
});

test("pushes go out for news only, the train you're after first", () => {
  const train = (minutes: number, extra = {}) => ({ at: s(NOW) + minutes * 60, cancelled: false, ...extra });
  const shown: ContentState = { trains: [train(2), train(8), train(13)], updated: s(NOW), live: true };
  assert.equal(urgency(undefined, shown, NOW), 10);
  assert.equal(urgency(shown, { ...shown, updated: s(NOW) + 60 }, NOW), 0, "the same trains: nothing");
  assert.equal(urgency(shown, { ...shown, trains: [train(2), train(8.5), train(13)] }, NOW), 0, "under a minute's drift: nothing");
  assert.equal(urgency(shown, { ...shown, trains: [train(4), train(8), train(13)] }, NOW), 10, "yours moved");
  assert.equal(urgency(shown, { ...shown, trains: [train(2, { cancelled: true }), train(8), train(13)] }, NOW), 10, "yours cancelled");
  assert.equal(urgency(shown, { ...shown, trains: [train(2), train(10), train(13)] }, NOW), 5, "a later one moved");
  assert.equal(urgency(shown, { ...shown, notice: "Severe delays" }, NOW), 5);
  assert.equal(urgency(shown, { ...shown, trains: [train(8), train(13), train(17)] }, NOW + 2.5 * 60_000), 10, "yours has gone");
});

test("the phone looks again just after the first train leaves", () => {
  const state: ContentState = { trains: [{ at: s(NOW) - 10, cancelled: false }, { at: s(NOW) + 240, cancelled: false }], updated: s(NOW), live: true };
  assert.equal(staleDate(state, NOW), s(NOW) + 270);
  assert.equal(staleDate({ ...state, trains: [] }, NOW), s(NOW) + 600);
  const aps = updatePush(state, 5, NOW).payload.aps as Record<string, unknown>;
  assert.deepEqual(Object.keys(aps).sort(), ["content-state", "event", "stale-date", "timestamp"]);
});

test("notices say the trouble in a few words", () => {
  assert.equal(shortNotice("Central line: severe delays", "Central line"), "Severe delays");
  assert.equal(shortNotice("Bank closed (Northern line)", "Northern line"), "Bank closed (Northern line)");
  assert.equal(shortNotice(`Central line: ${"very ".repeat(20)}late`, "Central line").length, 40);
});

test("a saved line starts one when its time begins, once, and not in its last ten minutes", () => {
  const device = { token: "ab".repeat(32), environment: "sandbox" as const, time_zone: "Europe/London", alerts: JSON.stringify([commute]), start_token: "ef".repeat(40), started: "{}", state: "{}" };
  const [due] = dueStarts([device], NOW);
  assert.equal(due.alert.id, "commute");
  assert.equal(due.follow.from!.name, "Redbridge");
  assert.equal(due.ends, Date.parse("2026-11-25T20:00:00Z"));
  assert.deepEqual(dueStarts([{ ...device, started: JSON.stringify({ [due.occurrence]: due.ends }) }], NOW), [], "already started this time");
  assert.deepEqual(dueStarts([{ ...device, state: JSON.stringify({ revoked: NOW - 60_000 }) }], NOW), [], "not for a phone whose invitation was taken out");

  // Two times that overlap: each starts once, not one after the other every minute.
  const overlapping = { ...device, alerts: JSON.stringify([{ ...commute, windows: [{ start: 18 * 60 + 30, end: 20 * 60 }, { start: 19 * 60, end: 20 * 60 + 30 }] }]) };
  const first = dueStarts([overlapping], NOW)[0];
  const second = dueStarts([{ ...overlapping, started: JSON.stringify({ [first.occurrence]: first.ends }) }], NOW)[0];
  assert.notEqual(second.occurrence, first.occurrence);
  assert.deepEqual(dueStarts([{ ...overlapping, started: JSON.stringify({ [first.occurrence]: first.ends, [second.occurrence]: second.ends }) }], NOW), []);
  assert.deepEqual(dueStarts([device], Date.parse("2026-11-25T19:51:00Z")), [], "nine minutes left");
  assert.deepEqual(dueStarts([{ ...device, alerts: JSON.stringify([{ ...commute, liveActivity: false }]) }], NOW), []);
  assert.deepEqual(dueStarts([device], Date.parse("2026-11-28T19:15:00Z")), [], "not on a Saturday");
});

// MARK: The server

const activity = "12".repeat(40), startToken = "ef".repeat(40), phone = "ab".repeat(32);
const mine = "a".repeat(40), theirs = "b".repeat(40);

async function setup() {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign"])) as CryptoKeyPair;
  const key = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
  const db = sqliteD1();
  const env = {
    DB: db, APP_TOKEN: "app-token", APNS_KEY: key, APNS_KEY_ID: "KEY123", APNS_TEAM_ID: "TEAM123456", APNS_TOPIC: "com.cloudslope.beeline",
    STATUS_LIMITER: { limit: async () => ({ success: true }) },
  } as unknown as Env;
  const pushes: { url: string; headers: Record<string, string>; body: any }[] = [];
  const apns = { status: 200, reason: "" };
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input instanceof Request ? input.url : input);
    if (url.includes("push.apple.com")) {
      pushes.push({ url, headers: init!.headers as Record<string, string>, body: JSON.parse(init!.body as string) });
      return new Response(apns.status === 200 ? "" : JSON.stringify({ reason: apns.reason }), { status: apns.status });
    }
    if (url.includes("/Line/Mode/")) return Response.json(fixture("tfl-lines.json"));
    if (url.includes("/Route/Sequence/")) return Response.json(fixture(url.includes("/central/") ? "tfl-sequence-central.json" : "tfl-sequence-elizabeth.json"));
    if (url.includes("/Arrivals/")) return Response.json(fixture("tfl-arrivals-central.json"));
    if (url.includes("/ArrivalDepartures")) return Response.json(fixture("tfl-departures-elizabeth.json"));
    if (url.includes("/StopPoint/Mode/")) return Response.json([]);
    if (url.includes("/Status")) return Response.json([{ id: "central", name: "Central", lineStatuses: [{ statusSeverity: 10, statusSeverityDescription: "Good Service" }] }]);
    throw new Error(`unexpected fetch ${url}`);
  }) as typeof fetch;
  const call = (method: string, path: string, secret?: string, body?: unknown) => {
    const headers: Record<string, string> = { authorization: "Bearer app-token", "content-type": "application/json" };
    if (secret) headers["x-device-secret"] = secret;
    return worker.fetch(new Request(`https://alerts.example.com${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined }), env, {} as ExecutionContext);
  };
  const rows = (sql: string, ...args: unknown[]) => (db.prepare(sql).bind(...args).all() as Promise<{ results: any[] }>).then((r) => r.results);
  return { env, db, pushes, apns, call, rows };
}

const follow = contract().attributes.follow;

test("a phone registers its Live Activity and gets the next trains back at once", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: NOW });
  const { call, rows } = await setup();
  const ends = s(NOW) + 3600;
  const reply = await call("PUT", `/v1/activities/${activity}`, mine, { environment: "sandbox", follow, ends });
  assert.equal(reply.status, 200);
  const { state, pushes: canPush } = (await reply.json()) as { state: ContentState; pushes: boolean };
  assert.deepEqual(state.trains.map((t) => t.at), [1795634274, 1795634664]);
  assert.equal(state.live, true);
  assert.equal(canPush, true, "the phone needn't keep it fresh itself");
  const [row] = await rows("SELECT * FROM activities");
  assert.equal(row.ends_at, ends * 1000);
  assert.deepEqual(JSON.parse(row.state), state, "kept, so the next minute pushes only news");

  assert.equal((await call("PUT", `/v1/activities/${activity}`, theirs, { environment: "sandbox", follow, ends })).status, 403);
  assert.equal((await call("DELETE", `/v1/activities/${activity}`, theirs)).status, 200);
  assert.equal((await rows("SELECT token FROM activities")).length, 1, "only its owner removes it");
  assert.equal((await call("DELETE", `/v1/activities/${activity}`, mine)).status, 200);
  assert.equal((await rows("SELECT token FROM activities")).length, 0);
});

test("only lines TfL has live times for, ends ahead, and four at a time per invitation", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: NOW });
  const { call, rows } = await setup();
  const ends = s(NOW) + 3600;
  const rail = { ...follow, line: { id: "c2c", name: "c2c" }, mode: "national-rail" };
  assert.equal((await call("PUT", `/v1/activities/${activity}`, mine, { environment: "sandbox", follow: rail, ends })).status, 400);
  assert.equal((await call("PUT", `/v1/activities/${activity}`, mine, { environment: "sandbox", follow, ends: s(NOW) - 1 })).status, 400);
  assert.equal((await call("PUT", `/v1/activities/${activity}`, mine, { environment: "sandbox", follow: { ...follow, to: undefined }, ends })).status, 400);
  for (let i = 0; i < 5; i++) {
    t.mock.timers.setTime(NOW + i * 1000);
    assert.equal((await call("PUT", `/v1/activities/${String(i).repeat(80)}`, mine, { environment: "sandbox", follow, ends })).status, 200);
  }
  assert.deepEqual((await rows("SELECT token FROM activities ORDER BY token")).map((r) => r.token[0]), ["1", "2", "3", "4"], "the oldest made room");
});

test("every minute: news is pushed to the Live Activity, sameness isn't, and it ends on time", async () => {
  const { env, db, pushes, rows } = await setup();
  const ends = NOW + 30 * 60_000;
  await db.prepare("INSERT INTO activities (token, environment, follow, ends_at, state, updated_at, secret_hash, enrollment_hash) VALUES (?1, 'sandbox', ?2, ?3, '', ?4, 'h', 'e')")
    .bind(activity, JSON.stringify(follow), ends, NOW).run();

  assert.deepEqual(await runActivities(env, NOW), { followed: 1, sent: 1, started: 0, ended: 0 });
  const [push] = pushes;
  assert.equal(push.url, `https://api.sandbox.push.apple.com/3/device/${activity}`);
  assert.equal(push.headers["apns-topic"], "com.cloudslope.beeline.push-type.liveactivity");
  assert.equal(push.headers["apns-push-type"], "liveactivity");
  assert.equal(push.headers["apns-priority"], "10");
  assert.equal(push.body.aps.event, "update");
  assert.deepEqual(push.body.aps["content-state"].trains.map((t: { at: number }) => t.at), [1795634274, 1795634664]);
  assert.equal(push.body.aps["stale-date"], 1795634274 + 30);

  pushes.length = 0;
  assert.deepEqual(await runActivities(env, NOW + 60_000), { followed: 1, sent: 0, started: 0, ended: 0 }, "nothing new");
  assert.equal(pushes.length, 0);

  assert.deepEqual(await runActivities(env, NOW + 3 * 60_000), { followed: 1, sent: 1, started: 0, ended: 0 }, "the 19:17 has gone");
  assert.deepEqual(pushes[0].body.aps["content-state"].trains.map((t: { at: number }) => t.at), [1795634664]);

  pushes.length = 0;
  assert.deepEqual(await runActivities(env, ends), { followed: 0, sent: 0, started: 0, ended: 1 });
  assert.equal(pushes[0].body.aps.event, "end");
  assert.equal((await rows("SELECT token FROM activities")).length, 0);
});

test("a Live Activity the phone has dismissed is forgotten", async () => {
  const { env, db, apns, rows } = await setup();
  await db.prepare("INSERT INTO activities (token, environment, follow, ends_at, state, updated_at, secret_hash, enrollment_hash) VALUES (?1, 'sandbox', ?2, ?3, '', ?4, 'h', 'e')")
    .bind(activity, JSON.stringify(follow), NOW + 30 * 60_000, NOW).run();
  Object.assign(apns, { status: 410, reason: "Unregistered" });
  await runActivities(env, NOW);
  assert.equal((await rows("SELECT token FROM activities")).length, 0);
});

test("at a saved line's travel time the server starts the Live Activity, once", async () => {
  const { env, db, pushes, call, rows } = await setup();
  const registration = { environment: "sandbox", timeZone: "Europe/London", alerts: [commute], startToken };
  const reply = await call("PUT", `/v1/devices/${phone}`, mine, registration);
  assert.equal(reply.status, 200, await reply.clone().text());
  assert.equal(db.rows.get(phone)!.start_token, startToken);

  assert.deepEqual(await runActivities(env, NOW), { followed: 0, sent: 0, started: 1, ended: 0 });
  const [push] = pushes;
  assert.equal(push.url, `https://api.sandbox.push.apple.com/3/device/${startToken}`);
  assert.equal(push.headers["apns-topic"], "com.cloudslope.beeline.push-type.liveactivity");
  assert.equal(push.body.aps.event, "start");
  assert.equal(push.body.aps.attributes.key, "alert:commute");
  assert.equal(push.body.aps.attributes.ends, s(Date.parse("2026-11-25T20:00:00Z")));
  assert.equal(push.body.aps["content-state"].trains.length, 2);

  pushes.length = 0;
  assert.deepEqual(await runActivities(env, NOW + 60_000), { followed: 0, sent: 0, started: 0, ended: 0 }, "not again this evening");
  assert.deepEqual(JSON.parse((await rows("SELECT started FROM devices"))[0].started), { [`commute@${Date.parse("2026-11-25T19:00:00Z")}`]: Date.parse("2026-11-25T20:00:00Z") });

  // A registration without the token (notifications reset) stops the starts.
  await call("PUT", `/v1/devices/${phone}`, mine, { ...registration, startToken: undefined });
  assert.equal(db.rows.get(phone)!.start_token, null);
});

test("one run at a time, and trouble TfL didn't say this time keeps its notice", async () => {
  const { env, db, pushes } = await setup();
  const shown: ContentState = { trains: [{ at: 1795634274, cancelled: false }, { at: 1795634664, cancelled: false }], notice: "Severe delays", updated: s(NOW), live: true };
  await db.prepare("INSERT INTO activities (token, environment, follow, ends_at, state, updated_at, secret_hash, enrollment_hash) VALUES (?1, 'sandbox', ?2, ?3, ?4, ?5, 'h', 'e')")
    .bind(activity, JSON.stringify(follow), NOW + 30 * 60_000, JSON.stringify(shown), NOW).run();

  await db.prepare("INSERT INTO meta (key, value, updated_at) VALUES ('live_run', '', ?1)").bind(Date.now()).run();
  assert.deepEqual(await runActivities(env, NOW), { followed: 0, sent: 0, started: 0, ended: 0 }, "another run has the turn");
  await db.prepare("UPDATE meta SET updated_at = 0 WHERE key = 'live_run'").run();

  // TfL's status doesn't answer: the trains are the same, and the notice stays, so nothing to push.
  const fetchWithStatus = globalThis.fetch;
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) =>
    String(input).includes("/Status") ? new Response("", { status: 503 }) : fetchWithStatus(input, init)) as typeof fetch;
  assert.deepEqual(await runActivities(env, NOW), { followed: 1, sent: 0, started: 0, ended: 0 });
  assert.equal(pushes.length, 0);

  // It answers good service: the notice goes.
  globalThis.fetch = fetchWithStatus;
  assert.deepEqual(await runActivities(env, NOW), { followed: 1, sent: 1, started: 0, ended: 0 });
  assert.equal(pushes[0].body.aps["content-state"].notice, undefined);
});
