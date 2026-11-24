import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { Alert, Segment } from "../src/types.ts";

/** Recorded TfL responses and the app's contract live with the app's tests. */
export function fixture(name: string): any {
  return JSON.parse(readFileSync(fileURLToPath(new URL(`../../BeelineTests/Fixtures/${name}`, import.meta.url)), "utf8"));
}

export const contract = () => fixture("alert-contract.json");

export function alert(segments: Segment[], extra: Partial<Alert> = {}): Alert {
  return { id: "test-alert", name: "Test", days: [1, 2, 3, 4, 5, 6, 7], windows: [{ start: 0, end: 1439 }], minorDelays: true, segments, ...extra };
}

export function stretch(lineId: string, lineName: string, mode: string, stations: { id: string; name: string }[]): Segment {
  return { line: { id: lineId, name: lineName }, mode, from: stations[0], to: stations.at(-1), stations: stations.map((s) => s.id) };
}

/** Today's recordings were made at 11:15 on Monday 9 November 2026. */
export const RECORDED_AT = Date.parse("2026-11-09T11:15:00Z");

/** D1 as the routes use it, over a real in-memory SQLite with the real migrations, so the
 * statements themselves are what's tested. `rows` reads and seeds the devices table. */
export function sqliteD1() {
  // Node's own SQLite; required here so the Worker's types never see it.
  const { DatabaseSync } = (globalThis as any).process.getBuiltinModule("node:sqlite");
  const db = new DatabaseSync(":memory:");
  for (const name of readdirSync(new URL("../migrations/", import.meta.url)).filter((name) => /^\d+_.*\.sql$/.test(name)).sort()) {
    db.exec(readFileSync(fileURLToPath(new URL(`../migrations/${name}`, import.meta.url)), "utf8"));
  }
  const statement = (sql: string) => {
    let args: unknown[] = [];
    const s = {
      bind(...values: unknown[]) { args = values; return s; },
      async first() { return db.prepare(sql).get(...args) ?? null; },
      async all() { return { results: db.prepare(sql).all(...args) }; },
      async run() { const r = db.prepare(sql).run(...args); return { meta: { changes: Number(r.changes) } }; },
    };
    return s;
  };
  const rows = {
    get: (token: string) => db.prepare("SELECT * FROM devices WHERE token = ?").get(token) as Record<string, any> | undefined,
    get size() { return Number((db.prepare("SELECT COUNT(*) AS n FROM devices").get() as { n: number }).n); },
    set: (token: string, row: Record<string, any>) => db.prepare(
      "INSERT INTO devices (token, environment, time_zone, alerts, state, updated_at, secret_hash) VALUES (?, ?, ?, ?, ?, ?, ?)",
    ).run(token, row.environment, row.time_zone, row.alerts, row.state ?? "{}", row.updated_at ?? 0, row.secret_hash ?? null),
  };
  return { prepare: statement, rows };
}
