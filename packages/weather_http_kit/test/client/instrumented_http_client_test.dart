// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:weather_http_kit/weather_http_kit.dart';

import '../_helpers/otel_test_harness.dart';

void main() {
  late OtelTestHarness harness;
  late InMemorySpanExporter spans;

  setUpAll(() async {
    harness = await maybeInitializeOtelForTest();
    spans = harness.spans;
  });
  setUp(() => spans.clear());

  group('InstrumentedHttpClient.send', () {
    test('emits a client-kind span with HTTP semconv attributes', () async {
      final inner = MockClient((req) async {
        return http.Response('ok', 200);
      });
      final client = InstrumentedHttpClient(inner: inner);

      final response = await client.get(Uri.parse('http://example.com/api'));
      expect(response.statusCode, 200);

      final span = spans.findSpanByName('GET');
      expect(span, isNotNull);
      expect(span!.kind, SpanKind.client);
      expect(span.status, SpanStatusCode.Ok);
    });

    test('injects W3C traceparent into outbound request headers', () async {
      String? capturedTraceparent;
      final inner = MockClient((req) async {
        capturedTraceparent = req.headers['traceparent'];
        return http.Response('ok', 200);
      });
      final client = InstrumentedHttpClient(inner: inner);

      await client.get(Uri.parse('http://example.com/api'));

      expect(capturedTraceparent, isNotNull);
      // Must match the W3C traceparent format:
      //   version-traceid-spanid-flags
      //   2 hex - 32 hex - 16 hex - 2 hex
      expect(
        capturedTraceparent,
        matches(RegExp(r'^[0-9a-f]{2}-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$')),
      );

      // The injected traceparent's trace id must match the emitted span's
      // trace id — that is the entire point of the injection.
      final span = spans.findSpanByName('GET');
      expect(span, isNotNull);
      final injectedTraceId = capturedTraceparent!.split('-')[1];
      expect(injectedTraceId, span!.spanContext.traceId.hexString);
    });

    test(
      '4xx responses set span status Error per OTel client-span semconv',
      () async {
        final inner = MockClient((_) async => http.Response('not found', 404));
        final client = InstrumentedHttpClient(inner: inner);

        final response = await client.get(Uri.parse('http://example.com/x'));
        expect(response.statusCode, 404);

        final span = spans.findSpanByName('GET');
        expect(span!.status, SpanStatusCode.Error);
      },
    );

    test('5xx responses set span status Error', () async {
      final inner = MockClient((_) async => http.Response('boom', 503));
      final client = InstrumentedHttpClient(inner: inner);

      final response = await client.get(Uri.parse('http://example.com/x'));
      expect(response.statusCode, 503);

      final span = spans.findSpanByName('GET');
      expect(span!.status, SpanStatusCode.Error);
    });

    test('records exception when transport fails', () async {
      final inner = MockClient((_) async {
        throw const SocketException('connection refused');
      });
      final client = InstrumentedHttpClient(inner: inner);

      await expectLater(
        client.get(Uri.parse('http://example.com/x')),
        throwsA(isA<SocketException>()),
      );

      final span = spans.findSpanByName('GET');
      expect(span, isNotNull);
      expect(span!.status, SpanStatusCode.Error);
      expect(span.spanEvents?.any((e) => e.name == 'exception'), true);
    });

    test(
      'injects W3C baggage from Context.current into outbound headers',
      () async {
        // The client must read baggage from Context.current (set by the
        // calling code or by an upstream middleware) and inject it into the
        // outbound `baggage` header. This is what makes baggage flow across
        // process boundaries.
        String? capturedBaggage;
        final inner = MockClient((req) async {
          capturedBaggage = req.headers['baggage'];
          return http.Response('ok', 200);
        });
        final client = InstrumentedHttpClient(inner: inner);

        final baggage = OTel.baggageForMap(<String, String>{
          'user_id': '42',
          'tenant': 'acme',
        });
        final ctx = OTel.context(baggage: baggage);

        await ctx.run(
          () async => client.get(Uri.parse('http://example.com/api')),
        );

        expect(capturedBaggage, isNotNull);
        // Baggage is unordered; just verify both entries are present.
        expect(capturedBaggage, contains('user_id=42'));
        expect(capturedBaggage, contains('tenant=acme'));
      },
    );

    test('span name follows OTel semconv — just the HTTP method', () async {
      final inner = MockClient((_) async => http.Response('', 200));
      final client = InstrumentedHttpClient(inner: inner);

      await client.post(
        Uri.parse('http://example.com/users/42'),
        body: 'hello',
      );

      // Span is named after the method only — keeping span-name cardinality
      // bounded by the small set of HTTP methods. The full URL goes into
      // attributes, not the span name.
      expect(spans.findSpanByName('POST'), isNotNull);
      expect(spans.findSpanByName('POST /users/42'), isNull);
    });

    test('close() forwards to the inner client', () async {
      var innerClosed = false;
      final inner = _ClosingTrackingClient(onClose: () => innerClosed = true);
      final client = InstrumentedHttpClient(inner: inner);

      client.close();
      expect(innerClosed, true);
    });
  });
}

/// Minimal `http.Client` that records when `close()` is called.
class _ClosingTrackingClient extends http.BaseClient {
  _ClosingTrackingClient({required this.onClose});

  final void Function() onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw UnimplementedError('not used in close() test');
  }

  @override
  void close() {
    onClose();
    super.close();
  }
}
