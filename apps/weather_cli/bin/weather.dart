// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.
//
// weather_cli entry point.
//
// Tiny by design — all logic lives in lib/src/run.dart so tests can
// drive the same code path without spawning a process. This file
// exists only to call `runWeatherCli` and exit with its return code.

import 'dart:io';

import 'package:weather_cli/weather_cli.dart';
import 'package:weather_otel/weather_otel.dart';

void main(List<String> args) {
  runWithOtelErrorHandlers(() async {
    final code = await runWeatherCli(args);
    // Use `exitCode` rather than `exit(code)` so any pending I/O on
    // stdout or stderr drains before the process terminates. The
    // Dart VM exits with this code once the event loop is empty.
    exitCode = code;
  });
}
