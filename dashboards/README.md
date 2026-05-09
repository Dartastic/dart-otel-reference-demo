# Dashboards

Pre-built Grafana dashboards for the Dart OTel demo. Auto-loaded into
the Grafana inside the [local stack](../deploy/local/) under a folder
named **Dart OTel Demo**.

## What's here

```
dashboards/
└── grafana/
    ├── provisioning.yaml          # tells Grafana to load json/* into the
    │                              # 'Dart OTel Demo' folder
    └── json/
        └── service_overview.json  # RED metrics for the demo's services
```

The compose file at `deploy/local/docker-compose.yml` bind-mounts both
into the LGTM container — no separate import step. Bring up the stack
and the dashboards are there:

```sh
tool/stack.sh up
open http://localhost:3000        # admin / admin → Dashboards → Dart OTel Demo
```

## `service_overview.json`

The headline dashboard. RED-style — Rate, Errors, Duration — for the
two services the demo runs. Five visible panels plus three header
rows:

| Panel                                    | What it shows                                                         |
| ---------------------------------------- | --------------------------------------------------------------------- |
| Total requests (window)                  | `sum(increase(...count))` over the dashboard's time range             |
| Error rate %                             | 5xx-rate / total-rate, 4xx excluded (caller-attributable, not the server's fault)  |
| p95 latency (window)                     | `histogram_quantile(0.95, …)` across both services                    |
| Active services                          | Count of distinct `service.name` emitting metrics — should be 2       |
| Request rate per service / route         | RPS broken out by `service.name` × `http.route` template (low-card)   |
| Latency p50 / p95 / p99 per service      | Three quantiles per service                                           |
| **weather-api latency heatmap**          | **The bimodal pattern — fast band = cache hits, slow band = open-meteo round trips** |
| Status code mix per service              | Stacked bars of HTTP response codes per service                       |

The latency heatmap is the one to look at. After a `load/run_swarm.sh`
run, you should see two distinct horizontal bands: a fast band where
`cache_service` had a hit and `weather-api` returned in single-digit
ms, and a slow band where the cache missed and `weather-api` waited
for the open-meteo round trip. That bimodal pattern is the demo's
clearest visual proof that the cache is doing its job.

## Editing

Dashboards are provisioned with `allowUiUpdates: true`, so tweaks made
live in Grafana survive container restarts but are wiped on
`docker compose down -v`. To make an edit permanent:

1. Open the dashboard in Grafana → click the share icon → **Export**
   → **Save to file**.
2. Replace the JSON file in `dashboards/grafana/json/` with the export.
3. Commit.

## Adding new dashboards

Drop another JSON file into `dashboards/grafana/json/`. Grafana picks
up new files automatically (the provisioner re-scans every 30 seconds
per `provisioning.yaml`). No compose changes needed.

## Scope

These dashboards are deliberately demo-focused — a small set of panels
covering the headline observations the post is about. They are not a
full observability toolkit; SLO tracking, multi-environment correlation,
and deployment markers are out of scope here.

## Datasource UIDs

Queries reference the LGTM image's default datasource UIDs:
`prometheus`, `tempo`, and `loki`. If you point this dashboard at a
different Grafana, update the `"datasource"` blocks accordingly.
