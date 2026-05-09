// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

/// Command-line client for the demo's v1 weather API.
///
/// The deployable binary lives at `bin/weather.dart`. This library
/// exports the pure formatters and the entry function so tests can
/// drive the same code paths the binary does.
library;

export 'src/output.dart' show renderJson, renderText;
export 'src/run.dart' show exitFailure, exitOk, exitUsage, runWeatherCli;
