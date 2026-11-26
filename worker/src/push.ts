// What each notification says, in as few words as say it: a line's own name and what's wrong
// with it, a strike's dates or how much it has stopped. Closures and delays are Time Sensitive,
// so they come through a Focus; minor delays and planned works are ordinary; "good service
// again" is quiet.

import { brief, stretch } from "./brief.ts";
import { colourFor } from "./lines.ts";
import { hash } from "./match.ts";
import type { StrikeBulletin } from "./strikes.ts";
import type { Alert, Issue, Segment } from "./types.ts";

export interface Push {
  payload: Record<string, unknown>;
  priority: 5 | 10;
  /** Notifications only: a Live Activity's pushes have none. */
  collapseId?: string;
  /** Seconds since 1970 after which APNs stops trying. */
  expiration: number;
  /** "background" shows nothing on the phone: it only asks Apple whether the token still lives.
   * "liveactivity" is a next-train Live Activity's start, update or end (activities.ts). */
  type?: "alert" | "background" | "liveactivity";
}

/** Nothing the phone shows or keeps: Apple's answer says whether the app is still installed. */
export const probePush = (): Push => ({ payload: { aps: { "content-available": 1 } }, priority: 5, collapseId: "still-here", expiration: 0, type: "background" });

const RELEVANCE = { closed: 1, delays: 0.8, minor: 0.4 } as const;
// With control characters cleaned below, JSON needs at most three UTF-8 bytes per
// UTF-16 code unit. These fields leave room for the envelope and both 64-byte IDs
// within APNs' 4096-byte limit.
const MAX_TITLE = 120;
const MAX_BODY = 700;

// Emoji are the only colour a notification's own text can carry.
const WARNING = "⚠️", CALENDAR = "\u{1F4C5}", RUNNING = "✅";

// MARK: Your lines

/** Who a line's notification comes from: the app's notification extension draws a disc in the
 * line's colour with this symbol on it, in place of the app icon (LineSender in the app). A
 * build without the extension shows the same title and body beside the app icon. */
export interface Sender {
  /** One conversation per line: "line:central". */
  id: string;
  /** "Central line". */
  name: string;
  /** Hex, as the Live Activity's attributes carry it. */
  color?: string;
  /** SF Symbol: the mode's train, or a tick once it's running again. */
  symbol: string;
}

/** The stretch an issue is on: the alert's segment for that line. A status the app asked for
 * (the test push) names the line in its title alone. */
function segmentFor(alert: Alert, issue?: Issue): Segment | undefined {
  return (issue && (alert.segments.find((s) => s.line.name === issue.line) ?? alert.segments.find((s) => issue.title.includes(s.line.name))))
    ?? alert.segments[0];
}

function sender(segment: Segment | undefined, clear = false): Sender | undefined {
  if (!segment) return undefined;
  const color = colourFor(segment.line.id, segment.mode);
  const symbol = clear ? "checkmark" : segment.mode === "tube" || segment.mode === "dlr" || segment.mode === "tram" ? "tram.fill" : "train.side.front.car";
  return { id: `line:${trim(segment.line.id, 64)}`, name: trim(segment.line.name, MAX_TITLE), ...(color ? { color } : {}), symbol };
}

/** A line's notification: its name, then what's wrong in a few words, one thing a line. */
function linePayload(alert: Alert, from: Sender | undefined, lines: (string | undefined | false | 0)[], aps: Record<string, unknown>): Record<string, unknown> {
  return {
    aps: {
      alert: { title: from?.name ?? trim(alert.name, MAX_TITLE), body: trim(lines.filter(Boolean).join("\n"), MAX_BODY) },
      // Lets the app's notification extension put the line's disc on it before it shows.
      "mutable-content": 1,
      "thread-id": alert.id,
      ...aps,
    },
    alert: alert.id,
    ...(from ? { sender: from } : {}),
  };
}

export function issuesPush(alert: Alert, issues: Issue[], now: number): Push {
  const [first, ...rest] = issues;
  const urgent = issues.some((i) => i.severity !== "minor");
  const said = brief(first);
  return {
    payload: linePayload(alert, sender(segmentFor(alert, first)), [said.status, stretch(said) ?? said.cause, rest.length && `+${rest.length} more on your route`], {
      sound: "default",
      "interruption-level": urgent ? "time-sensitive" : "active",
      "relevance-score": RELEVANCE[first.severity],
    }),
    priority: 10,
    collapseId: alert.id,
    expiration: Math.floor(now / 1000) + 3 * 3600,
  };
}

export function clearPush(alert: Alert, now: number): Push {
  // One line: it says so itself. Several: the route does, with its first line's disc.
  const lines = new Set(alert.segments.map((s) => s.line.id));
  const from = sender(alert.segments[0], true);
  return {
    payload: linePayload(alert, from && lines.size > 1 ? { ...from, id: `route:${alert.id}`, name: trim(alert.name, MAX_TITLE) } : from, ["Good service again"], {
      "interruption-level": "passive",
      "relevance-score": 0.2,
    }),
    priority: 5,
    collapseId: alert.id,
    expiration: Math.floor(now / 1000) + 3600,
  };
}

export function plannedPush(alert: Alert, issues: Issue[], now: number): Push {
  const [first, ...rest] = issues;
  const said = brief(first);
  return {
    payload: linePayload(alert, sender(segmentFor(alert, first)), [`${said.status} tomorrow`, stretch(said), rest.length && `+${rest.length} more planned on your route`], {
      sound: "default",
      "interruption-level": "active",
      "relevance-score": 0.6,
    }),
    priority: 10,
    collapseId: `${alert.id}-planned`,
    expiration: Math.floor(now / 1000) + 12 * 3600,
  };
}

/** What the test button sends when nothing is wrong: proof that alerts arrive, as they will look. */
export function testPush(alert: Alert, good: boolean, now: number): Push {
  return {
    payload: linePayload(alert, sender(alert.segments[0], good), ["Test: alerts are on", good && "Good service now"], { sound: "default", "interruption-level": "active" }),
    priority: 10,
    collapseId: `${alert.id}-test`,
    expiration: Math.floor(now / 1000) + 3600,
  };
}

// MARK: London-wide strikes

// A network as a strike is named after it: "Tube strike", "Bus strike".
const STRIKE_NAMES: Record<string, string> = {
  bus: "Bus", "cable-car": "Cable Car", dlr: "DLR", "elizabeth-line": "Elizabeth line", "national-rail": "National Rail",
  overground: "Overground", "river-bus": "River Bus", tram: "Tram", tube: "Tube",
};
// Networks that are one line: saying which line is on strike says the network again.
const ONE_LINE = new Set(["cable-car", "dlr", "elizabeth-line", "tram"]);
const london = (options: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", ...options });
const DAY = london({ weekday: "short", day: "numeric", month: "short" });
const CLOCK = london({ hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
const DATE = london({ day: "numeric", month: "short", year: "numeric" });
const part = (ms: number, type: string) => DAY.formatToParts(ms).find((p) => p.type === type)?.value ?? "";
/** "Thu 17 Dec", without the comma some runtimes put after the weekday. */
const day = (ms: number) => `${part(ms, "weekday")} ${part(ms, "day")} ${part(ms, "month")}`;

/** "24h", "3 days": only a length that is a whole number of hours, give or take a minute. */
function length(from: number, to: number): string | undefined {
  const minutes = Math.round((to - from) / 60_000), hours = Math.round(minutes / 60);
  if (hours < 1 || Math.abs(minutes - hours * 60) > 1) return undefined;
  return hours >= 48 && hours % 24 === 0 ? `${hours / 24} days` : `${hours}h`;
}

/** When the periods are, in London time, in as few words as say it: "Thu 17 Dec · 12:00 · 24h",
 * "17 + 19 Dec · 12:00 · 24h each", or each period on a line of its own when they differ. */
export function strikeTimes(periods: { from: number; to: number }[]): string {
  const sorted = [...periods].sort((a, b) => a.from - b.from);
  const [first] = sorted;
  if (!first) return "";
  const lasts = length(first.from, first.to);
  const alike = lasts !== undefined && sorted.every((p) => CLOCK.format(p.from) === CLOCK.format(first.from) && length(p.from, p.to) === lasts);
  if (alike && sorted.length === 1) return `${day(first.from)} · ${CLOCK.format(first.from)} · ${lasts}`;
  if (alike && sorted.length <= 4) {
    // The month once for days that share it: "17 + 19 Dec", "30 Nov + 2 Dec".
    const month = (ms: number) => part(ms, "month");
    const days = sorted.map((p, i) => (i < sorted.length - 1 && month(p.from) === month(sorted[i + 1].from) ? part(p.from, "day") : `${part(p.from, "day")} ${month(p.from)}`));
    return `${days.join(" + ")} · ${CLOCK.format(first.from)} · ${lasts} each`;
  }
  const range = (p: { from: number; to: number }) => `${day(p.from)} ${CLOCK.format(p.from)} – ${DATE.format(p.from) === DATE.format(p.to) ? "" : `${day(p.to)} `}${CLOCK.format(p.to)}`;
  return [...sorted.slice(0, 3).map(range), ...(sorted.length > 3 ? [`+${sorted.length - 3} more`] : [])].join("\n");
}

/** "Tube strike"; a published bulletin with no network keeps its own heading. */
function strikeName(notice: StrikeBulletin): string {
  const name = (notice.mode && STRIKE_NAMES[notice.mode]) || notice.network;
  return /\b(?:strikes?|industrial action|walk[ -]?outs?|overtime ban)\b/i.test(name) ? name : `${name} strike`;
}

/** One strike, or several periods of the same one announced together: a symbol for whether it
 * is still to come or on now, then when, or how much is affected and what still runs. */
export function strikePush(told: StrikeBulletin | StrikeBulletin[], now: number): Push {
  const notices = Array.isArray(told) ? told : [told];
  const [notice] = notices;
  let title: string, lines: (string | undefined | false | 0)[];
  // Which lines or routes, where a strike is on some of a network: named up to three, counted
  // past that. A network that is one line has nothing to add.
  const names = [...new Set(notices.flatMap((n) => n.lines))];
  const unit = notice.mode === "bus" ? "routes" : "lines";
  const some = !ONE_LINE.has(notice.mode ?? "") && names.length > 0 && (names.length > 3 ? `${names.length} ${unit}` : names.join(", "));
  if (notice.active) {
    title = `${WARNING} Strike now`;
    lines = [[notice.mode ? notice.network : strikeName(notice), some && (names.length > 3 ? `${some} affected` : some)].filter(Boolean).join(" · "),
      notice.running?.length && `${RUNNING} ${notice.running.join(" · ")}`];
  } else {
    const periods = notices.flatMap((n) => (n.from !== undefined && n.to !== undefined ? [{ from: n.from, to: n.to }] : []));
    const starts = periods.length ? Math.min(...periods.map((p) => p.from)) : undefined;
    const soon = notice.reminder && starts !== undefined
      ? DATE.format(starts) === DATE.format(now) ? " today" : DATE.format(starts) === DATE.format(now + 86_400_000) ? " tomorrow" : ""
      : "";
    title = `${CALENDAR} ${strikeName(notice)}${soon}`;
    lines = [strikeTimes(periods) || notice.detail, some];
  }
  return {
    payload: {
      aps: {
        alert: { title: trim(title, MAX_TITLE), body: trim(lines.filter(Boolean).join("\n"), MAX_BODY) },
        sound: "default",
        "interruption-level": notice.active ? "time-sensitive" : "active",
        "thread-id": "london-strikes",
      },
      alert: "london-strikes",
    },
    priority: 10, collapseId: `strike:${hash(notice.key)}`, expiration: Math.floor(Math.min(notice.expires, now + 3 * 3600_000) / 1000),
  };
}

/** What the test button sends to a phone with strike alerts alone. */
export function strikeTestPush(now: number): Push {
  return {
    payload: {
      aps: { alert: { title: `${RUNNING} Strike alerts are on`, body: "London strikes will come through here." }, sound: "default", "interruption-level": "active", "thread-id": "london-strikes" },
      alert: "london-strikes",
    },
    priority: 10, collapseId: `strike:${hash("test")}`, expiration: Math.floor(now / 1000) + 300,
  };
}

/** "the Elizabeth line and the Central line"; train operators go without "the". */
export function lineList(alert: Alert): string {
  const names = [...new Set(alert.segments.map((s) => (s.mode === "national-rail" ? s.line.name : `the ${s.line.name}`)))];
  return names.length > 1 ? `${names.slice(0, -1).join(", ")} and ${names.at(-1)}` : names[0] ?? "your lines";
}

function trim(text: string, max: number): string {
  const truncated = text.length > max;
  const prefix = truncated ? text.slice(0, max - 1).replace(/[\uD800-\uDBFF]$/, "").trimEnd() : text;
  // Keep tabs and line breaks. Other non-printing controls and unpaired surrogates
  // would become six-byte JSON escapes. Unicode mode preserves valid surrogate pairs.
  const printable = prefix.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\uD800-\uDFFF]/gu, " ");
  return truncated ? `${printable}…` : printable;
}
