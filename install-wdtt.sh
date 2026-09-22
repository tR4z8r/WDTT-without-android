#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

INSTALLER_VERSION="v2.1.9"

hr()      { echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
info()    { echo -e "${BLUE}ℹ️  [INFO]${NC} $1"; }
success() { echo -e "${GREEN}✅ [УСПЕХ]${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠️  [ВНИМАНИЕ]${NC} $1"; }
error()   { echo -e "${RED}❌ [ОШИБКА]${NC} $1"; exit 1; }
step()    { echo -e "\n${MAGENTA}${BOLD}➤ $1${NC}"; }

generate_random_string() {
    local length=$1
    set +o pipefail
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length"
    set -o pipefail
}

check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        error "Запустите скрипт с правами root (sudo)!"
    fi
}

check_os() {
    if ! command -v apt-get >/dev/null 2>&1; then
        error "Скрипт поддерживает только Debian / Ubuntu."
    fi
}

check_internet() {
    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        error "Отсутствует подключение к интернету."
    fi
}

get_system_info() {
    OS_NAME=$(grep -oP '(?<=^NAME=")[^"]*' /etc/os-release || echo "Linux")
    SERVER_IP=$(curl -s --connect-timeout 3 ifconfig.me || curl -s --connect-timeout 3 api.ipify.org || echo "127.0.0.1")

    if systemctl is-active --quiet csqtt; then
        CSQTT_STATUS="${GREEN}● ACTIVE (Работает)${NC}"
    elif [ -f /usr/local/bin/csqtt ]; then
        CSQTT_STATUS="${YELLOW}○ STOPPED (Остановлен)${NC}"
    else
        CSQTT_STATUS="${RED}⊗ NOT INSTALLED (Не установлен)${NC}"
    fi
}

install_csqtt() {
    step "Конфигурация параметров сервера"

    echo -e " ${BOLD}🔑 Настройка мастер-пароля соединения:${NC}"
    echo -e "  ${CYAN}[1]${NC} Сгенерировать криптографический (Рекомендуется)"
    echo -e "  ${CYAN}[2]${NC} Использовать '000' (Тестовый)"
    echo -e "  ${CYAN}[3]${NC} Задать вручную"
    read -rp " Ваш выбор [1]: " PASS_CHOICE
    PASS_CHOICE=${PASS_CHOICE:-1}

    case "$PASS_CHOICE" in
        2) CSQTT_PASS="000" ;;
        3) read -rp " Введите ваш пароль: " CSQTT_PASS ;;
        *) CSQTT_PASS=$(generate_random_string 24) ;;
    esac

    read -rp "$(echo -e "\n ${BOLD}🌐 Порт входящих соединений (PEER_PORT UDP)${NC} [46000]: ")" CSQTT_PEER_PORT
    CSQTT_PEER_PORT=${CSQTT_PEER_PORT:-46000}

    read -rp "$(echo -e " ${BOLD}📊 Порт WEB-панели (TCP)${NC} [46002]: ")" CSQTT_WEB_PORT
    CSQTT_WEB_PORT=${CSQTT_WEB_PORT:-46002}

    echo ""
    read -rp "$(echo -e " ${BOLD}📞 Введите хэш звонка ВКонтакте${NC} (Для формирования ссылки): ")" VK_HASH
    if [[ -z "$VK_HASH" ]]; then
        warn "Хэш звонка не указан! В ссылку будет добавлена заглушка 'NO_HASH'."
        VK_HASH="NO_HASH"
    fi

    WEB_USER="admin"
    WEB_PASS=$(generate_random_string 16)
    DEVICE_ID="vps-$(generate_random_string 8)"

    step "Установка системных зависимостей"
    apt-get update -qq -y > /dev/null 2>&1
    apt-get install -qq -y iptables iproute2 nftables procps psmisc wget unzip curl < /dev/null > /dev/null 2>&1
    success "Зависимости установлены"

    step "Включение маршрутизации ядра (IP Forwarding)"
    echo 1 > /proc/sys/net/ipv4/ip_forward
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-csqtt.conf << 'EOF'
net.ipv4.ip_forward = 1
EOF
    sysctl -p /etc/sysctl.d/99-csqtt.conf >/dev/null 2>&1 || true

    step "Загрузка и распаковка CSQTT ${INSTALLER_VERSION}"
    rm -rf /opt/csqtt && mkdir -p /opt/csqtt
    cd /opt/csqtt

    info "Скачивание APK-пакета..."
    wget -q -O csqtt.apk "https://github.com/amurcanov/csqtt/releases/download/${INSTALLER_VERSION}/CSQTT-x86_64.apk" || \
    wget -q -O csqtt.apk "https://github.com/amurcanov/csqtt/releases/download/${INSTALLER_VERSION}/CSQTT.apk" || \
    error "Не удалось загрузить APK из репозитория."

    info "Извлечение исполняемого файла..."
    unzip -q -o csqtt.apk -d apk > /dev/null 2>&1

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) TARGET_BIN="apk/assets/csqtt-linux-amd64" ;;
        aarch64|arm64) TARGET_BIN="apk/assets/csqtt-linux-arm64" ;;
        armv7*|armhf)  TARGET_BIN="apk/assets/csqtt-linux-armv7" ;;
        *) error "Архитектура $ARCH не поддерживается." ;;
    esac

    if [ ! -f "$TARGET_BIN" ]; then
        error "Бинарник $TARGET_BIN внутри пакета не найден!"
    fi

    install -m 0755 "$TARGET_BIN" /usr/local/bin/csqtt
    success "Бинарник установлен в /usr/local/bin/csqtt"

    step "Настройка сетевых правил и NAT"
    WAN_IFACE=$(ip -o -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); break}}')
    [ -z "$WAN_IFACE" ] && WAN_IFACE=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=dev )\S+' | head -1)

    iptables -w 2 -C INPUT -p udp --dport "$CSQTT_PEER_PORT" -m comment --comment "CSQTT_MANAGED" -j ACCEPT 2>/dev/null || \
        iptables -w 2 -I INPUT -p udp --dport "$CSQTT_PEER_PORT" -m comment --comment "CSQTT_MANAGED" -j ACCEPT

    iptables -w 2 -C INPUT -p tcp --dport "$CSQTT_WEB_PORT" -m comment --comment "CSQTT_MANAGED" -j ACCEPT 2>/dev/null || \
        iptables -w 2 -I INPUT -p tcp --dport "$CSQTT_WEB_PORT" -m comment --comment "CSQTT_MANAGED" -j ACCEPT

    iptables -w 2 -C FORWARD -i csqtt1 -m comment --comment "CSQTT_MANAGED" -j ACCEPT 2>/dev/null || \
        iptables -w 2 -I FORWARD -i csqtt1 -m comment --comment "CSQTT_MANAGED" -j ACCEPT

    iptables -w 2 -C FORWARD -o csqtt1 -m comment --comment "CSQTT_MANAGED" -j ACCEPT 2>/dev/null || \
        iptables -w 2 -I FORWARD -o csqtt1 -m comment --comment "CSQTT_MANAGED" -j ACCEPT

    iptables -w 2 -t nat -C POSTROUTING -s 10.66.67.0/24 -o "$WAN_IFACE" -m comment --comment "CSQTT_MANAGED" -j MASQUERADE 2>/dev/null || \
        iptables -w 2 -t nat -A POSTROUTING -s 10.66.67.0/24 -o "$WAN_IFACE" -m comment --comment "CSQTT_MANAGED" -j MASQUERADE

    iptables -w 2 -t mangle -C FORWARD -s 10.66.67.0/24 -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "CSQTT_MANAGED" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -w 2 -t mangle -I FORWARD -s 10.66.67.0/24 -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "CSQTT_MANAGED" -j TCPMSS --clamp-mss-to-pmtu

    step "Формирование конфигураций"
    mkdir -p /etc/csqtt
    chmod 700 /etc/csqtt

    cat > /etc/csqtt/csqtt.env << EOF
CSQTT_WEB_USER=${WEB_USER}
CSQTT_WEB_PASS=${WEB_PASS}
EOF
    chmod 600 /etc/csqtt/csqtt.env

    cat > /etc/csqtt/deploy-overrides.json << EOF
{
  "main_password": "${CSQTT_PASS}",
  "device_id": "${DEVICE_ID}"
}
EOF
    chmod 600 /etc/csqtt/deploy-overrides.json

    step "Конфигурация SystemD"
    cat > /etc/systemd/system/csqtt.service << EOF
[Unit]
Description=CSQTT VPN Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/csqtt/csqtt.env
Environment=CSQTT_SERVICE_MANAGER=systemd
ExecStartPre=-/usr/bin/env bash -c "ip link show csqtt1 >/dev/null 2>&1 && ip link del csqtt1 || true"
ExecStart=/usr/local/bin/csqtt --listen 0.0.0.0:${CSQTT_PEER_PORT} --web-port ${CSQTT_WEB_PORT} --config-dir /etc/csqtt
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    success "Служба csqtt.service создана"

    step "Запуск сервера"
    systemctl daemon-reload
    systemctl enable csqtt --now >/dev/null 2>&1
    sleep 3

    if systemctl is-active --quiet csqtt; then
        success "Сервер успешно стартовал!"
    else
        error "Сервер не запустился. Посмотрите подробности: journalctl -fu csqtt"
    fi

    echo ""
    hr
    echo -e " ${GREEN}${BOLD}🎉 УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО 🎉${NC}"
    hr
    echo -e " 📍 ${BOLD}IP Сервера:${NC}        ${YELLOW}${SERVER_IP}${NC}"
    echo -e " 📍 ${BOLD}Порт PEER (UDP):${NC}   ${CYAN}${CSQTT_PEER_PORT}${NC}"
    echo -e " 📍 ${BOLD}Порт WEB-панели:${NC}   ${CYAN}${CSQTT_WEB_PORT}${NC}"
    echo -e " 📍 ${BOLD}Мастер-пароль:${NC}     ${MAGENTA}${CSQTT_PASS}${NC}"
    hr
    echo -e " 👤 ${BOLD}WEB-Логин:${NC}         ${WHITE}${WEB_USER}${NC}"
    echo -e " 🔑 ${BOLD}WEB-Пароль:${NC}        ${MAGENTA}${WEB_PASS}${NC}"
    echo -e " 🌐 ${BOLD}WEB-Панель:${NC}        https://${SERVER_IP}:${CSQTT_WEB_PORT}"
    hr
    echo -e " ${CYAN}${BOLD}🔗 ВАША ССЫЛКА ДЛЯ ПОДКЛЮЧЕНИЯ В ПРИЛОЖЕНИИ:${NC}"
    echo -e " ${WHITE}csqtt://${SERVER_IP}:${CSQTT_PEER_PORT}:${CSQTT_PASS}:${VK_HASH}${NC}"
    hr
    echo ""
}

uninstall_csqtt() {
    step "Деинсталляция системы CSQTT"
    systemctl stop csqtt 2>/dev/null || true
    systemctl disable csqtt 2>/dev/null || true
    rm -f /etc/systemd/system/csqtt.service
    systemctl daemon-reload

    ip link del csqtt1 2>/dev/null || true
    rm -f /usr/local/bin/csqtt
    rm -rf /opt/csqtt /etc/csqtt

    success "CSQTT полностью удалён."
}

check_root
check_os
check_internet
get_system_info

clear
hr
echo -e "${CYAN}${BOLD}                    ⚡ CSQTT SERVER MANAGER ⚡                    ${NC}"
hr
echo -e " 💻 ${BOLD}ОС:${NC}          ${WHITE}$OS_NAME${NC}"
echo -e " 🌐 ${BOLD}IP Адрес:${NC}    ${YELLOW}$SERVER_IP${NC}"
echo -e " 📊 ${BOLD}Статус:${NC}      $CSQTT_STATUS"
hr
echo -e "  ${GREEN}[1]${NC} Установить / Обновить CSQTT"
echo -e "  ${RED}[2]${NC} Полностью удалить CSQTT"
echo -e "  ${WHITE}[3]${NC} Выйти"
hr

read -rp "$(echo -e " ${BOLD}Выберите действие (1-3):${NC} ")" ACTION

case "$ACTION" in
    1) install_csqtt ;;
    2) uninstall_csqtt ;;
    3) exit 0 ;;
    *) error "Введена неверная команда." ;;
esac
