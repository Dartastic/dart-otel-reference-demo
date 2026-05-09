// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:cache_service/cache_service.dart';
import 'package:test/test.dart';

void main() {
  group('TtlCache', () {
    test('returns miss for an absent key', () {
      final cache = TtlCache<String, int>(ttl: const Duration(seconds: 5));
      final result = cache.get('absent');
      expect(result.value, isNull);
      expect(result.outcome, CacheOutcome.miss);
    });

    test('returns hit before TTL elapses', () {
      var clock = DateTime.utc(2026, 5, 9, 12);
      final cache = TtlCache<String, int>(
        ttl: const Duration(seconds: 5),
        now: () => clock,
      );
      cache.put('k', 42);
      clock = clock.add(const Duration(seconds: 4));
      final result = cache.get('k');
      expect(result.value, 42);
      expect(result.outcome, CacheOutcome.hit);
    });

    test('returns expired and removes the entry after TTL', () {
      var clock = DateTime.utc(2026, 5, 9, 12);
      final cache = TtlCache<String, int>(
        ttl: const Duration(seconds: 5),
        now: () => clock,
      );
      cache.put('k', 42);
      clock = clock.add(const Duration(seconds: 6));

      final first = cache.get('k');
      expect(first.value, isNull);
      expect(first.outcome, CacheOutcome.expired);

      // After an expired lookup the entry is gone — the next lookup is
      // a miss, not a second 'expired'.
      final second = cache.get('k');
      expect(second.outcome, CacheOutcome.miss);
    });

    test('put replaces an existing entry and resets the TTL', () {
      var clock = DateTime.utc(2026, 5, 9, 12);
      final cache = TtlCache<String, int>(
        ttl: const Duration(seconds: 5),
        now: () => clock,
      );
      cache.put('k', 1);
      clock = clock.add(const Duration(seconds: 4));
      cache.put('k', 2);
      // 4s after the original put + 4s after the second put still
      // within TTL of the second put.
      clock = clock.add(const Duration(seconds: 4));
      final result = cache.get('k');
      expect(result.value, 2);
      expect(result.outcome, CacheOutcome.hit);
    });

    test('size reflects unexpired puts (untouched expired entries persist '
        'until next get)', () {
      var clock = DateTime.utc(2026, 5, 9, 12);
      final cache = TtlCache<String, int>(
        ttl: const Duration(seconds: 5),
        now: () => clock,
      );
      cache.put('a', 1);
      cache.put('b', 2);
      cache.put('c', 3);
      expect(cache.size, 3);
      clock = clock.add(const Duration(seconds: 6));
      // Still 3 — TtlCache does not sweep proactively. Document this
      // so callers don't expect size to drop without a get().
      expect(cache.size, 3);
    });
  });
}
