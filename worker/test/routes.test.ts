import assert from "node:assert/strict";
import { timingSafeEqual } from "node:crypto";
import { after, afterEach, before, test } from "node:test";
import worker, { maxDevices } from "../src/index.ts";
import { contract, fixture, sqliteD1 } from "./helpers.ts";

// Workers have crypto.subtle.timingSafeEqual; Node keeps it in node:crypto.
(crypto.subtle as any).timingSafeEqual ??= (a: ArrayBuffer, b: ArrayBuffer) => timingSafeEqual(Buffer.from(a), Buffer.from(b));

const fakeDB = sqliteD1;
const realFetch = globalThis.fetch;
const upstreamRequests: URL[] = [];
/** What TfL answers beyond its line catalog, in the status tests. */
let upstream: ((url: URL) => Response) | undefined;
before(() => {
  globalThis.fetch = async (input) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    upstreamRequests.push(url);
    if (url.pathname.startsWith("/Line/Mode/")) return Response.json(fixture("tfl-lines.json"));
    if (upstream) return upstream(url);
    throw new Error("Unexpected upstream request " + url.pathname);
  };
});
afterEach(() => { upstream = undefined; });
after(() => { globalThis.fetch = realFetch; });

const token = "cd".repeat(32);
const mine = "a".repeat(40), theirs = "b".repeat(40);

function call(env: any, method: string, path: string, secret?: string, body?: unknown, invite = "app-token") {
  const headers: Record<string, string> = { authorization: `Bearer ${invite}`, "content-type": "application/json" };
  if (secret) headers["x-device-secret"] = secret;
  const bindings = { STATUS_LIMITER: { limit: async () => ({ success: true }) }, ...env };
  return worker.fetch(new Request(`https://alerts.example.com${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined }), bindings, {} as ExecutionContext);
}

test("only the install that registered a phone can change or remove it", async () => {
  const db = fakeDB();
  const env = { DB: db, APP_TOKEN: "app-token" };
  const body = { ...contract(), environment: "sandbox" };
  assert.equal((await call(env, "PUT", `/v1/devices/${token}`, mine, body)).status, 200);
  assert.match(db.rows.get(token)!.secret_hash, /^[0-9a-f]{64}$/, "only a hash is kept");

  assert.equal((await call(env, "PUT", `/v1/devices/${token}`, theirs, body)).status, 403);
  assert.equal((await call(env, "DELETE", `/v1/devices/${token}`, theirs)).status, 403);
  assert.equal((await call(env, "POST", `/v1/devices/${token}/test`, theirs)).status, 403);
  assert.equal((await call(env, "PUT", `/v1/devices/${token}`, undefined, body)).status, 400, "no secret, no registration");

  assert.equal((await call(env, "PUT", `/v1/devices/${token}`, mine, body)).status, 200);
  assert.equal((await call(env, "DELETE", `/v1/devices/${token}`, mine)).status, 200);
  assert.equal(db.rows.size, 0);
});

test("an invitation admits one phone and can be reused after its old token is removed", async () => {
  const db = fakeDB();
  const env = { DB: db, APP_TOKEN: "app-token", MAX_DEVICES: 4 };
  const body = { ...contract(), environment: "sandbox" };
  const path = `/v1/devices/${token}`;
  const next = `/v1/devices/${"ef".repeat(32)}`;

  assert.equal((await call(env, "PUT", path, mine, body)).status, 200);
  const first = db.rows.get(token)!;
  assert.match(first.enrollment_hash, /^[0-9a-f]{64}$/);
  assert.equal((await call(env, "PUT", path, mine, body)).status, 200);
  assert.notEqual(first.revision, db.rows.get(token)!.revision);
  assert.equal((await call(env, "PUT", next, mine, body)).status, 409);
  assert.equal(db.rows.size, 1);
  assert.equal((await call(env, "DELETE", path, mine)).status, 200);
  assert.equal((await call(env, "DELETE", path, mine)).status, 200, "an already removed token stays removed");
  assert.equal((await call(env, "POST", `${path}/test`, mine)).status, 404);
  assert.equal((await call(env, "PUT", next, mine, body)).status, 200);
});

test("phones registered before enrollment limits retain ownership and can still sync", async () => {
  const db = fakeDB();
  const env = { DB: db, APP_TOKEN: "app-token" };
  const body = { ...contract(), environment: "sandbox" };
  const path = `/v1/devices/${token}`;
  assert.equal((await call(env, "PUT", path, mine, body)).status, 200);
  await db.prepare("UPDATE devices SET enrollment_hash = NULL WHERE token = ?1").bind(token).run();
  assert.equal((await call(env, "PUT", `/v1/devices/${"ef".repeat(32)}`, theirs, body)).status, 200);
  assert.equal((await call(env, "PUT", path, mine, body)).status, 200);
  assert.equal(db.rows.get(token)!.enrollment_hash, null);
  assert.equal((await call(env, "DELETE", path, theirs)).status, 403);
});

test("a stored phone with no secret can't be claimed by the next caller", async () => {
  const db = fakeDB();
  db.rows.set(token, { token, environment: "sandbox", time_zone: "Europe/London", alerts: "[]", secret_hash: null });
  const env = { DB: db, APP_TOKEN: "app-token" };
  assert.equal((await call(env, "PUT", `/v1/devices/${token}`, theirs, { ...contract(), environment: "sandbox" })).status, 403);
  assert.equal((await call(env, "DELETE", `/v1/devices/${token}`, theirs)).status, 403);
  assert.equal((await call(env, "POST", `/v1/devices/${token}/test`, theirs)).status, 403);
  assert.equal(db.rows.get(token)!.secret_hash, null);
});

test("without the app's token, nothing", async () => {
  const env = { DB: fakeDB(), APP_TOKEN: "app-token" };
  const response = await worker.fetch(new Request(`https://x/v1/devices/${token}`, { method: "DELETE", headers: { authorization: "Bearer wrong" } }), env as any, {} as ExecutionContext);
  assert.equal(response.status, 401);
});

test("a full server takes no new phone, but keeps the ones it has", async () => {
  const db = fakeDB();
  const env = { DB: db, APP_TOKEN: "app-token\nsecond-invite", MAX_DEVICES: "1" };
  const body = { ...contract(), environment: "sandbox" };
  assert.equal((await call(env, "PUT", `/v1/devices/${token}`, mine, body)).status, 200);
  assert.equal((await call(env, "PUT", `/v1/devices/${"ef".repeat(32)}`, theirs, body, "second-invite")).status, 503);
  assert.equal((await call(env, "PUT", `/v1/devices/${token}`, mine, body)).status, 200, "an update isn't a new phone");
  assert.equal(db.rows.size, 1);
});

test("an oversized body is refused from its Content-Length, before it's read", async () => {
  const env = { DB: fakeDB(), APP_TOKEN: "app-token" };
  const read = { body: false };
  const stream = new ReadableStream({ pull() { read.body = true; } }, { highWaterMark: 0 });
  const request = new Request(`https://alerts.example.com/v1/devices/${token}`, {
    method: "PUT", body: stream, duplex: "half",
    headers: { authorization: "Bearer app-token", "x-device-secret": mine, "content-type": "application/json", "content-length": String(300 * 1024) },
  } as RequestInit);
  assert.equal((await worker.fetch(request, env as any, {} as ExecutionContext)).status, 413);
  assert.equal(read.body, false, "refused without reading the body");
});

test("an oversized body without a Content-Length is refused as it's read", async () => {
  const env = { DB: fakeDB(), APP_TOKEN: "app-token" };
  const huge = { ...contract(), environment: "sandbox", padding: "x".repeat(300 * 1024) };
  assert.equal((await call(env, "PUT", `/v1/devices/${token}`, mine, huge)).status, 413);
});

test("a line id can't climb out of TfL's /Line/ path", async () => {
  const env = { DB: fakeDB(), APP_TOKEN: "app-token" };
  const body = contract();
  body.alerts[0].segments[0].line.id = "..";
  const response = await worker.fetch(new Request("https://alerts.example.com/v1/status", { method: "POST", headers: { authorization: "Bearer app-token", "content-type": "application/json" }, body: JSON.stringify(body) }), env as any, {} as ExecutionContext);
  assert.equal(response.status, 400);
});

test("health says whether pushes can go out and TfL is asked with a key, and nothing more", async () => {
  const health = async (env: object) => (await worker.fetch(new Request("https://alerts.example.com/health"), { DB: fakeDB(), ...env } as any, {} as ExecutionContext)).json();
  assert.deepEqual(await health({}), { ok: true, pushes: false, tflKey: false });
  assert.deepEqual(await health({ APNS_KEY: "k", APNS_KEY_ID: "K", APNS_TEAM_ID: "T", APNS_TOPIC: "com.cloudslope.beeline", TFL_APP_KEY: "tfl-key" }), { ok: true, pushes: true, tflKey: true });
});

test("MAX_DEVICES: unset is 100, 0 takes no new phones, nonsense is 100; a number from wrangler works", async () => {
  assert.equal(maxDevices({}), 100);
  assert.equal(maxDevices({ MAX_DEVICES: 50 as unknown as string }), 50, "an unquoted var arrives as a number");
  const numeric = { DB: fakeDB(), APP_TOKEN: "app-token\nsecond-invite", MAX_DEVICES: 1 };
  assert.equal((await call(numeric, "PUT", `/v1/devices/${token}`, mine, { ...contract(), environment: "sandbox" })).status, 200);
  assert.equal((await call(numeric, "PUT", `/v1/devices/${"ef".repeat(32)}`, theirs, { ...contract(), environment: "sandbox" }, "second-invite")).status, 503);
  assert.equal(maxDevices({ MAX_DEVICES: "0" }), 0);
  assert.equal(maxDevices({ MAX_DEVICES: " 7 " }), 7);
  assert.equal(maxDevices({ MAX_DEVICES: "lots" }), 100);
  assert.equal(maxDevices({ MAX_DEVICES: "-1" }), 100);
  const env = { DB: fakeDB(), APP_TOKEN: "app-token", MAX_DEVICES: "0" };
  assert.equal((await call(env, "PUT", `/v1/devices/${token}`, mine, { ...contract(), environment: "sandbox" })).status, 503);
});

test("empty or unscheduled registrations cannot consume a phone's place", async () => {
  const db = fakeDB();
  const env = { DB: db, APP_TOKEN: "app-token" };
  for (const alerts of [[], [{ ...contract().alerts[0], segments: [] }], [{ ...contract().alerts[0], days: [] }]]) {
    const res = await call(env, "PUT", `/v1/devices/${token}`, mine, { ...contract(), alerts });
    assert.equal(res.status, 400);
  }
  assert.equal(db.rows.size, 0);
});

test("status uses the authenticated enrollment's limit before contacting TfL", async () => {
  const keys: string[] = [];
  const env = { DB: fakeDB(), APP_TOKEN: "app-token", STATUS_LIMITER: { limit: async ({ key }: { key: string }) => {
    keys.push(key);
    return { success: false };
  } } };
  const before = upstreamRequests.length;
  const res = await call(env, "POST", "/v1/status", undefined, contract());
  assert.equal(res.status, 429);
  assert.equal(res.headers.get("Retry-After"), "60");
  assert.match(keys[0], /^[0-9a-f]{64}$/);
  assert.equal(upstreamRequests.length, before);
});

test("unknown and mismatched lines are rejected using a fixed TfL catalog endpoint", async () => {
  const env = { DB: fakeDB(), APP_TOKEN: "app-token" };
  const before = upstreamRequests.length;
  for (const id of ["unlisted-line", "avanti-west-coast"]) {
    const body = contract();
    body.alerts[0].segments[0].line.id = id;
    assert.equal((await call(env, "POST", "/v1/status", undefined, body)).status, 400);
  }
  assert.equal(upstreamRequests.length - before, 2);
  assert.ok(upstreamRequests.slice(before).every(u => u.pathname.startsWith("/Line/Mode/")));
});

/** TfL with good service on every line asked about and no closures or planned works, except
 * that the requests `fails` picks get a 500. */
const tfl = (fails: (url: URL) => boolean) => (url: URL) => {
  if (fails(url)) return new Response("", { status: 500 });
  if (url.pathname.startsWith("/StopPoint/") || url.pathname.includes("/to/")) return Response.json([]);
  const ids = decodeURIComponent(url.pathname.split("/")[2]).split(",");
  return Response.json(ids.map((id) => ({ id, name: id, lineStatuses: [{ statusSeverity: 10, statusSeverityDescription: "Good Service", reason: "", validityPeriods: [] }] })));
};

async function statusOf(fails: (url: URL) => boolean) {
  upstream = tfl(fails);
  const res = await call({ DB: fakeDB(), APP_TOKEN: "app-token" }, "POST", "/v1/status", undefined, contract());
  return { code: res.status, body: (await res.json()) as any };
}

// The contract's two alerts: the Elizabeth line (its own batch) and the District (in the tube's).
const [elizabeth, district] = contract().alerts;

for (const [what, fails] of [
  ["a line batch", (u: URL) => u.pathname.includes("district") && !u.pathname.includes("/to/")],
  ["a mode's station closures", (u: URL) => u.pathname === "/StopPoint/Mode/tube/Disruption"],
] as const) {
  test(`status: ${what} TfL didn't answer leaves out only the alerts riding it, listed as unchecked`, async (t) => {
    t.mock.method(console, "warn", () => {});
    const { code, body } = await statusOf(fails);
    assert.equal(code, 200);
    assert.deepEqual(body.alerts, [{ id: elizabeth.id, issues: [], upcoming: [] }], "no verdict an older build would show as good service");
    assert.deepEqual(body.unchecked, [district.id]);
  });
}

test("status: planned works TfL didn't give are unknown, not none, and only for the alerts that ride the line", async (t) => {
  t.mock.method(console, "warn", () => {});
  const { code, body } = await statusOf((u) => u.pathname.startsWith("/Line/elizabeth/Status/") && u.pathname.includes("/to/"));
  assert.equal(code, 200);
  assert.deepEqual(body.alerts, [{ id: elizabeth.id, issues: [], upcoming: [], upcomingUnknown: true }, { id: district.id, issues: [], upcoming: [] }]);
  assert.deepEqual(body.unchecked, []);
});

test("status: with every line checked, nothing is unchecked", async () => {
  const { code, body } = await statusOf(() => false);
  assert.equal(code, 200);
  assert.match(body.checkedAt, /^\d{4}-\d\d-\d\dT/);
  assert.deepEqual(body.alerts.map((a: any) => a.id), [elizabeth.id, district.id]);
  assert.deepEqual(body.unchecked, []);
});

test("status: TfL failing every query is a 503, not a list of unchecked alerts", async (t) => {
  t.mock.method(console, "warn", () => {});
  const { code, body } = await statusOf(() => true);
  assert.equal(code, 503);
  assert.match(body.error, /TfL/);
});
