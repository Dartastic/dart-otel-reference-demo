// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:weather_http_kit/weather_http_kit.dart';

import '../_helpers/otel_test_harness.dart';

/// Builds a synthetic shelf request with the given method/path/headers.
Request _request(String method, String path, {Map<String, String>? headers}) {
  return Request(
    method,
    Uri.parse('http://localhost:8080$path'),
    headers: headers,
  );
}

void main() {
  late OtelTestHarness harness;
  late InMemorySpanExporter spans;

  setUpAll(() async {
    harness = await maybeInitializeOtelForTest();
    spans = harness.spans;
  });
  setUp(() => harness.clear());

  group('otelMiddleware', () {
    test('emits a server span with HTTP semconv attributes', () async {
      final handler = const Pipeline()
          .addMiddleware(otelMiddleware())
          .addHandler((Request req) => Response.ok('hi'));

      final response = await handler(_request('GET', '/weather'));

      expect(response.statusCode, 200);
      final span = spans.findSpanByName('GET');
      expect(span, isNotNull);
      expect(span!.kind, SpanKind.server);
      expect(span.status, SpanStatusCode.Ok);
    });

    test('uses route from RouteResolver in span name', () async {
      final handler = const Pipeline()
          .addMiddleware(otelMiddleware(routeResolver: (_) => '/weather/:city'))
          .addHandler((Request req) => Response.ok('hi'));

      await handler(_request('GET', '/weather/Toulouse'));

      final span = spans.findSpanByName('GET /weather/:city');
      expect(span, isNotNull);
    });

    test('custom ServerSpanNamer overrides the default name', () async {
      final handler = const Pipeline()
          .addMiddleware(otelMiddleware(spanNamer: (req) => 'custom-name'))
          .addHandler((_) => Response.ok('hi'));

      await handler(_request('POST', '/anything'));

      expect(spans.findSpanByName('custom-name'), isNotNull);
    });

    test('5xx responses map to span status Error', () async {
      final handler = const Pipeline()
          .addMiddleware(otelMiddleware())
          .addHandler((_) => Response.internalServerError(body: 'boom'));

      final response = await handler(_request('GET', '/x'));

      expect(response.statusCode, 500);
      final span = spans.findSpanByName('GET');
      expect(span, isNotNull);
      expect(span!.status, SpanStatusCode.Error);
    });

    test(
      '4xx responses leave span status Ok (caller error, not server)',
      () async {
        final handler = const Pipeline()
            .addMiddleware(otelMiddleware())
            .addHandler((_) => Response.badRequest(body: 'malformed'));

        final response = await handler(_request('GET', '/x'));

        expect(response.statusCode, 400);
        final span = spans.findSpanByName('GET');
        expect(span!.status, SpanStatusCode.Ok);
      },
    );

    test('handler exceptions are recorded on the span and rethrown', () async {
      final handler = const Pipeline()
          .addMiddleware(otelMiddleware())
          .addHandler((_) => throw StateError('boom'));

      await expectLater(
        handler(_request('GET', '/x')),
        throwsA(isA<StateError>()),
      );

      final span = spans.findSpanByName('GET');
      expect(span, isNotNull);
      expect(span!.status, SpanStatusCode.Error);
      expect(span.spanEvents?.any((e) => e.name == 'exception'), true);
    });

    test(
      'extracts inbound traceparent so the server span is a child',
      () async {
        // A valid W3C traceparent: version-traceid-parentid-flags.
        const traceId = '00112233445566778899aabbccddeeff';
        const parentId = '0011223344556677';
        const traceparent = '00-$traceId-$parentId-01';

        final handler = const Pipeline()
            .addMiddleware(otelMiddleware())
            .addHandler((_) => Response.ok('hi'));

        await handler(
          _request(
            'GET',
            '/x',
            headers: <String, String>{'traceparent': traceparent},
          ),
        );

        // Inspect the exported span — it should share the inbound trace id
        // and have a fresh span id of its own.
        final span = spans.findSpanByName('GET');
        expect(span, isNotNull);
        expect(span!.spanContext.traceId.hexString, traceId);
        expect(span.spanContext.spanId.hexString, isNot(parentId));
      },
    );

    test('handler runs with the new span as the active span', () async {
      // `Context.current.span` returns the API-level type `APISpan?` —
      // every concrete SDK span implements that interface. We use an
      // `is Span` check to promote to the concrete SDK type (which is
      // exported by `dartastic_opentelemetry`); that lets the test assert
      // SDK-only properties such as `kind`. The check also guards
      // against an accidental no-op API span sneaking in.
      Span? capturedActive;
      final handler = const Pipeline()
          .addMiddleware(otelMiddleware())
          .addHandler((_) {
            final s = Context.current.span;
            if (s is Span) capturedActive = s;
            return Response.ok('hi');
          });

      await handler(_request('GET', '/weather/Toulouse?units=metric'));
      expect(capturedActive, isNotNull);
      expect(capturedActive!.name, 'GET');
      expect(capturedActive!.kind, SpanKind.server);
    });

    test(
      'extracts inbound baggage so the handler sees it on Context.current',
      () async {
        // Open-Meteo doesn't itself use baggage, but services in the demo
        // chain (CLI -> weather_api -> cache_service) can pass low-cardinality
        // tenant / user identifiers via baggage. The middleware must extract
        // any `baggage` header into Context.current so downstream code in the
        // handler can read it.
        String? capturedUserId;
        final handler = const Pipeline()
            .addMiddleware(otelMiddleware())
            .addHandler((_) {
              capturedUserId = Context.current.baggage
                  ?.getEntry('user_id')
                  ?.value;
              return Response.ok('hi');
            });

        await handler(
          _request(
            'GET',
            '/x',
            headers: <String, String>{'baggage': 'user_id=42,tenant=acme'},
          ),
        );

        expect(capturedUserId, '42');
      },
    );

    test(
      'records http.server.request.duration with low-cardinality labels',
      () async {
        // Drive a request through the middleware so the histogram fires,
        // then collect the resulting metrics from the in-memory reader.
        final handler = const Pipeline()
            .addMiddleware(
              otelMiddleware(routeResolver: (_) => '/weather/:city'),
            )
            .addHandler((_) => Response.ok('hi'));
        await handler(_request('GET', '/weather/Toulouse'));

        await harness.collectMetrics();

        final metric = harness.metrics.findMetricByName(
          'http.server.request.duration',
        );
        expect(
          metric,
          isNotNull,
          reason: 'expected the duration histogram to be exported',
        );

        // Verify the labels are exactly the low-cardinality set we
        // committed to: method, route TEMPLATE (not concrete path),
        // status code, scheme. If a future change quietly added a
        // high-cardinality label like url.path, this test catches it
        // before the metric series count explodes in production.
        expect(metric!.points, isNotEmpty);
        final attributes = metric.points.first.attributes;
        final attributeMap = <String, Object?>{
          for (final attr in attributes.toList()) attr.key: attr.value,
        };
        expect(
          attributeMap.keys.toSet(),
          <String>{
            'http.request.method',
            'http.route',
            'http.response.status_code',
            'url.scheme',
          },
          reason: 'metric labels must be the low-cardinality subset only',
        );
        expect(attributeMap['http.request.method'], 'GET');
        expect(attributeMap['http.route'], '/weather/:city');
        expect(attributeMap['http.response.status_code'], 200);
        expect(attributeMap['url.scheme'], 'http');
      },
    );
  });
}
