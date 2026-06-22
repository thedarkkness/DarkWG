# Контейнер darkwg — REST API + поднятие туннеля.
# Бинарники awg/awg-quick НЕ ставятся внутри образа (Amnezia PPA — Ubuntu-only,
# несовместим с debian-slim базой) — монтируются с хоста как тома в docker-compose.yml.
# Сам kernel-модуль amneziawg в принципе не может жить "в контейнере" — это
# свойство хост-ядра, грузится один раз на хосте через install.sh.
FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    iproute2 iptables procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/darkwg

COPY api/requirements.txt ./api/requirements.txt
RUN pip install --no-cache-dir -r api/requirements.txt

COPY api/ ./api/
COPY scripts/ ./scripts/
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
