// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:meta/meta.dart';

import 'city.dart';

/// The result of a geocoding lookup.
///
/// A geocoder may return zero, one, or many cities for a given query (e.g.
/// "Springfield" matches dozens of US cities). The caller decides how to
/// disambiguate; the service layer in this demo takes the first match,
/// records the alternatives count as a span attribute, and emits a
/// `geocode.ambiguous` span event when more than one match is returned.
@immutable
class GeocodeResult {
  const GeocodeResult({required this.query, required this.matches});

  /// The query string the user supplied (e.g. "Boston").
  final String query;

  /// Matching cities in the order returned by the provider — most relevant
  /// first by provider convention.
  final List<City> matches;

  /// Convenience accessor for the most relevant match.
  ///
  /// Throws [StateError] if the result is empty. Callers should check
  /// [isEmpty] first or handle the throw at the service layer where the
  /// not-found case becomes a 404 response with full span context.
  City get best {
    if (matches.isEmpty) {
      throw StateError('GeocodeResult for "$query" has no matches');
    }
    return matches.first;
  }

  bool get isEmpty => matches.isEmpty;
  bool get isNotEmpty => matches.isNotEmpty;
  bool get isAmbiguous => matches.length > 1;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GeocodeResult &&
          runtimeType == other.runtimeType &&
          query == other.query &&
          _listEquals(matches, other.matches);

  @override
  int get hashCode => Object.hash(query, Object.hashAll(matches));

  @override
  String toString() => 'GeocodeResult($query, ${matches.length} matches)';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
