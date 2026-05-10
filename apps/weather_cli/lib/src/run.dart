// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:weather_client/weather_client.dart';
import 'package:weather_core/weather_core.dart';
import 'package:weather_http_kit/weather_http_kit.dart';
import 'package:weather_otel/weather_otel.dart';

import 'output.dart';

const String _serviceName = 'weather-cli';
const String _serviceVersion = '0.1.0';

/// Default weather_api endpoint used when neither `--upstream` nor the
/// `WEATHER_API_URL` environment variable is set.
const String _defaultUpstreamUrl = 'http://localhost:8080';

/// Exit codes follow the BSD `sysexits.h` convention loosely:
///   * 0  — success
///   * 1  — operational failure (upstream returned an error, network
///          unreachable, malformed response, etc.)
///   * 64 — usage error (`EX_USAGE`)
const int exitOk = 0;
const int exitFailure = 1;
const int exitUsage = 64;

/// Entry point shared between `bin/weather.dart` and tests.
///
/// Returns the process exit code rather than calling `exit` directly, so
/// tests can drive `runWeatherCli` and assert on the return value
/// without terminating the test runner.
Future<int> runWeatherCli(
  List<String> args, {
  Stream<String>? stdoutSink,
  IOSink? stdoutOverride,
  IOSink? stderrOverride,
}) async {
  final out = stdoutOverride ?? stdout;
  final err = stderrOverride ?? stderr;

  // ── 1. Parse arguments. Usage errors return exitUsage immediately
  //       and do not touch the OTel SDK — there's nothing meaningful
  //       to trace before we know what we're being asked to do.
  final parser = _buildArgParser();
  late ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } on FormatException catch (e) {
    err
      ..writeln('error: ${e.message}')
      ..writeln()
      ..writeln(_usage(parser));
    return exitUsage;
  }

  if (parsed.flag('help')) {
    out.writeln(_usage(parser));
    return exitOk;
  }
  if (parsed.flag('version')) {
    out.writeln('weather_cli $_serviceVersion');
    return exitOk;
  }
  if (parsed.rest.isEmpty) {
    err
      ..writeln('error: missing required <city> argument')
      ..writeln()
      ..writeln(_usage(parser));
    return exitUsage;
  }
  if (parsed.rest.length > 1) {
    err
      ..writeln(
        'error: unexpected positional arguments after <city>: '
        '${parsed.rest.skip(1).join(" ")}',
      )
      ..writeln('  hint: quote multi-word city names ("New York")')
      ..writeln()
      ..writeln(_usage(parser));
    return exitUsage;
  }

  final city = parsed.rest.first;
  final days = int.tryParse(parsed['days'] as String);
  if (days == null || days < 1 || days > 16) {
    err.writeln('error: --days must be an integer in 1..16');
    return exitUsage;
  }

  final upstreamRaw =
      (parsed['upstream'] as String?) ??
      Platform.environment['WEATHER_API_URL'] ??
      _defaultUpstreamUrl;
  final Uri upstream;
  try {
    upstream = Uri.parse(upstreamRaw);
    if (!upstream.hasScheme || upstream.host.isEmpty) {
      throw const FormatException('missing scheme or host');
    }
  } on FormatException catch (e) {
    err.writeln(
      'error: --upstream is not a valid URL "$upstreamRaw" (${e.message})',
    );
    return exitUsage;
  }

  final asJson = parsed.flag('json');
  final quiet = parsed.flag('quiet');

  // ── 2. Logging setup before OTel so any init issues are visible.
  _configureLogging(quiet: quiet);
  final log = Logger('weather_cli');

  // ── 3. Initialize OpenTelemetry. The CLI is short-lived, so we don't
  //       attach signal handlers — natural exit through the finally
  //       block below runs the flush and shutdown. Ctrl-C still works
  //       (the default SIGINT handler kills the process), but spans
  //       in flight at that moment may be lost. That's the right
  //       trade-off for a one-shot CLI.
  final otel = await initializeOtel(
    serviceName: _serviceName,
    serviceVersion: _serviceVersion,
  );

  // Outbound HTTP client. InstrumentedHttpClient emits the client span
  // and injects W3C trace context — that's what stitches the CLI's
  // root span to weather_api's server span as a parent-child link.
  final outboundClient = InstrumentedHttpClient(
    inner: http.Client(),
    tracerName: 'weather_cli.http',
  );

  // WeatherClient is the v1 SDK. Implements WeatherProvider, so it can
  // drop into anything else that wants a remote provider — including,
  // notably, weather_api's own outbound path. Same code, two consumers.
  final client = WeatherClient(
    baseUrl: upstream,
    client: outboundClient,
    providerName: 'weather-api',
  );

  // Build baggage entries that the BaggageSpanProcessor will copy
  // onto every span across the trace — including spans emitted by
  // weather-api and cache-service after the W3C baggage propagator
  // carries these values across each HTTP hop. Two entries:
  //
  //   * cli.run_id — UUID v4 generated per CLI invocation. One run
  //     of `dart run apps/weather_cli/bin/weather.dart` produces one
  //     run_id; finding all spans for one run is a single search by
  //     `cli.run_id=<value>` in any backend.
  //   * cli.session_id — bounded set, sourced from the
  //     CLI_SESSION_ID env var. The swarm script
  //     (load/run_swarm.sh) sets one session id for an entire swarm
  //     so every CLI invocation in one batch shares it. Useful for
  //     load-test runs: "show me all spans across all 200 CLI
  //     invocations from yesterday's load test."
  //
  // Both are bounded-cardinality identifiers — safe to put on
  // baggage and safe for the BaggageSpanProcessor to copy onto
  // every span. Free-text values like a user query string DO NOT
  // belong here; they'd produce one span attribute combination per
  // distinct value across every backend that aggregates by
  // attribute.
  final runId = _generateRunId();
  final sessionId = Platform.environment['CLI_SESSION_ID'];
  final baggageEntries = <String, BaggageEntry>{
    'cli.run_id': OTel.baggageEntry(runId),
    if (sessionId != null && sessionId.isNotEmpty)
      'cli.session_id': OTel.baggageEntry(sessionId),
  };
  final baggage = OTel.baggage(baggageEntries);

  // The "root span" of the CLI's trace. Without this, the only span
  // would be the InstrumentedHttpClient's per-request client span, and
  // the trace would be a flat list rather than a hierarchy. A single
  // top-level INTERNAL span gives the user one row in the trace UI to
  // expand.
  final tracer = OTel.tracerProvider().getTracer('weather_cli');
  final rootSpan = tracer.startSpan(
    'cli.forecast',
    kind: SpanKind.internal,
    attributes: OTel.attributesFromMap(<String, Object>{
      'cli.command': 'forecast',
      'cli.city': city,
      'cli.days': days,
      'cli.output_format': asJson ? 'json' : 'text',
    }),
  );

  int exitCode;
  try {
    // Combine baggage and span on one Context for the rest of the
    // CLI's work. The InstrumentedHttpClient's W3CBaggagePropagator
    // reads from Context.current and injects the entries as a
    // `baggage` header on every outbound HTTP request, so they
    // propagate to weather-api and cache-service.
    exitCode = await Context.current
        .copyWithBaggage(baggage)
        .withSpan(rootSpan)
        .run(() async {
          try {
            log.info('Fetching $days-day forecast for "$city" from $upstream');
            final geocoded = await client.geocode(city);
            if (geocoded.isEmpty) {
              err.writeln('error: no city named "$city" was found');
              rootSpan.setStatus(.Error, 'city not found');
              return exitFailure;
            }
            final best = geocoded.best;
            if (geocoded.isAmbiguous) {
              rootSpan.addEventNow(
                'geocode.ambiguous',
                OTel.attributesFromMap(<String, Object>{
                  'weather.geocode.match_count': geocoded.matches.length,
                }),
              );
              if (!quiet) {
                err.writeln(
                  'note: "$city" matched ${geocoded.matches.length} '
                  'cities; using ${best.name}, ${best.country}',
                );
              }
            }
            final forecast = await client.getForecast(
              city: best,
              forecastDays: days,
            );
            out.write(asJson ? renderJson(forecast) : renderText(forecast));
            // Ensure the trailing newline is present even if renderJson
            // didn't include one — terminals and pipes both expect it.
            if (!asJson || !renderJson(forecast).endsWith('\n')) out.writeln();
            rootSpan.setStatus(.Ok);
            return exitOk;
          } on WeatherProviderException catch (e, st) {
            rootSpan
              ..recordException(e, stackTrace: st)
              ..setStatus(.Error, e.toString());
            err.writeln('error: ${e.kind.name}: ${e.message}');
            return exitFailure;
          } on Object catch (e, st) {
            rootSpan
              ..recordException(e, stackTrace: st)
              ..setStatus(.Error, e.toString());
            err.writeln('error: unexpected: $e');
            return exitFailure;
          }
        });
  } finally {
    rootSpan.end();
    await otel.shutdown();
    outboundClient.close();
  }

  return exitCode;
}

ArgParser _buildArgParser() {
  return ArgParser()
    ..addOption(
      'days',
      abbr: 'd',
      defaultsTo: '3',
      help: 'Forecast horizon in days (1..16).',
    )
    ..addOption(
      'upstream',
      abbr: 'u',
      help:
          'Base URL of the weather_api service.\n'
          '(default: \$WEATHER_API_URL or $_defaultUpstreamUrl)',
    )
    ..addFlag(
      'json',
      negatable: false,
      help: 'Emit machine-readable JSON instead of human-readable text.',
    )
    ..addFlag(
      'quiet',
      abbr: 'q',
      negatable: false,
      help: 'Suppress informational logging on stderr.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show this usage and exit.',
    )
    ..addFlag(
      'version',
      negatable: false,
      help: 'Print the CLI version and exit.',
    );
}

String _usage(ArgParser parser) {
  return 'Usage: weather_cli [options] <city>\n'
      '\n'
      'Fetches a weather forecast for <city> from a v1 weather API\n'
      '(by default, weather_api on http://localhost:8080) and prints it.\n'
      '\n'
      'Options:\n'
      '${parser.usage}\n'
      '\n'
      'Examples:\n'
      '  weather_cli Toulouse\n'
      '  weather_cli --days 7 "New York"\n'
      '  weather_cli --json --quiet Tokyo | jq .city.name';
}

void _configureLogging({required bool quiet}) {
  Logger.root.level = quiet ? Level.WARNING : Level.INFO;
  Logger.root.onRecord.listen((record) {
    final tag = '[${record.level.name}] ${record.loggerName}';
    stderr.writeln('$tag: ${record.message}');
    if (record.error != null) {
      stderr.writeln('  error: ${record.error}');
    }
  });
}

/// Generates an RFC 4122 v4 UUID with `Random.secure()`. Used as the
/// per-process `cli.run_id` baggage entry so every span across one
/// CLI invocation shares one identifier — searchable in any backend
/// without server-side correlation. `weather_otel.bootstrap` has the
/// equivalent helper for `service.instance.id`; duplicated here so
/// the CLI doesn't need a dependency on `weather_otel`'s internal
/// helpers (and so this file remains a single-source teaching
/// example for what a CLI's OTel wiring looks like).
String _generateRunId() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  final s = bytes.map(hex).join();
  return '${s.substring(0, 8)}-'
      '${s.substring(8, 12)}-'
      '${s.substring(12, 16)}-'
      '${s.substring(16, 20)}-'
      '${s.substring(20, 32)}';
}
