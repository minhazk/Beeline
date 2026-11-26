// When to tell you: once per disruption, again if it gets worse, and "good service again"
// when it clears soon after. Pure, so the rules are tested without a clock or a phone.

import { rank } from "./match.ts";
import type { Direction, Issue, Severity } from "./types.ts";

export interface AlertState {
  /** Disruptions seen, by signature: how bad, when last seen, and the ways you were told it is
   * on (absent: every way, as before times had their own ways). */
  live: Record<string, { severity: Severity; seen: number; ways?: Direction[] }>;
  /** When we last told you about trouble, until it clears. */
  open?: number;
  /** The first check that found nothing, while `open`. */
  quietSince?: number;
}

export interface DeviceState {
  alerts: Record<string, AlertState>;
  /** London-wide strike bulletins already delivered, with the time each can be forgotten. */
  strikes?: Record<string, number>;
  /** Planned works already told, by alert and signature, with when. */
  planned: Record<string, number>;
  /** Local date of the last evening check for tomorrow. */
  plannedOn?: string;
  /** Pushes APNs couldn't take for a passing reason (busy, rate limited, network), by what they
   * were for (an alert id, or "planned:" and one): tried again next run, up to `MAX_RETRIES`. */
  retries?: Record<string, number>;
  /** APNs says this push token is not this app's (BadDeviceToken, DeviceTokenNotForTopic):
   * when it first and last said so, and how often. Pushes wait longer after each refusal. */
  refused?: { first: number; last: number; count: number };
  /** When Apple last took a push for this phone, a silent one included. */
  heard?: number;
  /** When its invitation was first found gone from APP_TOKEN; cleared if it comes back. */
  revoked?: number;
}

export const MAX_RETRIES = 3;

export type Decision = { kind: "issues"; issues: Issue[] } | { kind: "clear" };

const MINUTE = 60_000;
// A line's status overnight says nothing about whether this morning's is the same incident.
const LINE_MEMORY = 90 * MINUTE;
// Station works run for weeks; don't repeat them every morning.
const STATION_MEMORY = 7 * 24 * 60 * MINUTE;
// TfL flips a line between "minor delays" and "good service" for a few minutes at a time.
const FLAP_GUARD = 30 * MINUTE;
const QUIET_BEFORE_CLEAR = 4 * MINUTE;
const CLEAR_WITHIN = 3 * 60 * MINUTE;
const PLANNED_MEMORY = 14 * 24 * 60 * MINUTE;

/** What a check knows about ways, for an alert whose times go one way or the other. */
export interface Ways {
  /** The way ridden at this check ("both" when times going different ways overlap). */
  way: Direction;
  /** For each disruption on your stretch either way, the ways it is on. */
  on: ReadonlyMap<string, Direction[]>;
  /** Some time of this alert goes the other way: trouble told now only the other way stays open. */
  holds: boolean;
  /** What memory from before ways were kept counts as told: the alert's own way. */
  told: Direction[];
}

const BOTH: Direction[] = ["out", "back"];

/** One check during a time you travel. With times going different ways (mornings one way,
 * evenings the other), a disruption is told again when it is on a way you ride now and haven't
 * been told about (it spread, or you ride a way it wasn't on before); the ways told are what was
 * pushed. One-way trouble told that is now only the other way is remembered, and isn't "good
 * service again" while it lasts, if some time of the alert goes that way. Without `ways`, as before. */
export function step(previous: AlertState | undefined, issues: Issue[], now: number, ways?: Ways): { state: AlertState; push?: Decision } {
  const prev = previous ?? { live: {} };
  const known: AlertState["live"] = {};
  for (const [signature, entry] of Object.entries(prev.live)) {
    const memory = signature.startsWith("stop:") ? STATION_MEMORY : LINE_MEMORY;
    if (now - entry.seen <= memory) known[signature] = entry;
  }

  const rides = !ways || ways.way === "both" ? BOTH : [ways.way];
  // The ways a disruption of yours is on that you ride now.
  const yours = (signature: string) => {
    const on = (ways?.on.get(signature) ?? rides).filter((d) => rides.includes(d));
    return on.length ? on : rides;
  };
  const told = (entry: { ways?: Direction[] }) => entry.ways ?? ways?.told ?? BOTH;
  const untold = (signature: string) => !!ways && yours(signature).some((d) => !told(known[signature]).includes(d));
  const news = issues.some((i) => !known[i.signature] || rank(i.severity) > rank(known[i.signature].severity) || untold(i.signature));
  const pushing = issues.length > 0 && (news || prev.open === undefined);

  const live: AlertState["live"] = {};
  for (const issue of issues) {
    const seen = known[issue.signature];
    // Ways told grow only with a push, by every way the disruption is on then (the notice says so);
    // without ways, nothing is recorded, as before.
    const kept = !ways ? seen?.ways : pushing ? [...new Set([...(seen ? told(seen) : []), ...(ways.on.get(issue.signature) ?? rides)])] : seen?.ways;
    live[issue.signature] = kept ? { severity: issue.severity, seen: now, ways: kept } : { severity: issue.severity, seen: now };
  }
  // Told before, still there, only the other way now: remembered, if a time of the alert goes that way.
  let away = false;
  if (ways?.holds) {
    for (const signature of ways.on.keys()) {
      if (!known[signature] || signature in live) continue;
      live[signature] = { ...known[signature], seen: now };
      away = true;
    }
  }
  for (const [signature, entry] of Object.entries(known)) {
    if (!(signature in live) && now - entry.seen <= FLAP_GUARD) live[signature] = entry;
  }

  if (issues.length) {
    if (pushing) return { state: { live, open: now }, push: { kind: "issues", issues } };
    return { state: { live, open: prev.open } };
  }

  if (prev.open === undefined) return { state: { live } };
  // Still there, just not your way now: not cleared.
  if (away) return { state: { live, open: prev.open } };
  const quietSince = prev.quietSince ?? now;
  if (now - quietSince < QUIET_BEFORE_CLEAR) return { state: { live, open: prev.open, quietSince } };
  // Cleared. Say so if we told you recently; yesterday evening's delays needn't be undone at breakfast.
  return { state: { live }, push: now - prev.open <= CLEAR_WITHIN ? { kind: "clear" } : undefined };
}

/** The evening before: planned works on tomorrow's trips you haven't been told about. */
export function plannedStep(planned: Record<string, number>, alertId: string, issues: Issue[], now: number): { planned: Record<string, number>; fresh: Issue[] } {
  const next: Record<string, number> = {};
  for (const [key, at] of Object.entries(planned)) if (now - at <= PLANNED_MEMORY) next[key] = at;
  const fresh = issues.filter((i) => !(`${alertId}|${i.signature}` in next));
  for (const issue of issues) next[`${alertId}|${issue.signature}`] ??= now;
  return { planned: next, fresh };
}
