#!/usr/bin/env bash
# DarkWG installer — поднимает VPN-туннель с обфускацией + REST API
# для управления пирами. Тестировалось на Ubuntu 24.04 (noble).
#
# Использование:
#   sudo DARKWG_ENDPOINT=<домен_или_IP> bash install.sh
#   (либо просто sudo bash install.sh — спросит домен интерактивно)

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Запускать нужно от root (sudo bash install.sh)" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/darkwg"
CONFIG_DIR="/etc/darkwg"
PEERS_DIR="${CONFIG_DIR}/peers"
IFACE="darkwg0"

PORT="${DARKWG_PORT:-$(shuf -i 20000-60000 -n 1)}"
SUBNET="${DARKWG_SUBNET:-10.13.0.0/16}"
SERVER_IP="10.13.0.1"
API_PORT="${DARKWG_API_PORT:-8765}"

if [[ -z "${DARKWG_ENDPOINT:-}" ]]; then
  echo ""
  echo "Нужен публичный IP-адрес или домен этого сервера — именно по нему"
  echo "будут подключаться клиенты."
  DETECTED_IP="$(curl -s --max-time 3 -4 ifconfig.me || true)"
  if [[ -n "${DETECTED_IP}" ]]; then
    read -rp "IP или домен сервера [по умолчанию: ${DETECTED_IP}, просто нажми Enter]: " DARKWG_ENDPOINT
    DARKWG_ENDPOINT="${DARKWG_ENDPOINT:-${DETECTED_IP}}"
  else
    read -rp "IP-адрес или домен сервера: " DARKWG_ENDPOINT
  fi
fi

echo "==> 1/8: устанавливаю системные зависимости"
apt-get update -qq
apt-get install -y -qq \
  software-properties-common python3-launchpadlib gnupg2 \
  "linux-headers-$(uname -r)" \
  python3-venv python3-pip \
  qrencode wireguard-tools ufw

echo "==> 2/8: ставлю тоннельный модуль и инструменты ядра"
if ! grep -rq "amnezia/ppa" /etc/apt/sources.list.d/ 2>/dev/null; then
  add-apt-repository -y ppa:amnezia/ppa
  apt-get update -qq
fi
apt-get install -y -qq amneziawg amneziawg-tools

if ! lsmod | grep -q amneziawg; then
  modprobe amneziawg || {
    echo "ВНИМАНИЕ: модуль не загрузился через modprobe." >&2
    echo "Частая причина — DKMS не нашёл sources текущего ядра. Попробуй:" >&2
    echo "  ln -s /usr/src/linux-headers-\$(uname -r) /var/lib/dkms/amneziawg/1.0.0/build/kernel" >&2
    echo "  dpkg --configure -a" >&2
    exit 1
  }
fi

echo "==> 3/8: создаю свои имена команд (darkwg, darkwg-quick)"
ln -sf "$(command -v awg)" /usr/local/bin/darkwg
ln -sf "$(command -v awg-quick)" /usr/local/bin/darkwg-quick

echo "==> 4/8: определяю сетевой интерфейс для NAT"
EGRESS_IFACE="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}')"
echo "    интерфейс выхода в интернет: ${EGRESS_IFACE}"

echo "==> 5/8: генерирую ключи и обфускационные параметры"
mkdir -p "${CONFIG_DIR}" "${PEERS_DIR}"
chmod 700 "${CONFIG_DIR}"
umask 077
darkwg genkey | tee "${CONFIG_DIR}/server_private.key" | darkwg pubkey > "${CONFIG_DIR}/server_public.key"

PARAMS_JSON="$(python3 "${REPO_DIR}/scripts/generate_obfuscation_params.py")"
JC=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['Jc'])" "${PARAMS_JSON}")
JMIN=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['Jmin'])" "${PARAMS_JSON}")
JMAX=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['Jmax'])" "${PARAMS_JSON}")
S1=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['S1'])" "${PARAMS_JSON}")
S2=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['S2'])" "${PARAMS_JSON}")
H1=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['H1'])" "${PARAMS_JSON}")
H2=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['H2'])" "${PARAMS_JSON}")
H3=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['H3'])" "${PARAMS_JSON}")
H4=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['H4'])" "${PARAMS_JSON}")

SERVER_PRIVATE_KEY="$(cat "${CONFIG_DIR}/server_private.key")"
SERVER_PUBLIC_KEY="$(cat "${CONFIG_DIR}/server_public.key")"

echo "==> 6/8: пишу ${CONFIG_DIR}/${IFACE}.conf и поднимаю интерфейс"
cat > "${CONFIG_DIR}/${IFACE}.conf" << EOF
[Interface]
PrivateKey = ${SERVER_PRIVATE_KEY}
Address = ${SERVER_IP}/16
ListenPort = ${PORT}
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}
PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -A FORWARD -i ${IFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${EGRESS_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${IFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${EGRESS_IFACE} -j MASQUERADE
EOF
chmod 600 "${CONFIG_DIR}/${IFACE}.conf"

cp "${REPO_DIR}/systemd/darkwg-quick@.service" "/etc/systemd/system/darkwg-quick@.service"
systemctl daemon-reload
systemctl enable --now "darkwg-quick@${IFACE}"
ufw allow "${PORT}/udp" || true

echo "==> 7/8: разворачиваю API и создаю первого пира"
mkdir -p "${INSTALL_DIR}"
cp -r "${REPO_DIR}/api" "${REPO_DIR}/scripts" "${INSTALL_DIR}/"
python3 -m venv "${INSTALL_DIR}/venv"
"${INSTALL_DIR}/venv/bin/pip" install --quiet --upgrade pip
"${INSTALL_DIR}/venv/bin/pip" install --quiet -r "${INSTALL_DIR}/api/requirements.txt"

API_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
cat > "${CONFIG_DIR}/api.env" << EOF
DARKWG_IFACE=${IFACE}
DARKWG_SUBNET=${SUBNET}
DARKWG_SERVER_IP=${SERVER_IP}
DARKWG_SERVER_PUBLIC_KEY=${SERVER_PUBLIC_KEY}
DARKWG_ENDPOINT_HOST=${DARKWG_ENDPOINT}
DARKWG_ENDPOINT_PORT=${PORT}
DARKWG_CLIENT_DNS=1.1.1.1
DARKWG_DB_PATH=${INSTALL_DIR}/darkwg.db
DARKWG_API_KEY=${API_KEY}
DARKWG_JC=${JC}
DARKWG_JMIN=${JMIN}
DARKWG_JMAX=${JMAX}
DARKWG_S1=${S1}
DARKWG_S2=${S2}
DARKWG_H1=${H1}
DARKWG_H2=${H2}
DARKWG_H3=${H3}
DARKWG_H4=${H4}
EOF
chmod 600 "${CONFIG_DIR}/api.env"

# Первый пир по умолчанию — например, для собственного теста владельца сервера
"${INSTALL_DIR}/venv/bin/python3" "${INSTALL_DIR}/scripts/darkwg_cli.py" \
  add-peer --telegram-user-id 0 --ttl-days 0 --out "${PEERS_DIR}/peer1"

cp "${REPO_DIR}/systemd/darkwg-api.service" /etc/systemd/system/darkwg-api.service
sed -i "s#__API_PORT__#${API_PORT}#g" /etc/systemd/system/darkwg-api.service
systemctl daemon-reload
systemctl enable --now darkwg-api

echo "==> 8/8: готово"
echo ""
echo "===================================================================="
echo "  DarkWG установлен."
echo "  Туннель:        ${IFACE}, порт ${PORT}/udp, подсеть ${SUBNET}"
echo "  Публичный ключ:  ${SERVER_PUBLIC_KEY}"
echo "  API:             127.0.0.1:${API_PORT} (только локально)"
echo "  API ключ:        ${API_KEY}"
echo "  Конфиг API:      ${CONFIG_DIR}/api.env"
echo ""
echo "  Первый пир создан:"
echo "    конфиг: ${PEERS_DIR}/peer1.conf"
echo "    QR:     ${PEERS_DIR}/peer1.png"
echo ""
echo "  Управление пирами без API:"
echo "    ${INSTALL_DIR}/venv/bin/python3 ${INSTALL_DIR}/scripts/darkwg_cli.py list-peers"
echo ""
echo "  Проверка API: curl -s -H \"X-API-Key: ${API_KEY}\" http://127.0.0.1:${API_PORT}/health"
echo "===================================================================="