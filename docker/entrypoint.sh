#!/usr/bin/env bash
set -euo pipefail

# awg/awg-quick — смонтированы с хоста под настоящими именами (см. volumes
# в docker-compose.yml), потому что сам awg-quick внутри себя вызывает awg
# по жёсткому имени. darkwg/darkwg-quick — симлинки для нашего собственного
# кода (api/wireguard.py, scripts/darkwg_cli.py), создаём их здесь же.
ln -sf /usr/local/bin/awg /usr/local/bin/darkwg
ln -sf /usr/local/bin/awg-quick /usr/local/bin/darkwg-quick

if ! ip link show darkwg0 &>/dev/null; then
  echo "[entrypoint] поднимаю интерфейс darkwg0"
  darkwg-quick up /etc/darkwg/darkwg0.conf
else
  echo "[entrypoint] darkwg0 уже поднят (например, после перезапуска контейнера)"
fi

echo "[entrypoint] запускаю API"
exec python3 -m uvicorn api.main:app --host 127.0.0.1 --port 8765