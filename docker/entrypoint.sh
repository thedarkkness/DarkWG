#!/usr/bin/env bash
set -euo pipefail

# awg/awg-quick — смонтированы с хоста под настоящими именами (см. volumes
# в docker-compose.yml), потому что сам awg-quick внутри себя вызывает awg
# по жёсткому имени. darkwg/darkwg-quick — симлинки для нашего собственного
# кода (api/wireguard.py, scripts/darkwg_cli.py), создаём их здесь же.
ln -sf /usr/local/bin/awg /usr/local/bin/darkwg
ln -sf /usr/local/bin/awg-quick /usr/local/bin/darkwg-quick

# Всегда пересобираем интерфейс с нуля из текущего /etc/darkwg/darkwg0.conf.
# Раньше здесь была проверка "если уже существует — не трогаем", но это
# означало, что после переустановки (новые ключи/параметры/пиры на диске)
# уже живой интерфейс с прошлого запуска оставался со старым состоянием —
# конфиг с диска просто никогда не применялся повторно.
if ip link show darkwg0 &>/dev/null; then
  echo "[entrypoint] darkwg0 уже существует — опускаю, чтобы пересобрать из текущего конфига"
  darkwg-quick down /etc/darkwg/darkwg0.conf 2>/dev/null || ip link delete dev darkwg0 2>/dev/null || true
fi

echo "[entrypoint] поднимаю интерфейс darkwg0"
darkwg-quick up /etc/darkwg/darkwg0.conf

echo "[entrypoint] запускаю API"
exec python3 -m uvicorn api.main:app --host 127.0.0.1 --port 8765