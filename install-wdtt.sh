#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ==========================================
# 🎨 Цветовая палитра и стили
# ==========================================
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

# ==========================================
# 🛠 Вспомогательные функции UI
# ==========================================
hr()      { echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
info()    { echo -e "${BLUE}ℹ️  [INFO]${NC} $1"; }
success() { echo -e "${GREEN}✅ [УСПЕХ]${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠️  [ВНИМАНИЕ]${NC} $1"; }
error()   { echo -e "${RED}❌ [ОШИБКА]${NC} $1"; exit 1; }
step()    { echo -e "\n${MAGENTA}${BOLD}➤ $1${NC}"; }

generate_random_string() {
    local length=$1
    set +o pipefail
    tr -dc 'a-zA-Z0-9_-' < /dev/urandom | head -c "$length"
    set -o pipefail
}

# ==========================================
# 🛡 БЛОК ПРОВЕРОК (CHECKS)
# ==========================================
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        error "Запустите скрипт с правами root (sudo)!"
    fi
}

check_os() {
    if ! command -v apt-get >/dev/null 2>&1; then
        error "Скрипт поддерживает только Debian / Ubuntu. Утилита apt-get не найдена."
    fi
}

check_internet() {
    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        error "Отсутствует подключение к интернету. Проверьте сеть."
    fi
}

check_port() {
    local port=$1
    local name=$2
    if ss -tuln | grep -q ":${port} "; then
        error "Порт ${port} (${name}) уже занят другим процессом! Освободите его или выберите другой."
    fi
}

get_system_info() {
    OS_NAME=$(grep -oP '(?<=^NAME=")[^"]*' /etc/os-release || echo "Linux")
    SERVER_IP=$(curl -s --connect-timeout 3 ifconfig.me || curl -s --connect-timeout 3 api.ipify.org || echo "127.0.0.1")

    if systemctl is-active --quiet csqtt; then
        CSQTT_STATUS="${GREEN}● ACTIVE (Работает)${NC}"
    elif [ -f /usr/local/bin/csqtt-server ]; then
        CSQTT_STATUS="${YELLOW}○ STOPPED (Остановлена)${NC}"
    else
        CSQTT_STATUS="${RED}⊗ NOT INSTALLED (Не установлена)${NC}"
    fi
}

# ==========================================
# 🚀 ФУНКЦИЯ УСТАНОВКИ
# ==========================================
install_csqtt() {
    step "Конфигурация параметров сервера"

    echo -e " ${BOLD}🔑 Настройка пароля (Секрета):${NC}"
    echo -e "  ${CYAN}[1]${NC} Сгенерировать криптографический (Рекомендуется)"
    echo -e "  ${CYAN}[2]${NC} Использовать '000' (Тестовый)"
    echo -e "  ${CYAN}[3]${NC} Задать вручную"
    read -rp " Ваш выбор [1]: " PASS_CHOICE
    PASS_CHOICE=${PASS_CHOICE:-1}

    case "$PASS_CHOICE" in
        2) CSQTT_PASS="000" ;;
        3) read -rp " Введите ваш пароль: " CSQTT_PASS ;;
        *) CSQTT_PASS=$(generate_random_string 32) ;;
    esac

    read -rp "$(echo -e "\n ${BOLD}🌐 DTLS порт${NC} [56000]: ")" CSQTT_DTLS_PORT
    CSQTT_DTLS_PORT=${CSQTT_DTLS_PORT:-56000}

    read -rp "$(echo -e " ${BOLD}🛡️  WG порт${NC} [56001]: ")" CSQTT_WG_PORT
    CSQTT_WG_PORT=${CSQTT_WG_PORT:-56001}

    if ! systemctl is-active --quiet csqtt; then
        check_port "$CSQTT_DTLS_PORT" "DTLS"
        check_port "$CSQTT_WG_PORT" "WireGuard"
    fi

    echo ""
    read -rp "$(echo -e " ${BOLD}🤖 Telegram Bot Token${NC} (Enter пропустить): ")" BOT_TOKEN
    read -rp "$(echo -e " ${BOLD}👤 Telegram Admin ID${NC} (Enter пропустить): ")" ADMIN_ID
    
    echo ""
    read -rp "$(echo -e " ${BOLD}📞 Введите хэш звонка ВКонтакте${NC} (Обязательно для ссылки): ")" VK_HASH
    if [[ -z "$VK_HASH" ]]; then
        warn "Хэш звонка не указан! В ссылку будет добавлена заглушка 'NO_HASH'."
        VK_HASH="NO_HASH"
    fi

    CSQTT_DNS="77.88.8.8,77.88.8.1"

    step "Установка системных зависимостей"
    info "Обновление индексов apt..."
    apt-get update -qq -y > /dev/null 2>&1
    info "Установка iptables, iproute2, nftables, unzip..."
    apt-get install -qq -y iptables iproute2 nftables procps psmisc wget unzip curl < /dev/null > /dev/null 2>&1
    success "Зависимости успешно установлены"

    step "Загрузка и распаковка CSQTT ${INSTALLER_VERSION}"
    rm -rf /opt/csqtt && mkdir -p /opt/csqtt
    cd /opt/csqtt
    
    info "Скачивание сборки сервера..."
    # Загрузка архива/apk нового репозитория csqtt
    wget -q -O csqtt.apk "https://github.com/amurcanov/csqtt/releases/download/${INSTALLER_VERSION}/CSQTT-x86_64.apk" || \
    wget -q -O csqtt.apk "https://github.com/amurcanov/csqtt/releases/download/${INSTALLER_VERSION}/csqtt-server-linux-amd64.tar.gz" || \
    error "Не удалось скачать релиз с GitHub. Проверьте версию или подключение."

    info "Извлечение бинарных файлов..."
    if [[ -f csqtt.apk ]]; then
        unzip -q -o csqtt.apk -d apk > /dev/null 2>&1
        if [ -f apk/assets/server ]; then
            install -m 0755 apk/assets/server /usr/local/bin/csqtt-server
        elif [ -f apk/lib/x86_64/libserver.so ]; then
            install -m 0755 apk/lib/x86_64/libserver.so /usr/local/bin/csqtt-server
        else
            error "Исполняемый файл сервера внутри пакета не найден."
        fi
    fi

    mkdir -p /etc/csqtt
    success "Ядро сервера установлено: /usr/local/bin/csqtt-server"

    step "Конфигурация SystemD"
    cat > /etc/systemd/system/csqtt.service <<EOF
[Unit]
Description=CSQTT VPN Server
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=3
LimitNOFILE=65535

ExecStartPre=-/usr/bin/env bash -c "ip link show csqtt0 >/dev/null 2>&1 && ip link del csqtt0 || true"

ExecStart=/usr/local/bin/csqtt-server \\
  -listen 0.0.0.0:${CSQTT_DTLS_PORT} \\
  -wg-port ${CSQTT_WG_PORT} \\
  -config-dir /etc/csqtt \\
  -password "${CSQTT_PASS}" \\
  -dns "${CSQTT_DNS}" \\
  -bot-token "${BOT_TOKEN}" \\
  -admin "${ADMIN_ID}"

[Install]
WantedBy=multi-user.target
EOF
    success "Служба csqtt.service создана"

    step "Запуск сервера"
    systemctl daemon-reload
    systemctl enable csqtt --now >/dev/null 2>&1
    sleep 2

    if systemctl is-active --quiet csqtt; then
        success "Сервер успешно стартовал!"
    else
        error "Сервер не смог запуститься. Проверьте логи: journalctl -fu csqtt"
    fi

    # ==========================================
    # 🏆 ИТОГОВЫЙ ДАШБОРД
    # ==========================================
    echo ""
    hr
    echo -e " ${GREEN}${BOLD}🎉 УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО 🎉${NC}"
    hr
    echo -e " 📍 ${BOLD}IP Адрес:${NC}      ${YELLOW}${SERVER_IP}${NC}"
    echo -e " 📍 ${BOLD}DTLS Порт:${NC}     ${CYAN}${CSQTT_DTLS_PORT}${NC}"
    echo -e " 📍 ${BOLD}WG Порт:${NC}       ${CYAN}${CSQTT_WG_PORT}${NC}"
    echo -e " 📍 ${BOLD}Пароль:${NC}        ${MAGENTA}${CSQTT_PASS}${NC}"
    hr
    echo -e " ${CYAN}${BOLD}🔗 ВАША ССЫЛКА ДЛЯ ПОДКЛЮЧЕНИЯ:${NC}"
    echo -e " ${WHITE}csqtt://${SERVER_IP}:${CSQTT_DTLS_PORT}:${CSQTT_WG_PORT}:9000:${CSQTT_PASS}:${VK_HASH}${NC}"
    hr
    echo ""
}

# ==========================================
# 🗑 ФУНКЦИЯ УДАЛЕНИЯ
# ==========================================
uninstall_csqtt() {
    step "Деинсталляция системы CSQTT"
    
    if [ ! -f /usr/local/bin/csqtt-server ]; then
        warn "Служба не найдена. Возможно, она уже удалена."
        exit 0
    fi

    info "Остановка процессов..."
    systemctl stop csqtt 2>/dev/null || true
    systemctl disable csqtt 2>/dev/null || true
    rm -f /etc/systemd/system/csqtt.service
    systemctl daemon-reload

    info "Очистка сетевых интерфейсов и файлов..."
    ip link del csqtt0 2>/dev/null || true
    rm -f /usr/local/bin/csqtt-server
    rm -rf /etc/csqtt /opt/csqtt

    success "CSQTT полностью удален с сервера."
    echo ""
}

# ==========================================
# 🏁 ГЛАВНОЕ МЕНЮ
# ==========================================
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
    3) echo -e "\n${GREEN}До встречи!${NC}\n" ; exit 0 ;;
    *) error "Введена неверная команда. Запустите скрипт заново." ;;
esac
