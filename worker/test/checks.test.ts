import assert from "node:assert/strict";
import { test } from "node:test";
import { runChecks, type Env } from "../src/checks.ts";
import { forgetLineMaps } from "../src/linemap.ts";
import { contract, fixture, sqliteD1 } from "./helpers.ts";

const token = "ab".repeat(32);

/** A quoted notice: severe delays near Heathrow and minor ones elsewhere, no stations listed. */
const NOTICE = [{ id: "elizabeth", name: "Elizabeth line", lineStatuses: [{ statusSeverity: 6, statusSeverityDescription: "Severe Delays", reason: "Elizabeth line: Severe delays between Paddington and Heathrow Terminals, and MINOR DELAYS between Hayes & Harlington and Reading, and between Whitechapel and Shenfield. GOOD SERVICE on the rest of the line.", validityPeriods: [], disruption: { category: "RealTime", affectedStops: [] } }] }];

/** What APNs says when it refuses, for the tests that need a particular reason. */
let apnsReason: string | undefined;
/** When Apple says it last found a token gone, with a 410. */
let apnsGoneAt: number | undefined;

async function setup(apnsStatus: number | ((n: number) => number) = 200, status: unknown = fixture("tfl-line-status-detail.json"), sequence: number | "fixture" | "hang" = "fixture", alerts: unknown[] = [contract().alerts[0]]) {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign"])) as CryptoKeyPair;
  const key = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
  const db = sqliteD1();
  db.rows.set(token, { environment: "sandbox", time_zone: "Europe/London", alerts: JSON.stringify(alerts), state: JSON.stringify({ alerts: {}, planned: {} }) });
  const env = { DB: db, APNS_KEY: key, APNS_KEY_ID: "KEY123", APNS_TEAM_ID: "TEAM123456", APNS_TOPIC: "com.cloudslope.beeline" } as unknown as Env;
  const requests: { url: string; init?: RequestInit }[] = [];
  let pushCount = 0; // pushes asked of APNs so far, however often a test clears `requests`
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    requests.push({ url, init });
    if (url.includes("push.apple.com")) {
      const code = typeof apnsStatus === "function" ? apnsStatus(++pushCount) : apnsStatus;
      const reason = apnsReason ?? ({ 410: "Unregistered", 400: "BadTopic", 429: "TooManyRequests", 503: "ServiceUnavailable" } as Record<number, string>)[code] ?? "InternalServerError";
      return new Response(code === 200 ? "" : JSON.stringify({ reason, ...(code === 410 && apnsGoneAt !== undefined ? { timestamp: apnsGoneAt } : {}) }), { status: code });
    }
    if (url.includes("/Line/Mode/")) return Response.json(fixture("tfl-lines.json"));
    if (url.includes("/StopPoint/")) return Response.json(typeof status === "function" ? stopsNow : status === NOTICE ? [] : fixture("tfl-station-disruptions.json"));
    if (url.includes("/to/")) return Response.json(fixture("tfl-line-status-week.json"));
    if (url.includes("/Route/Sequence/")) {
      if (sequence === "hang") return new Promise<Response>((_, reject) => init?.signal?.addEventListener("abort", () => reject(new Error("aborted"))));
      return sequence === "fixture" ? Response.json(fixture("tfl-sequence-elizabeth.json")) : new Response("", { status: sequence });
    }
    if (url.includes("/Line/")) return Response.json(typeof status === "function" ? status() : status);
    throw new Error(`unexpected fetch ${url}`);
  }) as typeof fetch;
  return { env, db, requests };
}

test("nobody travelling: nothing asked of TfL", async () => {
  const { env, requests } = await setup();
  const result = await runChecks(env, Date.parse("2026-11-09T11:15:00Z"));
  assert.deepEqual(result, { devices: 1, checked: 0, sent: 0 });
  assert.equal(requests.length, 0);
});

test("in the evening window: today's closure is pushed once, Time Sensitive", async () => {
  const { env, db, requests } = await setup();
  const evening = Date.parse("2026-11-09T17:00:00Z");
  assert.deepEqual(await runChecks(env, evening), { devices: 1, checked: 1, sent: 1 });
  assert.ok(requests.some((r) => r.url === "https://api.tfl.gov.uk/Line/elizabeth/Status?detail=true"));
  const push = requests.find((r) => r.url.includes("push.apple.com"))!;
  assert.equal(push.url, `https://api.sandbox.push.apple.com/3/device/${"ab".repeat(32)}`);
  const headers = push.init!.headers as Record<string, string>;
  assert.equal(headers["apns-topic"], "com.cloudslope.beeline");
  assert.equal(headers["apns-collapse-id"], contract().alerts[0].id);
  assert.match(headers.authorization, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  const payload = JSON.parse(push.init!.body as string);
  assert.equal(payload.aps["interruption-level"], "time-sensitive");
  assert.equal(payload.aps.alert.subtitle, "Canary Wharf closed (Elizabeth line)");
  assert.ok(JSON.parse(db.rows.get(token)!.state).alerts[contract().alerts[0].id].open);

  // Two minutes later, same closure: quiet. The provider token is reused.
  requests.length = 0;
  assert.deepEqual(await runChecks(env, evening + 2 * 60_000), { devices: 1, checked: 1, sent: 0 });
  assert.ok(!requests.some((r) => r.url.includes("push.apple.com")));
});

test("after 7 pm: tomorrow's planned works are checked once", async () => {
  const { env, db, requests } = await setup();
  const at = Date.parse("2026-11-09T19:05:00Z");
  await runChecks(env, at);
  assert.ok(requests.some((r) => r.url.includes("/Status/2026-11-10T07:00:00/to/2026-11-10T20:00:00?detail=true")), requests.map((r) => r.url).join("\n"));
  assert.equal(JSON.parse(db.rows.get(token)!.state).plannedOn, "2026-11-09");
  requests.length = 0;
  await runChecks(env, at + 2 * 60_000);
  assert.ok(!requests.some((r) => r.url.includes("/to/")), "not twice in an evening");
});

test("a phone Apple says is gone is forgotten", async () => {
  const { env, db } = await setup(410);
  await runChecks(env, Date.parse("2026-11-09T17:00:00Z"));
  assert.equal(db.rows.size, 0);
});

test("an edit during the TfL lookup stops delivery from the obsolete registration", async () => {
  const { env, db, requests } = await setup();
  const recorded = globalThis.fetch;
  globalThis.fetch = async (input, init) => {
    if (String(input).includes("/Line/")) {
      await db.prepare("UPDATE devices SET revision = 'edited', alerts = '[]' WHERE token = ?1").bind(token).run();
    }
    return recorded(input, init);
  };
  await runChecks(env, Date.parse("2026-11-09T17:00:00Z"));
  assert.equal(requests.filter(r => r.url.includes("push.apple.com")).length, 0);
  assert.equal(db.rows.get(token)!.revision, "edited");
});

for (const response of [200, 410]) {
  test(`a registration refreshed during APNs response ${response} retains its own state`, async () => {
    const { env, db } = await setup(response);
    const recorded = globalThis.fetch;
    globalThis.fetch = async (input, init) => {
      if (String(input).includes("push.apple.com")) {
        await db.prepare("UPDATE devices SET revision = 'refreshed', state = ?1 WHERE token = ?2")
          .bind('{"alerts":{},"planned":{}}', token).run();
      }
      return recorded(input, init);
    };
    await runChecks(env, Date.parse("2026-11-09T17:00:00Z"));
    assert.equal(db.rows.get(token)!.revision, "refreshed");
    assert.deepEqual(JSON.parse(db.rows.get(token)!.state), { alerts: {}, planned: {} });
  });
}

test("trouble TfL places elsewhere on the line: the line's order is fetched, and nothing is pushed", async () => {
  forgetLineMaps();
  const { env, requests } = await setup(200, NOTICE);
  assert.deepEqual(await runChecks(env, Date.parse("2026-11-09T17:00:00Z")), { devices: 1, checked: 1, sent: 0 });
  assert.deepEqual(requests.filter((r) => r.url.includes("/Route/")).map((r) => r.url), ["https://api.tfl.gov.uk/Line/elizabeth/Route/Sequence/all"]);
  // Two minutes later it's still held: not asked again.
  requests.length = 0;
  await runChecks(env, Date.parse("2026-11-09T17:02:00Z"));
  assert.ok(!requests.some((r) => r.url.includes("/Route/")));
});

test("no line order from TfL: told, as before", async () => {
  forgetLineMaps();
  const { env, requests } = await setup(200, NOTICE, 500);
  assert.deepEqual(await runChecks(env, Date.parse("2026-11-09T17:00:00Z")), { devices: 1, checked: 1, sent: 1 });
  const payload = JSON.parse(requests.find((r) => r.url.includes("push.apple.com"))!.init!.body as string);
  assert.equal(payload.aps.alert.subtitle, "Elizabeth line: severe delays");
});

test("good service, or stations listed: no line order asked for", async () => {
  forgetLineMaps();
  const { env, requests } = await setup();
  await runChecks(env, Date.parse("2026-11-09T17:00:00Z"));
  assert.ok(!requests.some((r) => r.url.includes("/Route/")));
});

test("after TfL fails to give a line's order, it isn't asked again for ten minutes", async () => {
  forgetLineMaps();
  const { env, requests } = await setup(200, NOTICE, 500);
  const at = Date.parse("2026-11-09T17:00:00Z");
  const asked = () => requests.filter((r) => r.url.includes("/Route/")).length;
  await runChecks(env, at);
  assert.equal(asked(), 1);
  await runChecks(env, at + 2 * 60_000);
  await runChecks(env, at + 8 * 60_000);
  assert.equal(asked(), 1, "not within ten minutes");
  await runChecks(env, at + 11 * 60_000);
  assert.equal(asked(), 2, "asked again after ten");
});

test("a TfL that hangs on the line's order holds the pushes up a few seconds, then tells", async () => {
  forgetLineMaps();
  const { env } = await setup(200, NOTICE, "hang");
  const started = Date.now();
  assert.deepEqual(await runChecks(env, Date.parse("2026-11-09T17:00:00Z")), { devices: 1, checked: 1, sent: 1 });
  assert.ok(Date.now() - started < 6000, `${Date.now() - started} ms`);
});

// Times of day with their own way: Liverpool Street → Canary Wharf (eastbound) until 10:00,
// back to Liverpool Street (westbound) 10:00–12:00, in one alert with no way of its own.
const slotted = { ...contract().alerts[0], direction: undefined, windows: [{ start: 420, end: 600, direction: "out" }, { start: 600, end: 720, direction: "back" }] };
const status = (reason: string, stops: string[] = []) => ({ statusSeverity: 6, statusSeverityDescription: "Severe Delays", reason, validityPeriods: [], disruption: { category: "RealTime", affectedStops: stops.map((id) => ({ stationNaptan: id })) } });
const said = (reason: string, stops: string[] = []) => [{ id: "elizabeth", name: "Elizabeth line", lineStatuses: [status(reason, stops)] }];
/** Station notices at this check, in the slot tests. */
let stopsNow: unknown[] = [];
const partClosed = (description: string) => [{ type: "Part Closure", stationAtcoCode: "910GCANWHRF", commonName: "Canary Wharf", mode: "elizabeth-line", description, appearance: "RealTime" }];
// With the stations listed, only the one-way word needs the line's order.
const WEST_LISTED = said("Severe delays westbound.", ["910GLIVST", "910GWCHAPXR", "910GCANWHRF"]);
const EAST = said("Severe delays eastbound between Liverpool Street and Abbey Wood.");
const WEST = said("Severe delays westbound between Abbey Wood and Liverpool Street.");
const BOTH = said("Severe delays between Liverpool Street and Abbey Wood.");
const GOOD = [{ id: "elizabeth", name: "Elizabeth line", lineStatuses: [{ statusSeverity: 10, statusSeverityDescription: "Good Service", reason: "", validityPeriods: [] }] }];
const at = (hhmm: string) => Date.parse(`2026-11-09T${hhmm}:00Z`); // a Monday, GMT

/** Each check in turn, with what TfL says then (lines, and station notices); what was pushed at each. */
async function run(steps: ([string, unknown] | [string, unknown, unknown[]])[], alerts: unknown[] = [slotted]) {
  forgetLineMaps();
  let now: unknown = GOOD;
  const { env, requests } = await setup(200, () => now, "fixture", alerts);
  const out: string[] = [];
  for (const [time, status, stops] of steps) {
    now = status;
    stopsNow = stops ?? [];
    const before = requests.filter((r) => r.url.includes("push.apple.com")).length;
    await runChecks(env, time.includes("T") ? Date.parse(`${time}:00Z`) : at(time));
    const pushed = requests.filter((r) => r.url.includes("push.apple.com")).slice(before);
    out.push(pushed.map((r) => (JSON.parse(r.init!.body as string).aps.alert.subtitle ? "issues" : "clear")).join(",") || "-");
  }
  return { out, requests };
}

test("a time's own way: one-way trouble the other way is not pushed, and pushed when that way's time starts", async () => {
  assert.deepEqual((await run([["09:50", WEST], ["10:00", WEST]])).out, ["-", "issues"]);
  // The alert has no way of its own, only its times: the line's order must still be fetched.
  const { out, requests } = await run([["09:50", WEST_LISTED], ["10:00", WEST_LISTED]]);
  assert.deepEqual(out, ["-", "issues"]);
  assert.ok(requests.some((r) => r.url.includes("/Route/Sequence/")));
});

test("across times with different ways: both-ways trouble is pushed once", async () => {
  assert.deepEqual((await run([["09:50", BOTH], ["10:00", BOTH], ["10:06", BOTH], ["10:30", BOTH]])).out, ["issues", "-", "-", "-"]);
});

test("across times: one-way trouble told going out is not 'good service again' coming back", async () => {
  const { out } = await run([["09:50", EAST], ["10:00", EAST], ["10:06", EAST], ["10:12", EAST], ["10:20", GOOD], ["10:26", GOOD]]);
  assert.deepEqual(out, ["issues", "-", "-", "-", "-", "clear"], "cleared only when it has gone");
});

test("across times: one-way trouble told going out, spreading to both ways coming back, is pushed", async () => {
  assert.deepEqual((await run([["09:50", EAST], ["10:00", EAST], ["10:04", BOTH]])).out, ["issues", "-", "issues"]);
});

test("older builds: an alert with no ways at all is pushed for one-way trouble either way, as before", async () => {
  forgetLineMaps();
  const plain = { ...slotted, windows: [{ start: 420, end: 600 }, { start: 600, end: 720 }] };
  const { env } = await setup(200, () => EAST, "fixture", [plain]);
  assert.equal((await runChecks(env, at("09:30"))).sent, 1);
});

test("across days: weeks-long one-way station works told going out aren't told again every morning", async () => {
  const works = partClosed("Canary Wharf: eastbound trains will not stop here while the platform is rebuilt.");
  const { out } = await run([["2026-11-09T09:50", GOOD, works], ["2026-11-09T10:00", GOOD, works], ["2026-11-09T11:00", GOOD, works], ["2026-11-10T07:30", GOOD, works], ["2026-11-10T10:30", GOOD, works]]);
  assert.deepEqual(out, ["issues", "-", "-", "-", "-"]);
});

test("an alert going one way: trouble the other way it was never told about doesn't hold back 'good service again'", async () => {
  const out_ = { ...slotted, direction: "out", windows: [{ start: 420, end: 720 }] };
  const both = [{ id: "elizabeth", name: "Elizabeth line", lineStatuses: [status("Severe delays between Liverpool Street and Abbey Wood."), status("Severe delays westbound.", ["910GLIVST", "910GWCHAPXR", "910GCANWHRF"])] }];
  const { out } = await run([["09:00", both], ["09:10", WEST_LISTED], ["09:16", WEST_LISTED]], [out_]);
  assert.deepEqual(out, ["issues", "-", "clear"]);
});

// Review of PR #12.
const EAST_TO_BOTH_SAME = said("Severe delays between Liverpool Street and Abbey Wood.");
const WEST_SAME_ORDER = said("Severe delays westbound between Liverpool Street and Abbey Wood.");

test("review 1: trouble that spreads to both ways while you still ride out is told when the back time starts", async () => {
  const { out } = await run([["09:00", EAST], ["09:56", EAST_TO_BOTH_SAME], ["10:00", EAST_TO_BOTH_SAME]]);
  assert.deepEqual(out, ["issues", "-", "issues"]);
});

test("review 2: overlapping times (both ways): one-way trouble told going out that spreads is told", async () => {
  const overlap = { ...slotted, windows: [{ start: 420, end: 540, direction: "out" }, { start: 510, end: 600, direction: "back" }] };
  const { out } = await run([["08:00", EAST], ["08:30", EAST_TO_BOTH_SAME]], [overlap]);
  assert.deepEqual(out, ["issues", "issues"]);
  // Still one way only during the overlap: already told, no repeat.
  assert.deepEqual((await run([["08:00", EAST], ["08:30", EAST]], [overlap])).out, ["issues", "-"]);
});

test("review 3: an alert going one way at all its times: trouble told that narrows to the other way clears as before", async () => {
  const outOnly = { ...slotted, direction: "out", windows: [{ start: 420, end: 720 }] };
  const { out } = await run([["09:00", EAST_TO_BOTH_SAME], ["09:10", WEST_SAME_ORDER], ["09:16", WEST_SAME_ORDER]], [outOnly]);
  assert.deepEqual(out, ["issues", "-", "clear"]);
});

test("review 5: memory from before ways counts as told the alert's own way, so a back time added later is told", async () => {
  forgetLineMaps();
  let now: unknown = EAST;
  stopsNow = [];
  const outOnly = { ...slotted, direction: "out", windows: [{ start: 420, end: 600 }] };
  const { env, db, requests } = await setup(200, () => now, "fixture", [outOnly]);
  await runChecks(env, at("09:00"));
  assert.equal(requests.filter((r) => r.url.includes("push.apple.com")).length, 1);
  // As stored before this change: no ways. Then the phone adds a back time.
  const state = JSON.parse(db.rows.get(token)!.state);
  for (const entry of Object.values(state.alerts[outOnly.id].live) as any[]) delete entry.ways;
  await db.prepare("UPDATE devices SET state = ?1 WHERE token = ?2").bind(JSON.stringify(state), token).run();
  await db.prepare("UPDATE devices SET alerts = ?1 WHERE token = ?2")
    .bind(JSON.stringify([{ ...outOnly, windows: [{ start: 420, end: 600 }, { start: 600, end: 720, direction: "back" }] }]), token).run();
  now = EAST_TO_BOTH_SAME;
  await runChecks(env, at("10:00"));
  assert.equal(requests.filter((r) => r.url.includes("push.apple.com")).length, 2, "told on the way back");
});

test("review 5: memory from before ways causes no repeat push at the deploy for alerts as they are stored", async () => {
  forgetLineMaps();
  let now: unknown = EAST;
  stopsNow = [];
  const outOnly = { ...slotted, direction: "out", windows: [{ start: 420, end: 720 }] };
  const { env, db, requests } = await setup(200, () => now, "fixture", [outOnly]);
  await runChecks(env, at("09:00"));
  const state = JSON.parse(db.rows.get(token)!.state);
  for (const entry of Object.values(state.alerts[outOnly.id].live) as any[]) delete entry.ways;
  await db.prepare("UPDATE devices SET state = ?1 WHERE token = ?2").bind(JSON.stringify(state), token).run();
  now = EAST_TO_BOTH_SAME;
  await runChecks(env, at("09:04"));
  assert.equal(requests.filter((r) => r.url.includes("push.apple.com")).length, 1);
});

test("pushes not configured: nothing judged, so nothing is marked told", async () => {
  const { env, db, requests } = await setup();
  const before = db.rows.get(token)!.state;
  delete (env as any).APNS_TOPIC;
  assert.deepEqual(await runChecks(env, Date.parse("2026-11-09T17:00:00Z")), { devices: 1, checked: 0, sent: 0 });
  assert.equal(requests.length, 0, "not even TfL is asked");
  assert.equal(db.rows.get(token)!.state, before);
});

// Two alerts riding the same closure, each its own push.
const twin = { ...contract().alerts[0], id: "TWIN-ALERT-0001", name: "Twin" };
const pushesTo = (requests: { url: string; init?: RequestInit }[]) =>
  requests.filter((r) => r.url.includes("push.apple.com")).map((r) => (r.init!.headers as Record<string, string>)["apns-collapse-id"]);

test("one push sent, the other refused for a passing reason: only the refused one is tried again", async () => {
  const { env, requests } = await setup((n) => (n === 2 ? 503 : 200), undefined, "fixture", [contract().alerts[0], twin]);
  const evening = Date.parse("2026-11-09T17:00:00Z");
  await runChecks(env, evening);
  assert.deepEqual(pushesTo(requests), [contract().alerts[0].id, twin.id]);
  requests.length = 0;
  await runChecks(env, evening + 120_000);
  assert.deepEqual(pushesTo(requests), [twin.id], "the sent one isn't sent again");
  requests.length = 0;
  await runChecks(env, evening + 240_000);
  assert.deepEqual(pushesTo(requests), [], "and once through, neither");
});

test("a passing failure is tried a bounded number of times", async () => {
  const { env, requests } = await setup(503);
  const evening = Date.parse("2026-11-09T17:00:00Z");
  for (let i = 0; i < 6; i++) await runChecks(env, evening + i * 120_000);
  assert.equal(pushesTo(requests).length, 3);
});

test("a bad APNs topic keeps the phone and the unsent notification for a corrected configuration", async () => {
  const { env, db, requests } = await setup((attempt) => attempt === 1 ? 400 : 200);
  const evening = Date.parse("2026-11-09T17:00:00Z");
  await runChecks(env, evening);
  await runChecks(env, evening + 120_000);
  assert.equal(pushesTo(requests).length, 2);
  assert.ok(JSON.parse(db.rows.get(token)!.state).alerts[contract().alerts[0].id].open, "recorded after delivery");
});

test("planned works: a passing failure leaves the evening open for that alert only", async () => {
  // Mornings only, so at 19:05 the one push is tomorrow's planned works.
  const mornings = { ...contract().alerts[0], windows: [{ start: 420, end: 600 }] };
  const { env, db, requests } = await setup((n) => (n === 1 ? 503 : 200), undefined, "fixture", [mornings]);
  // Tomorrow morning, the whole line closed for engineering works.
  const works = [{ id: "elizabeth", name: "Elizabeth line", lineStatuses: [{ statusSeverity: 4, statusSeverityDescription: "Planned Closure",
    reason: "Elizabeth line: no service on Tuesday morning due to engineering works.", disruption: { category: "PlannedWork", affectedStops: [] },
    validityPeriods: [{ fromDate: "2026-11-10T05:00:00Z", toDate: "2026-11-10T12:00:00Z" }] }] }];
  const recorded = globalThis.fetch;
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) =>
    String(input).includes("/to/") ? (requests.push({ url: String(input), init }), Response.json(works)) : recorded(input, init)) as typeof fetch;
  const at7 = Date.parse("2026-11-09T19:05:00Z");
  await runChecks(env, at7);
  assert.equal(pushesTo(requests).length, 1, "the recorded week has planned works for tomorrow");
  assert.equal(JSON.parse(db.rows.get(token)!.state).plannedOn, undefined, "not settled while a push is owed");
  requests.length = 0;
  await runChecks(env, at7 + 120_000);
  assert.equal(pushesTo(requests).length, 1, "the owed one, once");
  assert.equal(JSON.parse(db.rows.get(token)!.state).plannedOn, "2026-11-09");
  requests.length = 0;
  await runChecks(env, at7 + 240_000);
  assert.equal(pushesTo(requests).length, 0);
});

test("with pushes going through, 'good service again' still comes", async () => {
  const { out } = await run([["17:00", BOTH], ["17:02", GOOD], ["17:04", GOOD], ["17:06", GOOD], ["17:08", GOOD]], [contract().alerts[0]]);
  assert.deepEqual(out, ["issues", "-", "-", "clear", "-"]);
});

test("an all-digit team ID given as a number still signs as text", async () => {
  const { env, requests } = await setup();
  (env as any).APNS_TEAM_ID = 1234567890;
  assert.equal((await runChecks(env, Date.parse("2026-11-09T17:00:00Z"))).sent, 1);
  const jwt = (requests.find((r) => r.url.includes("push.apple.com"))!.init!.headers as Record<string, string>).authorization.split(" ")[1];
  assert.equal(JSON.parse(Buffer.from(jwt.split(".")[1], "base64url").toString()).iss, "1234567890");
});

test("an incomplete TfL batch preserves the missing line's memory and leaves other modes running", async () => {
  const [elizabeth, district] = contract().alerts;
  const second = { ...district, days: elizabeth.days, windows: elizabeth.windows };
  const { env, db, requests } = await setup(200, fixture("tfl-line-status-detail.json"), "fixture", [elizabeth, second]);
  const stored = { alerts: { [second.id]: { open: true, live: {}, goodSince: 1234 } }, planned: {} };
  await db.prepare("UPDATE devices SET state = ? WHERE token = ?").bind(JSON.stringify(stored), token).run();
  const mockFetch = globalThis.fetch;
  globalThis.fetch = async (input, init) => {
    const url = String(input);
    if (url.includes("/Status?") && url.includes("district")) return Response.json([]);
    return mockFetch(input, init);
  };
  const result = await runChecks(env, Date.parse("2026-11-09T17:00:00Z"));
  assert.equal(result.checked, 1);
  assert.ok(requests.some((r) => r.url.includes("push.apple.com")));
  assert.deepEqual(JSON.parse(String(db.rows.get(token)!.state)).alerts[second.id], stored.alerts[second.id]);
});

test("a push token APNs says isn't this app's is asked ever less often, then forgotten once pushes are known to work", async () => {
  forgetLineMaps();
  // A notice with no end, so there is something to tell at every check.
  const { env, db, requests } = await setup(400, NOTICE, 500);
  apnsReason = "BadDeviceToken";
  try {
    const pushes = () => requests.filter((r) => r.url.includes("push.apple.com")).length;
    const at = Date.parse("2026-11-09T17:00:00Z");
    await runChecks(env, at);
    assert.equal(pushes(), 1);
    assert.equal(JSON.parse(db.rows.get(token)!.state).refused.count, 1);
    assert.equal(JSON.parse(db.rows.get(token)!.state).alerts[contract().alerts[0].id], undefined, "the notice stays pending");
    await runChecks(env, at + 2 * 60_000);
    await runChecks(env, at + 28 * 60_000);
    assert.equal(pushes(), 1, "not asked again inside half an hour");
    await runChecks(env, at + 31 * 60_000);
    assert.equal(pushes(), 2);
    assert.equal(JSON.parse(db.rows.get(token)!.state).refused.count, 2);
    await runChecks(env, at + 62 * 60_000);
    assert.equal(pushes(), 2, "then an hour");
    await runChecks(env, at + 92 * 60_000);
    assert.equal(pushes(), 3);

    // A day on, refused again: kept while nothing shows the server's own push setup works.
    const nextDay = Date.parse("2026-11-10T17:30:00Z");
    await runChecks(env, nextDay);
    assert.equal(db.rows.size, 1);
    assert.equal(JSON.parse(db.rows.get(token)!.state).refused.count, 4);
    // Once a push has gone out to someone since then, a fresh refusal is the token's fault.
    await db.prepare("INSERT INTO meta (key, value, updated_at) VALUES ('apns_ok:sandbox', '', ?1)").bind(nextDay + 3_600_000).run();
    await runChecks(env, Date.parse("2026-11-11T17:30:00Z"));
    assert.equal(db.rows.size, 0);
  } finally {
    apnsReason = undefined;
  }
});

test("a registration again clears APNs' refusals; a delivered push notes that pushes work", async () => {
  const { env, db } = await setup();
  await runChecks(env, Date.parse("2026-11-09T17:00:00Z"));
  const noted = await db.prepare("SELECT updated_at FROM meta WHERE key = 'apns_ok:sandbox'").first() as { updated_at: number };
  assert.equal(noted.updated_at, Date.parse("2026-11-09T17:00:00Z"));
  assert.equal(JSON.parse(db.rows.get(token)!.state).heard, Date.parse("2026-11-09T17:00:00Z"));
});

test("one unreadable row, or one phone's failed write, doesn't stop the others", async () => {
  const { env, db, requests } = await setup();
  db.rows.set("ef".repeat(32), { environment: "sandbox", time_zone: "Europe/London", alerts: "{not json", state: "{}" });
  db.rows.set("12".repeat(32), { environment: "sandbox", time_zone: "Nowhere/Land", alerts: JSON.stringify([contract().alerts[0]]), state: "{}" });
  assert.deepEqual(await runChecks(env, Date.parse("2026-11-09T17:00:00Z")), { devices: 1, checked: 1, sent: 1 });
  assert.equal(requests.filter((r) => r.url.includes("push.apple.com")).length, 1);
});

test("a phone whose invitation was taken out of APP_TOKEN is removed; phones from before invitations stay", async () => {
  const { env, db } = await setup();
  const hash = async (invite: string) => Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(invite))).toString("hex");
  const revoked = "ef".repeat(32), current = "12".repeat(32);
  for (const [device, invite] of [[revoked, "old-invite"], [current, "new-invite"]]) {
    db.rows.set(device, { environment: "sandbox", time_zone: "Europe/London", alerts: JSON.stringify([contract().alerts[0]]), state: "{}" });
    await db.prepare("UPDATE devices SET enrollment_hash = ?1 WHERE token = ?2").bind(await hash(invite), device).run();
  }
  const quiet = Date.parse("2026-11-09T11:15:00Z"), hour = 3_600_000;
  // A secret set with a line left out looks the same as a revocation: a day to put it right.
  const without = { ...env, APP_TOKEN: "new-invite\nanother" } as Env;
  await runChecks(without, quiet);
  await runChecks(without, quiet + 23 * hour);
  assert.equal(db.rows.size, 3);
  assert.equal(JSON.parse(db.rows.get(revoked)!.state).revoked, quiet);
  await runChecks({ ...env, APP_TOKEN: "new-invite\nold-invite" } as Env, quiet + 23 * hour);
  assert.equal(JSON.parse(db.rows.get(revoked)!.state).revoked, undefined, "put back: the day starts over");
  await runChecks(without, quiet + 30 * hour);
  await runChecks(without, quiet + 53 * hour);
  assert.ok(db.rows.get(revoked), "a day from when it was last taken out");
  await runChecks(without, quiet + 54 * hour);
  assert.equal(db.rows.get(revoked), undefined);
  assert.ok(db.rows.get(current));
  assert.ok(db.rows.get(token), "no invitation kept: from before them");
});

test("a phone not heard from in a month is asked after silently, and forgotten when Apple says it's gone", async () => {
  const now = Date.parse("2026-11-09T11:15:00Z");
  const { env, db, requests } = await setup(200);
  await db.prepare("UPDATE devices SET updated_at = ?1 WHERE token = ?2").bind(now - 31 * 86400_000, token).run();
  await runChecks(env, now);
  const probe = requests.find((r) => r.url.includes("push.apple.com"))!;
  assert.equal((probe.init!.headers as Record<string, string>)["apns-push-type"], "background");
  assert.deepEqual(JSON.parse(probe.init!.body as string), { aps: { "content-available": 1 } });
  assert.equal(JSON.parse(db.rows.get(token)!.state).heard, now);
  requests.length = 0;
  await runChecks(env, now + 2 * 60_000);
  assert.equal(requests.length, 0, "heard: not asked again for a month");

  const gone = await setup(410);
  await gone.db.prepare("UPDATE devices SET updated_at = ?1 WHERE token = ?2").bind(now - 31 * 86400_000, token).run();
  await runChecks(gone.env, now);
  assert.equal(gone.db.rows.size, 0);
});

test("an alert id every object answers to is no alert: the phone's others are still checked", async () => {
  const { env } = await setup(200, undefined, "fixture", [{ ...contract().alerts[0], id: "constructor" }, contract().alerts[0]]);
  assert.deepEqual(await runChecks(env, Date.parse("2026-11-09T17:00:00Z")), { devices: 1, checked: 1, sent: 1 });
});

test("recorded answers are only ever this machine's, and never get TfL's key; a shape TfL never sent is a line left unknown", async () => {
  const { useLocalTfL, fetchTfL, parseLineStatuses, parseStationDisruptions } = await import("../src/tfl.ts");
  const asked: string[] = [];
  const upstream = globalThis.fetch;
  globalThis.fetch = (async (input: RequestInfo | URL) => { asked.push(String(input)); return Response.json([]); }) as typeof fetch;
  try {
    useLocalTfL("https://elsewhere.dev");
    await fetchTfL("https://api.tfl.gov.uk/Line/victoria/Status", 60, "the-key");
    assert.equal(asked.pop(), "https://api.tfl.gov.uk/Line/victoria/Status?app_key=the-key", "an address that isn't this machine is ignored");
    useLocalTfL("http://127.0.0.1:9000");
    await fetchTfL("https://api.tfl.gov.uk/Line/victoria/Status", 60, "the-key");
    assert.equal(asked.pop(), "http://127.0.0.1:9000/Line/victoria/Status");
  } finally {
    useLocalTfL(undefined);
    globalThis.fetch = upstream;
  }
  const odd = parseLineStatuses([null, 7, { id: 9 }, { id: "victoria", name: {}, lineStatuses: [null, { statusSeverity: "6", reason: { text: "x" }, validityPeriods: "soon", disruption: { affectedStops: [{ id: 4 }, { id: "940GZZLUVIC" }] } }] }]);
  assert.equal(odd.length, 1);
  assert.deepEqual({ ...odd[0], severity: 0 }, { lineId: "victoria", lineName: "", severity: 0, summary: "", reason: "", planned: false, periods: [], stops: ["940GZZLUVIC"] });
  assert.ok(Number.isNaN(odd[0].severity));
  assert.deepEqual(parseStationDisruptions([null, { type: "Closure", atcoCode: 5, description: "x" }, { type: "Closure", atcoCode: "940GZZLUVIC", description: ["x"] }]), []);
});

test("phones refused while the server's own push setup was wrong are tried again once it's right, not forgotten", async () => {
  forgetLineMaps();
  const day = 86400_000, at = Date.parse("2026-11-12T17:00:00Z");
  const { env, db, requests } = await setup(200, NOTICE, 500);
  // Refused three times over two days, by a wrong topic since put right.
  await db.prepare("UPDATE devices SET state = ?1 WHERE token = ?2")
    .bind(JSON.stringify({ alerts: {}, planned: {}, refused: { first: at - 2 * day, last: at - day, count: 3 } }), token).run();
  await db.prepare("INSERT INTO meta (key, value, updated_at) VALUES ('apns_ok:sandbox', '', ?1)").bind(at - 3_600_000).run();
  assert.deepEqual(await runChecks(env, at), { devices: 1, checked: 1, sent: 1 });
  assert.equal(requests.filter((r) => r.url.includes("push.apple.com")).length, 1);
  assert.equal(JSON.parse(db.rows.get(token)!.state).refused, undefined);
});

test("a push key that can't sign leaves every notice waiting, however long, and stops asking for the rest of the run", async () => {
  const { env, db, requests } = await setup(200);
  db.rows.set("ef".repeat(32), { environment: "sandbox", time_zone: "Europe/London", alerts: JSON.stringify([contract().alerts[0]]), state: "{}" });
  const broken = { ...env, APNS_KEY: "bm90IGEga2V5" } as Env;
  const at = Date.parse("2026-11-09T17:00:00Z");
  for (let run = 0; run < 5; run++) assert.equal((await runChecks(broken, at + run * 120_000)).sent, 0);
  assert.equal(requests.filter((r) => r.url.includes("push.apple.com")).length, 0);
  for (const device of [token, "ef".repeat(32)]) {
    const state = JSON.parse(db.rows.get(device)!.state);
    assert.equal(state.alerts?.[contract().alerts[0].id], undefined, "not marked told");
    assert.equal(state.retries, undefined, "nor counted towards giving up");
  }
  assert.equal((await runChecks(env, at + 12 * 60_000)).sent, 2, "told once the key is right");
});

test("every invitation taken out is every phone's invitation taken out: the same day, then they go", async () => {
  const { env, db } = await setup();
  await db.prepare("UPDATE devices SET enrollment_hash = 'a-hash-once-admitted' WHERE token = ?1").bind(token).run();
  const at = Date.parse("2026-11-09T11:15:00Z");
  await runChecks(env, at);
  await runChecks(env, at + 23 * 3_600_000);
  assert.equal(db.rows.size, 1);
  await runChecks(env, at + 25 * 3_600_000);
  assert.equal(db.rows.size, 0);
});

test("a run that finds another still sending leaves the phones to it; one environment's refusal doesn't stop the other's pushes", async () => {
  const { env, db, requests } = await setup(200);
  const at = Date.parse("2026-11-09T17:00:00Z");
  await db.prepare("INSERT INTO meta (key, value, updated_at) VALUES ('cron_run', '', ?1)").bind(Date.now()).run();
  assert.deepEqual(await runChecks(env, at), { devices: 1, checked: 0, sent: 0 });
  assert.equal(requests.filter((r) => r.url.includes("push.apple.com")).length, 0);
  // The run that held it is long over (or died): the next one takes its turn.
  await db.prepare("UPDATE meta SET updated_at = ?1 WHERE key = 'cron_run'").bind(Date.now() - 6 * 60_000).run();
  assert.equal((await runChecks(env, at)).sent, 1);
  assert.equal((await db.prepare("SELECT updated_at FROM meta WHERE key = 'cron_run'").first() as { updated_at: number }).updated_at, 0, "and gives it back");

  // Production's topic is refused; the sandbox phone is still told.
  const split = await setup((n) => (n === 1 ? 400 : 200));
  const live = "ef".repeat(32), other = "12".repeat(32);
  for (const [device, environment] of [[live, "production"], [other, "production"]]) {
    split.db.rows.set(device, { environment, time_zone: "Europe/London", alerts: JSON.stringify([contract().alerts[0]]), state: "{}" });
  }
  await split.db.prepare("DELETE FROM devices WHERE token = ?1").bind(token).run();
  split.db.rows.set(token, { environment: "sandbox", time_zone: "Europe/London", alerts: JSON.stringify([contract().alerts[0]]), state: "{}" });
  // 17:00 is a multiple of two minutes that starts the run at the first row.
  const result = await runChecks(split.env, at);
  const pushed = split.requests.filter((r) => r.url.includes("push.apple.com")).map((r) => r.url);
  assert.equal(pushed.filter((url) => url.includes("api.push.apple.com")).length, 1, "the second production phone isn't asked the same thing");
  assert.equal(pushed.filter((url) => url.includes("api.sandbox.push.apple.com")).length, 1);
  assert.equal(result.sent, 1);
});

test("a station notice TfL sends half-formed is a mode left unknown, not good news", async () => {
  const closure = fixture("tfl-station-disruptions.json");
  const { lineChecks: _unused, stationChecks } = await import("../src/linechecks.ts");
  const upstream = globalThis.fetch;
  try {
    globalThis.fetch = (async () => Response.json([...closure, { type: "Closure", atcoCode: "940GZZLUVIC" }])) as typeof fetch;
    assert.deepEqual([...(await stationChecks([{ line: { id: "victoria", name: "Victoria" }, mode: "tube", stations: [] }])).missing], ["tube"]);
    globalThis.fetch = (async () => Response.json(closure)) as typeof fetch;
    assert.equal((await stationChecks([{ line: { id: "victoria", name: "Victoria" }, mode: "tube", stations: [] }])).missing.size, 0);
  } finally {
    globalThis.fetch = upstream;
  }
});

test("Apple's other word for a token that's gone is treated the same", async () => {
  const { env, db } = await setup(410);
  apnsReason = "ExpiredToken";
  try {
    await runChecks(env, Date.parse("2026-11-09T17:00:00Z"));
    assert.equal(db.rows.size, 0);
  } finally {
    apnsReason = undefined;
  }
});

test("a phone registered after Apple last found its token gone is kept; a provider token Apple won't take leaves the notice waiting", async () => {
  const at = Date.parse("2026-11-09T17:00:00Z");
  const kept = await setup(410);
  apnsGoneAt = at - 30 * 86400_000;
  try {
    await runChecks(kept.env, at);
    assert.equal(kept.db.rows.size, 1, "registered since: not this registration's answer");
    apnsGoneAt = at;
    await runChecks(kept.env, at + 120_000);
    assert.equal(kept.db.rows.size, 0);
  } finally {
    apnsGoneAt = undefined;
  }

  const refused = await setup(403);
  apnsReason = "BadEnvironmentKeyIdInToken";
  try {
    for (let run = 0; run < 5; run++) await runChecks(refused.env, at + run * 120_000);
    const state = JSON.parse(refused.db.rows.get(token)!.state);
    assert.equal(state.alerts?.[contract().alerts[0].id], undefined, "not marked told");
    assert.equal(state.retries, undefined);
  } finally {
    apnsReason = undefined;
  }
});

test("a run sends only as many pushes as fit the plan, and the rest go next run", async () => {
  const { env, db, requests } = await setup(200);
  const { maxPushes } = await import("../src/checks.ts");
  assert.equal(maxPushes({}), 12);
  assert.equal(maxPushes({ MAX_PUSHES_PER_RUN: 200 }), 200);
  assert.equal(maxPushes({ MAX_PUSHES_PER_RUN: "lots" }), 12);
  for (let i = 0; i < 14; i++) db.rows.set(i.toString(16).padStart(2, "0").repeat(32), { environment: "sandbox", time_zone: "Europe/London", alerts: JSON.stringify([contract().alerts[0]]), state: "{}" });
  const at = Date.parse("2026-11-09T17:00:00Z");
  assert.equal((await runChecks(env, at)).sent, 12);
  assert.equal((await runChecks(env, at + 120_000)).sent, 3);
  assert.equal(requests.filter((r) => r.url.includes("push.apple.com")).length, 15, "each phone told once");
});

test("a quiet phone whose token Apple keeps refusing is forgotten too, once pushes are known to work", async () => {
  const now = Date.parse("2026-11-09T11:15:00Z"), day = 86400_000;
  const { env, db } = await setup(400);
  apnsReason = "BadDeviceToken";
  try {
    await db.prepare("UPDATE devices SET updated_at = ?1, state = ?2 WHERE token = ?3")
      .bind(now - 40 * day, JSON.stringify({ alerts: {}, planned: {}, refused: { first: now - 3 * day, last: now - 2 * day, count: 2 } }), token).run();
    await db.prepare("INSERT INTO meta (key, value, updated_at) VALUES ('apns_ok:sandbox', '', ?1)").bind(now - day).run();
    await runChecks(env, now);
    assert.equal(db.rows.size, 0);
  } finally {
    apnsReason = undefined;
  }
});

test("a run never asks D1 more than Workers Free answers, however many phones are on a troubled line", async () => {
  forgetLineMaps();
  const { env, db } = await setup(200, NOTICE, 500);
  for (let i = 0; i < 59; i++) db.rows.set((i + 16).toString(16).padStart(2, "0").repeat(32), { environment: "sandbox", time_zone: "Europe/London", alerts: JSON.stringify([contract().alerts[0]]), state: "{}" });
  let asked = 0;
  const counting = { ...env, DB: { ...db, prepare: (sql: string) => (asked++, db.prepare(sql)) } } as unknown as Env;
  const at = Date.parse("2026-11-09T17:00:00Z");
  let told = 0, most = 0;
  for (let run = 0; run < 12; run++) {
    asked = 0;
    told += (await runChecks(counting, at + run * 120_000)).sent;
    most = Math.max(most, asked);
  }
  assert.ok(most <= 50, `one run asked D1 ${most} times`);
  assert.equal(told, 60, "and every phone was told, once");
  // The trouble simply still being there isn't a write for every phone every run: when each
  // last saw it is refreshed every ten minutes, so a fifth of them a run.
  for (let run = 12; run < 20; run++) {
    asked = 0;
    await runChecks(counting, at + run * 120_000);
    assert.ok(asked <= 30, `a run with nothing new asked D1 ${asked} times`);
  }
});

test("what an invocation asks of TfL is counted, and what it can't afford is left unknown, not failed", async () => {
  const { fetchTfL, OutOfRequests } = await import("../src/tfl.ts");
  const { lineChecks } = await import("../src/linechecks.ts");
  const { tflRequests } = await import("../src/checks.ts");
  assert.deepEqual(tflRequests({}, 12), { left: 32 }, "Workers Free: 50, less the run's pushes and a few to spare");
  assert.deepEqual(tflRequests({ MAX_PUSHES_PER_RUN: 100 }, 100), { left: 900 });
  const upstream = globalThis.fetch;
  let asked = 0;
  globalThis.fetch = (async () => (asked++, Response.json(fixture("tfl-line-status-detail.json")))) as typeof fetch;
  try {
    const ops = { left: 1 };
    await fetchTfL("https://api.tfl.gov.uk/Line/elizabeth/Status?detail=true", 60, { ops });
    await assert.rejects(fetchTfL("https://api.tfl.gov.uk/Line/victoria/Status?detail=true", 60, { ops }), OutOfRequests);
    assert.equal(asked, 1);
    const report = await lineChecks([{ line: { id: "elizabeth", name: "Elizabeth line" }, mode: "elizabeth-line", stations: [] }], new Map([["elizabeth", "elizabeth-line"]]), { ops: { left: 0 } });
    assert.deepEqual([...report.missing], ["elizabeth"]);
  } finally {
    globalThis.fetch = upstream;
  }
});

test("trouble that is simply still there isn't a write every run, even on a phone with another alert seen hours ago", async () => {
  forgetLineMaps();
  const morning = { ...contract().alerts[0], id: "morning", windows: [{ start: 6 * 60, end: 9 * 60 }] };
  const { env, db } = await setup(200, NOTICE, 500, [contract().alerts[0], morning]);
  const at = Date.parse("2026-11-09T17:00:00Z");
  // The morning's alert saw trouble at eight, and keeps that until its next morning.
  await db.prepare("UPDATE devices SET state = ?1 WHERE token = ?2").bind(JSON.stringify({ alerts: { morning: { live: { old: { severity: "delays", seen: at - 9 * 3_600_000 } } } }, planned: {} }), token).run();
  let writes = 0;
  const counting = { ...env, DB: { ...db, prepare: (sql: string) => (sql.startsWith("UPDATE devices SET state") && writes++, db.prepare(sql)) } } as unknown as Env;
  for (let run = 0; run < 5; run++) await runChecks(counting, at + run * 120_000);
  assert.equal(writes, 1, "told once and written once; four checks later nothing new");
  await runChecks(counting, at + 6 * 120_000);
  assert.equal(writes, 2, "when it was last seen is brought up to date every ten minutes");
});

test("a line order there were no requests left to ask for is waited for, not guessed around", async () => {
  forgetLineMaps();
  const { loadLineMaps } = await import("../src/linemap.ts");
  const unasked = new Set<string>();
  const maps = await loadLineMaps(["elizabeth"], { ops: { left: 0 } }, Date.parse("2026-11-09T17:00:00Z"), unasked);
  assert.equal(maps.size, 0);
  assert.deepEqual([...unasked], ["elizabeth"]);
  // Asked again as soon as there are requests: not held back as a failure would be.
  const { requests } = await setup(200, NOTICE);
  await loadLineMaps(["elizabeth"], { ops: { left: 5 } }, Date.parse("2026-11-09T17:02:00Z"));
  assert.equal(requests.filter((r) => r.url.includes("/Route/Sequence/")).length, 1);
});
