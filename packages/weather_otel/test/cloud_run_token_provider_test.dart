// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:weather_otel/weather_otel.dart';

/// Builds a JWT-shaped string with the given `exp` claim. Header and
/// signature are stub values — the SUT only decodes the payload to
/// read `exp`.
String _fakeJwt({required int expEpochSeconds, String? aud}) {
  String b64(Object obj) =>
      base64Url.encode(utf8.encode(jsonEncode(obj))).replaceAll('=', '');
  final header = b64(<String, String>{'alg': 'RS256', 'typ': 'JWT'});
  final payload = b64(<String, Object>{'exp': expEpochSeconds, 'aud': ?aud});
  return '$header.$payload.signature';
}

void main() {
  final audience = Uri.parse('https://cache-service-abc.a.run.app');

  group('cloudRunIdTokenProvider', () {
    test(
      'returns null without calling the metadata server when K_SERVICE is unset',
      () async {
        var calls = 0;
        final mock = MockClient((_) async {
          calls++;
          return http.Response('should-not-be-called', 200);
        });
        final provider = cloudRunIdTokenProvider(
          audience: audience,
          client: mock,
        );

        expect(await provider(), isNull);
        expect(await provider(), isNull);
        expect(calls, 0);
      },
    );

    test(
      'fetches an ID token from the metadata server when K_SERVICE is set',
      () async {
        final futureExp = DateTime.now().toUtc().add(const Duration(hours: 1));
        final token = _fakeJwt(
          expEpochSeconds: futureExp.millisecondsSinceEpoch ~/ 1000,
        );

        Uri? observedUri;
        Map<String, String>? observedHeaders;
        final mock = MockClient((request) async {
          observedUri = request.url;
          observedHeaders = request.headers;
          return http.Response(token, 200);
        });
        final provider = cloudRunIdTokenProvider(
          audience: audience,
          client: mock,
          environment: const <String, String>{'K_SERVICE': 'weather-api'},
        );

        expect(await provider(), token);
        expect(
          observedUri.toString(),
          startsWith(
            'http://metadata.google.internal'
            '/computeMetadata/v1/instance/service-accounts/default/identity?audience=',
          ),
        );
        expect(observedUri!.queryParameters['audience'], audience.toString());
        expect(observedHeaders!['Metadata-Flavor'], 'Google');
      },
    );

    test('caches the token across calls', () async {
      final futureExp = DateTime.now().toUtc().add(const Duration(hours: 1));
      final token = _fakeJwt(
        expEpochSeconds: futureExp.millisecondsSinceEpoch ~/ 1000,
      );

      var calls = 0;
      final mock = MockClient((_) async {
        calls++;
        return http.Response(token, 200);
      });
      final provider = cloudRunIdTokenProvider(
        audience: audience,
        client: mock,
        environment: const <String, String>{'K_SERVICE': 'weather-api'},
      );

      // Three calls back-to-back hit the metadata server exactly once.
      expect(await provider(), token);
      expect(await provider(), token);
      expect(await provider(), token);
      expect(calls, 1);
    });

    test(
      'refreshes when the cached token is within refreshLeadTime of exp',
      () async {
        // First fetch returns a token that expires in 30s; second fetch
        // returns a fresh one. With refreshLeadTime = 1m, the second
        // call must refresh.
        final firstExp = DateTime.now().toUtc().add(
          const Duration(seconds: 30),
        );
        final firstToken = _fakeJwt(
          expEpochSeconds: firstExp.millisecondsSinceEpoch ~/ 1000,
        );
        final secondExp = DateTime.now().toUtc().add(const Duration(hours: 1));
        final secondToken = _fakeJwt(
          expEpochSeconds: secondExp.millisecondsSinceEpoch ~/ 1000,
        );
        final tokens = <String>[firstToken, secondToken];
        var calls = 0;
        final mock = MockClient((_) async {
          final t = tokens[calls];
          calls++;
          return http.Response(t, 200);
        });
        // refreshLeadTime defaults to 1 minute; the cached token's exp
        // (now+30s) is inside that window, so the second call refreshes.
        final provider = cloudRunIdTokenProvider(
          audience: audience,
          client: mock,
          environment: const <String, String>{'K_SERVICE': 'weather-api'},
        );

        expect(await provider(), firstToken);
        // Second call: cached token's exp (now+30s) is within
        // refreshLeadTime (1m) of now, so we refresh.
        expect(await provider(), secondToken);
        expect(calls, 2);
      },
    );

    test('coalesces concurrent first-call fetches into a single hit', () async {
      final futureExp = DateTime.now().toUtc().add(const Duration(hours: 1));
      final token = _fakeJwt(
        expEpochSeconds: futureExp.millisecondsSinceEpoch ~/ 1000,
      );
      var calls = 0;
      final mock = MockClient((_) async {
        calls++;
        // Slow response so concurrent callers see the in-flight future.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return http.Response(token, 200);
      });
      final provider = cloudRunIdTokenProvider(
        audience: audience,
        client: mock,
        environment: const <String, String>{'K_SERVICE': 'weather-api'},
      );

      final results = await Future.wait<String?>(<Future<String?>>[
        provider(),
        provider(),
        provider(),
      ]);

      expect(results, everyElement(token));
      expect(calls, 1);
    });

    test('throws on a non-200 metadata server response', () async {
      final mock = MockClient((_) async {
        return http.Response('forbidden', 403);
      });
      final provider = cloudRunIdTokenProvider(
        audience: audience,
        client: mock,
        environment: const <String, String>{'K_SERVICE': 'weather-api'},
      );

      await expectLater(provider(), throwsA(isA<StateError>()));
    });
  });
}
