# Edge reverse-proxy that emits its OWN OpenTelemetry traces via the
# official ngx_otel_module — so a trace starts at the front door
# (nginx) and fans out through weather-api → cache-service → open-meteo
# as one waterfall.
#
# The base image is built from nginx.org packages, but it does NOT ship
# nginx.org's apt repo — only Debian's, which has no nginx-module-* at
# all. So the repo has to be added here before the module is installable.
#
# The module is a *dynamic* module and nginx refuses to load one built
# against a different nginx version, so it is pinned to this image's own
# ${NGINX_VERSION}. If nginx.org stops publishing a module for that
# version the build fails loudly here, rather than producing an image
# that dies at startup on "module is not binary compatible".
FROM nginx:1.30

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates gnupg; \
    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg; \
    . /etc/os-release; \
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg]" \
         "http://nginx.org/packages/debian ${VERSION_CODENAME} nginx" \
         > /etc/apt/sources.list.d/nginx.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends "nginx-module-otel=${NGINX_VERSION}*"; \
    apt-get purge -y --auto-remove curl gnupg; \
    rm -rf /var/lib/apt/lists/*; \
    [ -f /usr/lib/nginx/modules/ngx_otel_module.so ]

COPY deploy/local/nginx/nginx.conf /etc/nginx/nginx.conf
