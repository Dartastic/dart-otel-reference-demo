# cache_service

The second deployable binary in the demo. A caching weather provider
that implements the v1 weather API — the contract `weather_client`
speaks. Sits between `weather_api` and Open-Meteo and inserts the
second server hop into the trace tree:

```
client ──► weather_api ──► cache_service ──► open-meteo
```

The point of this service is not the caching itself (a real
deployment would use Redis or Caffeine, not the in-memory `TtlCache`
here). The point is to give the demo's distributed-tracing story a
real **two-server-hop** chain, with an interesting span graph at
each hop and a **cache.hit / cache.miss** signal that's exactly the
kind of thing operators learn to read on dashboards.

## Endpoints

| Method | Path             | Description                                                   |
| ------ | ---------------- | ------------------------------------------------------------- |
| `GET`  | `/v1/geocode`    | Returns matching cities for `?q=<query>&limit=<int>` (1..50). |
| `POST` | `/v1/forecast`   | Returns a forecast for the supplied `{city, forecastDays}`.   |
| `GET`  | `/healthz`       | Liveness / readiness probe.                                   |

The wire-format contract is documented at
`packages/weather_client/README.md`. `cache_service` is the
canonical implementation; anything else that speaks the same
contract is a drop-in replacement.

## What the cache annotates

Every request hits one of the two caches before any upstream call.
The handler adds three attributes to the active server span (the one
created by `otelMiddleware`) and one event:

| Attribute / event                         | Value                              |
| ----------------------------------------- | ---------------------------------- |
| `weather.cache.namespace` (attribute)     | `geocode` or `forecast`            |
| `weather.cache.outcome` (attribute)       | `hit`, `miss`, or `expired`        |
| `weather.cache.size` (attribute)          | Current entry count for this cache |
| `cache.hit` / `cache.miss` / `cache.expired` (event) | One of the three        |

`weather.cache.outcome` is bounded (3 values) and safe to use as a
metric label. `weather.cache.size` is an integer attribute that
collectors typically convert into a metric of its own. Together they
tell you, at a glance, what your hit ratio is and how full the cache
is — the two questions you ask first when tuning a cache.

## Configuration

| Environment variable    | Default | Description                                          |
| ----------------------- | ------- | ---------------------------------------------------- |
| `PORT`                  | `8090`  | Public service port.                                 |
| `ADMIN_PORT`            | `8091`  | Admin port (only bound when `OTEL_DEMO_MODE=true`).  |
| `FORECAST_TTL_SECONDS`  | `300`   | TTL for forecast cache entries.                      |
| `GEOCODE_TTL_SECONDS`   | `86400` | TTL for geocode cache entries.                       |
| `OTEL_DEMO_MODE`        | unset   | When `true`, exposes `POST /flush` on `ADMIN_PORT`.  |
| `OTEL_*`                |         | Standard OTel env vars — see `weather_otel`.         |

The two TTLs default to "forecasts change every few minutes,
geocoding answers don't." Tune via env in production deployments.

## Running

```sh
# From the repo root:
tool/run.sh cache_service

# In another shell:
curl -s 'http://localhost:8090/v1/geocode?q=Boston' | jq .

curl -sX POST 'http://localhost:8090/v1/forecast' \
     -H 'content-type: application/json' \
     -d '{"city": <City JSON>, "forecastDays": 3}' | jq .
```

## Tests

```sh
cd services/cache_service
dart test
```

Two test files. `cache_test.dart` covers the `TtlCache` itself with
an injectable clock — `hit` / `miss` / `expired` semantics, TTL reset
on replacement, the documented quirk that `size` does not sweep
proactively. `handler_test.dart` covers the v1 endpoints against a
`FakeWeatherProvider` with call counters: that's how the cache-hit
assertions verify the upstream was NOT called on the second request.
The same tests assert the `weather.cache.*` span attributes and
events that dashboards depend on.

## Docker

Same two-stage compile-to-exe build as `weather_api`. Build context
is the repository root.

```sh
docker build -t cache_service -f services/cache_service/Dockerfile .
docker run --rm -p 8090:8090 cache_service
```
