// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

/// Application-side OpenTelemetry bootstrap for the Dart OTel demo.
///
/// ```dart
/// import 'package:weather_otel/weather_otel.dart';
///
/// Future<void> main() async {
///   final otel = await initializeOtel(
///     serviceName: 'weather-api',
///     serviceVersion: '1.0.0',
///   );
///   otel.attachToProcessLifecycle();
///   // ... run the service ...
/// }
/// ```
///
/// See the package README for the full API.
library;

export 'src/bootstrap.dart' show defaultSamplingRatio, initializeOtel;
export 'src/cloud_run_token_provider.dart' show cloudRunIdTokenProvider;
export 'src/handle.dart' show WeatherOtelHandle;
export 'src/zone_handler.dart' show runWithOtelErrorHandlers;
