// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

/// HTTP front door for the Dart OTel demo.
///
/// The deployable binary lives at `bin/server.dart`. This library exports
/// the pure pipeline-builder so tests can construct the same handler
/// against an in-memory provider without binding to a port.
library;

export 'src/error_mapping.dart' show httpStatusForProviderError;
export 'src/router.dart'
    show
        buildWeatherApiPipeline,
        defaultForecastDays,
        maxForecastDays,
        minForecastDays;
