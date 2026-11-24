import assert from "node:assert/strict";
import { test } from "node:test";
import { sign } from "../src/apns.ts";
import { clearPush, issuesPush, lineList, plannedPush } from "../src/push.ts";
import type { Issue } from "../src/types.ts";
import * as valid from "../src/validate.ts";
import { contract } from "./helpers.ts";

const now = Date.parse("2026-11-09T07:30:00Z");
const [commute, district] = contract().alerts;
const closed: Issue = { signature: "a", severity: "closed", line: "Elizabeth line", title: "Canary Wharf closed (Elizabeth line)", detail: "Closed - escalators." };
const minor: Issue = { signature: "b", severity: "minor", line: "Elizabeth line", title: "Elizabeth line: minor delays", detail: "Minor delays." };

test("a closure is Time Sensitive, says where, and replaces the last one for this alert", () => {
  const push = issuesPush(commute, [closed, minor], now);
  const aps = (push.payload as any).aps;
  assert.equal(aps["interruption-level"], "time-sensitive");
  assert.deepEqual(aps.alert, { title: "Liverpool Street → Canary Wharf", subtitle: closed.title, body: "Closed - escalators.\n\nAlso: Elizabeth line: minor delays." });
  assert.equal(push.collapseId, commute.id);
  assert.equal((push.payload as any).alert, commute.id);
});

test("minor delays don't break through a Focus; good service again is quiet", () => {
  assert.equal((issuesPush(commute, [minor], now).payload as any).aps["interruption-level"], "active");
  const clear = clearPush(commute, now);
  assert.equal((clear.payload as any).aps["interruption-level"], "passive");
  assert.equal((clear.payload as any).aps.alert.body, "Good service again on the Elizabeth line.");
  assert.equal(clear.collapseId, commute.id);
});

test("planned works say what and when", () => {
  const push = plannedPush(commute, [{ ...closed, title: "Elizabeth line: part closure", detail: "Sunday 15 November, until 1015, no service." }], now);
  assert.equal((push.payload as any).aps.alert.subtitle, "Planned: part closure tomorrow");
  assert.equal(push.collapseId, `${commute.id}-planned`);
});

test("every kind of alert fits Apple's byte limit with long Unicode notices", () => {
  const text = '🚇界"\\\u0001'.repeat(260);
  const alert = {
    ...commute,
    id: "a".repeat(64),
    name: text.slice(0, 120),
    segments: Array.from({ length: 8 }, (_, i) => ({
      ...commute.segments[0],
      line: { id: String(i), name: `${i}${"界".repeat(79)}` },
    })),
  };
  const issues = Array.from({ length: 20 }, () => ({ ...closed, title: text, detail: text }));
  for (const push of [issuesPush(alert, issues, now), clearPush(alert, now), plannedPush(alert, issues.slice(0, 1), now)]) {
    const fields = (push.payload as any).aps.alert;
    assert.ok(Buffer.byteLength(JSON.stringify(push.payload), "utf8") <= 4096);
    assert.ok(fields.title.length <= 120 && (fields.subtitle?.length ?? 0) <= 160 && fields.body.length <= 700);
    assert.ok([fields.title, fields.subtitle ?? "", fields.body].every(field => field.isWellFormed()));
  }
});

test("lines are said the way people say them", () => {
  assert.equal(lineList(district), "the District line");
  assert.equal(lineList({ ...commute, segments: [...commute.segments, { line: { id: "southeastern", name: "Southeastern" }, mode: "national-rail", stations: [] }] }),
    "the Elizabeth line and Southeastern");
});

test("the app's alerts pass validation unchanged", () => {
  const body = contract();
  // The second alert is as older builds send it, without a direction: both ways.
  assert.equal(body.alerts[1].direction, undefined);
  assert.deepEqual(valid.alerts(body.alerts), body.alerts.map((a: any) => ({ ...a, direction: a.direction ?? "both", segments: a.segments.map((s: any) => ({ from: undefined, to: undefined, ...s })) })));
  assert.equal(valid.alerts(body.alerts)[0].direction, "out");
  assert.equal(valid.alerts([{ ...commute, direction: "back" }])[0].direction, "back");
  assert.equal(valid.alerts([{ ...commute, direction: "sideways" }])[0].direction, "both", "a word from a newer build is both ways, not refused");
  // Each time's own way: kept; missing stays missing (the alert's); an unknown word is both ways.
  assert.deepEqual(body.alerts[0].windows.map((w: any) => w.direction), [undefined, "back"]);
  assert.ok(!("direction" in valid.alerts(body.alerts)[0].windows[0]), "missing isn't filled in");
  assert.equal(valid.alerts(body.alerts)[0].windows[1].direction, "back");
  const sideways = valid.alerts([{ ...commute, windows: [{ start: 420, end: 600, direction: "sideways" }] }])[0];
  assert.equal(sideways.windows[0].direction, "both");
  assert.equal(valid.environment(body.environment), "sandbox");
  assert.equal(valid.timeZone(body.timeZone), "Europe/London");
  assert.throws(() => valid.deviceToken("not-a-token"));
  assert.throws(() => valid.alerts([{ ...commute, segments: [{ ...commute.segments[0], mode: "bus" }] }]));
  assert.throws(() => valid.alerts([{ ...commute, windows: [{ start: 600, end: 600 }] }]));
});

test("the APNs token is a JWT Apple can verify", async () => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pkcs8 = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
  const pem = `-----BEGIN PRIVATE KEY-----\n${pkcs8.match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`;
  const jwt = await sign(pem, "KEY123", "TEAM456", now);
  const [header, claims, signature] = jwt.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(header, "base64url").toString()), { alg: "ES256", kid: "KEY123" });
  assert.deepEqual(JSON.parse(Buffer.from(claims, "base64url").toString()), { iss: "TEAM456", iat: now / 1000 });
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, Buffer.from(signature, "base64url"), new TextEncoder().encode(`${header}.${claims}`));
  assert.ok(ok);
});
