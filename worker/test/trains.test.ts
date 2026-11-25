import assert from "node:assert/strict";
import { test } from "node:test";
import { parseLineMap } from "../src/linemap.ts";
import { callsAt, nextTrains, parseArrivals, parseDepartures, trainsURL } from "../src/trains.ts";
import type { Segment } from "../src/types.ts";
import { fixture } from "./helpers.ts";

/** The arrivals and departures were recorded at 19:15:46 on Wednesday 25 November 2026. */
const NOW = Date.parse("2026-11-25T19:15:46Z");
const clock = (s: number) => new Date(s * 1000).toISOString().slice(11, 16);

const central = parseLineMap("central", fixture("tfl-sequence-central.json"))!;
const elizabeth = parseLineMap("elizabeth", fixture("tfl-sequence-elizabeth.json"))!;

const ride = (line: string, name: string, mode: string, from: [string, string], to: [string, string]): Segment =>
  ({ line: { id: line, name }, mode, from: { id: from[0], name: from[1] }, to: { id: to[0], name: to[1] }, stations: [] });

test("tube and Elizabeth line times come from the request each one answers best", () => {
  assert.equal(trainsURL("central", "tube", "940GZZLURBG"), "https://api.tfl.gov.uk/Line/central/Arrivals/940GZZLURBG");
  assert.equal(trainsURL("elizabeth", "elizabeth-line", "910GPADTLL"), "https://api.tfl.gov.uk/StopPoint/910GPADTLL/ArrivalDepartures?lineIds=elizabeth");
  assert.equal(trainsURL("weaver", "overground", "910GHACKNYC"), "https://api.tfl.gov.uk/StopPoint/910GHACKNYC/ArrivalDepartures?lineIds=weaver");
});

test("Redbridge to Liverpool Street: only the westbound trains, not the ones round the Hainault loop", () => {
  const trains = nextTrains(parseArrivals(fixture("tfl-arrivals-central.json")), ride("central", "Central line", "tube", ["940GZZLURBG", "Redbridge"], ["940GZZLULVT", "Liverpool Street"]), central, NOW);
  assert.deepEqual(trains.map((t) => clock(t.at)), ["19:17", "19:24"]);
  assert.ok(trains.every((t) => !t.cancelled && t.late === undefined), "arrivals have no timetable to be late against");

  const east = nextTrains(parseArrivals(fixture("tfl-arrivals-central.json")), ride("central", "Central line", "tube", ["940GZZLURBG", "Redbridge"], ["940GZZLUNBP", "Newbury Park"]), central, NOW);
  assert.deepEqual(east.map((t) => clock(t.at)), ["19:22", "19:27", "19:33", "19:37"], "the other way, four at most");
});

test("a train calls where you get off when that's between here and where it ends, either way along the line", () => {
  const key = (id: string) => central.keyOf.get(id)!;
  const [rbg, lvt, nbp] = ["940GZZLURBG", "940GZZLULVT", "940GZZLUNBP"].map(key);
  assert.equal(callsAt(central, rbg, lvt, "940GZZLUWRP"), true, "to West Ruislip via Liverpool Street");
  assert.equal(callsAt(central, rbg, lvt, "940GZZLUHLT"), false, "to Hainault via Newbury Park");
  assert.equal(callsAt(central, rbg, nbp, "940GZZLUHLT"), true);
  assert.equal(callsAt(central, rbg, lvt, "940GZZLUSTD"), false, "ending at Stratford, short of Liverpool Street");
  assert.equal(callsAt(central, rbg, lvt, "9400NOWHERE"), undefined, "a destination that isn't on the line");
});

test("Paddington to Liverpool Street: eastbound only, with delays, and no trains that end here", () => {
  const predictions = parseDepartures(fixture("tfl-departures-elizabeth.json"));
  assert.ok(predictions.every((p) => p.destination !== "910GPADTLL" || p.scheduled !== undefined), "a train ending here has no departure");
  const trains = nextTrains(predictions, ride("elizabeth", "Elizabeth line", "elizabeth-line", ["910GPADTLL", "Paddington"], ["910GLIVSTLL", "Liverpool Street"]), elizabeth, NOW, 6);
  assert.deepEqual(trains.map((t) => [clock(t.at), t.late ?? 0]), [["19:18", 0], ["19:20", 5], ["19:26", 6], ["19:26", 3], ["19:30", 0], ["19:36", 3]]);

  const cancelled = parseDepartures([{ scheduledTimeOfDeparture: "2026-11-25T19:40:00Z", estimatedTimeOfDeparture: "2026-11-25T19:52:00Z", departureStatus: "Cancelled", destinationNaptanId: "910GSHENFLD", platformName: "Platform A" }]);
  assert.deepEqual(cancelled, [{ at: Date.parse("2026-11-25T19:40:00Z"), scheduled: Date.parse("2026-11-25T19:40:00Z"), cancelled: true, destination: "910GSHENFLD", platform: "Platform A" }],
    "a cancelled train keeps its timetabled time");
});

test("a train TfL gives no destination for counts on a platform the others going your way use", () => {
  const follow = ride("central", "Central line", "tube", ["940GZZLURBG", "Redbridge"], ["940GZZLULVT", "Liverpool Street"]);
  const at = (minutes: number) => NOW + minutes * 60_000;
  const trains = nextTrains([
    { at: at(2), cancelled: false, destination: "940GZZLUWRP", platform: "Outer Rail - Platform 1" },
    { at: at(5), cancelled: false, platform: "Outer Rail - Platform 1" },
    { at: at(6), cancelled: false, platform: "Inner Rail - Platform 2" },
    { at: at(5) + 10_000, cancelled: false, platform: "Outer Rail - Platform 1" },
    { at: at(-2), cancelled: false, destination: "940GZZLUWRP", platform: "Outer Rail - Platform 1" },
  ], follow, central, NOW);
  assert.deepEqual(trains.map((t) => clock(t.at)), ["19:17", "19:20"], "one train listed twice is one; gone ones are gone");
});
