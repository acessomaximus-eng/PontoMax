#!/usr/bin/env bash
# Inicia/para a API local do PontoMax (desenvolvimento).
# Uso: scripts/dev_server.sh start|stop|restart [--seed]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-8080}"
PIDFILE="${PIDFILE:-/tmp/pontomax-dev-$PORT.pid}"
LOG="${LOG:-/tmp/pontomax-dev-$PORT.log}"

stop() {
  if [[ -f "$PIDFILE" ]]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
}

start() {
  cd "$ROOT/backend"
  dart compile exe bin/server.dart -o "/tmp/pontomax-server-$PORT" >/dev/null
  PORT="$PORT" SEED_DEMO="${SEED_DEMO:-false}" nohup "/tmp/pontomax-server-$PORT" "$@" >"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
  for _ in $(seq 1 60); do
    if curl -sf "http://localhost:$PORT/api/v1/health" >/dev/null; then
      echo "PontoMax API em http://localhost:$PORT (log: $LOG)"
      return 0
    fi
    sleep 1
  done
  echo "Falha ao iniciar; veja $LOG" >&2
  return 1
}

case "${1:-}" in
  start) shift; start "$@" ;;
  stop) stop ;;
  restart) shift; stop; start "$@" ;;
  *) echo "Uso: $0 start|stop|restart [--seed]"; exit 1 ;;
esac
