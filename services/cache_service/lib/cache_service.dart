// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

/// Caching weather provider for the Dart OTel demo. Implements the v1
/// weather API so `weather_client` (and anything else that speaks the
/// same contract) can use it as the upstream `WeatherProvider`.
///
/// The deployable binary lives at `bin/server.dart`. This library
/// exports the pipeline-builder and supporting types so tests and
/// other binaries can compose them without binding to a port.
library;

export 'src/cache.dart' show CacheOutcome, TtlCache;
export 'src/error_mapping.dart' show httpStatusForProviderError;
export 'src/router.dart'
    show
        ForecastKey,
        GeocodeKey,
        buildCacheServicePipeline,
        defaultForecastTtl,
        defaultGeocodeTtl,
        maxForecastDays,
        minForecastDays;
