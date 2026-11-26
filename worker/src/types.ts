// What the app sends: the lines you use regularly and when you travel.
// BeelineTests/Fixtures/alert-contract.json is the shared example both sides test against.

import type { Section } from "./clauses.ts";

export type Severity = "minor" | "delays" | "closed";

export interface Station {
  id: string; // TfL station id as in its line routes, then any other ids TfL uses for it: "910GLIVSTLL|910GLIVST"
  name: string;
}

export interface Segment {
  line: { id: string; name: string }; // TfL line id ("elizabeth") and how to say it ("Elizabeth line")
  mode: string; // TfL mode name: tube, dlr, elizabeth-line, overground, tram, national-rail
  from?: Station; // absent for the whole line
  to?: Station;
  stations: string[]; // station ids (same form) from `from` to `to` in order; empty for the whole line
}

export interface TimeWindow {
  start: number; // minutes after local midnight
  end: number;
  /** This slot's way, when it differs from the alert's: "to Paddington" mornings, "to Reading"
   * evenings. Absent (older builds) is the alert's `direction`. */
  direction?: Direction;
}

export interface Alert {
  id: string;
  name: string;
  days: number[]; // ISO weekdays, 1 is Monday
  windows: TimeWindow[];
  minorDelays: boolean;
  segments: Segment[];
  /** Which way you ride: "out" is each segment's `from` to `to`, "back" the reverse. Absent
   * (alerts saved before it, and older builds) means both ways. Only trouble TfL says is one
   * way only depends on it. */
  direction?: Direction;
  /** Start a next-train Live Activity at these times (activities.ts), with the phone's
   * push-to-start token. */
  liveActivity?: boolean;
}

export type Direction = "out" | "back" | "both";

export interface Issue {
  signature: string;
  severity: Severity;
  line: string;
  title: string;
  detail: string;
  /** The stretch it is on, when it was judged by one TfL names ("between X and Y"). */
  section?: Section;
  /** For planned works: when it starts (ms). */
  from?: number;
}

export type Environment = "sandbox" | "production";

export interface Device {
  token: string;
  environment: Environment;
  timeZone: string;
  alerts: Alert[];
}
