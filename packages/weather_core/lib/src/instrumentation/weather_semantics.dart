// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart'
    show OTelSemantic;

/// Custom OpenTelemetry semantic attribute keys for the weather domain.
///
/// Modeled on the Dartastic API's built-in semantic enums (`Http`,
/// `Cloud`, `Client`, etc.) — `implements OTelSemantic` so these enum
/// values can be mixed into the same `attributesFromSemanticMap`
/// literal as the spec-defined ones, with Dart 3.10 dot-shorthand
/// inside each typed spread:
///
/// ```dart
/// OTel.attributesFromSemanticMap({
///   ...<WeatherSemantics, Object>{
///     .provider:  'open-meteo',
///     .operation: 'getForecast',
///   },
///   ...<Http, Object>{
///     .requestMethod: 'GET',
///   },
/// })
/// ```
///
/// The `weather.*` namespace is a custom namespace. Per the OpenTelemetry
/// specification's guidance for custom attributes, custom namespaces SHOULD
/// avoid collisions with reserved OTel namespaces (`http`, `db`, `messaging`,
/// `rpc`, `network`, `server`, `client`, `url`, `error`, `code`, `enduser`,
/// `event`, `exception`, `os`, `peer`, `process`, `thread`, `service`, `host`,
/// `cloud`, `container`, `k8s`, `faas`, `aws`, `gcp`, `azure`). `weather.*`
/// is clear of those.
///
/// **Cardinality discipline.** The doc on each value calls out whether it is
/// safe as a metric attribute (low-cardinality, bounded enum-equivalent) or
/// span-only (potentially high-cardinality). See DESIGN.md, "Cardinality
/// discipline."
enum WeatherSemantics implements OTelSemantic {
  /// Weather data provider — e.g. `open-meteo`.
  /// Bounded enum-equivalent. **Safe on metrics.**
  provider('weather.provider'),

  /// High-level operation — e.g. `geocode`, `getForecast`.
  /// Bounded enum-equivalent. **Safe on metrics.**
  operation('weather.operation'),

  /// Operation outcome — `success` or `error`.
  /// Bounded. **Safe on metrics.**
  outcome('weather.outcome'),

  /// Provider error category when [outcome] is `error`.
  /// Bounded (`WeatherProviderErrorKind`). **Safe on metrics.**
  errorKind('weather.error.kind'),

  /// Free-text geocode query supplied by the caller — e.g. `Toulouse`.
  /// **Span-only — high-cardinality.**
  geocodeQuery('weather.geocode.query'),

  /// Number of city matches returned by the geocoder.
  /// Bounded (0..maxResults). Safe on metrics if needed, but typically
  /// span-only as a debugging signal.
  geocodeMatchCount('weather.geocode.match_count'),

  /// True when the geocode result had more than one match.
  /// Bounded. **Safe on metrics.**
  geocodeAmbiguous('weather.geocode.ambiguous'),

  /// Caller-requested cap on geocode matches.
  /// Bounded small integer. **Safe on metrics.**
  geocodeMaxResults('weather.geocode.max_results'),

  /// City id from the geocoding provider.
  /// **Span-only — high-cardinality.**
  cityId('weather.city.id'),

  /// City display name — e.g. `Toulouse`.
  /// **Span-only — high-cardinality.**
  cityName('weather.city.name'),

  /// ISO 3166-1 alpha-2 country code — e.g. `FR`.
  /// Bounded (~250 values). **Safe on metrics.**
  cityCountryCode('weather.city.country_code'),

  /// Number of forecast days requested (1–16).
  /// Bounded small integer. **Safe on metrics.**
  forecastDays('weather.forecast.days'),

  /// Current observation's WMO weather code (numeric).
  /// Bounded (~30 values). **Safe on metrics.**
  currentWeatherCode('weather.current.weather_code'),

  /// Current observation's severity bucket — `calm`, `notable`, `severe`.
  /// Bounded. **Safe on metrics.**
  currentSeverity('weather.current.severity'),

  /// Whether the current observation is during daylight hours.
  /// Bounded boolean. **Safe on metrics.**
  currentIsDay('weather.current.is_day');

  const WeatherSemantics(this.key);

  @override
  final String key;

  @override
  String toString() => key;
}
