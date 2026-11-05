# syntax=docker/dockerfile:1

# Apitomy OpenAPI Editor - container image
#
# Multi-stage build:
#   1. "build"  - builds the editor web application from test-app/ (which
#                 bundles the component library sources in src/ via Vite
#                 path aliases).
#   2. runtime  - serves the static build output with Caddy.
#
# Build arguments:
#   BASE_PATH   Path prefix the app is served under. Must start and end with
#               a "/". Defaults to "/" (http://host:8080/). Use e.g. "/editor/"
#               to serve the app under http://host:8080/editor/.
#
# Example build & run:
#   docker build -t apitomy-openapi-editor .
#   docker run --rm -p 8080:8080 apitomy-openapi-editor

ARG NODE_VERSION=24.21.0
ARG CADDY_VERSION=2.10

# ---------------------------------------------------------------------------
# Stage 1: build the editor web application
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-alpine AS build

ARG BASE_PATH=/

RUN case "$BASE_PATH" in \
        /|/*/) echo "Building editor app for base path: ${BASE_PATH}" ;; \
        *)     echo "ERROR: BASE_PATH must start and end with a slash (e.g. / or /editor/)" >&2; exit 1 ;; \
    esac

WORKDIR /app

# The root project dependencies are required so the TypeScript compiler can
# resolve the library's dependencies (react, zustand, @apitomy/data-models,
# ...) when test-app compiles the sources in ../src.
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

# Install the test-app dependencies in their own layer so it is only
# invalidated when the dependency manifests change.
COPY test-app/package.json test-app/package-lock.json ./test-app/
RUN cd test-app && npm ci --no-audit --no-fund

# Application sources: the component library (src/) and the editor app
# (test-app/, which imports the library sources via Vite path aliases).
COPY src ./src
COPY test-app ./test-app

# `npm run build` runs the TypeScript compiler and the Vite build.
# VITE_BASE_PATH is picked up by test-app/vite.config.ts.
RUN cd test-app && VITE_BASE_PATH="${BASE_PATH}" npm run build

# ---------------------------------------------------------------------------
# Stage 2: serve the static build output with Caddy (non-root)
# ---------------------------------------------------------------------------
FROM caddy:${CADDY_VERSION}-alpine

ARG BASE_PATH=/

# BASE_PATH is kept as an environment variable so the health check below can
# use it at runtime. Caddy keeps no persistent state (no TLS, no admin API),
# so its state directories point to a writable scratch location.
ENV BASE_PATH=${BASE_PATH} \
    XDG_CONFIG_HOME=/tmp \
    XDG_DATA_HOME=/tmp

LABEL org.opencontainers.image.title="Apitomy OpenAPI Editor" \
      org.opencontainers.image.description="Visual OpenAPI editor based on the Apitomy OpenAPI Editor React component" \
      org.opencontainers.image.source="https://github.com/Apitomy/apitomy-openapi-editor" \
      org.opencontainers.image.licenses="Apache-2.0"

# Caddy listens on an unprivileged port.
EXPOSE 8080

# The built app is served under the configured base path.
COPY --from=build /app/test-app/dist /srv${BASE_PATH}

# Generate the Caddyfile from the template. Substituting at build time keeps
# the configuration in the image deterministic.
#
# Note: the Caddyfile is deliberately NOT validated with `caddy validate`
# here - the Go runtime crashes under QEMU/Rosetta emulation, which breaks
# cross-platform builds from Apple Silicon. Validate on the target host
# instead after loading the image:
#   docker run --rm apitomy-openapi-editor:latest \
#     caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
COPY docker/Caddyfile.template /tmp/Caddyfile.template
RUN if [ "$BASE_PATH" = "/" ]; then \
        root_redirect=""; \
    else \
        root_redirect="redir / ${BASE_PATH} 302"; \
    fi; \
    sed -e "s|__BASE_PATH__|${BASE_PATH}|g" \
        -e "s|# __ROOT_REDIRECT__|${root_redirect}|" \
        /tmp/Caddyfile.template > /etc/caddy/Caddyfile \
    && rm /tmp/Caddyfile.template

# Run as an unprivileged user.
RUN addgroup -g 1000 -S caddy && adduser -u 1000 -S -D -H -G caddy caddy
USER caddy

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q --spider "http://127.0.0.1:8080${BASE_PATH}" || exit 1
