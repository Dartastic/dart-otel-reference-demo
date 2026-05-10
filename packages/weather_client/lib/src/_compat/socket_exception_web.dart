// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

// Web stub for `SocketException`. `dart:io` is unavailable on the
// browser; this stub keeps the `on SocketException catch` block in
// `weather_client.dart` well-typed without an unconditional `dart:io`
// dependency.
//
// Browser HTTP errors arrive as `http.ClientException` (or a wrapping
// of a JS-side exception that the http package raises on fetch
// failure), not as `SocketException`. This catch is therefore
// unreachable on web — but keeping the type around means the same
// source file builds for both io and web targets unchanged.

class SocketException implements Exception {
  const SocketException(this.message);

  final String message;

  @override
  String toString() => 'SocketException: $message';
}
