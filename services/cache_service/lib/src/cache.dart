// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:meta/meta.dart';

/// Outcome of a cache lookup. Used as a low-cardinality span attribute
/// (`weather.cache.outcome`) and as a metric label.
enum CacheOutcome {
  /// Entry present and not expired. Caller used the cached value.
  hit,

  /// Entry present but past its TTL. Caller had to refill from upstream.
  /// Reported separately from miss because expiry suggests the TTL may
  /// need tuning, while miss suggests a cold cache or low key reuse.
  expired,

  /// No entry for the key. Caller had to populate from upstream.
  miss,
}

/// A minimal time-aware cache. Single-isolate, in-memory, no eviction
/// beyond TTL — sized for a demo, not a production cache. Replace with
/// a Caffeine-style cache or a Redis client when you need bounds and
/// eviction policy.
class TtlCache<K, V> {
  TtlCache({required this.ttl, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// How long an entry stays valid after insertion.
  final Duration ttl;

  /// Clock function. Injectable so tests can advance time without
  /// waiting for it. Defaults to `DateTime.now`.
  final DateTime Function() _now;

  final Map<K, _Entry<V>> _entries = <K, _Entry<V>>{};

  /// Returns the cached value for [key] if present and not expired.
  /// Returns `(null, miss)` for an absent key, `(null, expired)` for a
  /// stale one (and removes the stale entry), `(value, hit)` otherwise.
  ({V? value, CacheOutcome outcome}) get(K key) {
    final entry = _entries[key];
    if (entry == null) {
      return (value: null, outcome: CacheOutcome.miss);
    }
    if (_now().isAfter(entry.expiresAt)) {
      _entries.remove(key);
      return (value: null, outcome: CacheOutcome.expired);
    }
    return (value: entry.value, outcome: CacheOutcome.hit);
  }

  /// Inserts or replaces the entry for [key], stamping `expiresAt`
  /// at `now + ttl`.
  void put(K key, V value) {
    _entries[key] = _Entry<V>(value: value, expiresAt: _now().add(ttl));
  }

  /// Number of cached entries (including any that may now be expired
  /// but haven't been touched since). Used as a low-cardinality span
  /// attribute and as a metric value.
  int get size => _entries.length;

  @visibleForTesting
  void clear() => _entries.clear();
}

class _Entry<V> {
  _Entry({required this.value, required this.expiresAt});
  final V value;
  final DateTime expiresAt;
}
