// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

// Conditional-import target for dart:io platforms. Re-exports the real
// `SocketException` so the catch block in `weather_client.dart` matches
// connection-refused, host-unreachable, and similar low-level network
// failures that bypass `package:http`'s `ClientException`.
//
// The web counterpart of this file is `socket_exception_web.dart`,
// which declares a stub class — the catch block is then well-typed on
// web but unreachable, since browser HTTP errors arrive as
// `http.ClientException` (or a JS-side exception that the http
// package wraps).

export 'dart:io' show SocketException;
