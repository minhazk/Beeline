// What each notification says. Closures and delays are Time Sensitive, so they come
// through a Focus; minor delays and planned works are ordinary; "good service again" is quiet.

import type { Alert, Issue } from "./types.ts";

export interface Push {
  payload: Record<string, unknown>;
  priority: 5 | 10;
  collapseId: string;
  /** Seconds since 1970 after which APNs stops trying. */
  expiration: number;
}

const RELEVANCE = { closed: 1, delays: 0.8, minor: 0.4 } as const;
// With control characters cleaned below, JSON needs at most three UTF-8 bytes per
// UTF-16 code unit. These fields leave room for the envelope and both 64-byte IDs
// within APNs' 4096-byte limit.
const MAX_TITLE = 120;
const MAX_SUBTITLE = 160;
const MAX_BODY = 700;

export function issuesPush(alert: Alert, issues: Issue[], now: number): Push {
  const [first, ...rest] = issues;
  const urgent = issues.some((i) => i.severity !== "minor");
  const also = rest.length ? trim(`\n\nAlso: ${rest.map((i) => i.title).join("; ")}.`, MAX_BODY / 2) : "";
  return {
    payload: {
      aps: {
        alert: {
          title: trim(alert.name, MAX_TITLE),
          subtitle: trim(first.title, MAX_SUBTITLE),
          body: trim(first.detail || first.title, MAX_BODY - also.length) + also,
        },
        sound: "default",
        "interruption-level": urgent ? "time-sensitive" : "active",
        "relevance-score": RELEVANCE[first.severity],
        "thread-id": alert.id,
      },
      alert: alert.id,
    },
    priority: 10,
    collapseId: alert.id,
    expiration: Math.floor(now / 1000) + 3 * 3600,
  };
}

export function clearPush(alert: Alert, now: number): Push {
  return {
    payload: {
      aps: {
        alert: { title: trim(alert.name, MAX_TITLE), body: trim(`Good service again on ${lineList(alert)}.`, MAX_BODY) },
        "interruption-level": "passive",
        "relevance-score": 0.2,
        "thread-id": alert.id,
      },
      alert: alert.id,
    },
    priority: 5,
    collapseId: alert.id,
    expiration: Math.floor(now / 1000) + 3600,
  };
}

export function plannedPush(alert: Alert, issues: Issue[], now: number): Push {
  const body = issues.map((i) => i.detail || i.title).join("\n\n");
  return {
    payload: {
      aps: {
        alert: {
          title: trim(alert.name, MAX_TITLE),
          subtitle: issues.length === 1
            ? `Planned: ${trim(issues[0].title.replace(/^.*?: /, ""), MAX_SUBTITLE - "Planned:  tomorrow".length)} tomorrow`
            : `${issues.length} planned works tomorrow`,
          body: trim(body, MAX_BODY),
        },
        sound: "default",
        "interruption-level": "active",
        "relevance-score": 0.6,
        "thread-id": alert.id,
      },
      alert: alert.id,
    },
    priority: 10,
    collapseId: `${alert.id}-planned`,
    expiration: Math.floor(now / 1000) + 12 * 3600,
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
