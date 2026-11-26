import assert from "node:assert/strict";
import { test } from "node:test";
import { sign } from "../src/apns.ts";
import { clearPush, issuesPush, lineList, plannedPush, strikePush, strikeTestPush, strikeTimes, testPush } from "../src/push.ts";
import { clauses } from "../src/clauses.ts";
import type { StrikeBulletin } from "../src/strikes.ts";
import type { Issue } from "../src/types.ts";
import * as valid from "../src/validate.ts";
import { contract } from "./helpers.ts";

const now = Date.parse("2026-11-09T07:30:00Z");
const [commute, district] = contract().alerts;
const closed: Issue = { signature: "a", severity: "closed", line: "Elizabeth line", title: "Canary Wharf closed (Elizabeth line)", detail: "Closed - escalators." };
const minor: Issue = { signature: "b", severity: "minor", line: "Elizabeth line", title: "Elizabeth line: minor delays", detail: "Minor delays." };

test("a closure is Time Sensitive, comes from its line in a few words, and replaces the last one for this alert", () => {
  const push = issuesPush(commute, [closed, minor], now);
  const aps = (push.payload as any).aps;
  assert.equal(aps["interruption-level"], "time-sensitive");
  assert.deepEqual(aps.alert, { title: "Elizabeth line", body: "Canary Wharf closed\n+1 more on your route" });
  assert.equal(aps["mutable-content"], 1);
  assert.deepEqual((push.payload as any).sender, { id: "line:elizabeth", name: "Elizabeth line", color: "6950A1", symbol: "train.side.front.car" });
  assert.equal(push.collapseId, commute.id);
  assert.equal((push.payload as any).alert, commute.id);
});

test("a delay says the stretch TfL names, or else why", () => {
  const central = { ...commute, segments: [{ line: { id: "central", name: "Central line" }, mode: "tube", stations: [] }] };
  const issue = (detail: string): Issue => ({ signature: "c", severity: "delays", line: "Central line", title: "Central line: severe delays", detail });
  const alert = (detail: string) => (issuesPush(central, [issue(detail)], now).payload as any).aps.alert;
  assert.deepEqual(alert("Severe delays between Leytonstone and Hainault via Newbury Park due to a signal failure at Leytonstone. Tickets are being accepted on local buses."),
    { title: "Central line", body: "Severe delays\nLeytonstone → Hainault" });
  assert.deepEqual(alert("Severe delays due to an earlier faulty train at St. Paul's. Tickets are accepted on buses."), { title: "Central line", body: "Severe delays\nEarlier faulty train at St. Paul's" });
  assert.deepEqual(alert("Severe delays."), { title: "Central line", body: "Severe delays" });
  // A notice that names several stretches without saying which is yours names none of them; one
  // judged by its stretch says that one, with every place it could end.
  const two = "Minor delays between North Acton and Ealing Broadway / West Ruislip and between, Leytonstone and Epping / Hainault via Newbury Park due to a late finish of engineering works.";
  assert.equal(alert(two).body, "Severe delays\nLate finish of engineering works");
  const [, east] = clauses(two)[0].sections;
  assert.equal((issuesPush(central, [{ ...issue(two), section: east }], now).payload as any).aps.alert.body, "Severe delays\nLeytonstone → Epping / Hainault");
  assert.equal((issuesPush(central, [issue("Severe delays.")], now).payload as any).sender.symbol, "tram.fill");
  // A status the app asked for names its line in the title alone.
  assert.equal((issuesPush({ ...commute, segments: [...commute.segments, ...central.segments] }, [{ ...issue("Severe delays."), line: "" }], now).payload as any).sender.id, "line:central");
});

test("minor delays don't break through a Focus; good service again is quiet and ticked", () => {
  assert.equal((issuesPush(commute, [minor], now).payload as any).aps["interruption-level"], "active");
  const clear = clearPush(commute, now);
  assert.equal((clear.payload as any).aps["interruption-level"], "passive");
  assert.deepEqual((clear.payload as any).aps.alert, { title: "Elizabeth line", body: "Good service again" });
  assert.equal((clear.payload as any).sender.symbol, "checkmark");
  assert.equal(clear.collapseId, commute.id);
  // A route of several lines says which route is clear.
  const two = { ...commute, segments: [...commute.segments, { line: { id: "central", name: "Central line" }, mode: "tube", stations: [] }] };
  assert.equal((clearPush(two, now).payload as any).aps.alert.title, commute.name);
});

test("planned works say what, where and when", () => {
  const push = plannedPush(commute, [{ ...closed, title: "Elizabeth line: part closure", detail: "Sunday 15 November, until 1015, no service between Paddington and Abbey Wood." }], now);
  assert.deepEqual((push.payload as any).aps.alert, { title: "Elizabeth line", body: "Part closure tomorrow\nPaddington → Abbey Wood" });
  assert.equal(push.collapseId, `${commute.id}-planned`);
});

test("the test button shows what an alert will look like", () => {
  assert.deepEqual((testPush(commute, true, now).payload as any).aps.alert, { title: "Elizabeth line", body: "Test: alerts are on\nGood service now" });
  assert.equal((testPush(commute, false, now).payload as any).aps.alert.body, "Test: alerts are on");
  assert.equal((strikeTestPush(now).payload as any).alert, "london-strikes");
});

const strike = (extra: Partial<StrikeBulletin>): StrikeBulletin => ({ key: "k", active: false, title: "", detail: "As TfL said it.", expires: now + 3600_000, network: "Tube", mode: "tube", lines: [], ...extra });
const london = (text: string) => Date.parse(`${text}:00Z`);

test("a strike to come says its dates; several periods announced together are one line", () => {
  const thu = { from: london("2026-12-17T12:00"), to: london("2026-12-18T11:59") }, sat = { from: london("2026-12-19T12:00"), to: london("2026-12-20T11:59") };
  const alert = (...told: StrikeBulletin[]) => (strikePush(told, now).payload as any).aps.alert;
  assert.deepEqual(alert(strike(thu)), { title: "\u{1F4C5} Tube strike", body: "Thu 17 Dec · 12:00 · 24h" });
  assert.deepEqual(alert(strike(thu), strike(sat)), { title: "\u{1F4C5} Tube strike", body: "17 + 19 Dec · 12:00 · 24h each" });
  assert.equal(strikeTimes([{ from: london("2026-11-30T12:00"), to: london("2026-12-01T12:00") }, { from: london("2026-12-02T12:00"), to: london("2026-12-03T12:00") }]), "30 Nov + 2 Dec · 12:00 · 24h each");
  assert.equal(strikeTimes([{ from: london("2026-12-17T00:00"), to: london("2026-12-20T00:00") }]), "Thu 17 Dec · 00:00 · 3 days");
  // Periods that differ, or an odd length, are said in full; summer dates in London time.
  assert.equal(strikeTimes([thu, { from: london("2026-12-19T05:00"), to: london("2026-12-19T09:30") }]), "Thu 17 Dec 12:00 – Fri 18 Dec 11:59\nSat 19 Dec 05:00 – 09:30");
  assert.equal(strikeTimes([{ from: london("2026-07-08T08:00"), to: london("2026-07-09T08:00") }]), "Wed 8 Jul · 09:00 · 24h");
  // The day before, and on the day.
  assert.equal(alert(strike({ ...thu, reminder: true })).title, "\u{1F4C5} Tube strike");
  assert.equal((strikePush(strike({ ...thu, reminder: true }), london("2026-12-16T12:00")).payload as any).aps.alert.title, "\u{1F4C5} Tube strike tomorrow");
  assert.equal((strikePush(strike({ ...thu, reminder: true }), london("2026-12-17T08:00")).payload as any).aps.alert.title, "\u{1F4C5} Tube strike today");
  // A strike on some of a network says which: named up to three, counted past that.
  assert.equal(alert(strike({ ...thu, lines: ["Piccadilly"] })).body, "Thu 17 Dec · 12:00 · 24h\nPiccadilly");
  assert.equal(alert(strike({ ...thu, mode: "bus", network: "London buses", lines: ["Route 25", "Route 86", "Route 104"] })).body, "Thu 17 Dec · 12:00 · 24h\nRoute 25, Route 86, Route 104");
  assert.equal(alert(strike({ ...thu, mode: "bus", network: "London buses", lines: ["Route 25", "Route 86", "Route 104", "Route 238"] })).body, "Thu 17 Dec · 12:00 · 24h\n4 routes");
  assert.equal(alert(strike({ ...thu, mode: "dlr", network: "DLR", lines: ["DLR"] })).body, "Thu 17 Dec · 12:00 · 24h", "a network of one line doesn't say it twice");
  // A published bulletin that names no network keeps its own heading, and one without dates TfL's words.
  assert.deepEqual(alert(strike({ mode: undefined, network: "Metroline bus drivers’ strike" })), { title: "\u{1F4C5} Metroline bus drivers’ strike", body: "As TfL said it." });
});

test("a strike on now says how much is affected and which networks still run", () => {
  const lines = ["Bakerloo", "Central", "Circle", "District", "Hammersmith & City", "Jubilee", "Metropolitan", "Northern", "Piccadilly", "Victoria"];
  const push = strikePush(strike({ active: true, lines, running: ["Elizabeth", "DLR", "Overground"] }), now);
  const aps = (push.payload as any).aps;
  assert.deepEqual(aps.alert, { title: "⚠️ Strike now", body: "Tube · 10 lines affected\n✅ Elizabeth · DLR · Overground" });
  assert.equal(aps["interruption-level"], "time-sensitive");
  assert.equal(aps["thread-id"], "london-strikes");
  const body = (told: Partial<StrikeBulletin>) => (strikePush(strike({ active: true, ...told }), now).payload as any).aps.alert.body;
  assert.equal(body({ lines: ["Bakerloo"] }), "Tube · Bakerloo");
  assert.equal(body({}), "Tube");
  assert.equal(body({ mode: "bus", network: "London buses", lines: ["Route 25", "Route 86"] }), "London buses · Route 25, Route 86");
  assert.equal(body({ mode: "bus", network: "London buses", lines: ["Route 25", "Route 86", "Route 104", "Route 238"] }), "London buses · 4 routes affected");
  // A network of one line doesn't say it twice.
  assert.equal(body({ mode: "dlr", network: "DLR", lines: ["DLR"] }), "DLR");
  assert.equal(body({ mode: "elizabeth-line", network: "Elizabeth line", lines: ["Elizabeth line"] }), "Elizabeth line");
  assert.equal(body({ mode: "tram", network: "London Trams", lines: ["Tram"] }), "London Trams");
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
  const long = strike({ active: true, network: text, mode: undefined, lines: [text], running: [text, text] });
  for (const push of [issuesPush(alert, issues, now), clearPush(alert, now), plannedPush(alert, issues.slice(0, 1), now), testPush(alert, true, now), strikePush(long, now), strikePush({ ...long, active: false }, now)]) {
    const fields = (push.payload as any).aps.alert;
    assert.ok(Buffer.byteLength(JSON.stringify(push.payload), "utf8") <= 4096);
    assert.ok(fields.title.length <= 120 && fields.body.length <= 700);
    assert.ok([fields.title, fields.body, (push.payload as any).sender?.name ?? ""].every(field => field.isWellFormed()));
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
