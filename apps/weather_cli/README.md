# weather_cli

Command-line client for the demo's public weather API. Same route as
the Flutter app (`GET /weather/<city>`). Invoking it produces a
complete distributed trace from the terminal through `weather-api`,
`cache-service`, and Open-Meteo. The swarm script drives many of
these in parallel.

## Quick start

```sh
# From the repo root, with weather_api running on localhost:8080:
dart run apps/weather_cli/bin/weather.dart Boston

# Override the upstream:
dart run apps/weather_cli/bin/weather.dart \
  --upstream http://my-weather-api.example.com \
  --days 7 \
  "New York"

# JSON output for piping to jq:
dart run apps/weather_cli/bin/weather.dart --json --quiet Tokyo | jq .city.name
```

## What gets emitted

When the CLI runs, it initializes the OpenTelemetry SDK via
`weather_otel.initializeOtel`, opens a single root span called
`cli.forecast`, then issues one `GET /weather/<city>` from inside
that span's context. `InstrumentedHttpClient` emits the client span
and injects W3C trace context — that is what stitches the CLI's
root span to `weather-api`'s server span. The trace tree for one
invocation is:

```
cli.forecast (INTERNAL — root)
└── GET (CLIENT — weather-api /weather/:city)
    └── GET /weather/:city (SERVER — weather-api)
        └── WeatherService.getForecast
            ├── GET /v1/geocode     (cache-service; Open-Meteo on miss)
            └── POST /v1/forecast   (cache-service; Open-Meteo on miss)
```

Before the process exits, the CLI calls `forceFlush` and then
`shutdown` on the OTel handle so spans land in the backend before the
event loop drains. The CLI does **not** install SIGTERM / SIGINT
handlers — it's short-lived; natural exit through the `finally` block
runs the flush.

## Configuration

| Source                   | Setting                | Default                 |
| ------------------------ | ---------------------- | ----------------------- |
| `--upstream` flag        | API base URL           | `WEATHER_API_URL` env / |
|                          |                        | `http://localhost:8080` |
| `--days N` flag          | Forecast horizon       | `3`                     |
| `--json` flag            | Machine-readable output| Off (text)              |
| `--quiet` flag           | Suppress info logging  | Off                     |
| `OTEL_*` env             | Standard OTel config   | unset                   |

## Exit codes

| Code | Meaning                                                          |
| ---- | ---------------------------------------------------------------- |
| 0    | Success.                                                         |
| 1    | Operational failure (upstream returned an error, network down,…)|
| 64   | Usage error (`EX_USAGE` per BSD `sysexits.h` convention).        |

## Tests

```sh
cd apps/weather_cli
dart test
```

The output formatters are tested with pinned fixtures so the
human-readable text format is stable across versions — any change to
the column layout or wording is intentional and visible in the diff.

## Library, not framework

The CLI logic lives in `lib/src/run.dart` as a pure `Future<int>
runWeatherCli(List<String> args)` function. The binary at
`bin/weather.dart` is a one-line wrapper. This split makes the CLI
testable end-to-end without spawning a process.
