// TfL publishes strikes as information notices as well as delays and suspensions.
// Check every London mode independently of the lines and times a phone has saved.
import { fetchTfL, lineStatusesComplete, lineStatusURL, parseLineStatuses, type LineStatus, type TfLAccess } from "./tfl.ts";
import { hash } from "./match.ts";

const networks: Record<string, string> = {
  bus: "London buses", "cable-car": "London Cable Car", dlr: "DLR", "elizabeth-line": "Elizabeth line",
  "national-rail": "National Rail", overground: "London Overground", "river-bus": "River Bus", tram: "London Trams", tube: "Tube",
};
const cityStatus = `https://api.tfl.gov.uk/Line/Mode/${Object.keys(networks).sort().join(",")}/Status?detail=false`;
const DAY = 86_400_000;
const dateTime = new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });

export interface StrikeBulletin {
  key: string;
  active: boolean;
  title: string;
  detail: string;
  expires: number;
}

interface StrikeGroup extends StrikeBulletin {
  lines: Set<string>;
}

interface NetworkStrike extends StrikeBulletin {
  /** New bus routes may join a separate operator's strike while another is ongoing. */
  occurrences: string[];
}

const action = String.raw`(?:strikes?(?: action)?|industrial action|walk[ -]?outs?|overtime ban)`;
const mentionsAction = new RegExp(String.raw`\b${action}\b`, "i");
// A date may separate the subject from "called off". Stop at a different
// subject: trains can be cancelled because a strike is going ahead.
const withdrawn = String.raw`(?:called off|cancelled|suspended|averted|postponed|ended|will not (?:go ahead|take place)|no longer (?:going ahead|taking place))`;
const actionWithdrawn = new RegExp(String.raw`\b${action}\b(?:(?!\b(?:trains?|services?|buses|departures?)\b)[^.!?;:]){0,100}\b${withdrawn}\b`, "i");
const withdrawnAction = new RegExp(String.raw`\b(?:called off|averted|cancelled|postponed|no) (?:the |their |planned |further )*${action}\b`, "i");

function industrialAction(words: string): boolean {
  const text = words.replace(/\b(?:lightning|bridge|bird|object|vehicle) strikes?\b|\bstrikes? (?:a|the) (?:bridge|vehicle|train|bus)\b/gi, "");
  return mentionsAction.test(text) && !actionWithdrawn.test(text) && !withdrawnAction.test(text);
}

function collect(found: Map<string, StrikeGroup>, status: LineStatus, mode: string, now: number, current: boolean) {
  const network = networks[mode];
  if (!network || !industrialAction(`${status.summary}. ${status.reason}`)) return;
  const lineName = status.lineName || status.lineId;
  const line = mode === "bus" ? `Route ${lineName}` : lineName;
  const reason = status.reason || status.summary;
  // The same announcement can be prefixed with the individual route it appears on.
  const normalized = reason.toLowerCase().replace(/\s+/g, " ").trim();
  const prefix = normalized.indexOf(":");
  const routeLabels = [lineName, line, `${lineName} line`].map(label => label.toLowerCase());
  const bulletin = prefix >= 0 && routeLabels.includes(normalized.slice(0, prefix).trim())
    ? normalized.slice(prefix + 1).trim() : normalized;
  // An undated entry on the current endpoint applies now. The same entry in a
  // month-long range gives no evidence of when it will apply.
  const periods = status.periods.length ? status.periods : current ? [{ from: now, to: now + 600_000 }] : [];
  for (const { from, to } of periods) {
    if (to <= now || from > now + 30 * DAY) continue;
    const active = from <= now;
    // Different lines report the same ongoing action with different start times.
    // National Rail line IDs are operators; two operators can strike independently.
    const scope = mode === "national-rail" ? `${mode}:${status.lineId}` : mode;
    const key = active ? `live:${scope}` : `planned:${scope}:${from}:${to}:${hash(bulletin)}`;
    const existing = found.get(key);
    if (existing) {
      existing.lines.add(line);
      if (active) existing.expires = Math.max(existing.expires, Math.min(to, now + 2 * 3_600_000));
      continue;
    }
    const description = reason.toLowerCase().startsWith(line.toLowerCase()) ? reason : `${line}: ${reason}`;
    found.set(key, {
      key, active, lines: new Set([line]), title: active ? `Strike disruption · ${network}` : `Upcoming strike · ${network}`,
      detail: active ? description : `${dateTime.format(from)} – ${dateTime.format(to)} (London time). ${description}`,
      expires: active ? Math.min(to, now + 2 * 3_600_000) : from,
    });
  }
}

export async function londonStrikes(now: number, access: TfLAccess): Promise<NetworkStrike[]> {
  const found = new Map<string, StrikeGroup>();
  try {
    const live = await fetchTfL(cityStatus, 600, access, 6000);
    if (!Array.isArray(live)) return [];
    const modes = new Map<string, string>();
    for (const line of live) {
      if (!lineStatusesComplete([line]) || !Object.hasOwn(networks, line.modeName)) continue;
      modes.set(line.id, line.modeName);
      for (const status of parseLineStatuses([line])) collect(found, status, line.modeName, now, true);
    }

    // TfL's dated endpoint accepts about 20 line IDs. Rotate through the network
    // (including every bus route) one batch per two-minute check.
    const ids = [...modes.keys()].sort((a, b) => modes.get(a)!.localeCompare(modes.get(b)!) || a.localeCompare(b));
    if (ids.length) {
      const batch = Math.floor(now / 120_000) % Math.ceil(ids.length / 20);
      const from = Math.floor(now / DAY) * DAY;
      const url = lineStatusURL(ids.slice(batch * 20, batch * 20 + 20), { from, to: from + 31 * DAY }, false);
      const ahead = await fetchTfL(url, 1800, access, 6000);
      if (Array.isArray(ahead)) {
        for (const line of ahead) {
          if (!lineStatusesComplete([line])) continue;
          for (const status of parseLineStatuses([line])) collect(found, status, modes.get(status.lineId) ?? "", now, false);
        }
      }
    }
  } catch {
    // If a dated batch fails, the citywide current answer is still usable.
  }
  return [...found.values()].map(({ lines, ...notice }) => {
    const names = [...lines].sort();
    const affected = names.slice(0, 5).join(", ") + (names.length > 5 ? ` and ${names.length - 5} more` : "");
    return {
      ...notice,
      occurrences: notice.key === "live:bus" ? names.map(line => `${notice.key}:${line}`) : [notice.key],
      detail: names.length > 1 ? `${affected}. ${notice.detail}` : notice.detail,
    };
  }).sort((a, b) => Number(b.active) - Number(a.active) || a.expires - b.expires);
}
