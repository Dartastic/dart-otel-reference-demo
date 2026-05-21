# Edge reverse-proxy that emits its OWN OpenTelemetry traces via the
# official ngx_otel_module — so a trace starts at the front door
# (nginx) and fans out through weather-api → cache-service → open-meteo
# as one waterfall.
#
# The official nginx image is built from nginx.org packages, so the
# matching dynamic module is a plain apt install — no custom build.
FROM nginx:1.27

RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx-module-otel \
    && rm -rf /var/lib/apt/lists/*

COPY deploy/local/nginx/nginx.conf /etc/nginx/nginx.conf
