// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

/// WMO weather interpretation codes used by Open-Meteo.
///
/// Reference: <https://open-meteo.com/en/docs> § "WMO Weather interpretation codes"
///
/// The numeric [code] is what the Open-Meteo API reports. Values that the API
/// may add in the future are surfaced as [unknown] so that an unrecognized
/// upstream code never crashes a request — it logs and degrades gracefully.
enum WeatherCode {
  clearSky(0, 'Clear sky', WeatherSeverity.calm),
  mainlyClear(1, 'Mainly clear', WeatherSeverity.calm),
  partlyCloudy(2, 'Partly cloudy', WeatherSeverity.calm),
  overcast(3, 'Overcast', WeatherSeverity.calm),
  fog(45, 'Fog', WeatherSeverity.notable),
  rimeFog(48, 'Depositing rime fog', WeatherSeverity.notable),
  drizzleLight(51, 'Light drizzle', WeatherSeverity.notable),
  drizzleModerate(53, 'Moderate drizzle', WeatherSeverity.notable),
  drizzleDense(55, 'Dense drizzle', WeatherSeverity.notable),
  freezingDrizzleLight(56, 'Light freezing drizzle', WeatherSeverity.notable),
  freezingDrizzleDense(57, 'Dense freezing drizzle', WeatherSeverity.notable),
  rainSlight(61, 'Slight rain', WeatherSeverity.notable),
  rainModerate(63, 'Moderate rain', WeatherSeverity.notable),
  rainHeavy(65, 'Heavy rain', WeatherSeverity.severe),
  freezingRainLight(66, 'Light freezing rain', WeatherSeverity.severe),
  freezingRainHeavy(67, 'Heavy freezing rain', WeatherSeverity.severe),
  snowSlight(71, 'Slight snowfall', WeatherSeverity.notable),
  snowModerate(73, 'Moderate snowfall', WeatherSeverity.notable),
  snowHeavy(75, 'Heavy snowfall', WeatherSeverity.severe),
  snowGrains(77, 'Snow grains', WeatherSeverity.notable),
  rainShowersSlight(80, 'Slight rain showers', WeatherSeverity.notable),
  rainShowersModerate(81, 'Moderate rain showers', WeatherSeverity.notable),
  rainShowersViolent(82, 'Violent rain showers', WeatherSeverity.severe),
  snowShowersSlight(85, 'Slight snow showers', WeatherSeverity.notable),
  snowShowersHeavy(86, 'Heavy snow showers', WeatherSeverity.severe),
  thunderstorm(95, 'Thunderstorm', WeatherSeverity.severe),
  thunderstormSlightHail(
    96,
    'Thunderstorm with slight hail',
    WeatherSeverity.severe,
  ),
  thunderstormHeavyHail(
    99,
    'Thunderstorm with heavy hail',
    WeatherSeverity.severe,
  ),

  /// Sentinel for codes the API may add later.
  unknown(-1, 'Unknown', WeatherSeverity.notable);

  const WeatherCode(this.code, this.description, this.severity);

  /// The WMO numeric code reported by Open-Meteo.
  final int code;

  /// Human-readable English description.
  final String description;

  /// Coarse severity bucket suitable as a low-cardinality metric attribute.
  final WeatherSeverity severity;

  /// Resolves a numeric code from the API to a [WeatherCode], returning
  /// [unknown] when the code is not recognized rather than throwing — an
  /// unrecognized upstream code is not a programming error.
  static WeatherCode fromCode(int code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return unknown;
  }
}

/// Coarse severity bucket. Bounded enum, safe to use as a metric label.
enum WeatherSeverity { calm, notable, severe }
