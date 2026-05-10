// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

/// HTTP client SDK for the demo's v1 weather API.
///
/// ```dart
/// final client = WeatherClient(
///   baseUrl: Uri.parse('http://cache-service:8090'),
///   client: InstrumentedHttpClient(inner: http.Client()),
/// );
/// final forecast = await WeatherService(provider: client)
///     .getForecast(cityName: 'Toulouse', forecastDays: 3);
/// ```
///
/// See the package README for the wire-format contract.
library;

export 'src/weather_client.dart' show WeatherClient, WeatherClientTokenProvider;
