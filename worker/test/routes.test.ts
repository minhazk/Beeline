import assert from "node:assert/strict";
import { timingSafeEqual } from "node:crypto";
import { after, afterEach, before, test } from "node:test";
import worker, { maxDevices, REQUESTS_PER_DAY, REQUESTS_PER_MINUTE } from "../src/index.ts";
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
  assert.equal((await call(env, "PUT", next, theirs, body)).status, 409, "another install can't use a taken invitation");
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
  const env = { DB: fakeDB(), APP_TOKEN: "app-token", STATUS_LIMITER: { limit: async () => ({ success: true }) } };
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
  const env = { DB: fakeDB(), APP_TOKEN: "app-token", STATUS_LIMITER: { limit: async () => ({ success: true }) } };
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

test("the same install with a new push token takes over its own registration under the invitation", async () => {
  const db = fakeDB();
  const env = { DB: db, APP_TOKEN: "app-token" };
  const body = { ...contract(), environment: "sandbox" };
  const next = "ef".repeat(32);
  assert.equal((await call(env, "PUT", `/v1/devices/${token}`, mine, body)).status, 200);
  await db.prepare("UPDATE devices SET updated_at = updated_at - 60000").run();
  assert.equal((await call(env, "PUT", `/v1/devices/${next}`, mine, body)).status, 200, "a reinstall keeps its secret and gets a new token");
  assert.equal(db.rows.get(token), undefined, "the token nothing can reach is gone");
  assert.ok(db.rows.get(next));
  assert.equal(db.rows.size, 1);
});

/** A request as if it reached the server at `time`, whenever it is really handled: the order
 * registrations and removals apply in is the order they arrived in. */
async function arriving<T>(time: number, work: () => Promise<T>): Promise<T> {
  const clock = Date.now;
  Date.now = () => time;
  try { return await work(); } finally { Date.now = clock; }
}

test("a registration still on its way when the phone is removed doesn't bring it back", async () => {
  const db = fakeDB();
  const env = { DB: db, APP_TOKEN: "app-token" };
  const body = { ...contract(), environment: "sandbox" };
  const path = `/v1/devices/${token}`, t = Date.now();
  // The removal arrives, and is done, while the registration sent before it waits on TfL.
  assert.equal((await arriving(t + 1000, () => call(env, "DELETE", path, mine))).status, 200);
  assert.equal((await arriving(t, () => call(env, "PUT", path, mine, body))).status, 409);
  assert.equal(db.rows.size, 0);
  // Another install's removal of the same token holds nobody back, and neither does a removal
  // that finishes late put its earlier time over a later one's.
  assert.equal((await arriving(t + 3000, () => call(env, "DELETE", path, theirs))).status, 200);
  assert.equal((await arriving(t + 500, () => call(env, "DELETE", path, mine))).status, 200);
  assert.equal((await arriving(t + 900, () => call(env, "PUT", path, mine, body))).status, 409, "still before the removal at t + 1000");
  assert.equal((await arriving(t + 2000, () => call(env, "PUT", path, mine, body))).status, 200, "saved again later, it registers");
});

test("changes to a phone apply in the order they arrived, whichever finishes last", async () => {
  const db = fakeDB();
  const env = { DB: db, APP_TOKEN: "app-token" };
  const body = (name: string) => { const b = { ...contract(), environment: "sandbox" }; b.alerts[0].name = name; return b; };
  const path = `/v1/devices/${token}`, t = Date.now();
  assert.equal((await arriving(t + 2000, () => call(env, "PUT", path, mine, body("newer")))).status, 200);
  assert.equal((await arriving(t + 1000, () => call(env, "PUT", path, mine, body("older")))).status, 409);
  assert.equal(JSON.parse(db.rows.get(token)!.alerts)[0].name, "newer");
  // A removal sent before the registration that's there isn't that registration's removal.
  assert.equal((await arriving(t + 1500, () => call(env, "DELETE", path, mine))).status, 200);
  assert.ok(db.rows.get(token));
  assert.equal((await arriving(t + 2500, () => call(env, "DELETE", path, mine))).status, 200);
  assert.equal(db.rows.size, 0);
});

test("every route is counted, everywhere at once, before anything is read or asked", async () => {
  const refuse = { DB: fakeDB(), APP_TOKEN: "app-token", STATUS_LIMITER: { limit: async () => ({ success: false }) } };
  for (const [method, path] of [["DELETE", `/v1/devices/${token}`], ["POST", `/v1/devices/${token}/test`], ["PUT", `/v1/devices/${token}`]]) {
    assert.equal((await call(refuse, method, path, mine, method === "PUT" ? { alerts: "nonsense" } : undefined)).status, 429, `${method} ${path}`);
  }
  // The edge limiter counts in each location; D1 holds the one count they share.
  const db = fakeDB();
  const env = { DB: db, APP_TOKEN: "app-token\nsecond-invite" };
  const statuses: number[] = [];
  for (let i = 0; i < REQUESTS_PER_MINUTE + 2; i++) statuses.push((await call(env, "DELETE", `/v1/devices/${token}`, mine)).status);
  assert.deepEqual([...new Set(statuses.slice(0, REQUESTS_PER_MINUTE))], [200]);
  assert.deepEqual(statuses.slice(REQUESTS_PER_MINUTE), [429, 429]);
  assert.equal((await call(env, "DELETE", `/v1/devices/${token}`, mine, undefined, "second-invite")).status, 200, "each invitation has its own count");
});

test("a body that isn't an object, a reserved alert id and a zone's other spellings", async () => {
  const db = fakeDB();
  const env = { DB: db, APP_TOKEN: "app-token" };
  const raw = (body: string) => worker.fetch(new Request("https://alerts.example.com/v1/status", { method: "POST", headers: { authorization: "Bearer app-token", "content-type": "application/json" }, body }),
    { STATUS_LIMITER: { limit: async () => ({ success: true }) }, ...env } as any, {} as ExecutionContext);
  for (const body of ["null", "[]", "7", '"text"']) assert.equal((await raw(body)).status, 400, body);
  for (const id of ["constructor", "__proto__", "toString"]) {
    const body = { ...contract(), environment: "sandbox" };
    body.alerts[0].id = id;
    assert.equal((await call(env, "PUT", `/v1/devices/${token}`, mine, body)).status, 400, id);
  }
  assert.equal((await call(env, "PUT", `/v1/devices/${token}`, mine, { ...contract(), environment: "sandbox", timeZone: "europe/LONDON" })).status, 200);
  assert.equal(db.rows.get(token)!.time_zone, "Europe/London");
});

test("a replaced invitation is the one the phone's registration keeps", async () => {
  const db = fakeDB();
  const body = { ...contract(), environment: "sandbox" };
  const path = `/v1/devices/${token}`;
  assert.equal((await call({ DB: db, APP_TOKEN: "first" }, "PUT", path, mine, body, "first")).status, 200);
  const before = db.rows.get(token)!.enrollment_hash;
  assert.equal((await call({ DB: db, APP_TOKEN: "second" }, "PUT", path, mine, body, "second")).status, 200);
  assert.notEqual(db.rows.get(token)!.enrollment_hash, before);
  assert.equal((await call({ DB: db, APP_TOKEN: "second" }, "PUT", `/v1/devices/${"ef".repeat(32)}`, theirs, body, "second")).status, 409, "so it can't admit a second phone");
});

test("a registration that finishes late can't take the place of the newer token's", async () => {
  const db = fakeDB();
  const env = { DB: db, APP_TOKEN: "app-token" };
  const body = { ...contract(), environment: "sandbox" };
  const old = `/v1/devices/${token}`, newer = "ef".repeat(32), t = Date.now();
  assert.equal((await arriving(t, () => call(env, "PUT", old, mine, body))).status, 200);
  // While an edit for the old token (sent at t + 1000) waits on TfL, the phone gets a new token:
  // it removes the old one and registers the new.
  assert.equal((await arriving(t + 2000, () => call(env, "DELETE", old, mine))).status, 200);
  assert.equal((await arriving(t + 3000, () => call(env, "PUT", `/v1/devices/${newer}`, mine, body))).status, 200);
  assert.equal((await arriving(t + 1000, () => call(env, "PUT", old, mine, body))).status, 409);
  assert.ok(db.rows.get(newer), "the newer registration stays");
  assert.equal(db.rows.size, 1);
  // The same when the phone never knew its old token to remove it (a reinstall), and the edit
  // for a third token sent before that finishes after.
  const third = "12".repeat(32);
  assert.equal((await arriving(t + 2500, () => call(env, "PUT", `/v1/devices/${third}`, mine, body))).status, 409);
  assert.ok(db.rows.get(newer));
  assert.equal(db.rows.size, 1);
});

test("a phone can't move to an invitation another phone holds, and is told so", async () => {
  const db = fakeDB();
  const env = { DB: db, APP_TOKEN: "first\nsecond" };
  const body = { ...contract(), environment: "sandbox" };
  const other = "ef".repeat(32);
  assert.equal((await call(env, "PUT", `/v1/devices/${token}`, mine, body, "first")).status, 200);
  assert.equal((await call(env, "PUT", `/v1/devices/${other}`, theirs, body, "second")).status, 200);
  const before = db.rows.get(token)!;
  // Answering 200 here would leave it on "first", to be removed with it when that's taken out.
  assert.equal((await call(env, "PUT", `/v1/devices/${token}`, mine, body, "second")).status, 409);
  assert.equal(db.rows.get(token)!.enrollment_hash, before.enrollment_hash);
  assert.equal(db.rows.get(token)!.revision, before.revision);
});

test("a reinstall keeps its place on a full server, and what the phone had been told", async () => {
  const db = fakeDB();
  const env = { DB: db, APP_TOKEN: "app-token", MAX_DEVICES: "1" };
  const body = { ...contract(), environment: "sandbox" };
  assert.equal((await call(env, "PUT", `/v1/devices/${token}`, mine, body)).status, 200);
  await db.prepare("UPDATE devices SET updated_at = updated_at - 60000, state = ?1").bind(JSON.stringify({ alerts: { kept: { live: {} } }, planned: {}, heard: 5, refused: { first: 1, last: 2, count: 3 } })).run();
  const next = "ef".repeat(32);
  assert.equal((await call({ ...env, MAX_DEVICES: "0" }, "PUT", `/v1/devices/${next}`, mine, body)).status, 200);
  assert.equal(db.rows.size, 1);
  assert.deepEqual(JSON.parse(db.rows.get(next)!.state), { alerts: { kept: { live: {} } }, planned: {}, heard: 5 }, "registering again forgets only APNs' refusals");
});

test("after moving to a new token and removing it, a registration sent earlier for the old token doesn't come back", async () => {
  const db = fakeDB();
  const env = { DB: db, APP_TOKEN: "app-token" };
  const body = { ...contract(), environment: "sandbox" };
  const newer = "ef".repeat(32), t = Date.now();
  assert.equal((await arriving(t, () => call(env, "PUT", `/v1/devices/${token}`, mine, body))).status, 200);
  assert.equal((await arriving(t + 2000, () => call(env, "PUT", `/v1/devices/${newer}`, mine, body))).status, 200, "moved to the new token");
  assert.equal((await arriving(t + 3000, () => call(env, "DELETE", `/v1/devices/${newer}`, mine))).status, 200);
  assert.equal((await arriving(t + 1000, () => call(env, "PUT", `/v1/devices/${token}`, mine, body))).status, 409);
  assert.equal(db.rows.size, 0);
  // A registration that crawled in for longer than removals are remembered is asked to come again.
  const clock = Date.now;
  let asked = 0;
  Date.now = () => (asked++ ? t + 20 * 60_000 : t + 10_000);
  try {
    assert.equal((await call(env, "PUT", `/v1/devices/${token}`, mine, body)).status, 409);
  } finally {
    Date.now = clock;
  }
  assert.equal(db.rows.size, 0);
});

test("a full minute's count is not written past; a new invitation's acceptance lifts the old one's notice", async () => {
  const db = fakeDB();
  const env = { DB: db, APP_TOKEN: "app-token" };
  for (let i = 0; i < REQUESTS_PER_MINUTE + 5; i++) await call(env, "DELETE", `/v1/devices/${token}`, mine);
  const counts = (await db.prepare("SELECT value FROM meta WHERE key >= 'rate:' AND key < 'rate;'").all()).results as { value: string }[];
  assert.ok(counts.length >= 1 && counts.every((row) => Number(row.value) <= REQUESTS_PER_MINUTE));

  const fresh = fakeDB();
  const body = { ...contract(), environment: "sandbox" };
  assert.equal((await call({ DB: fresh, APP_TOKEN: "first" }, "PUT", `/v1/devices/${token}`, mine, body, "first")).status, 200);
  await fresh.prepare("UPDATE devices SET updated_at = updated_at - 60000, state = ?1").bind(JSON.stringify({ alerts: {}, planned: {}, revoked: 1 })).run();
  assert.equal((await call({ DB: fresh, APP_TOKEN: "second" }, "PUT", `/v1/devices/${token}`, mine, body, "second")).status, 200);
  assert.equal(JSON.parse(fresh.rows.get(token)!.state).revoked, undefined);
});

test("an invitation's requests are counted by the day too, and what's past is cleared a minute at a time", async () => {
  const db = fakeDB();
  const env = { DB: db, APP_TOKEN: "app-token" };
  const t = Date.UTC(2026, 10, 9, 12, 0, 0), day = Math.floor(t / 86400_000);
  await db.prepare("INSERT INTO meta (key, value, updated_at) VALUES (?1, ?2, ?3)").bind(`rated:${"0".repeat(64)}:${day - 1}`, "7", day - 1).run();
  await db.prepare("INSERT INTO meta (key, value, updated_at) VALUES ('gone:old', '', ?1)").bind(t - 11 * 60_000).run();
  assert.equal((await arriving(t, () => call(env, "DELETE", `/v1/devices/${token}`, mine))).status, 200);
  const keys = ((await db.prepare("SELECT key FROM meta").all()).results as { key: string }[]).map((row) => row.key);
  assert.ok(!keys.includes("gone:old") && !keys.some((key) => key.endsWith(`:${day - 1}`)), keys.join());
  await db.prepare("UPDATE meta SET value = ?1 WHERE key >= 'rated:' AND key < 'rated;'").bind(String(REQUESTS_PER_DAY)).run();
  assert.equal((await arriving(t + 60_000, () => call(env, "DELETE", `/v1/devices/${token}`, mine))).status, 429);
  assert.equal((await arriving(t + 86400_000, () => call(env, "DELETE", `/v1/devices/${token}`, mine))).status, 200, "a new day");
});

test("a request refused for the day, or the minute, writes nothing", async () => {
  const db = fakeDB();
  const env = { DB: db, APP_TOKEN: "app-token" };
  const t = Date.UTC(2026, 10, 9, 12, 0, 0);
  assert.equal((await arriving(t, () => call(env, "DELETE", `/v1/devices/${token}`, mine))).status, 200);
  const snapshot = async () => JSON.stringify((await db.prepare("SELECT key, value FROM meta WHERE key >= 'rate' AND key < 'ratf' ORDER BY key").all()).results);
  await db.prepare("UPDATE meta SET value = '99999' WHERE key >= 'rated:all:' AND key < 'rated:all;'").run();
  const before = await snapshot();
  assert.equal((await arriving(t + 1000, () => call(env, "DELETE", `/v1/devices/${token}`, mine))).status, 429, "every invitation's requests together have a day's limit too");
  assert.equal(await snapshot(), before);
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
