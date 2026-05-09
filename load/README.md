# Load generation

Scripts that produce enough volume to make the demo's instrumentation
look like a real workload — RED metrics with non-zero rates, latency
histograms with actual distributions, cache hit ratio over time,
status-code mix.

## `run_swarm.sh`

Spawns N parallel `weather_cli` invocations against the running
stack, then forces a span flush so spans land in the backend
immediately rather than waiting for the `BatchSpanProcessor`'s
natural cadence.

```sh
# Default: 100 invocations, 10 parallel, 3-day forecast each:
load/run_swarm.sh

# Bigger batch:
load/run_swarm.sh --total 1000 --parallel 25

# Long forecast horizon stresses the daily-series serializer:
load/run_swarm.sh --days 14
```

Each invocation produces an independent trace (its own root
`cli.forecast` span, its own trace_id), so this is N independent
traces, not one big trace. That's what real load looks like.

### Speed

By default the runner is `dart run apps/weather_cli/bin/weather.dart`,
which JIT-compiles the CLI on every invocation. Acceptable for small
batches; painful at 1000+ invocations.

For real load, AOT-compile first:

```sh
tool/build.sh --release
load/run_swarm.sh --total 5000 --parallel 50
```

`run_swarm.sh` auto-detects `build/weather_cli/weather` and uses it
when present.

### Cities

Rotates through a fixed list of 12 cities chosen so:

- Cache hit ratio is interesting (some hits, some misses — the list
  intentionally repeats some entries, so cache dynamics show up
  after the first pass).
- Open-Meteo's geocoder doesn't trivially short-circuit (varied
  geographies).

To override, edit the `CITIES` array in the script — it's near the
top, designed to be tweaked without restructuring anything.

### Flush

After all invocations complete, the script POSTs to both services'
`/flush` admin endpoints (`http://localhost:8081/flush` and
`http://localhost:8091/flush`). This forces a `forceFlush()` on the
SDK so spans are exported to the backend before you go look at the
dashboard.

The admin endpoints are exposed by the local stack's
`docker-compose.yml`. They're loopback-bound on the host (`127.0.0.1`)
and only enabled when `OTEL_DEMO_MODE=true`. In production
deployments the same binary leaves the port closed.

To skip the flush step, pass `--no-flush`. To force a flush manually
without running the swarm:

```sh
curl -fsS -X POST http://localhost:8081/flush  # weather-api
curl -fsS -X POST http://localhost:8091/flush  # cache-service
```

## What to look at after a swarm run

After running the swarm against the local stack, open Grafana at
http://localhost:3000 (admin / admin), then:

- **Explore → Tempo** — search `service.name=weather-api`. Pick any
  trace; you should see the four-deep tree (cli.forecast → weather_api
  server → cache-service server → open-meteo on miss). Compare a
  trace from the first half of the run against one from the second
  half — the second-half traces should mostly show
  `weather.cache.outcome=hit` on the cache-service server span, with
  the open-meteo client span gone.
- **Explore → Tempo → Service Graph** — emerges from the trace
  data. Should show three nodes (weather-api, cache-service, the
  external open-meteo) with edges sized by request volume.
- **Explore → Mimir** — query
  `rate(http_server_request_duration_seconds_count{service_name="weather-api"}[1m])`
  for request rate, and the `_bucket` series for latency
  distribution. Cache-hit traffic shows up as a bimodal histogram —
  the fast tier (cache hits) and the slow tier (open-meteo round
  trips).
- **Explore → Loki** — query
  `{service_name="weather-api"}` for the structured logs your
  services emit during the run.

If you build a dashboard worth keeping, export it from Grafana and
check the JSON into `dashboards/grafana/`.
