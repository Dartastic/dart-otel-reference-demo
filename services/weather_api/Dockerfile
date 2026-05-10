# services/weather_api/Dockerfile
#
# Two-stage build:
#   1. Build stage uses the full Dart SDK to fetch dependencies and
#      AOT-compile the server entrypoint to a self-contained native exe.
#   2. Runtime stage uses a small base image with just the libc the AOT
#      runtime needs.
#
# Build context MUST be the repository root, not this directory, because
# the workspace's pubspec.yaml at the root resolves all member packages.
# Build with:
#
#   docker build -t weather_api -f services/weather_api/Dockerfile .

# ──────────────────────────── Build stage ────────────────────────────
FROM dart:stable AS build
WORKDIR /app

# Copy the workspace, skipping apps/weather_flutter — it requires the
# Flutter SDK that this Dart-only image doesn't carry, and no server
# binary depends on it. The sed drops the Flutter app's entry from the
# workspace pubspec so `dart pub get` resolves cleanly.
COPY pubspec.yaml ./
COPY analysis_options.yaml ./
COPY packages ./packages
COPY services ./services
COPY apps/weather_cli ./apps/weather_cli
RUN sed -i '\|apps/weather_flutter|d' pubspec.yaml

# Fetch deps for the entire workspace, then AOT-compile the entrypoint.
# `dart compile exe` does not auto-create the output directory, so the
# mkdir is explicit. (Older docs implied otherwise; current versions of
# the SDK error with PathNotFoundException if the parent of `-o` is
# missing.)
RUN dart pub get
RUN mkdir -p /app/bin && \
    dart compile exe \
        services/weather_api/bin/server.dart \
        -o /app/bin/weather_api

# ──────────────────────────── Runtime stage ──────────────────────────
# `FROM scratch` is the official Dart team pattern for AOT-compiled
# servers. The `dart:stable` image has a `/runtime/` directory
# containing exactly the system libraries and config files an
# AOT-compiled exe needs (libc, ld-linux, ca-certificates, tzdata).
# Copying `/runtime/` plus the exe into a scratch image produces a
# ~10 MB final image with no shell, no package manager, no extra
# attack surface.
FROM scratch AS runtime
WORKDIR /app

# Copy the runtime support libraries first, then the AOT-compiled
# binary. The runtime layer changes only when the Dart SDK does;
# the binary changes on every source change. Putting them in
# separate COPY layers helps the build cache.
COPY --from=build /runtime/ /
COPY --from=build /app/bin/weather_api /app/bin/weather_api

# Service defaults — overridable at run-time via `docker run -e`.
ENV PORT=8080
EXPOSE 8080

# AOT exe handles SIGTERM via dart:io's ProcessSignal stream, which
# weather_otel.attachToProcessLifecycle wires up. The container's stop
# signal (SIGTERM by default) reaches the exe directly because it runs
# as PID 1 with no shell wrapper.
ENTRYPOINT ["/app/bin/weather_api"]
