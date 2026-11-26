// TfL publishes strikes as information notices as well as delays and suspensions.
// Check every London mode independently of the lines and times a phone has saved.
import { fetchStrikeCalendar, fetchTfL, lineStatusesComplete, lineStatusURL, parseLineStatuses, type LineStatus, type TfLAccess } from "./tfl.ts";
import { publishedStrikes, type PublishedStrike } from "./strikecalendar.ts";
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
  /** "Tube", "London buses"; a published bulletin's own heading when it names no network. */
  network: string;
  /** TfL's mode, when the strike is one network's. */
  mode?: string;
  /** The dated period (ms), for one still to come or one TfL published dates for. */
  from?: number;
  to?: number;
  /** The lines or routes TfL reports it on: "Bakerloo", "Route 25". None for a strike TfL
   * published dates for and that hasn't started: that one is the network's, whichever lines
   * have said so yet. */
  lines: string[];
  /** For one happening now: the other rail networks with good service on every line. */
  running?: string[];
  /** The day-before reminder of a period already announced. */
  reminder?: boolean;
}

interface StrikeGroup extends Omit<StrikeBulletin, "lines" | "mode" | "from"> {
  lines: Set<string>;
  mode: string;
  from: number;
  aliases: Set<string>;
}

export interface NetworkStrike extends StrikeBulletin {
  /** Which strike this is a period of: TfL's published heading, or the network and lines a
   * line notice is on. Periods of the same one, first heard of together, are told together. */
  strike: string;
  /** New bus routes may join a separate operator's strike while another is ongoing. */
  occurrences: string[];
  aliases?: string[];
  publishedStart?: number;
  /** Remember overlapping live line reports when a dated period starts. */
  liveReport?: { key: string; from: number };
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

function collect(found: Map<string, StrikeGroup>, status: LineStatus, mode: string, now: number, current: boolean, calendar: PublishedStrike[]) {
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
    const lineKey = active ? `live:${scope}` : `planned:${scope}:${from}:${to}:${hash(bulletin)}`;
    const matches = singleNetworks.has(mode) ? [] : calendar.filter(event =>
      (active ? event.from <= now && now < event.to : event.from === from && event.to === to)
      && matchesOperator(event.title, mode, `${lineName} ${reason}`));
    const published = matches.length === 1 ? matches[0] : undefined;
    const key = published ? calendarKey(published, active) : lineKey;
    const alias = published ? (lineKey === "live:bus" ? `${lineKey}:${line}` : lineKey) : undefined;
    const existing = found.get(key);
    if (existing) {
      existing.lines.add(line);
      if (alias) existing.aliases.add(alias);
      if (active) existing.expires = Math.max(existing.expires, Math.min(to, now + 2 * 3_600_000));
      continue;
    }
    const description = reason.toLowerCase().startsWith(line.toLowerCase()) ? reason : `${line}: ${reason}`;
    found.set(key, {
      key, active, from, ...(active ? {} : { to }), mode, network, aliases: new Set(alias ? [alias] : []), lines: new Set([line]), title: active ? `Strike disruption · ${network}` : `Upcoming strike · ${network}`,
      detail: active ? description : `${dateTime.format(from)} – ${dateTime.format(to)} (London time). ${description}`,
      expires: active ? Math.min(to, now + 2 * 3_600_000) : from,
    });
  }
}

// The rail networks worth saying are still running during a strike on another, as people say them.
const railNetworks: Record<string, string> = { tube: "Tube", "elizabeth-line": "Elizabeth", dlr: "DLR", overground: "Overground" };
// TfL's statusSeverity for a line with nothing wrong: good service, no issues.
const GOOD = new Set([10, 18]);

async function lineStrikes(now: number, access: TfLAccess, published: Promise<PublishedStrike[]>): Promise<{ groups: StrikeGroup[]; running: Map<string, string> }> {
  const found = new Map<string, StrikeGroup>();
  // Each rail network TfL answered for in full, and whether every line of it has good service.
  const good = new Map<string, boolean>();
  try {
    const live = await fetchTfL(cityStatus, 600, access, 6000);
    if (!Array.isArray(live)) return { groups: [], running: new Map() };
    const calendar = await published;
    const modes = new Map<string, string>();
    for (const line of live) {
      const rail = Object.hasOwn(railNetworks, line?.modeName);
      if (!lineStatusesComplete([line]) || !Object.hasOwn(networks, line.modeName)) {
        // A line TfL didn't answer for: its network isn't said to be running.
        if (rail) good.set(line.modeName, false);
        continue;
      }
      modes.set(line.id, line.modeName);
      const statuses = parseLineStatuses([line]);
      if (rail) good.set(line.modeName, (good.get(line.modeName) ?? true) && statuses.length > 0 && statuses.every((s) => GOOD.has(s.severity)));
      for (const status of statuses) collect(found, status, line.modeName, now, true, calendar);
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
          for (const status of parseLineStatuses([line])) collect(found, status, modes.get(status.lineId) ?? "", now, false, calendar);
        }
      }
    }
  } catch {
    // If a dated batch fails, the citywide current answer is still usable.
  }
  const running = new Map(Object.entries(railNetworks).filter(([mode]) => good.get(mode)));
  return { groups: [...found.values()], running };
}

// These networks publish network-wide strikes. Buses and National Rail can have
// independent operators striking at the same time, so keep their bulletin identities.
const networkHeadings: [string, RegExp][] = [
  ["tube", /\b(tube|underground)\b/i], ["elizabeth-line", /\belizabeth line\b/i],
  ["dlr", /\b(dlr|docklands light railway)\b/i], ["tram", /\btrams?\b/i],
  ["cable-car", /\bcable car\b/i],
];
const singleNetworks = new Set(networkHeadings.map(([mode]) => mode));
/** A strike on one of these is the whole network's, so its dated periods are one strike. */
export const networkWide = (mode: string | undefined) => mode !== undefined && singleNetworks.has(mode);

const operatorHeadings: [string, RegExp][] = [
  ["river-bus", /\b(river bus|ferry)\b/i], ["bus", /\b(bus|buses)\b/i], ["overground", /\boverground\b/i],
  ["national-rail", /\b(rail|railway|trains?)\b/i],
];
const genericWords = new Set("the of on at by and london bus buses drivers driver s staff workers services service rail national railway train trains river overground strike strikes industrial action walkout walkouts planned".split(" "));

function matchesOperator(title: string, mode: string, report: string): boolean {
  const headingMode = [...networkHeadings, ...operatorHeadings].find(([, pattern]) => pattern.test(title))?.[0];
  if (headingMode && headingMode !== mode) return false;
  const operator = (title.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? []).filter(word => !genericWords.has(word));
  const words = new Set(report.toLowerCase().match(/[\p{L}\p{N}]+/gu));
  return operator.length > 0 && operator.every(word => words.has(word));
}

function calendarKey(event: PublishedStrike, active: boolean): string {
  const mode = networkHeadings.find(([, pattern]) => pattern.test(event.title))?.[0];
  const scope = mode ?? `calendar:${hash(event.title.toLowerCase())}`;
  return `${active ? "live" : "planned"}:${scope}:${event.from}`;
}

function lineBulletin(group: StrikeGroup): NetworkStrike {
  const names = [...group.lines].sort();
  const affected = names.slice(0, 5).join(", ") + (names.length > 5 ? ` and ${names.length - 5} more` : "");
  // The bulletin and line-status sources can announce the same period independently.
  const key = singleNetworks.has(group.mode) && !group.active ? `planned:${group.mode}:${group.from}` : group.key;
  return {
    key, aliases: [...group.aliases], active: group.active, title: group.title, expires: group.expires,
    detail: names.length > 1 ? `${affected}. ${group.detail}` : group.detail,
    network: group.network, mode: group.mode, lines: names, strike: `lines:${group.mode}:${names.join(",")}`,
    ...(group.active ? {} : { from: group.from, to: group.to }),
    occurrences: key === "live:bus" ? names.map(line => `${key}:${line}`) : [key],
  };
}

export async function londonStrikes(now: number, access: TfLAccess): Promise<NetworkStrike[]> {
  const published = fetchStrikeCalendar(access).then(publishedStrikes).catch(() => []);
  const [{ groups, running }, calendar] = await Promise.all([lineStrikes(now, access, published), published]);
  const notices = new Map<string, NetworkStrike>();
  for (const group of groups) {
    const notice = lineBulletin(group);
    if (!notices.has(notice.key)) notices.set(notice.key, notice);
  }
  for (const event of calendar) {
    if (event.to <= now || event.from > now + 30 * DAY) continue;
    const mode = networkHeadings.find(([, pattern]) => pattern.test(event.title))?.[0];
    const active = event.from <= now;
    const key = calendarKey(event, active);
    const reportKey = active && mode ? `live:${mode}` : key;
    const prior = notices.get(reportKey);
    if (prior && reportKey !== key) notices.delete(reportKey);
    const network = mode ? networks[mode] : event.title;
    notices.set(key, {
      key, active, expires: active ? event.to : event.from,
      title: prior?.title ?? (active ? `Strike disruption · ${network}` : `Upcoming strike · ${network}`),
      detail: prior?.detail ?? `${event.title}: ${dateTime.format(event.from)} – ${dateTime.format(event.to)} (London time).`,
      network, ...(mode ? { mode } : {}), from: event.from, to: event.to, lines: active ? prior?.lines ?? [] : [],
      strike: `published:${event.title.toLowerCase()}`,
      occurrences: [key], aliases: prior?.aliases, publishedStart: event.from, liveReport: active && mode ? { key: reportKey, from: event.from } : undefined,
    });
  }
  // The network a notice is about: its mode, or the one its published heading names.
  const networkOf = (notice: NetworkStrike) => notice.mode ?? [...networkHeadings, ...operatorHeadings].find(([, pattern]) => pattern.test(notice.network))?.[0];
  const striking = new Set([...notices.values()].filter((notice) => notice.active).map(networkOf));
  return [...notices.values()].map((notice): NetworkStrike => {
    if (notice.active) {
      // Never a network that is itself on strike, whatever its lines' statuses say yet; and
      // nothing at all beside a strike whose own network can't be told.
      if (striking.has(undefined)) return notice;
      const others = [...running].filter(([mode]) => !striking.has(mode)).map(([, name]) => name);
      return others.length ? { ...notice, running: others } : notice;
    }
    if (notice.expires - now > DAY) return notice;
    // A new subscriber inside the reminder window gets one useful push. A subscriber
    // who already received the announcement still gets this separate reminder.
    const key = `reminder:${notice.key}`;
    return { ...notice, key, occurrences: [key], aliases: notice.aliases?.map(alias => `reminder:${alias}`), reminder: true,
      title: notice.title.replace("Upcoming strike", "Strike reminder") };
  }).sort((a, b) => Number(b.active) - Number(a.active) || a.expires - b.expires);
}
