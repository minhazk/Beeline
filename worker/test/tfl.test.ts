import assert from "node:assert/strict";
import { test, type TestContext } from "node:test";
import worker from "../src/index.ts";
import { fetchTfL, lineStatusURL, retryDelay, stationDisruptionsURL } from "../src/tfl.ts";

/** TfL answering each request in turn from `answers`; waits recorded but not taken; what's
 * logged and what's kept at the edge. */
function upstream(t: TestContext, answers: (() => Response)[]) {
  const asked: string[] = [], waits: number[] = [], warned: string[] = [], cached: string[] = [];
  t.mock.method(globalThis, "fetch", async (input: RequestInfo | URL) => (asked.push(String(input)), answers[asked.length - 1]()));
  const realTimeout = globalThis.setTimeout;
  t.mock.method(globalThis, "setTimeout", (done: () => void, ms: number) => (waits.push(ms), realTimeout(done, 0)));
  t.mock.method(console, "warn", (...args: unknown[]) => void warned.push(args.join(" ")));
  (globalThis as any).caches = { open: async () => ({ match: async () => undefined, put: async (key: Request) => void cached.push(key.url) }) };
  t.after(() => delete (globalThis as any).caches);
  return { asked, waits, warned, cached };
}

const limited = (retryAfter?: string) => () =>
  new Response("Rate limit is exceeded. Try again in 1 seconds.", { status: 429, headers: retryAfter ? { "Retry-After": retryAfter } : {} });

for (const key of ["tfl-key", undefined]) {
  test(`a rate-limited request is asked again after TfL's Retry-After, ${key ? "with" : "without"} a key`, async (t) => {
    const { asked, waits, warned, cached } = upstream(t, [limited("2"), () => Response.json([{ id: "elizabeth" }])]);
    const url = lineStatusURL(["elizabeth"]);
    assert.deepEqual(await fetchTfL(url, 60, key, 6000), [{ id: "elizabeth" }]);
    assert.deepEqual(asked, Array(2).fill(key ? `${url}&app_key=${key}` : url));
    assert.deepEqual(waits, [2000]);
    assert.deepEqual(warned, []);
    assert.deepEqual(cached, [url], "kept under the URL without the key");
  });
}

test("a request TfL keeps refusing is asked twice, logged once with its status and path, never the key, and not cached", async (t) => {
  const { asked, waits, warned, cached } = upstream(t, [limited(), limited()]);
  await assert.rejects(fetchTfL(lineStatusURL(["elizabeth"]), 60, "tfl-key", 6000), (e: Error) => /^TfL 429 /.test(e.message) && !e.message.includes("tfl-key"));
  assert.equal(asked.length, 2);
  assert.deepEqual(waits, [1500], "1.5 s when TfL doesn't say");
  assert.deepEqual(warned, ["TfL request failed: 429 /Line/elizabeth/Status?detail=true"]);
  assert.deepEqual(cached, []);
});

test("a request that throws is logged by the error's name", async (t) => {
  const { asked, warned } = upstream(t, [() => { throw new DOMException("The operation was aborted due to timeout", "TimeoutError"); }]);
  await assert.rejects(fetchTfL(stationDisruptionsURL(["tube"]), 60, "tfl-key", 6000));
  assert.equal(asked.length, 1, "only a 429 is asked again");
  assert.deepEqual(warned, ["TfL request failed: TimeoutError /StopPoint/Mode/tube/Disruption"]);
});

test("Retry-After is whole seconds held to 1–3 s, and 1.5 s when absent or not a number", () => {
  const headers = [null, "", "soon", "1.5", "Wed, 25 Nov 2026 12:00:00 GMT", "0", "1", "2", " 3 ", "60"];
  assert.deepEqual(headers.map(retryDelay), [1500, 1500, 1500, 1500, 1500, 1000, 1000, 2000, 3000, 3000]);
});

test("a Worker without TFL_APP_KEY says so once, and /health shows it", async (t) => {
  const warned: string[] = [];
  t.mock.method(console, "warn", (...args: unknown[]) => void warned.push(args.join(" ")));
  const health = async (env: object) => (await worker.fetch(new Request("https://alerts.example.com/health"), env as any, {} as ExecutionContext)).json();
  assert.equal((await health({ TFL_APP_KEY: "tfl-key" })).tflKey, true);
  assert.deepEqual(warned, []);
  assert.equal((await health({})).tflKey, false);
  await health({});
  assert.deepEqual(warned, ["TFL_APP_KEY is not set: TfL rate-limits Cloudflare's shared addresses, so line checks will fail"]);
});
