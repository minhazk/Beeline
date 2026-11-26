import assert from "node:assert/strict";
import { test } from "node:test";
import { londonStrikes } from "../src/strikes.ts";

test("the forecast visits every TfL line across batches and ignores undated, expired and withdrawn notices", async (t) => {
  const now = Date.parse("2026-07-01T08:00:00Z");
  const lines = Array.from({ length: 45 }, (_, i) => ({ id: String(i + 1), modeName: "bus", name: String(i + 1), lineStatuses: [] }));
  const checked = new Set<string>();
  const from = new Date(now + 7 * 86400_000).toISOString();
  const to = new Date(now + 8 * 86400_000).toISOString();
  t.mock.method(globalThis, "fetch", async (input: RequestInfo) => {
    const url = new URL(String(input));
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
