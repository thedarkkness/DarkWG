#!/usr/bin/env bash
# DarkWG installer — поднимает VPN-туннель с обфускацией + REST API
# в отдельных Docker-контейнерах (darkwg, darkwg-nginx), полностью
# независимо от любой другой инфраструктуры на сервере (RemnaWave и т.п.).
# Тестировалось на Ubuntu 24.04 (noble).
#
# Использование:
#   sudo ./install.sh
#   (или одной командой без предварительного git clone:)
#   bash <(curl -fsSL https://raw.githubusercontent.com/thedarkkness/DarkWG/main/install.sh)

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Запускать нужно от root (sudo ./install.sh)" >&2
  exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}☑${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
fail() { echo -e "${RED}✗ ОШИБКА${NC}: $1" >&2; }
step() { echo -e "${CYAN}==> $1${NC}"; }

on_error() {
  local exit_code=$?
  local line_no=$1
  echo "" >&2
  fail "что-то пошло не так на строке ${line_no} (код выхода ${exit_code})."
  echo "Для пошагового подробного вывода перезапусти так:" >&2
  echo "  bash -x ./install.sh" >&2
  exit "${exit_code}"
}
trap 'on_error ${LINENO}' ERR


REPO_URL="https://github.com/thedarkkness/DarkWG.git"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_VERSION="1.0.1"
SCRIPT_AUTHOR="thedarkkness"

# Если рядом со скриптом нет остальных файлов репозитория (Dockerfile и т.п.) —
# значит, скрипт запущен напрямую через curl|bash / bash <(curl ...), а не из
# полного git clone. В этом случае клонируем репозиторий во временную папку
# и перезапускаем install.sh уже оттуда, где все нужные файлы рядом.
if [[ ! -f "${REPO_DIR}/docker/Dockerfile" ]]; then
  command -v git &>/dev/null || { apt-get update -qq && apt-get install -y -qq git; }
  TMP_CLONE_DIR="$(mktemp -d)"
  git clone --quiet "${REPO_URL}" "${TMP_CLONE_DIR}" &>/dev/null
  exec bash "${TMP_CLONE_DIR}/install.sh" "$@"
fi

print_banner() {
  local c1='\033[38;5;52m'
  local c2='\033[38;5;88m'
  local c3='\033[38;5;124m'
  local c4='\033[38;5;160m'
  echo -e "${c1}▛▀▖▞▀▖▛▀▖▌ ▌▌ ▌▞▀▖${NC}"
  echo -e "${c2}▌ ▌▙▄▌▙▄▘▙▞ ▌▖▌▌▄▖${NC}"
  echo -e "${c3}▌ ▌▌ ▌▌▚ ▌▝▖▙▚▌▌ ▌${NC}"
  echo -e "${c4}▀▀ ▘ ▘▘ ▘▘ ▘▘ ▘▝▀ ${NC}"
  echo -e "  ${YELLOW}by ${SCRIPT_AUTHOR} · v${SCRIPT_VERSION}${NC}"
  echo ""
}

check_for_updates() {
  local remote_version
  remote_version="$(curl -s --max-time 3 "https://raw.githubusercontent.com/thedarkkness/DarkWG/main/VERSION" 2>/dev/null | tr -d '[:space:]')"
  if [[ -z "${remote_version}" || "${remote_version}" == "${SCRIPT_VERSION}" ]]; then
    return 0
  fi
  warn "Доступна новая версия скрипта: ${remote_version} (у тебя ${SCRIPT_VERSION})"
  read -rp "Обновить и перезапустить? [y/N]: " update_ans
  if [[ "${update_ans,,}" != "y" ]]; then
    echo ""
    return 0
  fi
  echo "Обновляюсь..."
  if [[ -d "${REPO_DIR}/.git" ]]; then
    git -C "${REPO_DIR}" pull --quiet
    exec bash "${REPO_DIR}/install.sh" "$@"
  else
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    git clone --quiet "${REPO_URL}" "${tmp_dir}" &>/dev/null
    exec bash "${tmp_dir}/install.sh" "$@"
  fi
}

clear
print_banner
check_for_updates "$@"

CONFIG_DIR="/etc/darkwg"
PEERS_DIR="${CONFIG_DIR}/peers"
IFACE="darkwg0"

SUBNET="${DARKWG_SUBNET:-10.13.0.0/16}"
SERVER_IP="10.13.0.1"

port_in_use() {
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${1}$"
}

# ----------------------------------------------------------------------------
# Шаг 0: режим установки и вопросы — интерактивный мастер с возвратом назад
# ----------------------------------------------------------------------------
print_bye_and_exit() {
  echo ""
  echo "Bye!"
  exit 0
}

uninstall_darkwg() {
  echo ""
  echo -e "${RED}ВНИМАНИЕ:${NC} это безвозвратно удалит:"
  echo "  - контейнеры darkwg и darkwg-nginx (если есть)"
  echo "  - Docker-образ и volume с базой данных пиров — все уже выданные"
  echo "    клиентам конфиги перестанут работать навсегда"
  echo "  - интерфейс тоннеля darkwg0 и связанные правила iptables/ufw"
  echo "  - всю папку /etc/darkwg целиком (ключи сервера, конфиги, обфускация)"
  echo ""
  echo "Системный пакет amneziawg-tools и kernel-модуль НЕ удаляются."
  echo ""
  read -rp "Точно удалить всё безвозвратно? [y/N]: " confirm_ans
  if [[ "${confirm_ans,,}" != "y" ]]; then
    echo "Отменено, ничего не тронул."
    print_bye_and_exit
  fi

  echo ""
  echo "Удаляю..."

  OLD_PORT=""
  if [[ -f "/etc/darkwg/darkwg0.conf" ]]; then
    OLD_PORT="$(grep -E '^ListenPort' /etc/darkwg/darkwg0.conf | awk -F'= ' '{print $2}' || true)"
  fi

  docker rm -f darkwg darkwg-nginx 2>/dev/null || true

  # образы из временных клонов называются вида tmpXXXXX-darkwg
  docker images --format '{{.Repository}}:{{.ID}}' 2>/dev/null \
    | grep -- '-darkwg:' | awk -F: '{print $2}' \
    | xargs -r docker rmi -f 2>/dev/null || true

  # имя volume зависит от папки временного клона — чистим по маске
  docker volume ls -q 2>/dev/null | grep -- 'darkwg-data' \
    | xargs -r docker volume rm -f 2>/dev/null || true

  docker network ls -q --filter name=darkwg 2>/dev/null \
    | xargs -r docker network rm 2>/dev/null || true

  if ip link show darkwg0 &>/dev/null; then
    if [[ -f "/etc/darkwg/darkwg0.conf" ]]; then
      darkwg-quick down /etc/darkwg/darkwg0.conf 2>/dev/null || ip link delete dev darkwg0 2>/dev/null || true
    else
      ip link delete dev darkwg0 2>/dev/null || true
    fi
  fi

  if [[ -n "${OLD_PORT}" ]]; then
    ufw delete allow "${OLD_PORT}/udp" 2>/dev/null || true
  fi

  rm -f /usr/local/bin/darkwg /usr/local/bin/darkwg-quick
  rm -f /etc/sysctl.d/99-darkwg.conf
  rm -rf /etc/darkwg

  ok "DarkWG полностью удалён"
  print_bye_and_exit
}

# Если DARKWG_MODE задан через переменную окружения — считаем, что это
# автоматический/скриптовый запуск, и пропускаем мастер целиком (без
# навигации назад — она нужна только для интерактивного режима).
if [[ -n "${DARKWG_MODE:-}" ]]; then
  if [[ -z "${DARKWG_ENDPOINT:-}" ]]; then
    DETECTED_IP="$(curl -s --max-time 3 -4 ifconfig.me || true)"
    DARKWG_ENDPOINT="${DETECTED_IP}"
  fi
  DARKWG_PORT="${DARKWG_PORT:-443}"
else
  step="mode"
  while true; do
    case "${step}" in
      mode)
        echo ""
        echo "Выбор метода установки:"
        echo ""
        echo "  1. Панель + нода (туннель и API в одном месте, бот можно подключать локально)"
        echo "  2. Только нода (без панели — управление с отдельного сервера по HTTPS)"
        echo "  3. Удалить DarkWG полностью (контейнеры, данные, тоннель)"
        echo "  0. Выход"
        echo ""
        read -rp "Выбери [1/2/3/0]: " ans
        case "${ans}" in
          1) DARKWG_MODE="1"; step="endpoint" ;;
          2) DARKWG_MODE="2"; step="endpoint" ;;
          3) uninstall_darkwg ;;
          0) print_bye_and_exit ;;
          *) echo "Не понял, попробуй снова" ;;
        esac
        ;;

      endpoint)
        echo ""
        echo "Нужен публичный IP-адрес или домен этого сервера — именно по нему"
        echo "будут подключаться клиенты тоннеля."
        DETECTED_IP="$(curl -s --max-time 3 -4 ifconfig.me || true)"
        if [[ -n "${DETECTED_IP}" ]]; then
          read -rp "IP или домен сервера [${DETECTED_IP}, Enter = по умолчанию, 0 = назад]: " ans
        else
          read -rp "IP-адрес или домен сервера [0 = назад]: " ans
        fi
        if [[ "${ans}" == "0" ]]; then
          step="mode"; continue
        fi
        DARKWG_ENDPOINT="${ans:-${DETECTED_IP}}"
        if [[ -z "${DARKWG_ENDPOINT}" ]]; then
          echo "Не определился IP автоматически — введи вручную"
          continue
        fi
        step="port"
        ;;

      port)
        echo ""
        echo "Какой порт использовать для тоннеля?"
        echo "443/udp — рекомендуемый вариант: некоторые операторы блокируют"
        echo "UDP на нестандартных высоких портах, а 443 обычно проходит,"
        echo "так как массово используется легитимным QUIC-трафиком."
        read -rp "Порт [443, Enter = по умолчанию, 0 = назад]: " ans
        if [[ "${ans}" == "0" ]]; then
          step="endpoint"; continue
        fi
        DARKWG_PORT="${ans:-443}"
        if ! [[ "${DARKWG_PORT}" =~ ^[0-9]+$ ]] || (( DARKWG_PORT < 1 || DARKWG_PORT > 65535 )); then
          echo "Это не похоже на корректный номер порта (1-65535), попробуй снова"
          continue
        fi
        if [[ "${DARKWG_MODE}" == "2" ]]; then
          step="api_domain"
        else
          step="done"
        fi
        ;;

      api_domain)
        echo ""
        echo "Домен для API этой ноды (например, darkwg-api.example.com)."
        read -rp "Домен [0 = назад]: " ans
        if [[ "${ans}" == "0" ]]; then
          step="port"; continue
        fi
        if [[ -z "${ans}" ]]; then
          echo "Домен не может быть пустым"
          continue
        fi
        DARKWG_API_DOMAIN="${ans}"
        step="control_ip"
        ;;

      control_ip)
        echo ""
        echo "IP сервера управления (бота/панели) — доступ к API будет"
        echo "ограничен только этим IP."
        read -rp "IP сервера управления [0 = назад]: " ans
        if [[ "${ans}" == "0" ]]; then
          step="api_domain"; continue
        fi
        if [[ -z "${ans}" ]]; then
          echo "IP не может быть пустым"
          continue
        fi
        DARKWG_CONTROL_IP="${ans}"
        step="acme_email"
        ;;

      acme_email)
        echo ""
        read -rp "Email для уведомлений Let's Encrypt [можно пусто, 0 = назад]: " ans
        if [[ "${ans}" == "0" ]]; then
          step="control_ip"; continue
        fi
        DARKWG_ACME_EMAIL="${ans}"
        step="done"
        ;;

      done)
        break
        ;;
    esac
  done
fi

PORT="${DARKWG_PORT}"


# ----------------------------------------------------------------------------
# Шаг 1: системные зависимости (без python3-venv/pip — API теперь в контейнере)
# ----------------------------------------------------------------------------
step "1/8: устанавливаю системные зависимости"
apt-get update -qq
apt-get install -y -qq \
  software-properties-common python3-launchpadlib gnupg2 \
  "linux-headers-$(uname -r)" \
  qrencode wireguard-tools ufw

if ! command -v docker &>/dev/null; then
  echo "    Docker не найден — ставлю из репозитория Ubuntu"
  apt-get install -y -qq docker.io docker-compose-plugin
  systemctl enable --now docker
fi
ok "Зависимости установлены"

step "2/8: ставлю тоннельный модуль и инструменты ядра"
if ! grep -rq "amnezia/ppa" /etc/apt/sources.list.d/ 2>/dev/null; then
  add-apt-repository -y ppa:amnezia/ppa
  apt-get update -qq
fi
apt-get install -y -qq amneziawg amneziawg-tools

if ! lsmod | grep -q amneziawg; then
  modprobe amneziawg || {
    fail "модуль не загрузился через modprobe."
    echo "Частая причина — DKMS не нашёл sources текущего ядра. Попробуй:" >&2
    echo "  ln -s /usr/src/linux-headers-\$(uname -r) /var/lib/dkms/amneziawg/1.0.0/build/kernel" >&2
    echo "  dpkg --configure -a" >&2
    exit 1
  }
fi

if ! AWG_BIN_PATH="$(command -v awg)"; then
  fail "бинарь 'awg' не найден после установки amneziawg-tools."
  echo "Проверь: dpkg -l | grep amneziawg" >&2
  exit 1
fi
if ! AWG_QUICK_BIN_PATH="$(command -v awg-quick)"; then
  fail "бинарь 'awg-quick' не найден после установки amneziawg-tools."
  exit 1
fi
ln -sf "${AWG_BIN_PATH}" /usr/local/bin/darkwg
ln -sf "${AWG_QUICK_BIN_PATH}" /usr/local/bin/darkwg-quick
ok "Модуль и инструменты установлены"

step "3/8: определяю сетевой интерфейс для NAT"
EGRESS_IFACE="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}')"
echo "    интерфейс выхода в интернет: ${EGRESS_IFACE}"
ok "Интерфейс определён: ${EGRESS_IFACE}"

step "4/8: проверяю, что net.ipv4.ip_forward включён постоянно"
SYSCTL_FILE="/etc/sysctl.d/99-darkwg.conf"
CURRENT_FORWARD="$(sysctl -n net.ipv4.ip_forward)"
PERSISTED="$(grep -rhs '^net.ipv4.ip_forward' /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null | tail -n1 || true)"
if [[ "${CURRENT_FORWARD}" != "1" || "${PERSISTED}" != "net.ipv4.ip_forward=1" ]]; then
  echo "net.ipv4.ip_forward=1" > "${SYSCTL_FILE}"
  sysctl -p "${SYSCTL_FILE}" > /dev/null
  echo "    было выключено или не закреплено постоянно — включил и сохранил в ${SYSCTL_FILE}"
else
  echo "    уже включено и закреплено постоянно — пропускаю"
fi
ok "ip_forward в порядке"

step "5/8: генерирую ключи, обфускационные параметры и конфиг туннеля"
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
PostUp = iptables -A FORWARD -i ${IFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${EGRESS_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${IFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${EGRESS_IFACE} -j MASQUERADE
EOF
chmod 600 "${CONFIG_DIR}/${IFACE}.conf"
ufw allow "${PORT}/udp" || true
ok "Ключи и конфиг туннеля готовы"

step "6/8: пишу api.env и docker-compose.yml"
API_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
cat > "${CONFIG_DIR}/api.env" << EOF
DARKWG_IFACE=${IFACE}
DARKWG_SUBNET=${SUBNET}
DARKWG_SERVER_IP=${SERVER_IP}
DARKWG_SERVER_PUBLIC_KEY=${SERVER_PUBLIC_KEY}
DARKWG_ENDPOINT_HOST=${DARKWG_ENDPOINT}
DARKWG_ENDPOINT_PORT=${PORT}
DARKWG_CLIENT_DNS=1.1.1.1
DARKWG_DB_PATH=/opt/darkwg/data/darkwg.db
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

sed -e "s#__AWG_BIN_PATH__#${AWG_BIN_PATH}#g" \
    -e "s#__AWG_QUICK_BIN_PATH__#${AWG_QUICK_BIN_PATH}#g" \
    "${REPO_DIR}/docker-compose.yml" > "${REPO_DIR}/docker-compose.generated.yml"

touch "${REPO_DIR}/nginx/darkwg-api.conf"  # пустышка, чтобы volume в compose был валиден даже в режиме 1
ok "api.env и docker-compose.yml готовы"

# ----------------------------------------------------------------------------
# Шаг 7: внешний HTTPS-доступ к API (только режим 2) — HTTP-01 (standalone)
# ----------------------------------------------------------------------------
API_PUBLIC_URL=""
COMPOSE_PROFILE_ARGS=()
if [[ "${DARKWG_MODE}" == "2" ]]; then
  step "7/8: настраиваю внешний HTTPS-доступ к API (режим 2, HTTP-01/standalone)"

  CERT_PATH="/etc/letsencrypt/live/${DARKWG_API_DOMAIN}/fullchain.pem"
  CERT_OK=false
  if [[ -f "${CERT_PATH}" ]] && openssl x509 -checkend 2592000 -noout -in "${CERT_PATH}" >/dev/null 2>&1; then
    CERT_OK=true
    echo "    действующий сертификат для ${DARKWG_API_DOMAIN} уже есть (>30 дней) — пропускаю выпуск"
  fi

  apt-get install -y -qq certbot

  if [[ "${CERT_OK}" == "false" ]]; then
    EMAIL_ARGS="--register-unsafely-without-email"
    [[ -n "${DARKWG_ACME_EMAIL:-}" ]] && EMAIL_ARGS="-m ${DARKWG_ACME_EMAIL}"

    if port_in_use 80; then
      echo "    порт 80 занят — определяю, какой контейнер его держит"
      BLOCKER_CONTAINER="$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep ':80->' | awk '{print $1}' | head -n1 || true)"
      if [[ -z "${BLOCKER_CONTAINER}" ]]; then
        # network_mode: host не показывает порты в `docker ps` явно — проверяем
        # отдельно, не висит ли что-то известное на хосте без явного маппинга
        BLOCKER_CONTAINER="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i nginx | head -n1 || true)"
      fi
      if [[ -n "${BLOCKER_CONTAINER}" ]]; then
        echo "    порт 80 занят контейнером '${BLOCKER_CONTAINER}' — останавливаю"
        echo "    на момент выпуска сертификата и сразу поднимаю обратно"
        docker stop "${BLOCKER_CONTAINER}" > /dev/null
        set +e
        certbot certonly --standalone --non-interactive --agree-tos ${EMAIL_ARGS} \
          -d "${DARKWG_API_DOMAIN}" \
          --pre-hook "docker stop ${BLOCKER_CONTAINER} || true" \
          --post-hook "docker start ${BLOCKER_CONTAINER} || true"
        CERTBOT_EXIT=$?
        set -e
        docker start "${BLOCKER_CONTAINER}" > /dev/null
        [[ "${CERTBOT_EXIT}" -eq 0 ]] || { fail "выпуск сертификата не удался."; exit 1; }
        echo "    pre-hook/post-hook сохранены certbot'ом в конфиг продления —"
        echo "    при автообновлении (certbot.timer) контейнер так же будет"
        echo "    сам останавливаться и подниматься обратно, без твоего участия"
      else
        fail "порт 80 занят неизвестным процессом (не похоже на Docker-контейнер)."
        echo "Освободи порт 80 вручную и перезапусти скрипт, либо выпусти" >&2
        echo "сертификат для ${DARKWG_API_DOMAIN} самостоятельно и положи его" >&2
        echo "в ${CERT_PATH} перед повторным запуском." >&2
        exit 1
      fi
    else
      certbot certonly --standalone --non-interactive --agree-tos ${EMAIL_ARGS} -d "${DARKWG_API_DOMAIN}"
    fi
  fi

  systemctl enable --now certbot.timer

  HTTPS_PORT="${DARKWG_API_HTTPS_PORT:-8443}"
  if port_in_use "${HTTPS_PORT}"; then
    echo "    порт ${HTTPS_PORT} занят — выбери другой"
    read -rp "Порт для HTTPS-доступа к API [8444]: " HTTPS_PORT
    HTTPS_PORT="${HTTPS_PORT:-8444}"
  fi

  sed -e "s#__HTTPS_PORT__#${HTTPS_PORT}#g" \
      -e "s#__API_DOMAIN__#${DARKWG_API_DOMAIN}#g" \
      -e "s#__CONTROL_IP__#${DARKWG_CONTROL_IP}#g" \
      "${REPO_DIR}/nginx/darkwg-api.conf.template" > "${REPO_DIR}/nginx/darkwg-api.conf"

  ufw allow from "${DARKWG_CONTROL_IP}" to any port "${HTTPS_PORT}" proto tcp || true

  COMPOSE_PROFILE_ARGS=(--profile external)
  API_PUBLIC_URL="https://${DARKWG_API_DOMAIN}:${HTTPS_PORT}"
  ok "Внешний HTTPS-доступ настроен"
else
  step "7/8: режим 1 — внешний доступ к API не настраивается, всё локально"
  ok "Пропущено (не нужно в этом режиме)"
fi

# ----------------------------------------------------------------------------
# Шаг 8: поднимаю контейнеры
# ----------------------------------------------------------------------------
if [[ "${DARKWG_MODE}" == "2" ]]; then
  step "8/8: собираю и поднимаю контейнеры (darkwg, darkwg-nginx)"
else
  step "8/8: собираю и поднимаю контейнер darkwg"
fi
cd "${REPO_DIR}"
docker rm -f darkwg darkwg-nginx 2>/dev/null || true
docker compose -f docker-compose.generated.yml "${COMPOSE_PROFILE_ARGS[@]}" build darkwg
docker compose -f docker-compose.generated.yml "${COMPOSE_PROFILE_ARGS[@]}" up -d
ok "Образ собран, контейнеры запущены"

echo "    жду готовности API..."
API_READY=false
for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:8765/health" > /dev/null 2>&1; then
    API_READY=true
    break
  fi
  sleep 1
done

show_container_diagnostics() {
  echo "" >&2
  echo "Последние строки логов контейнера darkwg:" >&2
  echo "----------------------------------------" >&2
  docker compose -f docker-compose.generated.yml logs darkwg --tail 40 2>&1 | tail -40 >&2 || true
  echo "----------------------------------------" >&2
  echo "" >&2
  echo "Память на сервере:" >&2
  free -h >&2 || true
  echo "" >&2
  echo "Статус контейнера:" >&2
  docker ps -a --filter "name=darkwg" --format 'table {{.Names}}\t{{.Status}}' >&2 || true
  echo "" >&2
  echo "Полные логи:" >&2
  echo "  docker compose -f ${REPO_DIR}/docker-compose.generated.yml logs darkwg" >&2
}

if [[ "${API_READY}" != "true" ]]; then
  echo "" >&2
  fail "API не ответила за 30 секунд — контейнер darkwg не поднялся как надо."
  show_container_diagnostics
  exit 1
fi
ok "API отвечает"

echo "    создаю первого пира"
PEER_CREATED=false
for attempt in 1 2 3; do
  if docker compose -f docker-compose.generated.yml exec -T darkwg \
    python3 scripts/darkwg_cli.py add-peer --telegram-user-id 0 --ttl-days 0 \
    --out "${PEERS_DIR}/peer1"; then
    PEER_CREATED=true
    break
  fi
  warn "попытка ${attempt}/3 не удалась, контейнер мог перезапуститься — жду 5 секунд и пробую снова"
  sleep 5
done

if [[ "${PEER_CREATED}" != "true" ]]; then
  fail "не удалось создать первого пира после 3 попыток — контейнер darkwg нестабилен."
  show_container_diagnostics
  exit 1
fi
ok "Первый пир создан"

echo ""
echo -e "${GREEN}====================================================================${NC}"
echo -e "${GREEN}  DarkWG установлен.${NC}"
echo "  Туннель:        ${IFACE}, порт ${PORT}/udp, подсеть ${SUBNET}"
echo "  Публичный ключ:  ${SERVER_PUBLIC_KEY}"
if [[ -n "${API_PUBLIC_URL}" ]]; then
  echo "  API снаружи:     ${API_PUBLIC_URL} (доступ только с ${DARKWG_CONTROL_IP})"
else
  echo "  API:             127.0.0.1:8765 (только локально)"
fi
echo "  API ключ:        ${API_KEY}"
echo "  Конфиг API:      ${CONFIG_DIR}/api.env"
echo ""
echo "  Первый пир создан:"
echo "    конфиг: ${PEERS_DIR}/peer1.conf"
echo "    QR:     ${PEERS_DIR}/peer1.png"
echo ""
echo "  Посмотреть QR прямо в терминале:"
echo "    qrencode -t ansiutf8 < ${PEERS_DIR}/peer1.conf"
echo ""
echo "  Управление пирами без API (внутри контейнера):"
echo "    docker compose -f ${REPO_DIR}/docker-compose.generated.yml exec darkwg python3 scripts/darkwg_cli.py list-peers"
echo ""
if [[ -n "${API_PUBLIC_URL}" ]]; then
  echo "  Проверка API: curl -s -H \"X-API-Key: ${API_KEY}\" ${API_PUBLIC_URL}/health"
else
  echo "  Проверка API: curl -s -H \"X-API-Key: ${API_KEY}\" http://127.0.0.1:8765/health"
fi
echo -e "${GREEN}====================================================================${NC}"