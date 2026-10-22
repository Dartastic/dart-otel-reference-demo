# Changelog

All notable changes to this app are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- `dartastic_opentelemetry` 1.1.0-beta.17, on API 1.0.0-rc.4.
- The OpenTelemetry error handler (installed by `weather_otel`'s
  bootstrap) writes the SDK's reports to stderr.

### Changed
- Revamped the README.md
- Calls the public `GET /weather/<city>` route (same as Flutter)
  instead of the two-step v1 `WeatherClient` geocode + forecast path.

### Added
- Initial CLI: `weather_cli <city>` with `--days`, `--upstream`, `--json`,
  `--quiet`. Emits a `cli.forecast` root span around the operation and
  flushes pending spans before exit.
