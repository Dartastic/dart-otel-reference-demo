# Local stack

Single-command local deployment of the demo: `weather_api`,
`cache_service`, and an all-in-one [Grafana LGTM][lgtm] backend
(Loki / Grafana / Tempo / Mimir behind one OTel Collector).

```sh
# From the repository root:
tool/stack.sh up
# Or, equivalently:
docker compose -f deploy/local/docker-compose.yml up --build
```

First boot pulls the LGTM image (~700 MB), builds both service images,
and waits for Grafana to report healthy — about 60–90 seconds total
the first time, ~10 seconds on subsequent runs.

## What's running

| Service          | Image                          | Host port | Internal port  | Purpose                                              |
| ---------------- | ------------------------------ | --------- | -------------- | ---------------------------------------------------- |
| `lgtm`           | `grafana/otel-lgtm:0.11.10`    | 3000      | 3000           | Grafana UI (admin / admin)                           |
| `lgtm`           | (same)                         | 4317      | 4317           | OTLP/gRPC ingress (also for local non-containerized processes) |
| `lgtm`           | (same)                         | 4318      | 4318           | OTLP/HTTP ingress                                    |
| `weather-api`    | `dart-otel-demo/weather-api:dev` | 8080    | 8080           | Public HTTP front door                               |
| `weather-api`    | (same)                         | 8081 (loopback) | 8081     | Demo admin port — `POST /flush`                      |
| `cache-service`  | `dart-otel-demo/cache-service:dev` | —     | 8090           | Forecast cache (internal only)                       |
| `cache-service`  | (same)                         | 8091 (loopback) | 8091     | Demo admin port — `POST /flush`                      |

`cache-service` is deliberately not exposed to the host. The only
thing that should talk to it is `weather-api`, on the compose
network.

## Try it

```sh
# A real forecast request:
curl -s 'http://localhost:8080/weather/Toulouse?days=3' | jq .

# Open Grafana:
open http://localhost:3000           # macOS
xdg-open http://localhost:3000       # Linux
```

In Grafana, the demo's pre-built dashboards live under
**Dashboards → Dart OTel Demo**. The headline one is
**Service Overview** — request rate, error rate, latency percentiles,
and the bimodal weather-api latency heatmap that visualizes cache
hits vs misses. Source lives at [`dashboards/`](../../dashboards/);
the compose file bind-mounts them into the LGTM container.

For ad-hoc trace exploration, **Explore → Tempo** with the search
`service.name=weather-api` finds the trace your `curl` produced.
You should see the full hierarchy:

```
GET /weather/:city          (weather-api server span)
├── GET /v1/geocode         (cache-service server span)
│   └── open-meteo geocode  (cache-service → open-meteo, on cache miss)
└── POST /v1/forecast       (cache-service server span)
    └── open-meteo forecast (cache-service → open-meteo, on cache miss)
```

A second `curl` for the same city within five minutes hits the cache
— the `open-meteo *` spans disappear from the trace tree and the
`cache-service` server spans carry the attribute
`weather.cache.outcome=hit` instead of `miss`.

## Drive it from the CLI

The CLI binary doesn't need to run inside the stack — it can call
into it from your host:

```sh
# Point the CLI at the containerized weather-api:
WEATHER_API_URL=http://localhost:8080 \
  dart run apps/weather_cli/bin/weather.dart Toulouse

# Send the CLI's own spans to the same LGTM backend so the trace
# tree starts at `cli.forecast` (root span) and includes the
# weather-api / cache-service hops in one continuous chain:
WEATHER_API_URL=http://localhost:8080 \
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
  dart run apps/weather_cli/bin/weather.dart --days 7 Tokyo
```

## Forcing a flush

The `BatchSpanProcessor` exports spans on a 5-second cadence by
default — fast enough that you'll usually see your trace within a
few seconds of issuing the request. When you don't want to wait
(load-test runs that just finished, demo audiences asking "where's
my trace?"), POST to the demo admin endpoint:

```sh
curl -fsS -X POST http://localhost:8081/flush  # weather-api
curl -fsS -X POST http://localhost:8091/flush  # cache-service
```

Both endpoints call `forceFlush()` on the SDK, blocking until
buffered spans are exported. The endpoint is bound to localhost only
on the host — the compose stack is what enables the admin port; in
production the same binary leaves it closed unless `OTEL_DEMO_MODE=true`.

The swarm script (see [`load/`](../../load/)) calls these endpoints
automatically at the end of every batch.

## Tear down

```sh
# Stops and removes containers; preserves the LGTM data volume so
# accumulated traces are still there next time:
tool/stack.sh down

# Same plus wipes the volume — start with a clean Grafana / Tempo:
tool/stack.sh down -v
```

## Logs and status

```sh
tool/stack.sh ps        # which containers are running
tool/stack.sh logs      # tail logs from all services
tool/stack.sh logs lgtm # tail logs from one service
```

## Pinning, security, and other production concerns

This stack is designed for **local development and demos**. A few
things you should not copy into production:

- **`grafana/otel-lgtm` is not a production observability stack.** It
  exists to make development and demo setup trivial. Production
  observability uses Loki, Tempo, Mimir, and Grafana as four
  separately-deployed services with the OTel Collector configured
  for the specific data shape and volume of your environment.
- **Default Grafana credentials.** `admin / admin` is the upstream
  default and we leave it as-is so the docs and the running stack
  agree. Anywhere that's not your laptop behind your firewall: change
  it.
- **Pinned image tag.** The compose file pins `grafana/otel-lgtm:0.11.10`
  rather than `:latest`. Bump deliberately and re-test the full stack
  when upgrading; the all-in-one image rolls breaking changes
  into minor versions periodically.
- **No TLS.** OTLP traffic between the services and `lgtm:4317` is
  cleartext on the compose network. Production OTLP should use TLS
  (set `OTEL_EXPORTER_OTLP_PROTOCOL` and configure certs).
- **No persistence for Grafana dashboards.** The single `lgtm-data`
  volume keeps Tempo / Loki / Mimir data, but custom dashboards
  created in Grafana through the UI are lost on `down -v`. If you
  build dashboards worth keeping, export them and check them into
  `dashboards/grafana/` (TBD).

[lgtm]: https://github.com/grafana/docker-otel-lgtm
