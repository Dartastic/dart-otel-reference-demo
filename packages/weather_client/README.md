# weather_client

HTTP client SDK for the demo's v1 weather API. Implements the
`WeatherProvider` interface from `weather_core` against a remote
service that speaks the v1 contract — typically `cache_service`.

Used by:

- **`services/weather_api`** — as the upstream provider passed to
  `WeatherService`, when configured to call `cache_service` (the demo's
  default deployment shape).
- **`apps/weather_cli`** — for direct CLI access to `cache_service`
  during throughput demos and one-off lookups.

## v1 wire-format contract

Any service that implements these three endpoints can be used as a
backend for `WeatherClient`.

### `GET <baseUrl>/v1/geocode?q=<query>&limit=<int>`

Returns a list of cities matching `query`. `limit` caps the number of
matches returned (default 5).

```http
HTTP/1.1 200 OK
Content-Type: application/json

{
  "query": "Toulouse",
  "matches": [
    { "id": 2972315, "name": "Toulouse", "latitude": 43.604, ... }
  ]
}
```

### `POST <baseUrl>/v1/forecast`

Returns a forecast for the supplied city.

```http
POST /v1/forecast HTTP/1.1
Content-Type: application/json

{
  "city": { "id": 2972315, "name": "Toulouse", "latitude": 43.604, ... },
  "forecastDays": 3
}
```

```http
HTTP/1.1 200 OK
Content-Type: application/json

{
  "city": { ... },
  "current": { ... },
  "daily": [ ... ],
  "fetchedAt": "2026-05-09T12:00:00.000Z"
}
```

### `GET <baseUrl>/healthz`

Always 200 if the service is up. Body `"ok\n"`.

## Error contract

Status codes returned by the upstream are mapped back to
`WeatherProviderException` kinds — symmetric with the mapping
`services/weather_api` uses to translate the same exceptions to HTTP.

| HTTP status | `WeatherProviderErrorKind` |
| ----------- | -------------------------- |
| 400         | `badRequest`               |
| 404         | `notFound`                 |
| 429         | `rateLimit`                |
| 503         | `network`                  |
| 5xx (other) | `upstream`                 |
| Other 4xx   | `unknown`                  |
| Timeout     | `network`                  |
| `SocketException` | `network`            |
| Malformed JSON    | `parse`              |

A 404 from `cache_service` surfaces as `notFound` in the caller. If
the caller is itself an HTTP service (like `weather_api`), the same
mapping reverses cleanly back to a 404 for the original requester —
the cause survives every hop.

## Library, not bootstrap

`WeatherClient` does not call `OTel.initialize` and does not create
any spans of its own. Outbound spans come from the [`http.Client`][hc]
the consumer supplies — almost always `InstrumentedHttpClient` from
`weather_http_kit`, which adds W3C trace-context injection and a
client span per request:

```dart
import 'package:http/http.dart' as http;
import 'package:weather_http_kit/weather_http_kit.dart';
import 'package:weather_client/weather_client.dart';

final client = WeatherClient(
  baseUrl: Uri.parse('http://cache-service:8090'),
  client: InstrumentedHttpClient(inner: http.Client()),
);
```

[hc]: https://pub.dev/documentation/http/latest/http/Client-class.html

## Testing

```sh
dart test  # from this directory or the workspace root
```

Tests use `package:http/testing`'s `MockClient` to drive the
`WeatherClient` against a scripted backend — no network. Cover the
happy paths for both endpoints, the full HTTP-status-to-kind mapping,
network and parse error classification, and JSON round-trip
compatibility with the same `City` / `WeatherForecast` types
`weather_core` defines.
