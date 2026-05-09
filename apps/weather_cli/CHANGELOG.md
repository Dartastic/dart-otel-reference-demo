# Changelog

All notable changes to this app are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Initial CLI: `weather_cli <city>` with `--days`, `--upstream`, `--json`,
  `--quiet`. Emits a `cli.forecast` root span around the operation and
  flushes pending spans before exit.
