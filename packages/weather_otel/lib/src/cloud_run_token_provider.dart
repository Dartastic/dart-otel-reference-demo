// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// Returns a callback suitable for `WeatherClient.tokenProvider:` that
/// fetches a Google service-account ID token for [audience] from the
/// GCE metadata server when running on Cloud Run, and is a no-op
/// otherwise.
///
/// The standard pattern for Cloud Run service-to-service auth: when
/// `cache-service` is deployed `--no-allow-unauthenticated`, the
/// caller (`weather-api`) must attach an
/// `Authorization: Bearer ID-token` header on every request. The ID
/// token is signed by Google for the caller's runtime service account
/// with the upstream service URL as the audience claim. Cloud Run
/// validates the
/// signature and the audience and either lets the request through
/// (if the caller's service account has `roles/run.invoker` on the
/// upstream) or returns 401/403.
///
/// Usage in a service binary:
///
/// ```dart
/// final upstream = Uri.parse(Platform.environment['WEATHER_UPSTREAM_URL']!);
/// final client = WeatherClient(
///   baseUrl: upstream,
///   client: outboundClient,
///   tokenProvider: cloudRunIdTokenProvider(audience: upstream),
/// );
/// ```
///
/// Behaviour:
///
///   * When the `K_SERVICE` env var is not set — the platform marker
///     Cloud Run injects on every container — the returned closure
///     returns `null` synchronously. No metadata-server call is ever
///     made; the demo's local-stack and CLI runs continue to use the
///     non-auth path.
///
///   * On Cloud Run, the first call hits the metadata server and
///     caches the token. Subsequent calls return the cached value
///     until [refreshLeadTime] before its `exp` claim, at which
///     point the next call refreshes. The metadata server's tokens
///     are valid for ~1 hour; in practice the lead time means we
///     refresh just inside the last minute and never serve a stale
///     token.
///
///   * If the metadata-server call fails (HTTP error, network
///     error, no audience permission), the closure throws — and
///     `WeatherClient` translates that into a
///     `WeatherProviderException(network)` for the caller. The
///     pinned test in `weather_client/test/weather_client_test.dart`
///     locks that contract.
///
/// [environment] is provided for tests; production callers leave it
/// empty so the function reads `Platform.environment`. [client]
/// likewise — production callers leave it null and the function
/// uses a fresh `http.Client` (the metadata server is metadata-
/// server-only traffic, not user traffic, and doesn't need to share
/// the application's instrumented client).
Future<String?> Function() cloudRunIdTokenProvider({
  required Uri audience,
  http.Client? client,
  Map<String, String> environment = const <String, String>{},
  Duration refreshLeadTime = const Duration(minutes: 1),
}) {
  String? envLookup(String key) =>
      environment[key] ?? Platform.environment[key];

  // K_SERVICE is set by Cloud Run on every container start (also by
  // Cloud Functions Gen 2, which runs on Cloud Run). Its presence is
  // the canonical "am I on Cloud Run?" signal — more reliable than
  // checking metadata-server reachability, which would fail on hosts
  // that have a NAT to a private metadata IP.
  final isCloudRun = envLookup('K_SERVICE') != null;
  if (!isCloudRun) {
    return () async => null;
  }

  final logger = Logger('weather_otel.cloud_run_token_provider');
  final httpClient = client ?? http.Client();

  String? cachedToken;
  DateTime? cachedExpiry;
  Future<String>? inFlight;

  Future<String> fetchAndCache() async {
    // Coalesce concurrent calls that hit before the first fetch
    // completes — otherwise N parallel requests on first call all
    // hit the metadata server. Common pattern, worth the few lines
    // of bookkeeping.
    final existing = inFlight;
    if (existing != null) return existing;

    final fetch = _fetchIdToken(httpClient, audience);
    inFlight = fetch;
    try {
      final token = await fetch;
      cachedToken = token;
      cachedExpiry =
          _decodeJwtExpiry(token) ??
          DateTime.now().toUtc().add(const Duration(minutes: 50));
      logger.fine(
        'Cloud Run ID token fetched for $audience '
        '(expires $cachedExpiry)',
      );
      return token;
    } finally {
      inFlight = null;
    }
  }

  return () async {
    final now = DateTime.now().toUtc();
    final cachedTokenLocal = cachedToken;
    final cachedExpiryLocal = cachedExpiry;
    if (cachedTokenLocal != null &&
        cachedExpiryLocal != null &&
        cachedExpiryLocal.isAfter(now.add(refreshLeadTime))) {
      return cachedTokenLocal;
    }
    return fetchAndCache();
  };
}

/// Hits the GCE metadata server's `service-accounts/default/identity`
/// endpoint and returns the resulting JWT. Throws on any non-200
/// response — most commonly a 403 when the runtime service account
/// doesn't have `iam.serviceAccountTokenCreator` on itself (rare —
/// it's the default for Cloud Run runtime SAs) or when the audience
/// is malformed.
Future<String> _fetchIdToken(http.Client client, Uri audience) async {
  final uri = Uri.parse(
    'http://metadata.google.internal'
    '/computeMetadata/v1/instance/service-accounts/default/identity'
    '?audience=${Uri.encodeQueryComponent(audience.toString())}',
  );
  // Metadata-Flavor: Google is required by the metadata server. Its
  // absence returns 403 — both as a security check and a
  // misconfiguration sign for code that accidentally hits the
  // metadata IP.
  final response = await client.get(
    uri,
    headers: const <String, String>{'Metadata-Flavor': 'Google'},
  );
  if (response.statusCode != 200) {
    throw StateError(
      'metadata server returned HTTP ${response.statusCode} for '
      'audience=$audience: ${response.body}',
    );
  }
  return response.body.trim();
}

/// Decodes a JWT's payload and returns its `exp` claim as a UTC
/// [DateTime], or null if the JWT is malformed or has no exp.
///
/// Hand-rolled to avoid pulling a JWT library for what is
/// fundamentally a base64-decode + JSON-parse. The metadata server's
/// tokens are well-formed JWTs; this falls back to a sane default
/// expiry only when something is genuinely wrong (and the caller
/// will refresh on the next request anyway when the cache hits the
/// fallback expiry).
DateTime? _decodeJwtExpiry(String jwt) {
  final parts = jwt.split('.');
  if (parts.length != 3) return null;
  try {
    final padded = base64Url.normalize(parts[1]);
    final payload =
        jsonDecode(utf8.decode(base64Url.decode(padded)))
            as Map<String, dynamic>;
    final exp = payload['exp'];
    if (exp is int) {
      return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
    }
  } on Object catch (_) {
    // Malformed JWT — fall through to null.
  }
  return null;
}
