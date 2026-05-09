# weather_core

Domain models, weather provider abstraction, and business logic for the
Dart OTel demo.

This package is **library code**. It uses the Dartastic OpenTelemetry SDK
directly (`OTel.tracer()`, `OTel.meter()`) for instrumentation but does not
call `OTel.initialize()` — that is an application-layer responsibility
handled by `weather_otel` and the consuming services. A consumer who has
not initialized OTel before invoking this library will see runtime errors,
which is the intended behavior; this package is not designed to be useful
without telemetry.

## Public surface

- **Models** — immutable value types: `City`, `GeocodeResult`,
  `CurrentWeather`, `DailyForecast`, `WeatherForecast`, `WeatherCode`.
- **Providers** — `WeatherProvider` interface and the production
  `OpenMeteoProvider` implementation (free, no API key, see
  [open-meteo.com](https://open-meteo.com)).
- **Service** — `WeatherService` orchestrates geocoding + forecast
  retrieval with full instrumentation.

## Why `http.Client` is injected

The `OpenMeteoProvider` constructor accepts an `http.Client` rather than
constructing one. This lets the application inject the instrumented
client from `weather_http_kit` (which adds W3C trace context propagation
on outbound calls) while keeping this package testable with a fake client.

## Testing

Tests in this package call `await OTel.initialize(...)` once in
`setUpAll` to bring up a real SDK pointed at a console exporter. We do
not mock OTel — see DESIGN.md, "Non-goals."
