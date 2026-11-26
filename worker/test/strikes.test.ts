import assert from "node:assert/strict";
import { test } from "node:test";
import { publishedStrikes } from "../src/strikecalendar.ts";
import { londonStrikes } from "../src/strikes.ts";

test("the forecast visits every TfL line across batches and ignores undated, expired and withdrawn notices", async (t) => {
  const now = Date.parse("2026-07-01T08:00:00Z");
  const lines = Array.from({ length: 45 }, (_, i) => ({ id: String(i + 1), modeName: "bus", name: String(i + 1), lineStatuses: [] }));
  const checked = new Set<string>();
  const from = new Date(now + 7 * 86400_000).toISOString();
  const to = new Date(now + 8 * 86400_000).toISOString();
  t.mock.method(globalThis, "fetch", async (input: RequestInfo) => {
    const url = new URL(String(input));
    if (url.pathname === "/status-updates/strikes") return new Response("");
    if (url.pathname.includes("/Mode/")) return Response.json(lines);
    const ids = url.pathname.split("/")[2].split(",");
    assert.ok(ids.length <= 20);
    for (const id of ids) checked.add(id);
    return Response.json(ids.map(id => ({
      id, name: id, lineStatuses: [
        { statusSeverity: 0, disruption: { description: "Bus drivers are planning a walkout." }, validityPeriods: [{ fromDate: from, toDate: to }] },
        { statusSeverity: 0, reason: "Bus strike dates to be announced.", validityPeriods: [] },
        { statusSeverity: 0, reason: "Industrial action on Friday has been called off.", validityPeriods: [{ fromDate: to, toDate: "2026-07-10T08:00:00Z" }] },
        { statusSeverity: 0, reason: "Earlier strike action.", validityPeriods: [{ fromDate: "2026-06-29T12:00:00Z", toDate: "2026-06-30T12:00:00Z" }] },
      ],
    })));
  });
  for (let tick = 0; tick < 3; tick++) {
    const notices = await londonStrikes(now + tick * 120_000, {});
    assert.equal(notices.length, 1);
    assert.equal(notices[0].active, false);
    assert.match(notices[0].detail, /8 Jul, 09:00.*9 Jul, 09:00.*walkout/);
  }
  assert.deepEqual(checked, new Set(lines.map(line => line.id)));
});

test("calendar reminders use London time, reject invalid or withdrawn dates and ignore travel advice", () => {
  const summer = "12:00 Thursday 17 to 11:59 Friday 18 June 2027";
  const winter = "23:30 Thursday 31 December to 01:30 Friday 1 January 2027";
  const dates = (title: string, items: string[]) => `<h2>${title}</h2><h2>Strike dates</h2><h3>Dates</h3><ul>${items.map(s => `<li>${s}</li>`).join("")}</ul>`;
  const article = dates("Bus drivers’ strikes", [summer, winter, "12:00 Monday 31 to 11:59 Tuesday 32 June 2027"])
    + dates("Tram strikes", [summer]) + "<p>The tram strikes have been called off.</p>"
    + "<h2>Travel advice</h2><ul><li>10:00 Friday 18 to 18:00 Friday 18 June 2027</li></ul>";
  assert.deepEqual(publishedStrikes(article), [
    { title: "Bus drivers’ strike", from: Date.parse("2027-06-17T11:00:00Z"), to: Date.parse("2027-06-18T10:59:00Z") },
    { title: "Bus drivers’ strike", from: Date.parse("2026-12-31T23:30:00Z"), to: Date.parse("2027-01-01T01:30:00Z") },
  ]);
});

test("a late bus bulletin gives one reminder per start and no reminder after the window starts", async (t) => {
  const now = Date.parse("2026-12-04T09:00:00Z");
  const hour = 3600_000;
  const line = { id: "25", modeName: "bus", name: "25" };
  let calledOff = false;
  t.mock.method(globalThis, "fetch", async (input: RequestInfo) => {
    const path = new URL(String(input)).pathname;
    if (path === "/status-updates/strikes") return new Response("Unavailable", { status: 503 });
    const reason = calledOff ? "The bus strike has been called off." : "East depot bus drivers are taking strike action.";
    const validityPeriods = [1, 20].map(h => ({
      fromDate: new Date(now + h * hour).toISOString(), toDate: new Date(now + (h + 2) * hour).toISOString(),
    }));
    return Response.json([{ ...line, lineStatuses: path.includes("/to/") ? [{ reason, statusSeverity: 0, validityPeriods }] : [] }]);
  });
  const reminders = await londonStrikes(now, {});
  assert.deepEqual(reminders.map(r => r.title), ["Strike reminder · London buses", "Strike reminder · London buses"]);
  assert.notEqual(reminders[0].key, reminders[1].key);
  assert.deepEqual((await londonStrikes(now + 4 * hour, {})).map(r => r.key), [reminders[1].key]);
  calledOff = true;
  assert.deepEqual(await londonStrikes(now + 6 * hour, {}), []);
});

test("a dated cancellation removes only its start; suspended services do not cancel a strike", () => {
  const headings = "<h2>Bus drivers’ strikes</h2><h2>Strike dates</h2>";
  const periods = "<li>12:00 Thursday 17 to 11:59 Friday 18 December 2026</li><li>12:00 Saturday 19 to 11:59 Sunday 20 December 2026</li>";
  const serviceImpact = "<p>During the strikes, services may be suspended.</p>";
  assert.equal(publishedStrikes(headings + periods + serviceImpact).length, 2);
  for (const html of [periods + "<p>The strike on 17 December has been called off.</p>",
                      "<p>The strike on 17 December has been called off.</p>" + periods]) {
    assert.deepEqual(publishedStrikes(headings + html).map(e => e.from), [Date.parse("2026-12-19T12:00Z")]);
  }
});

test("a bus strike on both feeds gives one reminder alongside a different operator's strike", async t => {
  const now = Date.parse("2026-12-16T12:00Z");
  t.mock.method(globalThis, "fetch", async (input: RequestInfo) => {
    const path = new URL(String(input)).pathname;
    if (path === "/status-updates/strikes") return new Response("<h2>Metroline bus drivers’ strikes</h2><h2>Strike dates</h2><li>12:00 Thursday 17 to 11:59 Friday 18 December 2026</li>");
    return Response.json(["Metroline", "Arriva"].map((company, i) => ({
      id: String(i + 1), name: String(i + 1), modeName: "bus",
      lineStatuses: [{ reason: company + " bus drivers’ strike.", statusSeverity: 0,
        validityPeriods: [{ fromDate: "2026-12-17T12:00:00Z", toDate: "2026-12-18T11:59:00Z" }] }],
    })));
  });
  for (const at of [now, now + 86400000]) {
    const items = await londonStrikes(at, {});
    assert.equal(items.length, 2);
    assert.equal(items.filter(x => x.detail.includes("Metroline")).length, 1);
    assert.equal(items.filter(x => x.detail.includes("Arriva")).length, 1);
  }
});
