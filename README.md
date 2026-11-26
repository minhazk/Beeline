# Beeline

Beeline is an iOS fork of [Polaris](https://github.com/VDEData/polaris). The Xcode project and scheme are named `Beeline`. App Store Connect and TestFlight list it as **Beeline: Maps and Navigation** under the bundle ID `com.cloudslope.beeline`.

An iOS app for getting around London (and the rest of Great Britain) that asks several
journey planners the same question and shows every answer in one ranked list, because
each has blind spots: one says 50 minutes, another swears 75 is the best you can do.
Then it takes you there: live departure boards, turn-by-turn walking, a Live Activity,
and alerts for the lines you ride every day.

SwiftUI for iOS 26 and later, Swift 6 with strict concurrency, no third-party packages.
The optional alerts server is a small Cloudflare Worker in `worker/`.

It began as one person's app, so it is tuned for London: TfL is the richest source, and
alerts, disruptions and live buses are TfL's. Transitous and Google work anywhere they
have data.

## Sources

| Source | What it gives | Key |
|---|---|---|
| Google Routes API (`TRANSIT`) | Full routes, several alternatives per query, fares | Optional: `GOOGLE_ROUTES_API_KEY` |
| TfL Journey Planner | London's official planner incl. National Rail, live running | Optional: `TFL_APP_KEY` (50 req/min without) |
| Transitous (MOTIS) | Open GB timetables: rail, BODS buses, Underground | None |
| Apple MapKit | Transit **ETA only** (MapKit returns no route for `.transit`) | None |
| Citymapper, Google Maps, Apple Maps apps | One-tap hand-off with the same trip filled in | None |

Citymapper and Waze have no usable API (Citymapper closed theirs in June 2023;
Waze has no transit), so Citymapper is a link to its own site, which opens its app when it's installed.

**Search more route options** (on by default) asks Google five ways (fastest, fewer changes,
less walking, rail only, bus only) and TfL three ways. Most "blind spots" are
ranking rather than missing data, and the variants surface routes a source knows
about but buries. Results with the same lines boarding within 4 minutes merge
into one journey with every source's badge, and later departures on the same
lines fold into one card ("Or leave at 15:08 or 15:18").

**Google's free allowance.** Google is used only inside its free monthly allowance
(planned to the lowest cap, 1,000 requests). The phone counts every Google request
in Google's own month (Pacific time, `GoogleUsage`): deep search asks all five ways
under 700, one way under 900, and not at all past 900, when routes come from TfL and
Transitous alone. The count is in Settings → Service connections → Google Routes.

**Live map and Go.** Everything sits on one live map with a sheet over it, as in
Apple and Google Maps, with your dot's beam showing which way the phone faces:
home (search, Home/Work, recents, what's leaving near you),
then the routes, then a journey, then Go. Go follows you on the map, gives
turn-by-turn on every walk (MapKit walking directions, re-routed when you stray),
says whether you'll make the next departure ("2 min to spare", "you'll miss the
18:47; the next is 18:49, 2 min later at Farringdon"), moves leg by leg on its own
(by location on foot, by the clock underground), and sends a "get off next" alert
before each stop off. A Live Activity keeps the current step and a countdown on
the Lock Screen and in the Dynamic Island, with what missing your ride costs you at
the end of the trip ("If missed +8 min · Next 11:59, misses the 12:04 Elizabeth"):
the next one is followed through every later change on its departure board.
If you're already aboard (an earlier bus, or Go started once you'd got on), Go sees
you moving along the ride faster than anyone walks and catches up; one button says
it for you ("I'm on the 25", "I've got off"), and any step can be tapped to jump to it.

**Re-planning during Go**, as a satnav does. When you're early or late Go re-times
the trip and says so plainly ("You're early: the 07:00 277. Arrive 07:14, 20 min
sooner"). When that leaves a long wait at a change (10 min or more, 7 more than
planned), loses a connection or a missed ride makes you 8 min late, or the planned
departure ahead is cancelled, it asks the planners once, from the next stop you'll be
at and when the re-timed trip has you there (not your GPS underground). A new way is
offered only if it gets there 5 min sooner, or 15% of the time left if that's more,
less 3 min per extra change, and TfL flags nothing on it: in the sheet (Switch or
Keep my route), the banner, the map (outlined in blue), the Live Activity and one
ordinary notification with the same two buttons. Switch keeps what you've done and
carries on by the new way; Keep isn't asked again for the same reason. "Find a faster
way" asks by hand. Nothing better and a long wait is a line in the sheet, never a
notification. Go never switches route on its own. If TfL's status can't be had, the
offer still comes and says the line status couldn't be checked. Each search is at most
5 requests (Google, TfL and Transitous once each, never their deep-search variants,
plus TfL's status if older than 3 minutes), and a trip makes at most 3, answered or
not, 4 minutes apart: 15 requests, Google 3, at most. Nothing goes without a network
connection, and nothing runs on a timer.

**Next trains on the Lock Screen.** A line near you, a departure board, or a journey (Next
train, beside Go) can put the next three trains from that station on the Lock Screen and in the
Dynamic Island: a countdown to the next, and each train as a dot on a line from now, so the gaps
show at a glance, with late ones and cancellations in orange and trouble TfL reports on your stretch. A saved line can start it by itself at its travel times
(Next trains on Lock Screen in the alert) and take it away when each time ends. With an alerts
server and a TfL line (Underground, Elizabeth line, Overground, DLR, trams), the server keeps it
live while Beeline is closed: each minute it asks TfL for that station's trains, keeps the ones
that call where you get off (by the line's station order, so a Central line train round the
Hainault loop isn't yours), and pushes only news: a train gone, a new estimate, a cancellation.
Without a server, or on National Rail, it shows the timetable, refreshed while Beeline is open.

**Live buses.** Tap a bus line leaving near you, or "Where are the buses?" on a bus
ride, and London's buses on that line show on the map, each with how soon it reaches
your stop. TfL publishes no bus GPS, only each bus's predicted arrival at the stops
ahead (Countdown), so a bus is placed between the stop it last passed and the next
by how soon it's due there. During Go the bus you're waiting for or riding is shown,
and its live times replace the timetable's: whether you'll make it and what the next
one costs come from TfL's buses on the way, and once you're on, from your own bus.

**Disruptions.** Each search also asks TfL for the whole network's status (every
line, every closed or skipped station, National Rail operators included) and checks
every source's routes against it. The planner that knew about a closure routes round
it and says nothing; the ones that didn't put you straight through it. So a route
that gets on or off at a closed station, or rides a closed stretch, is flagged in
orange and can't be "Best"; it goes under the others. What's reported shows at the
top of the list, in TfL's own words, and on the leg it touches.

**Line alerts.** Tap Alerts → Add a line on the home screen, or use the bell on a journey.
Choose your line, boarding and exit stations, travel days, and times. Each time can have
its own direction. You can save the schedule before connecting a notification server. A small
Cloudflare Worker (`worker/`, which you host yourself: see below) checks TfL every two minutes
during those times and sends a push for trouble on the track you ride: the stations TfL
lists against a disruption, or else the sections its notice names ("between Paddington
and Heathrow"), placed on the line's station order. A section that only meets your
stretch at one station doesn't count; one TfL can't place, or a notice that names none,
does. Each alert can be set to one way (out or back): then trouble TfL reports as one way
only ("westbound", "towards Heathrow") counts only that way. The push is: Time Sensitive for closures and delays (so it comes through a Focus), ordinary for
minor delays, quiet for "good service again". Planned works on tomorrow's trips come at
7 pm the evening before. One notification per disruption, again only if it gets worse.
The home page shows each saved line's status.

**London-wide strike alerts.** Turn on **London-wide strike alerts** in **Line alerts**
and allow notifications. This works with an alerts server even when you have no saved lines.
Beeline checks TfL's current notices and looks 30 days ahead across the Tube, London buses,
Elizabeth line, DLR, Overground, National Rail services listed by TfL, trams, river buses
and cable car. Upcoming strike notifications give dates in London time. Ongoing action
gets a Time Sensitive notification, including when a previously announced strike starts.

**Departure boards.** Every boarding stop shows the departures around yours, the
ones that have just gone too, filtered to those that stop where you get off, with
what each does to your arrival there ("+3 min", "−2 min") and the line's status.
They come from Transitous's stop times (one request per board, kept for a minute).

**Places.** Search takes a chain or a kind of place as well as an address: "Apple
Store" lists every one nearby with its distance and Apple's public transport time,
quickest first, and ⓘ opens Apple Maps' card for it (opening hours, photos,
reviews). A bus ride says what walking the same stretch would take.

**Ranking** (`JourneyRanker`). Each sort (Best, Fastest, Fewest changes, Least
walking) is a generalised cost: arrival time plus minutes charged per change and
per minute walked, weighted differently per sort, so a minute less walking never
beats an hour quicker. A card shows if it's close to the best on the balanced
score or the chosen sort's own; anything beaten on time, changes *and* walking
(allowing a minute or two of noise between sources) folds under "more routes".
Filters (max changes, max walking, modes to avoid) are remembered, and the list
says how many routes they hid.

## Build from source

The app runs on iOS 26 and later. Build with Xcode 27.2 and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) on a Mac. The source includes iOS 27.1 fold-aware layout APIs
behind availability checks. Generate the Xcode project from the checked-in project specification.

1. Clone the repo and run `scripts/generate.sh`. It copies `Config/Secrets.example.xcconfig`
   to `Config/Secrets.xcconfig` (git-ignored) the first time, then writes `Beeline.xcodeproj`.
   Run it again whenever you add a file.
2. Open `Beeline.xcodeproj`, select the `Beeline` scheme, pick an iPhone simulator and run. With no keys at all it works:
   TfL (keyless), Transitous and Apple's estimates answer, and Google is shown as needing a key.
3. For your own iPhone, set in `Config/Secrets.xcconfig`:
   - `BEELINE_BUNDLE_ID`, if your team needs a different bundle ID (for example, `com.yourname.beeline`); the widget and
     tests add `.widgets` and `.tests`;
   - `DEVELOPMENT_TEAM`, your Apple team ID (developer.apple.com, Membership).
   A free Apple account can install it for a week at a time, but can't sign the push and
   Time Sensitive entitlements alerts need; for those you need the paid Apple Developer Program.
   If signing complains about them on a free account, delete those two keys from
   `Beeline/Resources/Beeline.entitlements` in your copy.
4. TfL and Transitous requests identify Beeline with its public repository URL. Set
   `BEELINE_CONTACT` to change that build-time contact.

`Config/Base.xcconfig` holds the defaults and includes your `Secrets.xcconfig` last, so
anything you set there wins. In an xcconfig `//` starts a comment: write URLs as
`https:/$()/host`.

`scripts/testflight.sh --upload` archives and uploads to App Store Connect (`--no-upload`
exports the `.ipa` only). It is for shipping to your own account (it needs your bundle ID, team
and an app record there); building for yourself doesn't need it. It ships what is committed, and
refuses a build with a Google key, TfL key or alerts invitation compiled in unless you add
`--embed-keys`.

### Keys

A new install opens on the map. The optional setup link on the home sheet explains each service.
You can also configure these services in Settings. Anything entered in the app is kept in the Keychain and beats the build-time value
from `Config/Secrets.xcconfig`. Prefer the app:
anything in the xcconfig is compiled into the app, where anyone with the `.ipa` can read it.

| Key | Where to get it | Without it |
|---|---|---|
| `GOOGLE_ROUTES_API_KEY` | [Google Cloud console](https://console.cloud.google.com): enable **Routes API**, create an API key restricted to iOS apps with your bundle ID and to the Routes API only | No Google routes |
| `TFL_APP_KEY` | [TfL API portal](https://api-portal.tfl.gov.uk): subscribe, copy the primary key | TfL still answers, at 50 requests a minute |
| `BEELINE_ALERTS_URL`, `BEELINE_ALERTS_TOKEN` | Your own alerts server, below | Alerts are off |
| `BEELINE_CONTACT` | A public contact for the build's open-data requests | Uses the Beeline repository URL by default |

## Run your own alerts server

Alerts need a server that watches TfL while the app is closed and sends pushes. There is no
shared one: each person who wants alerts runs their own `worker/`, which fits in Cloudflare's
free plan for a handful of phones. Without one, the app makes no alert requests and doesn't
ask for push permission; the Alerts page says what to set up.

You need a Cloudflare account, Node 24 or later with pnpm, and, for the pushes themselves, a
paid Apple Developer Program membership: only that can make the APNs key that lets your server
send notifications to your build of the app, and sign the app with the push entitlement.

1. `cd worker && pnpm install --frozen-lockfile` (the pnpm version is pinned in `package.json`), then
   `pnpm exec wrangler login`.
2. Create the database: `pnpm exec wrangler d1 create beeline-alerts`. Copy
   `wrangler.local.example.jsonc` to `wrangler.local.jsonc` (git-ignored) and put the printed
   `database_id` in it. `pnpm run deploy` and `pnpm run migrate` lay that file over
   `wrangler.jsonc`, and refuse to run while the id is still the placeholder.
3. In the same file set `APNS_TEAM_ID` (your team ID) and `APNS_TOPIC` (exactly your
   `BEELINE_BUNDLE_ID`). Add a `routes` entry only if you want your own domain; otherwise the
   Worker is served at `beeline-alerts.<your-subdomain>.workers.dev`.
4. `pnpm run migrate` creates the tables.
5. Make an APNs key: developer.apple.com, Certificates, Identifiers & Profiles, Keys, a new
   key with Apple Push Notifications service (Sandbox & Production). Download the `.p8` once.
6. Set the secrets, through the same wrapper as the deploy so they go to the Worker your
   `wrangler.local.jsonc` names (a bare `wrangler secret put` reads only `wrangler.jsonc`):
   ```sh
   openssl rand -hex 32 >> invitations.txt                          # one invitation for each phone, one per line
   pnpm run wrangler secret put APP_TOKEN < invitations.txt         # the whole list, read from stdin
   pnpm run wrangler secret put APNS_KEY < AuthKey_ABC123DEFG.p8    # the whole key file, read from stdin
   pnpm run wrangler secret put APNS_KEY_ID                         # the key's 10-character ID
   pnpm run wrangler secret put TFL_APP_KEY                         # free from api-portal.tfl.gov.uk
   ```
   These are secrets, never `vars`: a var is plain text in the dashboard and the config, and
   the wrapper refuses to deploy one. Keep invitations long and random, as above; nothing
   slows down guessing a short one. Setting `APP_TOKEN` replaces the whole list, and typed at
   wrangler's prompt it takes one line only, so keep the list in a file outside the repository
   and send all of it each time.
   The TfL key is needed: Cloudflare's addresses are shared, and TfL answers keyless requests
   from them with 429 (rate limited), so without one line checks fail.
7. `pnpm run deploy`. Check `https://<your worker>/health` says `{"ok":true,"pushes":true,"tflKey":true}`;
   `"pushes":false` means one of `APNS_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID` or `APNS_TOPIC` is
   missing, and until it's set the cron judges nothing, so no disruption is lost.
   `"tflKey":false` means `TFL_APP_KEY` isn't set.
8. Open Line alerts → Connect alerts server in a build without a configured service. Enter the server address and **that phone’s invitation**,
   then tap Use this server. Under Line alerts, save a line or enable London-wide strike alerts,
   allow notifications, and choose Send a test notification.

Each invitation admits one phone at a time. Each install also sends a random device secret so
only its owner can change, test or remove the registration; the same install with a new push
token (after a reinstall, or a restore to a new phone) takes over its own registration; restore
to a second phone and keep using the first, and alerts go to whichever was opened last. Taking
an invitation out of `APP_TOKEN` refuses its phone's requests at once and removes the phone it
admitted a day later (a line left out by mistake can be put back within the day; an `APP_TOKEN`
with nothing in it is every invitation taken out). Phones
registered before invitations were recorded aren't tied to one: remove those in D1. Run the
database migrations before updating the Worker: `0005` removes registrations from before device
secrets, which no phone could change or remove (their phones register again when next opened).

Next-train Live Activities use the same APNs key (Apple sends them on the app's
`.push-type.liveactivity` topic). The Worker updates them from a second, once-a-minute cron that
reads D1 and stops when none is showing; each invitation's phone can have four followed at once.
Migration `0006` adds their table.
`MAX_DEVICES` (a var, default 100; `0` takes no new phones) caps how many phones it keeps.
`MAX_PUSHES_PER_RUN` (a var, default 12) is the most notifications one two-minute check sends;
the rest go at the next. Twelve fits the Workers Free plan's 50 requests and 50 database queries
an invocation (a run counts its queries and stops short of them); on Workers Paid it can be
raised, up to 250, which also lifts the query allowance a run keeps to. The Free plan suits a
handful of phones whose owners you trust: every request is a database write, and D1's daily
allowance on Free is shared by them all.

What the server keeps for a phone is its push token, the lines, stations and times of its
alerts, its London-wide strike preference, and its time zone. It goes when you remove the
last subscription, change server, or turn
notifications off for Beeline (the next time the app is in front), and when Apple says the app
has gone from the phone: a phone not
heard from in a month is asked after with a push that shows nothing, so a deleted app's
registration doesn't stay. A push token Apple keeps refusing is asked ever less often, then
forgotten.

Nothing changes until you tap Use this server (or finish the setup step with an address and
token filled in); leaving Settings with a half-typed server keeps the one in use. Changing
server first removes this phone from the old server, using the old server's own token and
secret, then registers your saved alerts with the new one. Each server
gets its own device secret and the token entered with it, never the built-in one, so nothing
of one server's is sent to another. If the former server is unreachable, Settings reports the failure
and the phone retries the removal on a later launch.

The alerts worker checks line and mode selections against TfL's rail catalog. Every request an invitation makes is counted before anything is read or looked up: up to 12 a minute at a Cloudflare location, 30 a minute everywhere together, and 1,500 a day (12,000 a day for all invitations together). A request refused for any of these writes nothing. The scheduler uses separate batches for each mode and retries incomplete results at the next check. A status refresh answers for the alerts TfL could check and lists the rest as `unchecked`, with no verdict; planned works it couldn't get are marked `upcomingUnknown`. Only when no alert could be checked does it fail (503).

Development: `pnpm test` runs offline against the recorded TfL responses in
`BeelineTests/Fixtures`, which the app's tests share (`alert-contract.json` is the JSON the
app sends), and `pnpm exec tsc --noEmit` type-checks. To run it locally, put `APP_TOKEN=`
some test value in `.dev.vars` (see `.dev.vars.example`), `pnpm run migrate:local`, then
`pnpm run dev`; the simulator reaches it at `http://localhost:8787` (plain http is accepted
for localhost only, and only in debug builds and the simulator). To use recorded TfL answers
instead of TfL, serve them over HTTP and add `--var TFL_BASE:http://127.0.0.1:<port>`: only an
address on this machine is accepted, `TFL_APP_KEY` is never sent to it, and a deploy with it set
is refused. Without `APNS_KEY` it decides pushes but can't send.

## Being a good client

Every source here is free or has a free tier, run by people who ask for light use. Beeline
keeps to these limits, and changes should too:

- **Transitous** (volunteer-run): one request per search, never fanned out into variants.
  Departure boards are one stop-times request per board as it is shown, kept a minute;
  during Go only the next ride's board refreshes, once a minute. A descriptive User-Agent
  with `BEELINE_CONTACT`.
- **TfL**: network status is two requests per search, kept three minutes. A next-train Live
  Activity the alerts server follows is one request a minute for its station's trains (shared by
  every one at that station, kept 20 seconds), only while one is showing. Live buses are one
  arrivals request every 30 seconds while a bus line is on the map, and each line's route
  once per launch. For saved lines, the alerts server asks TfL while someone is inside their travel
  times: one line-status and one station-disruptions request per two-minute run, cached a
  minute, plus planned works once an evening, and a line's station order (about 200 KB) only
  for lines a saved alert needs, kept a week.
  When a phone subscribes to citywide strikes, the server also checks live status across
  all modes (cached for ten minutes) and rotates through dated forecasts in batches of
  up to 20 lines. All subscribed phones share these checks.
- **Google**: kept inside the free monthly allowance (counted per Google month on the phone:
  deep search asks five ways under 700 requests, one under 900, none past 900).
- **Re-plans during Go** happen only on an event or a tap, never on a timer: at most three
  searches a trip, four minutes apart, none without a network.

## Security

- A Google key set at build time ships inside the app, and its iOS restriction is only a
  header anyone can copy. Prefer entering it in Settings, restrict it to the Routes API,
  cap its daily quota and set a billing budget alert. For a wider audience, put it behind a
  small proxy instead.
- `APP_TOKEN` holds one random invitation per line. Distribute each invitation privately to one
  phone. A recipient can request status before enabling push and admit one new registration.
  To replace an invitation, update the Worker secret and the affected phone (Line alerts →
  Alerts server). Credentials compiled into a distributed IPA are readable by its recipients, so
  enter invitations in Settings; `scripts/testflight.sh` refuses a build with a key or invitation
  compiled in unless you pass `--embed-keys`.
- An invitation holder who also knows another phone's push token could register it first. The
  token is known only to that phone, Apple and the servers it registered with, so give
  invitations only to people you'd trust with that.
- Keys and tokens entered in the app are kept in the Keychain (not synced through iCloud
  Keychain; like other app data they are part of an encrypted backup of the phone and move with
  it to a new one) and go only to their own service. Alert requests refuse redirects and plain
  http (except localhost, in debug builds and the simulator). Replies are size-limited, and a
  server's error text isn't shown when it repeats this phone's credentials.
- Home, Work, favourites, recents and your alerts are kept in the app's preferences on the
  phone, so they are part of its backups. Go's Live Activity and trip notifications show the
  destination and next stop on the Lock Screen; trip notifications are cleared when the trip ends.
- Hand-offs to Citymapper and Google Maps use their own https links, never a custom URL scheme
  another app could claim. Nearby departures and a journey's departure boards come from
  Transitous, with your position or the stop's: turning Transitous off in Route sources turns
  them off too.
- Report a security problem through the repository's private vulnerability reporting
  (Security tab, Report a vulnerability), not in a public issue.

## Tests

Everything runs offline: the app's tests parse recorded TfL and Transitous responses and a
hand-written Google Routes answer in `BeelineTests/Fixtures` (Google's terms don't allow
republishing its responses; `scripts/make-google-fixture.py` writes that one), and the Worker's
tests share the TfL recordings.

```sh
xcodebuild test -project Beeline.xcodeproj -scheme Beeline -destination 'platform=iOS Simulator,name=iPhone 17'
cd worker && pnpm test && pnpm exec tsc --noEmit
```

If a recording is ever replaced, check it holds no key, token or personal location before committing it.

## Licence

MIT. See `LICENSE`.

## Layout

- `Beeline/Providers`: one file per source: request, response DTOs, mapping to `Journey`; `DepartureProvider` for boards and nearby departures; `TfLBuses` for live bus positions (`LiveBusStore` keeps them fresh).
- `Beeline/Engine`: `JourneyMerger` (same journey from several sources), `JourneyRanker` (sorts, filters, folding), `SearchModel` (fan-out, live status), `LiveTrip` and `PathProgress` (Go: legs, walking progress, connections).
- `Beeline/Views`: `RootView` (map plus sheet), `MapCanvas`, then one page per step: `HomeSheet`, `ResultsSheet`, `JourneySheet`, `BoardSheet`, `LineSheet` (a line at a stop near you, live), `LiveGuide`.
- `Beeline/Shared` and `BeelineWidgets`: the trip's Live Activity (the attributes are compiled into both targets).
- `worker/`: the alerts server: `match.ts` (which disruptions touch your stretch), `policy.ts` (when to tell you), `checks.ts` (the cron), `apns.ts`.
- `BeelineTests`: parsers against recorded Google/TfL/Transitous responses, boards, walking progress and leg-by-leg tracking, and the merge and ranking rules.
- `Beeline/Design/Theme.swift` defines the map and journey colours. The app and its trip Live Activity always use a dark appearance.

Launch flags for checking screens without tapping (Debug only): `-setup` shows the first-run setup step;
`-demoNextTrain` puts canned next Central line trains from Redbridge on the Lock Screen; `-demo -demoReplan
offer|wait|early` opens Go on a canned trip early onto the Bakerloo, with canned boards
and a canned planner answer, and asks no source at all; `-demo` plans King's
Cross → Canary Wharf, `-demoDetail` opens the best journey, `-demoGo` starts it,
and `-demoLeg N` starts Go at step N (from 0).
