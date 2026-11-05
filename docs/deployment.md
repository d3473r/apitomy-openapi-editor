# Deployment

The repository contains a multi-stage [Dockerfile](https://github.com/Apitomy/apitomy-openapi-editor/blob/main/Dockerfile)
that packages the editor web application (built from `test-app/`, which bundles
the component library sources in `src/`) and serves it with
[Caddy](https://caddyserver.com/).

The image is small (about 90&nbsp;MB), runs as a non-root user and listens on
the unprivileged port **8080**.

## Quick start

```bash
docker build -t apitomy-openapi-editor .
docker run --rm -p 8080:8080 apitomy-openapi-editor
```

The editor is then available at [http://localhost:8080](http://localhost:8080).

## Configuration

### `BASE_PATH` (build argument)

Path prefix the application is served under. Must start and end with a slash.
It is passed to the Vite build (`VITE_BASE_PATH`), the static file layout and
the generated Caddy configuration, so all three stay consistent.

```bash
# Serve the editor under http://localhost:8080/editor/
docker build --build-arg BASE_PATH=/editor/ -t apitomy-openapi-editor .
```

Requests to `/` are redirected to the base path.

### Runtime behaviour

| Aspect               | Behaviour                                                        |
| -------------------- | ---------------------------------------------------------------- |
| Port                 | `8080` (unprivileged, `EXPOSE 8080`)                             |
| User                 | Non-root (`caddy`, uid 1000) - safe for Kubernetes/OpenShift     |
| Health check         | `wget` against the base path, reports `healthy`/`unhealthy`      |
| Compression          | zstd (gzip fallback)                                             |
| Fingerprinted assets | `Cache-Control: public, max-age=31536000, immutable`             |
| HTML entry point     | `Cache-Control: no-cache` - new image versions are picked up immediately |
| Unknown paths        | SPA fallback to the entry point (single-page app)                |
| Security headers     | `X-Content-Type-Options: nosniff`, `Referrer-Policy`             |

## Cross-platform builds

When building on Apple Silicon for an `amd64` server, pass the platform
explicitly:

```bash
docker build --platform linux/amd64 -t apitomy-openapi-editor:latest .
```

!!! note
    The Caddyfile is deliberately not validated during the image build: the
    Go runtime crashes under QEMU/Rosetta emulation, which would break
    cross-platform builds. Validate natively on the target host instead:

    ```bash
    docker run --rm apitomy-openapi-editor:latest \
      caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
    ```

## Example: Traefik reverse proxy

The following Compose file runs the editor behind an existing Traefik
instance (Docker provider) on a shared `proxy` network and exposes it as
`editor.example.com`:

```yaml
services:
  openapi-editor:
    image: apitomy-openapi-editor:latest
    container_name: apitomy-openapi-editor
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      - proxy
    labels:
      traefik.enable: "true"
      traefik.http.routers.openapi-editor.rule: Host(`editor.example.com`)
      traefik.http.routers.openapi-editor.entrypoints: https
      traefik.http.routers.openapi-editor.service: openapi-editor
      traefik.http.services.openapi-editor.loadbalancer.server.port: "8080"

networks:
  proxy:
    external: true
```

Traefik terminates TLS; the container itself serves plain HTTP on port 8080.
Because Traefik routes by hostname, no `BASE_PATH` is required in this setup.

### Updating a running instance

Without a registry, transfer the image directly to the host and recreate the
container:

```bash
docker build --platform linux/amd64 -t apitomy-openapi-editor:latest .
docker save apitomy-openapi-editor:latest | gzip \
  | ssh <host> 'gunzip | docker load'
ssh <host> 'cd /path/to/apitomy-editor && docker compose up -d'
```
