import assert from "node:assert/strict";
import test from "node:test";
import { send, type ApnsEnv } from "../src/apns.ts";
import { sqliteD1 } from "./helpers.ts";

test("APNs requests reuse a token without keeping a usable bearer in the devices database", async (t) => {
  const db = sqliteD1();
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const key = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
  const env = { DB: db, APNS_KEY: key, APNS_KEY_ID: "TEST", APNS_TEAM_ID: "TEAM", APNS_TOPIC: "example" } as unknown as ApnsEnv;
  const authorizations: string[] = [];
  const collapseIDs: string[] = [];
  t.mock.method(globalThis, "fetch", async (_url: string, init: RequestInit) => {
    const headers = new Headers(init.headers);
    authorizations.push(headers.get("authorization")!);
    collapseIDs.push(headers.get("apns-collapse-id")!);
    return new Response(null, { status: 200 });
  });
  const push = { payload: { aps: { alert: "Test" } }, priority: 5 as const, collapseId: "x".repeat(64) + "-planned", expiration: 0 };
  await send(env, "ab".repeat(32), "sandbox", push, 1_000);
  await send(env, "ab".repeat(32), "sandbox", push, 2_000);
  const stored = await db.prepare("SELECT value FROM meta WHERE key = 'apns_jwt'").first() as { value: string };
  assert.equal(authorizations.length, 2);
  assert.equal(authorizations[0], authorizations[1]);
  assert.match(collapseIDs[0], /^[0-9a-f]{64}$/);
  assert.equal(collapseIDs[0], collapseIDs[1]);
  assert.match(stored.value, /^v1:/);
  assert.ok(!stored.value.includes(authorizations[0].slice("bearer ".length)));
});
