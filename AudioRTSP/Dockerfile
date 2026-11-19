FROM node:22-bookworm-slim AS build
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY index.html vite.config.js ./
COPY src ./src
RUN npm run build

FROM node:22-bookworm-slim
ARG MEDIAMTX_VERSION=1.15.2
ARG MEDIAMTX_ARCH=amd64
ENV NODE_ENV=production \
    WEB_PORT=8080 \
    RTSP_PORT=8554 \
    DATA_DIR=/data \
    MEDIAMTX_BIN=/usr/local/bin/mediamtx \
    FFMPEG_BIN=/usr/bin/ffmpeg
WORKDIR /app
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg ca-certificates curl \
    && curl -fsSL "https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VERSION}/mediamtx_v${MEDIAMTX_VERSION}_linux_${MEDIAMTX_ARCH}.tar.gz" -o /tmp/mediamtx.tar.gz \
    && tar -xzf /tmp/mediamtx.tar.gz -C /usr/local/bin mediamtx \
    && chmod +x /usr/local/bin/mediamtx \
    && rm -rf /var/lib/apt/lists/* /tmp/mediamtx.tar.gz
COPY --from=build /app/dist ./dist
COPY server ./server
COPY package*.json ./
RUN npm install --omit=dev --ignore-scripts && mkdir -p /data && chown -R node:node /app /data
USER node
EXPOSE 8080 8554
VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 CMD node -e "fetch('http://127.0.0.1:8080/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "server/index.js"]
