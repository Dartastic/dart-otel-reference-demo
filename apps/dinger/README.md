# Dinger ⚾

Last night's baseball, with **live stats from the MLB Stats API**, recaps
written by **Genkit running on Dartastic OpenTelemetry**, and every step lighting
up **Dartastic Hosted**.

This is the demo for the blog post: *"I ripped Workiva's OpenTelemetry out of
Genkit and dropped in Dartastic. Same OTel — it's a standard, so it just worked
— and here's a fun app pulling last night's Ohtani highlights with Dartastic
Hosted lighting up live."*

## What it does

1. Resolves your favorite players to MLB ids and pulls each one's most recent
   real game from the **MLB Stats API** (`statsapi.mlb.com`). No invented stats.
2. You tap **Generate highlight** → a **Genkit flow** (`playerHighlight`) runs:
   Gemini **calls the `getPlayerLastGame` tool** to fetch the real box score,
   then returns **structured output** — a typed `Recap {headline, body,
   funFact}` (no free-text parsing). Without a key, the flow exercises the same
   tool path directly and templates the Recap from the real stats.
3. **Watch on MLB** opens the real highlight clip for that game on MLB's own
   player (or [MLB Film Room reels](https://www.mlb.com/video/topic/mlb-film-room-reels)
   if no clip is tagged for the player).
4. Genkit here runs on Dartastic OpenTelemetry, so the flow auto-emits
   `genkit:*` spans, and the MLB calls emit client spans — all streaming over
   OTLP to your Dartastic Hosted box, where you watch the trace light up.

Edit the favorites in `lib/data_source.dart` (`kFavorites`). Names are matched to
MLB's roster at runtime (accents optional); anyone not in MLB is skipped — never
faked.

## The trace you'll see

```
load_lineup
├─ mlb.players_index           (GET /sports/1/players)
└─ mlb.gamelog × N             (GET /people/{id}/stats?stats=gameLog)

generate_highlight             (app span — player, home_runs)
└─ playerHighlight             (genkit flow — structured Recap output)
   └─ gemini-2.5-flash         (model decides to call a tool)
      └─ getPlayerLastGame     (genkit tool — genkit:name/type/input/output)
         └─ mlb.gamelog        (GET /people/{id}/stats — the real box score)

load_highlights                (GET /game/{gamePk}/content)
```

That nested trace — flow → model → **tool call** → live MLB fetch — is the
screenshot: the LLM orchestrating a real data fetch *through Genkit*, all
observed by Dartastic.

## Run it

Needs network (it's live). Desktop/mobile are simplest. Ships inside the OSS
reference demo as a self-contained app (not a workspace member, so the weather
demo stays dependency-clean). By default it exports to the demo's own local LGTM
stack, so Dinger's traces land in the **same Grafana** as the rest of the demo.

```sh
# From the repo root, bring up the demo's LGTM (Grafana :3000, OTLP :4318):
tool/stack.sh up

cd apps/dinger
flutter pub get

# Typed tool/output schemas are generated from lib/schemas.dart — regenerate
# after editing it:
dart run build_runner build

# Default OTEL endpoint is http://localhost:4318 → the demo's LGTM. Just run:
flutter run
# then open http://localhost:3000 (admin/admin) → Explore → Tempo.

# Light up Dartastic Hosted + use real Gemini:
flutter run \
  --dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=https://<your-box>.dartastic.io \
  --dart-define=DARTASTIC_TENANT=<your-tenant> \
  --dart-define=DARTASTIC_API_KEY=<your-key> \
  --dart-define=GEMINI_API_KEY=<your-gemini-key>
```

- No `GEMINI_API_KEY` → recaps come from the template fallback (still real
  stats, still traced). The app never *needs* a key to demo the telemetry.
- Hosted auth header names (`x-dartastic-tenant`, `x-dartastic-api-key`) live in
  `lib/telemetry.dart` — adjust to what your box expects.
- macOS: debug runs have the network entitlement; for a release build add
  `com.apple.security.network.client` to `macos/Runner/Release.entitlements`.
- Web: `statsapi.mlb.com` may block browser CORS, and calling Gemini from the
  client exposes the key — run a Dart proxy for a web build.

## Highlights & MLB's rules

The MLB Stats API and MLB video are for **personal, non-commercial use**. Dinger
reads box-score stats and highlight **metadata**, and **links** to MLB's own
video player (mlb.com / Film Room). It does **not** re-host or embed MLB's
video stream — that's the part that would violate their terms in a real product.
The content API does hand back direct `.mp4`/HLS URLs; playing them in-app is
technically possible but is a rights/ToS risk, so it's intentionally not done
here. (For a strictly private demo you could, at your own risk.)

## Dependency note (why the path/git deps)

The published `genkit` on pub.dev still uses Workiva's `opentelemetry`. The
Dartastic swap lives in the local Genkit clone, so `pubspec.yaml` uses:

- `genkit` + `genkit_google_genai` via **path** to `../genkit-dart`, and
- a `dependency_overrides` pin of `dartastic_opentelemetry` to the
  `feat/late-binding-proxies` branch (the beta has unreleased late-binding
  fixes Genkit relies on).

Once a Genkit release ships the Dartastic dependency and those fixes publish,
this becomes a clean pub.dev `flutter pub get`.

## What to screenshot for the blog

1. The app: a player card with the live stat line, the AI recap, and the
   "Watch on MLB" button.
2. Grafana on your Hosted box: the `generate_highlight` → `playerHighlight` →
   Gemini trace next to the `load_lineup` → `mlb.gamelog` HTTP spans.
3. The one-line `pubspec.yaml` diff: Workiva `opentelemetry` out,
   `dartastic_opentelemetry` in.
