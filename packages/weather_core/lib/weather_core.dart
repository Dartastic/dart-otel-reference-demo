// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

/// Domain models, weather provider abstraction, and business logic for the
/// Dart OTel demo.
///
/// Library code: uses the Dartastic OpenTelemetry SDK directly for
/// instrumentation but does not call `OTel.initialize()`. Consumers must
/// initialize the SDK at application startup before invoking this library;
/// see the `weather_otel` package for a bootstrap helper.
library;

// Instrumentation — domain-specific OpenTelemetry semantic enums.
export 'src/instrumentation/weather_semantics.dart';

// Models — immutable value types for the weather domain.
export 'src/models/city.dart';
export 'src/models/current_weather.dart';
export 'src/models/daily_forecast.dart';
export 'src/models/geocode_result.dart';
export 'src/models/weather_code.dart';
export 'src/models/weather_forecast.dart';

// Providers — the WeatherProvider abstraction and Open-Meteo implementation.
export 'src/providers/open_meteo_provider.dart';
export 'src/providers/weather_provider.dart';
export 'src/providers/weather_provider_exception.dart';

// Service — top-level orchestration with RED metrics.
export 'src/service/weather_service.dart';
