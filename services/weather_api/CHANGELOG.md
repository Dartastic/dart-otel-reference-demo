# Changelog

All notable changes to this service are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Initial service: HTTP front door composing weather_core,
  weather_http_kit, and weather_otel. Exposes `GET /weather/<city>` and
  `GET /healthz`. Optional admin port behind `OTEL_DEMO_MODE`.
