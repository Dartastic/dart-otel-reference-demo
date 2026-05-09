// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:weather_core/weather_core.dart';

/// Maps a [WeatherProviderErrorKind] to the HTTP status code we return to
/// the caller.
///
/// Rationale per kind:
///
///   * `badRequest`  → 400 — the caller asked for something invalid (an
///     out-of-range `days`, an empty city name). The provider call never
///     went out.
///   * `notFound`    → 404 — the geocoder returned no matches for the
///     supplied city name. The caller asked for a real but nonexistent
///     resource.
///   * `rateLimit`   → 429 — the upstream returned 429 to us. We pass
///     that signal through so the caller knows to back off.
///   * `network`     → 503 — the upstream is unreachable from this
///     service. The 5xx family is correct (the failure is server-side
///     from the caller's perspective) and `503 Service Unavailable`
///     more precisely describes "I cannot complete your request right
///     now" than the generic 502.
///   * `upstream`,
///     `parse`,
///     `unknown`     → 502 — the upstream returned a 5xx, returned
///     malformed data, or failed in some way we can't further classify.
///     Bad Gateway is the standard signal that an intermediary's
///     backend misbehaved.
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
