# weather_cli

Command-line client for the demo's v1 weather API. The third
deployable binary in the demo and the first non-server — invoking it
produces a complete distributed trace from the user's terminal all
the way through `weather_api`, `cache_service`, and Open-Meteo.

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
`cli.forecast`, then calls `weather_client.WeatherClient.geocode` and
`getForecast` from inside that span's context. The
`InstrumentedHttpClient` decorator on the HTTP transport emits a client
span per outbound request and injects W3C trace context — that is what
stitches the CLI's root span to `weather_api`'s server span as a
parent-child link. The trace tree for one invocation is:

```
cli.forecast (INTERNAL — root)
  ├── GET   (CLIENT — geocode call to weather_api)
  │   └── GET /v1/geocode (SERVER — weather_api → cache_service)
  │       └── ...                            (cache_service → open-meteo on miss)
  └── POST  (CLIENT — forecast call to weather_api)
      └── POST /v1/forecast (SERVER — weather_api → cache_service)
          └── ...                            (cache_service → open-meteo on miss)
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
