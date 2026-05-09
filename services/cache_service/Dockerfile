# services/cache_service/Dockerfile
#
# Two-stage build, same shape as services/weather_api/Dockerfile.
# Build context MUST be the repository root because the workspace's
# pubspec.yaml at the root resolves all member packages.
#
#   docker build -t cache_service -f services/cache_service/Dockerfile .

# ──────────────────────────── Build stage ────────────────────────────
FROM dart:stable AS build
WORKDIR /app

COPY pubspec.yaml ./
COPY analysis_options.yaml ./
COPY packages ./packages
COPY services ./services
COPY apps ./apps

# `dart compile exe` does not auto-create the output directory; see
# the longer comment in services/weather_api/Dockerfile.
RUN dart pub get
RUN mkdir -p /app/bin && \
    dart compile exe \
        services/cache_service/bin/server.dart \
        -o /app/bin/cache_service

# ──────────────────────────── Runtime stage ──────────────────────────
# `FROM scratch` with `/runtime/` from the build stage is the official
# Dart team pattern — see services/weather_api/Dockerfile for the
# longer comment.
FROM scratch AS runtime
WORKDIR /app

COPY --from=build /runtime/ /
COPY --from=build /app/bin/cache_service /app/bin/cache_service

ENV PORT=8090
EXPOSE 8090

ENTRYPOINT ["/app/bin/cache_service"]
