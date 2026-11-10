# clerk's self-host server, with the web app embedded. CI builds it for amd64 and
# arm64 on each push to main (.github/workflows/image.yml) as
# ghcr.io/cowellmi/clerk:<sha> and :main. The web app and the tests run once, on
# the build machine; Go cross-compiles for each target, so nothing is emulated.
FROM --platform=$BUILDPLATFORM node:24-bookworm-slim AS web
# the Elm compiler fetches packages over https, and slim has no CA certs
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY package.json package-lock.json elm.json elm-tooling.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npm run build # Elm into public/, which the Go binary embeds

FROM --platform=$BUILDPLATFORM golang:1.27-bookworm AS server
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY --from=web /src .
RUN go test ./... && CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -o /clerk ./cmd/clerk

FROM gcr.io/distroless/static-debian12
LABEL org.opencontainers.image.source=https://github.com/cowellmi/clerk
COPY --from=server /clerk /clerk
ENTRYPOINT ["/clerk"]
