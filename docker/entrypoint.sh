#!/usr/bin/env bash
set -euo pipefail

# darkwg/darkwg-quick — это смонтированные с хоста бинарники awg/awg-quick
# (см. volumes в docker-compose.yml), просто под другим именем внутри контейнера.

if ! ip link show darkwg0 &>/dev/null; then
  echo "[entrypoint] поднимаю интерфейс darkwg0"
  darkwg-quick up /etc/darkwg/darkwg0.conf
else
  echo "[entrypoint] darkwg0 уже поднят (например, после перезапуска контейнера)"
fi

echo "[entrypoint] запускаю API"
exec python3 -m uvicorn api.main:app --host 127.0.0.1 --port 8765
