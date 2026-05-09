# Changelog

All notable changes to this service are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Initial service: caching v1 weather provider. In-memory `TtlCache`
  for both geocode and forecast lookups; cache attribution on the
  active server span.
