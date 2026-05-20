// Dartastic OpenTelemetry bootstrap for Dinger.
//
// Everything is configured at build time via --dart-define, so no secrets
// live in the repo. Point it at a local collector for development, or at a
// Dartastic Hosted box for the "watch it light up" demo:
//
//   flutter run \
//     --dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=https://<your-box>.dartastic.io \
//     --dart-define=DARTASTIC_TENANT=<your-tenant> \
//     --dart-define=DARTASTIC_API_KEY=<your-key> \
//     --dart-define=GEMINI_API_KEY=<your-gemini-key>
//
// (Adjust the header names below to match what your Hosted box expects.)

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter/foundation.dart' show kDebugMode;

const String otlpEndpoint = String.fromEnvironment(
  'OTEL_EXPORTER_OTLP_ENDPOINT',
  defaultValue: 'http://localhost:4318',
);
const String _tenant =
    String.fromEnvironment('DARTASTIC_TENANT', defaultValue: '');
const String _apiKey =
    String.fromEnvironment('DARTASTIC_API_KEY', defaultValue: '');

/// True when we're shipping to a real Dartastic Hosted endpoint (not the
/// local dev collector) — used only for a UI hint.
bool get sendingToHosted =>
    otlpEndpoint.startsWith('https') || otlpEndpoint.contains('dartastic.io');

Future<void> initTelemetry() async {
  final headers = <String, String>{
    if (_tenant.isNotEmpty) 'x-dartastic-tenant': _tenant,
    if (_apiKey.isNotEmpty) 'x-dartastic-api-key': _apiKey,
  };

  final exporter = OtlpHttpSpanExporter(
    OtlpHttpExporterConfig(
      endpoint: otlpEndpoint,
      // JSON is friendliest for local collectors in debug; protobuf is the
      // compact production wire format.
      protocol:
          kDebugMode ? OtlpHttpProtocol.httpJson : OtlpHttpProtocol.httpProtobuf,
      headers: headers.isEmpty ? null : headers,
      compression: !kDebugMode,
    ),
  );

  await OTel.initialize(
    serviceName: 'dinger',
    serviceVersion: '1.0.0',
    endpoint: otlpEndpoint,
    secure: otlpEndpoint.startsWith('https'),
    spanProcessor: BatchSpanProcessor(exporter),
    enableMetrics: false,
    enableLogs: false,
  );
}
