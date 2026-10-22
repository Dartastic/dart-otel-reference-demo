# Changelog

All notable changes to this service are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- `dartastic_opentelemetry` 1.1.0-beta.17, on API 1.0.0-rc.4.
- The OpenTelemetry error handler (installed by `weather_otel`'s
  bootstrap) writes the SDK's reports to stderr.

### Added
- Initial service: HTTP front door composing weather_core,
  weather_http_kit, and weather_otel. Exposes `GET /weather/<city>` and
  `GET /health`. Optional admin port behind `WEATHER_DEMO_MODE`.
