# syntax=docker/dockerfile:1
# Imagem única: API (Dart) + app web (Flutter) + site institucional.

# 1) App web (Flutter) — SDK oficial na versão fixada.
FROM debian:bookworm-slim AS web
ARG FLUTTER_VERSION=3.47.6
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils && \
    rm -rf /var/lib/apt/lists/* && \
    curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
      | tar -xJ -C /opt && \
    git config --global --add safe.directory /opt/flutter
ENV PATH=/opt/flutter/bin:$PATH
RUN flutter config --no-analytics && flutter precache --web
WORKDIR /src
COPY packages ./packages
COPY app ./app
WORKDIR /src/app
RUN flutter pub get && \
    flutter build web --release --base-href /app/ --no-web-resources-cdn --no-wasm-dry-run

# 2) API (Dart AOT)
FROM dart:3.13 AS api
WORKDIR /src
COPY packages ./packages
COPY backend/pubspec.* ./backend/
WORKDIR /src/backend
RUN dart pub get
COPY backend ./
RUN mkdir -p /out && dart compile exe bin/server.dart -o /out/server

# 3) Runtime mínimo
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates tzdata && \
    rm -rf /var/lib/apt/lists/* && useradd --system --uid 10001 pontomax
WORKDIR /srv
COPY --from=api /out/server /srv/server
COPY --from=web /src/app/build/web /srv/web
COPY site /srv/site
COPY backend/assets /srv/assets
RUN mkdir -p /srv/storage && chown -R pontomax /srv/storage
USER pontomax
ENV PORT=8080 \
    WEB_DIR=/srv/web \
    SITE_DIR=/srv/site \
    FONTS_DIR=/srv/assets/fonts \
    STORAGE_DIR=/srv/storage \
    TZ=America/Sao_Paulo
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s CMD ["/srv/server", "--healthcheck"] 
CMD ["/srv/server"]
