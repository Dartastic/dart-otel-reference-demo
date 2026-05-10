# weather_flutter — Flutter web/wasm client

Simplest possible Flutter client for the demo's v1 weather API.
Demonstrates that the Dartastic OpenTelemetry SDK works in a
browser — both `dart2js` (canonical web) and `dart2wasm` (the wasm
target) — and that the same trace tree the CLI produces
originates in the user's tap and flows all the way through.

> **Why this exists.** SDK 1.1.0-beta.2 is the first release where
> the Dartastic OpenTelemetry SDK builds for the browser. This
> client is the demonstration that the demo's instrumentation
> patterns (the `InstrumentedHttpClient`, the W3C trace-context
> propagation, the `WeatherClient` SDK package) **all work
> unchanged** in a Flutter web context — one conditional import
> for `SocketException` was the entire portability cost.

## What it is

- A single Flutter Material screen — `TextField` for the city,
  button to fetch, a card showing current conditions and a 3-day
  forecast.
- Uses `weather_client` (the same Dart-side HTTP client SDK
  consumed by `weather_api` and `weather_cli`) unchanged.
- Wires the Dartastic OpenTelemetry SDK directly: `OTel.initialize`,
  a manually started root span around the user's tap, and
  `InstrumentedHttpClient` for trace-context propagation on every
  outbound request.

## What it isn't

- A full Flutter integration with the OTel SDK. That story belongs
  to **[Flutterrific OpenTelemetry][flutterrific]** — automatic
  navigator-observer spans, route-template extraction, error-
  boundary widgets, frame-timing metrics, app-lifecycle spans.
  Those land in `flutterrific_opentelemetry_pro` as part of
  Dartastic.io Pro.
- A polished consumer app. The UI is the simplest possible thing
  that proves the trace works end to end.
- A Flutter-on-iOS / Android / desktop demo. We deliberately ship
  only the `web/` platform folder; if you want to run on other
  platforms, run `flutter create .` from this directory and
  Flutter will scaffold them.

## Trace shape

When you tap "Get weather", the resulting trace tree looks like:

```
fetchWeather                         (span in the Flutter app — root)
└── GET                              (InstrumentedHttpClient client span)
    └── GET /weather/:city           (weather_api server span)
        └── WeatherService.getForecast
            └── GET                  (weather_api → cache_service client span)
                └── POST /v1/forecast (cache_service server span)
                    └── open-meteo geocode + forecast (when cache misses)
```

One trace_id. Five levels deep. The user's tap is the first
observable event in the entire request flow.

## Run it

In one shell, bring up the local stack:

```sh
tool/stack.sh up
```

In another shell, from the repo root:

```sh
cd apps/weather_flutter
flutter pub get
flutter run -d chrome
```

For the wasm target:

```sh
flutter run -d chrome --wasm
```

For a release build:

```sh
flutter build web                # dart2js
flutter build web --wasm         # dart2wasm
```

The build output lives at `build/web/`; serve it with any static
file server. Watch the trace tree in Grafana at
http://localhost:3000 (admin / admin) → Explore → Tempo.

## Configuration

Two endpoints are hard-coded in `lib/main.dart`:

| Constant | Default | Purpose |
| -------- | ------- | ------- |
| `_defaultApiBaseUrl`   | `http://localhost:8080` | weather_api endpoint |
| `_defaultOtlpEndpoint` | `http://localhost:4318` | OTLP HTTP endpoint (LGTM) |

To point at Cloud Operations, Honeycomb, Dartastic Cloud, or any
other OTLP/HTTP backend, edit `_defaultOtlpEndpoint`. The browser
can't read env vars, so we don't pretend env-var configuration
applies.

## CORS

The demo's `weather_api` service ships a permissive CORS middleware
that allows `traceparent`, `tracestate`, and `baggage` headers, so
the W3C trace context flows from the browser to the server
unimpeded. The middleware is in
`services/weather_api/lib/src/router.dart`. **Production code
should narrow the allowed origin** — the `*` we use here is
appropriate for a reference demo, not a deployed service.

[flutterrific]: https://github.com/MindfulSoftwareLLC/flutterrific_opentelemetry
