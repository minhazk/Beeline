// Dates on TfL's public strike bulletin can precede its Unified API line notices.
import { instant, localTime } from "./schedule.ts";

export interface PublishedStrike {
  title: string;
  from: number;
  to: number;
}

const months = "january february march april may june july august september october november december".split(" ");
const clockDay = String.raw`(\d{1,2}):(\d{2})\s+(?:[a-z]+\s+)?(\d{1,2})(?:st|nd|rd|th)?`;
const dateRange = new RegExp(`^${clockDay}(?:\\s+([a-z]+))?(?:\\s+(\\d{4}))?\\s+(?:to|until|–|-)\\s+${clockDay}\\s+([a-z]+)\\s+(\\d{4})[.]?$`, "i");

function londonDate(year: number, month: number, day: string, hour: string, minute: string): number | undefined {
  if (month < 1 || Number(hour) > 23 || Number(minute) > 59) return;
  const minutes = Number(hour) * 60 + Number(minute);
  const time = instant(year, month, Number(day), minutes, "Europe/London");
  const seen = localTime(time, "Europe/London");
  if (seen.year === year && seen.month === month && seen.day === Number(day) && seen.minutes === minutes) return time;
}

function window(text: string): Pick<PublishedStrike, "from" | "to"> | undefined {
  const match = dateRange.exec(text.toLowerCase());
  if (!match) return;
  const [, h, m, d, firstMonth, firstYear, h2, m2, d2, lastMonth, lastYear] = match;
  const month = months.indexOf(firstMonth ?? lastMonth) + 1, endMonth = months.indexOf(lastMonth) + 1;
  const year = firstYear ? Number(firstYear) : Number(lastYear) - Number(month > endMonth);
  const from = londonDate(year, month, d, h, m), to = londonDate(Number(lastYear), endMonth, d2, h2, m2);
  if (from !== undefined && to !== undefined && from < to) return { from, to };
}

// Only the action itself can be withdrawn. An accompanying warning that services
// may be suspended is not a cancellation. A dated withdrawal applies to that start.
const withdrawal = /\b(?:strikes?|industrial action)\b(?:\s+(?:on|planned for|scheduled for)\s+((?:(?!\b(?:services?|trains?|buses|may|could)\b)[^.;!?]){1,90}?))?\s+(?:(?:have|has|had)\s+been\s+|(?:is|are|was|were)\s+)?(?:called off|cancelled|postponed|suspended)\b/i;
function withdrawnOn(qualifier: string, start: number): boolean {
  if (!qualifier) return true;
  const date = localTime(start, "Europe/London");
  // The final month can be shared, as in "17 and 19 December".
  for (const item of qualifier.toLowerCase().matchAll(/((?:\d{1,2}(?:st|nd|rd|th)?(?:,\s*| and | & ))*\d{1,2})(?:st|nd|rd|th)?\s+([a-z]+)(?:\s+(\d{4}))?/g)) {
    if (months[date.month - 1] === item[2] && (!item[3] || Number(item[3]) === date.year)
        && item[1].match(/\d+/g)?.some(day => Number(day) === date.day)) return true;
  }
  return false;
}

export function publishedStrikes(html: string): PublishedStrike[] {
  const chunks: string[] = [];
  for (const match of html.matchAll(/<script[^>]*>\s*self\.__next_f\.push\((\[1,.*?\])\)\s*;?\s*<\/script>/gs)) {
    try {
      const [, chunk] = JSON.parse(match[1]);
      if (typeof chunk === "string") chunks.push(chunk);
    } catch { /* The server-rendered article is also checked. */ }
  }
  const article = (/<main\b[^>]*>(.*?)<\/main>/is.exec(html)?.[1] ?? html).replace(/<script\b[^>]*>.*?<\/script>/gis, "");
  const found = new Map<string, PublishedStrike>();
  const withdrawals = new Map<string, string[]>();
  for (const source of [article, chunks.join("")]) {
    let title = "", dates = false;
    const text = source.replace(/<p\s*>\s*(?=<[uo]l\b)/gi, "");
    const tags = /<(h[234]|li|p|div\s+data-fs-style=["']format\.h[234]["'])(?:\s+[^>]*)?>(.*?)<\/(?:h[234]|li|p|div)>/gis;
    for (const [, tag, body] of text.matchAll(tags)) {
      const label = body.replace(/<[^>]+>/g, "").replace(/&(?:nbsp|#160);/gi, " ").replace(/&amp;/gi, "&")
        .replace(/&(?:apos|#39|#x27|rsquo);/gi, "’").replace(/\s+/g, " ").trim();
      if (tag === "h2" || tag.includes("format.h2")) {
        dates = /^strike dates$/i.test(label);
        if (!dates) {
          title = /\b(strikes?|industrial action|walk[ -]?outs?|overtime ban)\b/i.test(label) && !/\b(called off|cancelled|suspended|postponed|ended)\b/i.test(label)
            ? label.replace(/\bstrikes$/i, "strike") : "";
        }
      } else if (tag === "p" && title) {
        const match = withdrawal.exec(label);
        if (match) withdrawals.set(title, [...(withdrawals.get(title) ?? []), match[1] ?? ""]);
      } else if (tag === "li" && dates && title) {
        const period = window(label);
        if (period) found.set(title + period.from, { title, ...period });
      }
    }
  }
  return [...found.values()].filter(event => !withdrawals.get(event.title)?.some(q => withdrawnOn(q, event.from)));
}
