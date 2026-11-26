// How a line is drawn: its pill name, the mode's symbol and TfL's colour, for what the server
// itself puts on a phone (a Live Activity it starts, the disc a line's notification comes from).

/** "Central line" → "Central", as the line's pill says it. */
export const pillName = (name: string) => name.replace(/ line$/i, "");

/** The SF Symbol the app draws for the mode (LegMode.symbol). */
export function symbolFor(mode: string): string {
  if (mode === "tube") return "tram.fill.tunnel";
  if (mode === "dlr" || mode === "tram") return "tram.fill";
  return "train.side.front.car";
}

// TfL's line colours, as the app's LineColors has them.
const COLOURS: Record<string, string> = {
  bakerloo: "B36305", central: "E32017", circle: "FFD300", district: "00782A", "hammersmith-city": "F3A9BB",
  jubilee: "A0A5A9", metropolitan: "9B0056", northern: "2B2B2B", piccadilly: "1C3F94", victoria: "0098D4",
  "waterloo-city": "95CDBA", elizabeth: "6950A1", dlr: "00A4A7", liberty: "61686B", lioness: "FFA32B",
  mildmay: "2E86F0", suffragette: "59C274", weaver: "A0457A", windrush: "EF4D5E", tram: "5FB526",
};
const MODE_COLOURS: Record<string, string> = { tube: "1C3F94", overground: "EE7C0E", "elizabeth-line": "6950A1", dlr: "00A4A7", tram: "5FB526" };
export const colourFor = (lineId: string, mode: string): string | undefined => COLOURS[lineId] ?? MODE_COLOURS[mode];
