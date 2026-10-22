# Changelog

All notable changes to this package are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- `dartastic_opentelemetry` 1.1.0-beta.17, on API 1.0.0-rc.4.
- Telemetry never throws: an out-of-range sampling ratio is reported to
  the OpenTelemetry error handler and the default used
  (`samplingRatioFor`), and `forceFlush` / `shutdown` report a failure
  instead of throwing it. `initializeOtel` installs a handler that
  writes to stderr, outside OpenTelemetry, so a report can't loop.

### Added
- Initial package: `initializeOtel` bootstrap, `WeatherOtelHandle` lifecycle,
  SIGTERM / SIGINT graceful-shutdown handlers, and the optional
  `WEATHER_DEMO_MODE` admin endpoint for forced flush.
