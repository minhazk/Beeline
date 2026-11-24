import assert from "node:assert/strict";
import { timingSafeEqual } from "node:crypto";
import { test } from "node:test";
import worker, { maxDevices } from "../src/index.ts";
import { contract, sqliteD1 } from "./helpers.ts";

// Workers have crypto.subtle.timingSafeEqual; Node keeps it in node:crypto.
(crypto.subtle as any).timingSafeEqual ??= (a: ArrayBuffer, b: ArrayBuffer) => timingSafeEqual(Buffer.from(a), Buffer.from(b));

const fakeDB = sqliteD1;

const token = "cd".repeat(32);
const mine = "a".repeat(40), theirs = "b".repeat(40);

function call(env: any, method: string, path: string, secret?: string, body?: unknown) {
  const headers: Record<string, string> = { authorization: "Bearer app-token", "content-type": "application/json" };
  if (secret) headers["x-device-secret"] = secret;
  return worker.fetch(new Request(`https://alerts.example.com${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined }), env, {} as ExecutionContext);
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
  const env = { DB: db, APP_TOKEN: "app-token", MAX_DEVICES: "1" };
  const body = { ...contract(), environment: "sandbox" };
  assert.equal((await call(env, "PUT", `/v1/devices/${token}`, mine, body)).status, 200);
  assert.equal((await call(env, "PUT", `/v1/devices/${"ef".repeat(32)}`, theirs, body)).status, 503);
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

test("health says whether pushes can go out, and nothing more", async () => {
  const health = async (env: object) => (await worker.fetch(new Request("https://alerts.example.com/health"), { DB: fakeDB(), ...env } as any, {} as ExecutionContext)).json();
  assert.deepEqual(await health({}), { ok: true, pushes: false });
  assert.deepEqual(await health({ APNS_KEY: "k", APNS_KEY_ID: "K", APNS_TEAM_ID: "T", APNS_TOPIC: "com.cloudslope.beeline" }), { ok: true, pushes: true });
});

test("MAX_DEVICES: unset is 100, 0 takes no new phones, nonsense is 100; a number from wrangler works", async () => {
  assert.equal(maxDevices({}), 100);
  assert.equal(maxDevices({ MAX_DEVICES: 50 as unknown as string }), 50, "an unquoted var arrives as a number");
  const numeric = { DB: fakeDB(), APP_TOKEN: "app-token", MAX_DEVICES: 1 };
  assert.equal((await call(numeric, "PUT", `/v1/devices/${token}`, mine, { ...contract(), environment: "sandbox" })).status, 200);
  assert.equal((await call(numeric, "PUT", `/v1/devices/${"ef".repeat(32)}`, theirs, { ...contract(), environment: "sandbox" })).status, 503);
  assert.equal(maxDevices({ MAX_DEVICES: "0" }), 0);
  assert.equal(maxDevices({ MAX_DEVICES: " 7 " }), 7);
  assert.equal(maxDevices({ MAX_DEVICES: "lots" }), 100);
  assert.equal(maxDevices({ MAX_DEVICES: "-1" }), 100);
  const env = { DB: fakeDB(), APP_TOKEN: "app-token", MAX_DEVICES: "0" };
  assert.equal((await call(env, "PUT", `/v1/devices/${token}`, mine, { ...contract(), environment: "sandbox" })).status, 503);
});
