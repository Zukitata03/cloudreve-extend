# syntax=docker/dockerfile:1
#
# Multi-stage build: fetches the frontend from GitHub, embeds it into the Go
# binary as application/statics/assets.zip (see application/statics/statics.go),
# then assembles the runtime image. Build from the backend repo root:
#
#   docker build -t cloudreve-extend .
#
# The spare machine only needs this repo cloned; the frontend is pulled
# remotely during the build.

ARG GO_VERSION=1.25
ARG NODE_VERSION=22
ARG FE_REPO=https://github.com/Zukitata03/cloudreve-extend-FE.git
ARG FE_BRANCH=develop

########## Stage 1: build frontend from the GitHub fork ##########
FROM node:${NODE_VERSION}-alpine AS frontend
ARG FE_REPO
ARG FE_BRANCH
RUN apk add --no-cache git
WORKDIR /fe
# NOTE: "yarn build" runs vite only. Do NOT use "build-prod" here: plain tsc
# currently reports pre-existing type errors unrelated to the build output.
RUN git clone --depth 1 --branch "${FE_BRANCH}" "${FE_REPO}" . \
    && yarn install --frozen-lockfile \
    && yarn build

########## Stage 2: compile backend with the frontend embedded ##########
FROM golang:${GO_VERSION}-alpine AS backend
RUN apk add --no-cache git zip
WORKDIR /src
COPY . .
# Stages are isolated: pull the frontend output over from stage 1.
COPY --from=frontend /fe/build ./fe-dist

# Assemble the embedded static bundle. The zip must contain assets/build/**
# (fs.Sub(statics, "assets/build") in statics.go), plus a version.json so the
# startup version check passes.
RUN mkdir -p application/statics/assets/build \
    && cp -r fe-dist/. application/statics/assets/build/ \
    && VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo dev)" \
    && COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
    && printf '{"name":"cloudreve-frontend","version":"%s"}' "$VERSION" \
        > application/statics/assets/build/version.json \
    && cd application/statics \
    && zip -qr assets.zip assets \
    && rm -rf assets \
    && cd /src \
    && CGO_ENABLED=0 go build -trimpath \
        -ldflags "-s -w \
            -X 'github.com/cloudreve/Cloudreve/v4/application/constants.BackendVersion=${VERSION}' \
            -X 'github.com/cloudreve/Cloudreve/v4/application/constants.LastCommit=${COMMIT}'" \
        -o /out/cloudreve .

########## Stage 3: runtime ##########
FROM alpine:latest

WORKDIR /cloudreve

RUN apk update \
    && apk add --no-cache tzdata vips-tools ffmpeg libreoffice aria2 supervisor font-noto font-noto-cjk libheif libraw-tools\
    && cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "Asia/Shanghai" > /etc/timezone \
    && mkdir -p ./data/temp/aria2 \
    && chmod -R 766 ./data/temp/aria2

ENV CR_ENABLE_ARIA2=1 \
    CR_SETTING_DEFAULT_thumb_ffmpeg_enabled=1 \
    CR_SETTING_DEFAULT_thumb_vips_enabled=1 \
    CR_SETTING_DEFAULT_thumb_libreoffice_enabled=1 \
    CR_SETTING_DEFAULT_media_meta_ffprobe=1  \
    CR_SETTING_DEFAULT_thumb_libraw_enabled=1

COPY .build/aria2.supervisor.conf .build/entrypoint.sh ./
COPY --from=backend /out/cloudreve ./cloudreve

RUN chmod +x ./cloudreve \
    && chmod +x ./entrypoint.sh

EXPOSE 5212 443 6888 6888/udp

VOLUME ["/cloudreve/data"]

ENTRYPOINT ["sh", "./entrypoint.sh"]
