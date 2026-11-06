# syntax=docker/dockerfile:1

FROM golang:1.25.1-alpine AS builder
WORKDIR /src

RUN apk add --no-cache ca-certificates

COPY --from=source go.mod go.sum ./
RUN go mod download

COPY --from=source . .
RUN printf '\t%s\n' \
  'viper.BindEnv("PORT")' 'viper.BindEnv("MONGO_URI")' 'viper.BindEnv("DB_NAME")' \
  'viper.BindEnv("JWT_SECRET_KEY")' 'viper.BindEnv("JWT_EXPIRATION_HOURS")' \
  'viper.BindEnv("ENABLE_CACHE")' 'viper.BindEnv("REDIS_ADDR")' 'viper.BindEnv("REDIS_PASSWORD")' \
  'viper.BindEnv("LOG_LEVEL")' 'viper.BindEnv("LOG_FORMAT")' > /tmp/env_keys.go \
  && sed -i '/viper.AutomaticEnv()/r /tmp/env_keys.go' internal/config/config.go
ENV GOFLAGS="-p=2" GOMAXPROCS=2
RUN gofmt -w internal/config/config.go \
  && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/muchtodo ./cmd/api

FROM alpine:3.22 AS runtime
RUN apk add --no-cache ca-certificates curl \
    && addgroup -S -g 10001 appgroup \
    && adduser -S -D -H -u 10001 -G appgroup appuser

WORKDIR /app
ENV HOME=/tmp GOMODCACHE=/tmp/gomodcache GOPATH=/tmp/gopath
COPY --from=builder /out/muchtodo /app/muchtodo

USER 10001:10001
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl --fail --silent http://localhost:8080/health || exit 1

ENTRYPOINT ["/app/muchtodo"]
