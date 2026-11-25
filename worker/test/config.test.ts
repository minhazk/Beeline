import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
// @ts-expect-error: a plain .mjs script, no types
import { deployProblems, parseJSONC, redacted, resolve } from "../scripts/wrangler.mjs";

const file = (name: string) => parseJSONC(readFileSync(new URL(`../${name}`, import.meta.url), "utf8"));

test("the tracked config alone can't be deployed", () => {
  assert.match(deployProblems(file("wrangler.jsonc")).join(), /database_id is a placeholder/);
});

test("nor with the example's values copied over unchanged", () => {
  const problems = deployProblems(resolve(file("wrangler.jsonc"), file("wrangler.local.example.jsonc"))).join("; ");
  assert.match(problems, /database_id/);
  assert.match(problems, /APNS_TEAM_ID/);
  assert.match(problems, /APNS_TOPIC/);
  assert.match(deployProblems({ vars: { APNS_TOPIC: "com.example.app" } }).join(), /APNS_TOPIC/);
});

test("a filled-in local config passes, and is laid over the tracked one", () => {
  const local = { routes: [{ pattern: "alerts.mydomain.dev", custom_domain: true }], vars: { APNS_TEAM_ID: "Z9Y8X7W6V5", APNS_TOPIC: "com.cloudslope.beeline" },
    d1_databases: [{ binding: "DB", database_name: "beeline-alerts", database_id: "12345678-90ab-cdef-1234-567890abcdef" }] };
  const merged = resolve(file("wrangler.jsonc"), local);
  assert.deepEqual(deployProblems(merged), []);
  assert.equal(merged.name, "beeline-alerts");
  assert.deepEqual(merged.triggers, { crons: ["*/2 * * * *"] });
});

test("comments and URLs in strings survive the JSONC reader", () => {
  assert.deepEqual(parseJSONC('{ "a": "https://x.example/y", // note\n "b": [1, 2,], /* c */ }'), { a: "https://x.example/y", b: [1, 2] });
});

test("example routes in any form are refused", () => {
  const base = { preview_urls: false, d1_databases: [{ binding: "DB", database_name: "beeline-alerts", database_id: "12345678-90ab-cdef-1234-567890abcdef" }], vars: { APNS_TEAM_ID: "Z9Y8X7W6V5", APNS_TOPIC: "com.cloudslope.beeline" } };
  for (const routes of [["alerts.example.com/*"], [{ pattern: "alerts.example.com/*", zone_name: "example.com" }], [{ pattern: "*.example.org/v1/*" }], [{ pattern: "alerts.mine.dev/*", zone_name: "example.net" }]]) {
    assert.match(deployProblems({ ...base, routes }).join(), /example's domain/, JSON.stringify(routes));
  }
  assert.match(deployProblems({ ...base, route: "https://alerts.example.com/*" }).join(), /example's domain/);
  assert.deepEqual(deployProblems({ ...base, routes: ["alerts.mine.dev/*"] }), []);
});

test("a secret put in vars, or recorded answers left on, is refused and never shown", () => {
  const base = { d1_databases: [{ binding: "DB", database_name: "beeline-alerts", database_id: "12345678-90ab-cdef-1234-567890abcdef" }] };
  for (const name of ["APP_TOKEN", "APNS_KEY", "APNS_KEY_ID", "TFL_APP_KEY"]) {
    assert.match(deployProblems({ ...base, vars: { [name]: "value" } }).join(), new RegExp(`${name} is a secret`));
  }
  assert.match(deployProblems({ ...base, vars: { TFL_BASE: "https://elsewhere.dev" } }).join(), /TFL_BASE/);
  const shown = JSON.stringify(redacted({ ...base, vars: { APP_TOKEN: "invitation-value", APNS_TOPIC: "com.cloudslope.beeline" } }));
  assert.ok(!shown.includes("invitation-value"));
  assert.ok(shown.includes("com.cloudslope.beeline"));
});

test("a local file can't turn request logs or preview addresses back on", () => {
  const local = { d1_databases: [{ binding: "DB", database_name: "beeline-alerts", database_id: "12345678-90ab-cdef-1234-567890abcdef" }] };
  assert.deepEqual(deployProblems(resolve(file("wrangler.jsonc"), local)), []);
  assert.match(deployProblems(resolve(file("wrangler.jsonc"), { ...local, observability: { enabled: true } })).join(), /invocation_logs/);
  assert.match(deployProblems(resolve(file("wrangler.jsonc"), { ...local, observability: { logs: { enabled: true, invocation_logs: true } } })).join(), /invocation_logs/);
  assert.deepEqual(deployProblems(resolve(file("wrangler.jsonc"), { ...local, observability: { enabled: false } })), []);
  assert.match(deployProblems(resolve(file("wrangler.jsonc"), { ...local, preview_urls: true })).join(), /preview_urls/);
});

test("traces, Logpush and tail Workers are refused: they record the same addresses", () => {
  const base = resolve(file("wrangler.jsonc"), { d1_databases: [{ binding: "DB", database_name: "beeline-alerts", database_id: "12345678-90ab-cdef-1234-567890abcdef" }] });
  assert.deepEqual(deployProblems(base), []);
  assert.match(deployProblems({ ...base, observability: { ...base.observability, traces: { enabled: true } } }).join(), /traces/);
  assert.match(deployProblems({ ...base, logpush: true }).join(), /logpush/);
  assert.match(deployProblems({ ...base, tail_consumers: [{ service: "tail" }] }).join(), /tail consumers/);
  assert.match(deployProblems({ ...base, env: { staging: {} } }).join(), /named environments/);
});

test("a secret in a named environment's vars isn't shown either", () => {
  const shown = JSON.stringify(redacted({ env: { staging: { vars: { APP_TOKEN: "invitation-value", APNS_TOPIC: "com.cloudslope.beeline" } } } }));
  assert.ok(!shown.includes("invitation-value") && shown.includes("com.cloudslope.beeline"));
});
