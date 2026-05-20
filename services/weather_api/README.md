# weather_api

The first deployable binary in the Dart OTel demo. An HTTP service that
accepts requests for a city's weather forecast and returns JSON, with
full OpenTelemetry instrumentation along the inbound and outbound paths.

```
client ──► weather_api ──► cache_service ──► open-meteo
```

`weather_api` is the front-door HTTP service. It calls `cache_service`
over HTTP via `weather_client` (the v1 API SDK), which in turn calls
Open-Meteo. Two server hops in the trace tree, with cache attribution
at the middle one.

## Endpoints

| Method | Path                  | Description                                   |
| ------ | --------------------- | --------------------------------------------- |
| `GET`  | `/weather/<city>`     | Forecast for `<city>`. Query: `?days=N` (1..16, default 3). |
| `GET`  | `/healthz`            | Liveness / readiness probe.                   |

Status mapping for `/weather/<city>` follows OTel HTTP semantics:

| Code | Cause                                                                                    |
| ---- | ---------------------------------------------------------------------------------------- |
| 200  | Forecast returned.                                                                       |
| 400  | `days` non-integer, out of range, or city name empty.                                    |
| 404  | Geocoder returned no matches for the supplied city name.                                 |
| 429  | Upstream returned 429 — back off.                                                        |
| 502  | Upstream returned 5xx, returned malformed data, or failed in some other unclassified way.|
| 503  | Upstream is unreachable from this service (network error, timeout).                      |

## Composition

The binary at `bin/server.dart` wires four library packages:

1. **`weather_otel`** — `initializeOtel(...)` configures the SDK from the
   standard `OTEL_*` environment variables and returns a handle.
   `attachToProcessLifecycle()` installs SIGTERM / SIGINT handlers so
   buffered spans flush before the container dies.
2. **`weather_http_kit`** — `otelMiddleware()` produces a server span per
   inbound request (W3C trace-context extracted, baggage extracted, HTTP
   semconv attributes set, route template used as the span name).
   `InstrumentedHttpClient` wraps the outbound `http.Client` so calls to
   `cache_service` emit client spans and inject W3C trace-context downstream
   — that's what stitches `weather_api`'s server span to `cache_service`'s
   server span as a parent-child link in the trace tree.
3. **`weather_client`** — `WeatherClient` implements `WeatherProvider`
   against the v1 API contract `cache_service` exposes. Slots into
   `WeatherService` unchanged.
4. **`weather_core`** — `WeatherService` orchestrates geocode + forecast
   via the supplied provider. The provider here is `WeatherClient`, not
   `OpenMeteoProvider` — Open-Meteo lives behind `cache_service`.

## Configuration

| Environment variable    | Default                  | Description                                         |
| ----------------------- | ------------------------ | --------------------------------------------------- |
| `PORT`                  | `8080`                   | Public service port.                                |
| `ADMIN_PORT`            | `8081`                   | Admin port (only bound when `OTEL_DEMO_MODE=true`). |
| `WEATHER_UPSTREAM_URL`  | `http://localhost:8090`  | Base URL of the v1 upstream service (cache_service).|
| `OTEL_DEMO_MODE`        | unset                    | When `true`, exposes `POST /flush` on `ADMIN_PORT`. |
| `OTEL_*`                |                          | Standard OTel env vars — see `weather_otel`.        |

## Running

```sh
# From the repo root, in two shells:
tool/run.sh cache_service
tool/run.sh weather_api

# Then:
curl -s 'http://localhost:8080/weather/Boston?days=3' | jq .
```

The default `WEATHER_UPSTREAM_URL` points at `http://localhost:8090` so
running both services with default ports just works. In Docker Compose
or Kubernetes, set `WEATHER_UPSTREAM_URL` to the cache_service's
in-cluster DNS name (e.g., `http://cache-service:8090`).

## Tests

```sh
cd services/weather_api
dart test
```

Tests build the same pipeline the production binary builds, but against
a hand-rolled `FakeWeatherProvider` — no network, no upstream. They
cover the happy path, every HTTP status mapping, and the route-template
span-name contract that dashboards depend on. See `DESIGN.md` §
"Testing strategy" at the repository root for the rationale.

## Docker

```sh
docker build -t weather_api -f services/weather_api/Dockerfile .
docker run --rm -p 8080:8080 weather_api
```

The Dockerfile is a two-stage compile-to-exe build that produces a small
final image suitable for both Docker Compose and Cloud Run.
