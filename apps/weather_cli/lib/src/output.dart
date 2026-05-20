// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:convert';

import 'package:weather_core/weather_core.dart';

/// Renders a [WeatherForecast] as the canonical machine-readable JSON
/// document — exactly what the v1 API returns over the wire. Callers
/// that want to pipe to `jq` or other tooling get bit-for-bit
/// compatibility with what `curl` would have shown.
String renderJson(WeatherForecast forecast) =>
    const JsonEncoder.withIndent('  ').convert(forecast.toJson());

/// Renders a [WeatherForecast] as a multi-line, human-readable text
/// block. The format is stable across versions of this CLI — tests
/// pin specific lines, so changes here should be deliberate.
///
/// Example output (3-day forecast for Boston):
///
/// ```
/// Boston, France (43.60°N, 1.44°E)
/// Now:  18.5°C feels like 17.2°C, partly cloudy, wind 12 km/h
///
///   Sat May 09  10.5–20.0°C  partly cloudy   precip 0% ( 0.0 mm)  uv 6.0
///   Sun May 10  11.0–22.0°C  cloudy          precip 30% ( 0.5 mm)  uv 7.0
///   Mon May 11  12.5–18.5°C  slight rain     precip 70% ( 4.2 mm)  uv 4.0
///
/// Fetched 2026-05-09T12:00:00.000Z
/// ```
String renderText(WeatherForecast forecast) {
  final buf = StringBuffer();

  // ── Location line ──
  final city = forecast.city;
  buf.writeln(_locationLine(city));

  // ── Current conditions ──
  buf.writeln(_currentLine(forecast.current));
  buf.writeln();

  // ── Daily series ──
  for (final day in forecast.daily) {
    buf.writeln(_dailyLine(day));
  }

  // ── Footer with retrieval time ──
  buf
    ..writeln()
    ..writeln('Fetched ${forecast.fetchedAt.toIso8601String()}');

  return buf.toString();
}

String _locationLine(City city) {
  // Use the absolute value with a cardinal-direction suffix so a
  // negative coordinate doesn't read as a double-negative ("-3.45°S").
  final latStr =
      '${city.latitude.abs().toStringAsFixed(2)}°${city.latitude >= 0 ? "N" : "S"}';
  final lonStr =
      '${city.longitude.abs().toStringAsFixed(2)}°${city.longitude >= 0 ? "E" : "W"}';
  return '${city.name}, ${city.country} ($latStr, $lonStr)';
}

String _currentLine(CurrentWeather current) {
  final temp = current.temperatureCelsius.toStringAsFixed(1);
  final feels = current.apparentTemperatureCelsius.toStringAsFixed(1);
  final wind = current.windSpeedKmh.toStringAsFixed(0);
  return 'Now:  $temp°C feels like $feels°C, '
      '${current.weatherCode.description.toLowerCase()}, '
      'wind $wind km/h';
}

String _dailyLine(DailyForecast day) {
  // 14-character date like "Sat May 09".
  final date = _shortDate(day.date);
  final tempRange =
      '${day.temperatureMinCelsius.toStringAsFixed(1)}'
      '–'
      '${day.temperatureMaxCelsius.toStringAsFixed(1)}°C';
  // Pad descriptions to a fixed column so the trailing precip / uv
  // align across rows.
  final desc = day.weatherCode.description.toLowerCase().padRight(14);
  final precipPct = day.precipitationProbabilityMaxPercent.toStringAsFixed(0);
  final precipMm = day.precipitationSumMm.toStringAsFixed(1);
  final uv = day.uvIndexMax.toStringAsFixed(1);
  return '  ${date.padRight(11)}'
      '$tempRange  '
      '$desc  '
      'precip ${precipPct.padLeft(2)}% (${precipMm.padLeft(4)} mm)  '
      'uv $uv';
}

const _weekdayNames = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

const _monthNames = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _shortDate(DateTime date) {
  // DateTime.weekday returns 1..7 for Mon..Sun.
  final dayName = _weekdayNames[date.weekday - 1];
  final monthName = _monthNames[date.month - 1];
  return '$dayName $monthName ${date.day.toString().padLeft(2, '0')}';
}
