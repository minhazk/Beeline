// A disruption in a handful of words: what a notification and the Live Activity's card say
// in place of TfL's paragraph.

import { clauses, type Section } from "./clauses.ts";
import type { Issue } from "./types.ts";

export interface Brief {
  /** "Severe delays"; a station's closure keeps its name: "Canary Wharf closed". */
  status: string;
  /** The ends of the stretch it is on ("between Leytonstone and Hainault"), when that is known:
   * the one it was judged by, or the only one its notice names. A notice that names several,
   * without saying which is yours, gives none. */
  from?: string;
  to?: string;
  /** Why, when TfL says: "Signal failure at Leytonstone". */
  cause?: string;
  /** Every stretch it could be on, as TfL's words give them, for placing on the line. */
  sections: Section[];
}

const CAUSE = /\b(?:due to|owing to|because of|following|while we|whilst we)\b(?:[^.]|(?<=\bSt)\.)*/i;
const capitalise = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
const cut = (s: string, max: number) => (s.length > max ? `${s.slice(0, max - 1).trimEnd()}…` : s);

/** "Central line: severe delays" → "Severe delays"; "Bank closed (Northern line)" → "Bank closed". */
export function statusOf(title: string): string {
  const bare = title.replace(/\s*\([^)]*\)\s*$/, "");
  const colon = bare.indexOf(": ");
  return cut(capitalise((colon >= 0 ? bare.slice(colon + 2) : bare).trim()), 40);
}

/** A stretch's ends as people say them; one with alternatives keeps them: "Epping / Hainault". */
export const ends = (section: Section) => ({ from: section.from.join(" / "), to: section.to.join(" / ") });

export function brief(issue: Issue): Brief {
  const status = statusOf(issue.title);
  const said = clauses(issue.detail).filter((c) => c.sections.length);
  // The clauses this issue is about, when its notice has several severities.
  const own = said.filter((c) => c.phrase.toLowerCase() === status.toLowerCase());
  const sections = issue.section ? [issue.section] : (own.length ? own : said).flatMap((c) => c.sections);
  const why = issue.detail.match(CAUSE)?.[0]
    .replace(/^(?:due to|owing to|because of|following)\s+(?:(?:a|an|the)\s+)?/i, "")
    .replace(/[\s,;]+$/, "");
  return {
    status,
    ...(sections.length === 1 ? ends(sections[0]) : {}),
    ...(why ? { cause: cut(capitalise(why), 48) } : {}),
    sections,
  };
}

/** "Leytonstone → Hainault". */
export const stretch = (b: Brief) => (b.from && b.to ? `${b.from} → ${b.to}` : undefined);
