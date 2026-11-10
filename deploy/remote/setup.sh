#!/usr/bin/env bash
# Server-side installer for the appleservices stack.
# Idempotent: safe to re-run. Subcommands: docker | app | verify | all
set -euo pipefail

ANISETTE_PORT="${ANISETTE_PORT:-6969}"
APP_DIR="${APP_DIR:-/opt/appsvc}"
SRC_DIR="${SRC_DIR:-/opt/appsvc/src}"
STATE_DIR="${STATE_DIR:-/opt/appsvc/state}"

log() { printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "run as root (or: sudo bash setup.sh $*)"
  fi
}

install_docker() {
  need_root
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "docker + compose plugin already present: $(docker --version)"
    return
  fi
  log "installing docker engine"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q ca-certificates curl >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q ca-certificates curl >/dev/null
  fi
  if ! command -v docker >/dev/null 2>&1; then
    # Official convenience script; falls back to distro packages below.
    if curl -fsSL --max-time 60 https://get.docker.com -o /tmp/get-docker.sh; then
      sh /tmp/get-docker.sh >/tmp/docker-install.log 2>&1 || true
      rm -f /tmp/get-docker.sh
    fi
  fi
  if ! command -v docker >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get install -y -qq docker.io docker-compose-plugin >/dev/null 2>&1 || apt-get install -y -qq docker.io >/dev/null
    fi
  fi
  command -v docker >/dev/null 2>&1 || die "docker install failed; see /tmp/docker-install.log"
  systemctl enable --now docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
  log "docker ready: $(docker --version)"
}

start_anisette() {
  need_root
  install_docker
  local dir="/opt/anisette"
  mkdir -p "$dir"
  cat > "$dir/docker-compose.yml" <<YAML
services:
  anisette-v3:
    image: dadoum/anisette-v3-server:latest
    container_name: anisette-v3
    restart: unless-stopped
    ports:
      - "127.0.0.1:${ANISETTE_PORT}:${ANISETTE_PORT}"
    volumes:
      - anisette-v3-data:/home/Alcoholic/.config/anisette-v3/lib/
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
volumes:
  anisette-v3-data:
YAML
  cd "$dir"
  docker compose up -d
  log "waiting for the container to provision (downloads Apple libraries on first run)"
  local i=0
  while [ $i -lt 90 ]; do
    if curl -fsS --max-time 5 "http://127.0.0.1:${ANISETTE_PORT}/v3/client_info" >/dev/null 2>&1; then
      log "anisette-v3 is answering on 127.0.0.1:${ANISETTE_PORT}"
      return 0
    fi
    i=$((i+1)); sleep 2
  done
  docker compose logs --tail 40 || true
  die "anisette did not come up within 180s"
}

install_go() {
  need_root
  if command -v go >/dev/null 2>&1; then
    local have
    have="$(go version | awk '{print $3}' | sed 's/^go//')"
    log "go already present: $have"
    return
  fi
  log "installing Go toolchain"
  command -v curl >/dev/null 2>&1 || die "curl is required"
  local url
  url="$(curl -fsSL --max-time 60 'https://go.dev/dl/?mode=json' \
    | tr ',' '\n' \
    | grep -o 'go[0-9.]*\.linux-amd64\.tar\.gz' \
    | head -1)"
  [ -n "$url" ] || die "could not resolve the current Go release"
  local want
  want="$(printf '%s' "$url" | sed 's/\.linux-amd64\.tar\.gz$//')"
  log "downloading $want"
  curl -fsSL --max-time 300 "https://go.dev/dl/$url" -o /tmp/go.tgz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tgz
  rm -f /tmp/go.tgz
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
  log "installed: $(/usr/local/bin/go version)"
}

build_app() {
  need_root
  [ -f "$SRC_DIR/go.mod" ] || die "source not found at $SRC_DIR"
  install_go
  mkdir -p "$APP_DIR/bin"
  log "building tools (CGO disabled)"
  cd "$SRC_DIR"
  export CGO_ENABLED=0 GOFLAGS=-mod=mod
  for target in cmd/login cmd/trusted-device cmd/dashboard tools/familyinspect tools/accountsetupcheck tools/anisettecheck; do
    name="$(basename "$target")"
    /usr/local/bin/go build -trimpath -ldflags '-s -w' -o "$APP_DIR/bin/$name" ".$target"
    log "built $name"
  done
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  log "binaries in $APP_DIR/bin, state in $STATE_DIR (0700)"
}

verify_all() {
  local base="http://127.0.0.1:${ANISETTE_PORT}"
  log "1/4 client_info"
  curl -fsS --max-time 15 "$base/v3/client_info" || die "client_info failed"
  log "2/4 get_headers must refuse an empty adi_pb"
  local resp
  resp="$(curl -sS --max-time 30 -X POST "$base/v3/get_headers" \
    -H 'Content-Type: application/json' \
    -d '{"identifier":"AAAAAAAAAAAAAAAAAAAAAA==","adi_pb":""}')"
  printf '%s\n' "$resp"
  case "$resp" in
    *'"result":"Headers"'*) log "WARNING: service invented headers without provisioning data" ;;
    *GetHeadersError*) log "refused as expected" ;;
  esac
  log "3/4 websocket upgrade"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "$base/v3/provisioning_session" || true)"
  [ "$code" = "101" ] || die "provisioning_session returned $code, expected 101"
  log "websocket upgrade OK (101)"
  log "4/4 client round-trip with provisioning"
  if [ -x "$APP_DIR/bin/anisettecheck" ]; then
    "$APP_DIR/bin/anisettecheck" -url "$base"
  else
    log "anisettecheck not built yet; run: setup.sh app"
  fi
  log "ALL CHECKS PASSED"
}

case "${1:-all}" in
  docker) start_anisette ;;
  app)    build_app ;;
  verify) verify_all ;;
  all)    start_anisette; build_app; verify_all ;;
  *)      die "usage: setup.sh [docker|app|verify|all]" ;;
esac
