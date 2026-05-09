// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:weather_core/weather_core.dart';

/// HTTP status code to return for a [WeatherProviderErrorKind] that
/// arose while talking to the upstream (Open-Meteo) on a cache miss.
///
/// Same mapping as `services/weather_api/lib/src/error_mapping.dart`
/// — kept symmetric so a 5xx out of Open-Meteo surfaces as a 5xx to
/// `weather_api`, which surfaces as a 5xx to the original caller.
/// Cause attribution is preserved across both server hops.
int httpStatusForProviderError(WeatherProviderErrorKind kind) {
  switch (kind) {
    case WeatherProviderErrorKind.badRequest:
      return 400;
    case WeatherProviderErrorKind.notFound:
      return 404;
    case WeatherProviderErrorKind.rateLimit:
      return 429;
    case WeatherProviderErrorKind.network:
      return 503;
    case WeatherProviderErrorKind.upstream:
    case WeatherProviderErrorKind.parse:
    case WeatherProviderErrorKind.unknown:
      return 502;
  }
}
