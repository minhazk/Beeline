#!/usr/bin/env python3
"""Writes BeelineTests/Fixtures/google-routes.json: a hand-written Google Routes answer.

Google's terms don't allow republishing its responses, so the test fixture is invented, in the
shape computeRoutes returns for the field mask GoogleRoutesProvider asks for. Six routes from
King's Cross to Canary Wharf; times, stop counts and paths are made up (paths join approximate
public station positions), line names are spelled as the operators spell them.
Run from the repo root: python3 scripts/make-google-fixture.py
"""
import json
from datetime import datetime, timedelta, timezone

STATIONS = {  # approximate public positions
    "King's Cross St. Pancras": (51.5308, -0.1238), "Angel": (51.5322, -0.1058), "Old Street": (51.5263, -0.0873),
    "Moorgate": (51.5186, -0.0886), "Bank": (51.5133, -0.0890), "London Bridge": (51.5052, -0.0864),
    "Shadwell": (51.5117, -0.0567), "Limehouse": (51.5123, -0.0397), "Westferry": (51.5097, -0.0265),
    "West India Quay": (51.5070, -0.0203), "Canary Wharf": (51.5058, -0.0181), "Canary Wharf DLR": (51.5048, -0.0209),
    "Farringdon": (51.5203, -0.1053), "Barbican": (51.5204, -0.0979), "Liverpool Street": (51.5178, -0.0823),
    "Whitechapel": (51.5195, -0.0599), "Euston": (51.5282, -0.1337), "Warren Street": (51.5247, -0.1384),
    "Oxford Circus": (51.5152, -0.1415), "Green Park": (51.5067, -0.1428), "Westminster": (51.5010, -0.1254),
    "Waterloo": (51.5036, -0.1143), "Southwark": (51.5041, -0.1052), "Bermondsey": (51.4979, -0.0637),
    "Canada Water": (51.4982, -0.0502), "Canary Wharf Jubilee": (51.5035, -0.0187),
}
START, END = (51.5308, -0.1238), (51.5049, -0.0195)  # King's Cross; One Canada Square


def encode(points):
    out, prev = [], (0, 0)
    for lat, lng in points:
        cur = (round(lat * 1e5), round(lng * 1e5))
        for d in (cur[0] - prev[0], cur[1] - prev[1]):
            v = ~(d << 1) if d < 0 else d << 1
            while v >= 0x20:
                out.append(chr((0x20 | (v & 0x1F)) + 63))
                v >>= 5
            out.append(chr(v + 63))
        prev = cur
    return "".join(out)


def walk(seconds, metres, a, b):
    return {"distanceMeters": metres, "staticDuration": f"{seconds}s", "polyline": {"encodedPolyline": encode([a, b])}, "travelMode": "WALK"}


def at(hhmm):
    h, m = map(int, hhmm.split(":"))
    return datetime(2026, 10, 28, h, m, tzinfo=timezone.utc)  # GMT season: London time is UTC


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def clock(t):
    return t.strftime("%-I:%M %p")


LINES = {
    "Northern": {"name": "Northern Line", "nameShort": "Northern", "color": "#000000", "textColor": "#ffffff", "vehicle": "SUBWAY", "agency": "Transport for London"},
    "Victoria": {"name": "Victoria Line", "nameShort": "Victoria", "color": "#0098d4", "textColor": "#ffffff", "vehicle": "SUBWAY", "agency": "Transport for London"},
    "Jubilee": {"name": "Jubilee line", "nameShort": "Jubilee", "color": "#a0a5a9", "textColor": "#ffffff", "vehicle": "SUBWAY", "agency": "Transport for London"},
    "Hammersmith & City": {"name": "Hammersmith & City Line", "nameShort": "Hammersmith & City", "color": "#f3a9bb", "textColor": "#000000", "vehicle": "SUBWAY", "agency": "Transport for London"},
    "DLR": {"nameShort": "DLR", "color": "#00a4a7", "textColor": "#ffffff", "vehicle": "TRAM", "agency": "Transport for London"},
    "Elizabeth line": {"nameShort": "Elizabeth line", "color": "#6950a1", "textColor": "#ffffff", "vehicle": "HEAVY_RAIL", "agency": "Elizabeth line"},
}
VEHICLE_NAMES = {"SUBWAY": "Subway", "TRAM": "Light rail", "HEAVY_RAIL": "Train"}


def ride(line, stops, dep, arr, headsign, headway=None, names=None):
    spec = LINES[line]
    d, a = at(dep), at(arr)
    names = names or (stops[0], stops[-1])
    points = [STATIONS[s] for s in stops]
    metres = int(sum(((p[0] - q[0]) ** 2 + ((p[1] - q[1]) * 0.62) ** 2) ** 0.5 * 111_000 for p, q in zip(points, points[1:])))
    transit_line = {k: v for k, v in spec.items() if k in ("name", "nameShort", "color", "textColor")}
    transit_line["agencies"] = [{"name": spec["agency"], "uri": "https://tfl.gov.uk"}]
    transit_line["vehicle"] = {"name": {"text": VEHICLE_NAMES[spec["vehicle"]]}, "type": spec["vehicle"]}
    details = {
        "stopDetails": {
            "arrivalStop": {"name": names[1], "location": {"latLng": {"latitude": points[-1][0], "longitude": points[-1][1]}}},
            "arrivalTime": iso(a),
            "departureStop": {"name": names[0], "location": {"latLng": {"latitude": points[0][0], "longitude": points[0][1]}}},
            "departureTime": iso(d),
        },
        "localizedValues": {"arrivalTime": {"time": {"text": clock(a)}, "timeZone": "Europe/London"},
                            "departureTime": {"time": {"text": clock(d)}, "timeZone": "Europe/London"}},
        "headsign": headsign,
        "transitLine": transit_line,
        "stopCount": len(stops) - 1,
    }
    if headway:
        details["headway"] = f"{headway}s"
    return {"distanceMeters": metres, "staticDuration": f"{int((a - d).total_seconds())}s",
            "polyline": {"encodedPolyline": encode(points)}, "transitDetails": details, "travelMode": "TRANSIT"}


def route(steps, first_walk, last_walk):
    rides = [s for s in steps if s["travelMode"] == "TRANSIT"]
    start = datetime.fromisoformat(rides[0]["transitDetails"]["stopDetails"]["departureTime"].replace("Z", "+00:00")) - timedelta(seconds=first_walk)
    end = datetime.fromisoformat(rides[-1]["transitDetails"]["stopDetails"]["arrivalTime"].replace("Z", "+00:00")) + timedelta(seconds=last_walk)
    return {"duration": f"{int((end - start).total_seconds())}s", "legs": [{"steps": steps}],
            "localizedValues": {"transitFare": {"text": "£3.10"}}}


KX, CW = STATIONS["King's Cross St. Pancras"], STATIONS["Canary Wharf"]
NORTHERN_BANK = ["King's Cross St. Pancras", "Angel", "Old Street", "Moorgate", "Bank"]
DLR_BANK = ["Bank", "Shadwell", "Limehouse", "Westferry", "West India Quay", "Canary Wharf DLR"]


def northern_dlr(dep, arr, dlr_dep, dlr_arr):
    return route([
        walk(0, 10, START, START), walk(240, 190, START, KX),
        ride("Northern", NORTHERN_BANK, dep, arr, "Morden via Bank", 120, ("King's Cross St. Pancras", "Bank Station")),
        walk(180, 120, STATIONS["Bank"], STATIONS["Bank"]),
        ride("DLR", DLR_BANK, dlr_dep, dlr_arr, "Lewisham", None, ("Bank Station", "Canary Wharf")),
        walk(90, 110, STATIONS["Canary Wharf DLR"], CW), walk(120, 150, CW, END),
    ], 240, 210)


routes = [
    northern_dlr("12:04", "12:13", "12:18", "12:30"),
    northern_dlr("12:09", "12:18", "12:23", "12:35"),
    route([
        walk(0, 10, START, START), walk(180, 160, START, KX),
        ride("Hammersmith & City", ["King's Cross St. Pancras", "Farringdon"], "12:05", "12:08", "Barking via Liverpool St", 180),
        walk(150, 300, STATIONS["Farringdon"], STATIONS["Farringdon"]),
        ride("Elizabeth line", ["Farringdon", "Liverpool Street", "Whitechapel", "Canary Wharf"], "12:14", "12:25", "Abbey Wood"),
        walk(120, 140, CW, CW), walk(100, 120, CW, END),
    ], 180, 220),
    route([
        walk(0, 10, START, START), walk(240, 190, START, KX),
        ride("Victoria", ["King's Cross St. Pancras", "Euston", "Warren Street", "Oxford Circus", "Green Park"], "12:06", "12:14", "Brixton", 120),
        walk(240, 250, STATIONS["Green Park"], STATIONS["Green Park"]),
        ride("Jubilee", ["Green Park", "Westminster", "Waterloo", "Southwark", "London Bridge", "Bermondsey", "Canada Water", "Canary Wharf Jubilee"], "12:19", "12:35", "Stratford", 120, ("Green Park", "Canary Wharf")),
        walk(240, 300, STATIONS["Canary Wharf Jubilee"], END),
    ], 240, 240),
    route([
        walk(0, 10, START, START), walk(240, 190, START, KX),
        ride("Northern", NORTHERN_BANK + ["London Bridge"], "12:09", "12:20", "Morden via Bank", 60, ("King's Cross St. Pancras", "London Bridge")),
        walk(180, 60, STATIONS["London Bridge"], STATIONS["London Bridge"]),
        ride("Jubilee", ["London Bridge", "Bermondsey", "Canada Water", "Canary Wharf Jubilee"], "12:25", "12:31", "Stratford", 120, ("London Bridge", "Canary Wharf")),
        walk(240, 300, STATIONS["Canary Wharf Jubilee"], END),
    ], 240, 240),
    route([
        walk(0, 10, START, START), walk(180, 160, START, KX),
        ride("Hammersmith & City", ["King's Cross St. Pancras", "Farringdon", "Barbican", "Liverpool Street"], "12:11", "12:18", "Barking via Liverpool St", 180),
        walk(240, 350, STATIONS["Liverpool Street"], STATIONS["Liverpool Street"]),
        ride("Elizabeth line", ["Liverpool Street", "Whitechapel", "Canary Wharf"], "12:24", "12:31", "Abbey Wood"),
        walk(220, 260, CW, END),
    ], 180, 220),
]

with open("BeelineTests/Fixtures/google-routes.json", "w") as f:
    json.dump({"routes": routes}, f, indent=1, ensure_ascii=False)
    f.write("\n")
print("wrote", len(routes), "routes")
