#!/usr/bin/env bash
set -Eeuo pipefail

############################
# Config
############################

TG_INSTALL_URL="https://raw.githubusercontent.com/dotX12/traffic-guard/master/install.sh"
TG_ANTISCANNER_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list"
TG_GOV_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list"
TG_SKIPA_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/skipa.list"

GEOBAN_DIR="/opt/geoban"
GEOBAN_LIST_URL="https://github.com/vitabled/geofiles/releases/download/lists/banned_ips.txt"
GEOBAN_LIST_FILE="${GEOBAN_DIR}/ipban.txt"

PRO_MANAGER_URL="https://raw.githubusercontent.com/DonMatteoVPN/TrafficGuard-auto/refs/heads/main/install-trafficguard.sh"
REMNAWAVE_PROXY_URL="https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/main/install_remnawave.sh"
REMNAWAVE_BACKUP_RESTORE_URL="https://raw.githubusercontent.com/distillium/remnawave-backup-restore/main/backup-restore.sh"

MTPROTOMAX_URL="https://raw.githubusercontent.com/SamNet-dev/MTProxyMax/main/install.sh"
YANDEX_CLOUD_MANAGER_URL="https://raw.githubusercontent.com/Mastachok/ya-vps-autostart/main/install.sh"

LOG_FILE="/var/log/server_protection_setup.log"

SHORTCUT_NAME="security-manager"
SHORTCUT_PATH="/usr/local/bin/${SHORTCUT_NAME}"

FAIL2BAN_CUSTOM_FILE="/etc/fail2ban/jail.d/custom.local"
PORTS_CHAIN="SECMGR_PORTS"

############################
# Colors / Logging
############################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    local level="$1"
    shift
    local msg="$*"
    local color="$NC"

    case "$level" in
        INFO) color="$GREEN" ;;
        WARN) color="$YELLOW" ;;
        ERROR) color="$RED" ;;
        STEP) color="$BLUE" ;;
    esac

    echo -e "${color}[$level]${NC} ${msg}"
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    echo "[$(date '+%F %T')] [$level] ${msg}" >> "$LOG_FILE"
}

die() {
    log ERROR "$*"
    exit 1
}

on_error() {
    local line="$1"
    log ERROR "Ошибка на строке ${line}. Выполнение прервано."
}
trap 'on_error $LINENO' ERR

############################
# Base helpers
############################
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Скрипт нужно запускать от root: sudo bash $0"
    fi
}

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "Не найдена команда: $cmd"
}

check_os() {
    [[ -f /etc/os-release ]] || die "Не удалось определить ОС"
    . /etc/os-release

    case "${ID:-}" in
        ubuntu|debian)
            log INFO "Обнаружена ОС: ${PRETTY_NAME}"
            ;;
        *)
            die "Скрипт рассчитан на Debian/Ubuntu. Обнаружено: ${PRETTY_NAME:-unknown}"
            ;;
    esac
}

fetch_url_head() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsI --max-time 20 "$url" >/dev/null
    else
        wget --spider -q "$url"
    fi
}

download_file() {
    local url="$1"
    local out="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$out"
    else
        wget -qO "$out" "$url"
    fi
}

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

run_remote_installer() {
    local url="$1"
    local name="$2"

    log STEP "Проверка доступности установщика: $name"
    fetch_url_head "$url"

    local tmp_script
    tmp_script="$(mktemp)"

    log STEP "Скачивание установщика: $name"
    download_file "$url" "$tmp_script"
    chmod +x "$tmp_script"

    log STEP "Запуск установщика: $name"
    bash "$tmp_script"

    rm -f "$tmp_script"
    log INFO "$name: установка завершена"
}

pause_screen() {
    echo
    read -r -p "Нажми Enter, чтобы продолжить..." _
}

create_shortcut() {
    local script_path=""
    script_path="$(readlink -f "$0" 2>/dev/null || true)"

    if [[ -n "$script_path" && -f "$script_path" && "$script_path" != /dev/fd/* ]]; then
        chmod +x "$script_path"
        ln -sfn "$script_path" "$SHORTCUT_PATH"
        log INFO "Создан shortcut: ${SHORTCUT_NAME} -> ${script_path}"
        return 0
    fi

    log WARN "Скрипт запущен без постоянного пути. Shortcut будет создан после установки в /usr/local/bin."
}

install_self_to_system() {
    local target_script="/usr/local/bin/security-manager-script"

    if [[ -n "${SELF_INSTALL_SOURCE_URL:-}" ]]; then
        log STEP "Скачивание скрипта в ${target_script}"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "$SELF_INSTALL_SOURCE_URL" -o "$target_script"
        else
            wget -qO "$target_script" "$SELF_INSTALL_SOURCE_URL"
        fi
    else
        local current_path
        current_path="$(readlink -f "$0" 2>/dev/null || true)"

        [[ -n "$current_path" && -f "$current_path" && "$current_path" != /dev/fd/* ]] || \
            die "Не удалось определить путь к скрипту для установки"

        install -Dm755 "$current_path" "$target_script"
    fi

    chmod +x "$target_script"
    ln -sfn "$target_script" "$SHORTCUT_PATH"

    log INFO "Скрипт установлен в ${target_script}"
    log INFO "Команда быстрого доступа: ${SHORTCUT_NAME}"
}

############################
# Validation
############################
validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

parse_ports_csv() {
    local input="$1"
    local cleaned
    cleaned="$(echo "$input" | tr -d '[:space:]')"
    [[ -n "$cleaned" ]] || return 1

    IFS=',' read -r -a PORTS_ARRAY <<< "$cleaned"
    [[ "${#PORTS_ARRAY[@]}" -gt 0 ]] || return 1

    local p
    for p in "${PORTS_ARRAY[@]}"; do
        validate_port "$p" || return 1
    done
    return 0
}

validate_ip_or_cidr() {
    local value="$1"

    if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 0
    fi

    if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
        return 0
    fi

    return 1
}

validate_ip_list_space_separated() {
    local input="$1"
    [[ -n "$input" ]] || return 0

    local item
    for item in $input; do
        validate_ip_or_cidr "$item" || return 1
    done
    return 0
}

############################
# Netfilter / iptables
############################
ensure_netfilter_persistent() {
    if ! command -v netfilter-persistent >/dev/null 2>&1; then
        log WARN "netfilter-persistent не найден, устанавливаю"
        apt-get update -y
        apt_install netfilter-persistent iptables-persistent
    fi
}

save_firewall_rules() {
    ensure_netfilter_persistent
    netfilter-persistent save
}

iptables_rule_exists() {
    local chain="$1"
    shift
    iptables -C "$chain" "$@" 2>/dev/null
}

iptables_add_unique() {
    local chain="$1"
    shift
    if ! iptables_rule_exists "$chain" "$@"; then
        iptables -A "$chain" "$@"
    fi
}

iptables_insert_unique() {
    local chain="$1"
    shift
    if ! iptables_rule_exists "$chain" "$@"; then
        iptables -I "$chain" "$@"
    fi
}

iptables_delete_all() {
    local chain="$1"
    shift
    while iptables -C "$chain" "$@" 2>/dev/null; do
        iptables -D "$chain" "$@"
    done
}

ensure_ports_chain() {
    ensure_netfilter_persistent

    if ! iptables -L "$PORTS_CHAIN" -n >/dev/null 2>&1; then
        iptables -N "$PORTS_CHAIN"
    fi

    iptables_insert_unique INPUT -j "$PORTS_CHAIN"
}

show_ports_chain_status() {
    echo
    echo "===== INPUT ====="
    iptables -S INPUT || true
    echo "===== ${PORTS_CHAIN} ====="
    if iptables -L "$PORTS_CHAIN" -n >/dev/null 2>&1; then
        iptables -S "$PORTS_CHAIN" || true
    else
        echo "Цепочка ${PORTS_CHAIN} ещё не создана"
    fi
    echo "========================="
    echo
}

current_ssh_port() {
    local port
    port="$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | tail -n1 | awk '{print $2}' || true)"
    echo "${port:-22}"
}

is_port_busy() {
    local port="$1"
    ss -ltnH "( sport = :${port} )" | grep -q .
}

set_default_ports_policy() {
    ensure_ports_chain

    local ssh_port
    ssh_port="$(current_ssh_port)"

    local tcp_ports=("22" "2222" "443")
    local extra_port
    local exists=false

    for extra_port in "${tcp_ports[@]}"; do
        if [[ "$extra_port" == "$ssh_port" ]]; then
            exists=true
            break
        fi
    done
    if [[ "$exists" == false ]]; then
        tcp_ports+=("$ssh_port")
    fi

    iptables -F "$PORTS_CHAIN"

    iptables_add_unique "$PORTS_CHAIN" -i lo -j RETURN
    iptables_add_unique "$PORTS_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

    for extra_port in "${tcp_ports[@]}"; do
        iptables_add_unique "$PORTS_CHAIN" -p tcp --dport "$extra_port" -j RETURN
    done

    iptables_add_unique "$PORTS_CHAIN" -p udp --dport 443 -j RETURN
    iptables_add_unique "$PORTS_CHAIN" -p udp --dport 16385 -j RETURN
    iptables_add_unique "$PORTS_CHAIN" -p tcp -j DROP
    iptables_add_unique "$PORTS_CHAIN" -p udp -j DROP
    iptables_add_unique "$PORTS_CHAIN" -j RETURN

    save_firewall_rules
}

open_tcp_port() {
    local port="$1"
    ensure_ports_chain

    iptables_delete_all "$PORTS_CHAIN" -p tcp --dport "$port" -j DROP
    iptables_insert_unique "$PORTS_CHAIN" -p tcp --dport "$port" -j RETURN

    save_firewall_rules
}

close_tcp_port() {
    local port="$1"
    ensure_ports_chain

    iptables_delete_all "$PORTS_CHAIN" -p tcp --dport "$port" -j RETURN
    iptables_insert_unique "$PORTS_CHAIN" -p tcp --dport "$port" -j DROP

    save_firewall_rules
}

open_udp_port() {
    local port="$1"
    ensure_ports_chain

    iptables_delete_all "$PORTS_CHAIN" -p udp --dport "$port" -j DROP
    iptables_insert_unique "$PORTS_CHAIN" -p udp --dport "$port" -j RETURN

    save_firewall_rules
}

close_udp_port() {
    local port="$1"
    ensure_ports_chain

    iptables_delete_all "$PORTS_CHAIN" -p udp --dport "$port" -j RETURN
    iptables_insert_unique "$PORTS_CHAIN" -p udp --dport "$port" -j DROP

    save_firewall_rules
}


change_ssh_port() {
    ensure_netfilter_persistent

    local old_port new_port
    old_port="$(current_ssh_port)"

    read -r -p "Введи новый SSH порт: " new_port
    validate_port "$new_port" || die "Некорректный порт"

    if [[ "$new_port" == "$old_port" ]]; then
        die "Новый порт совпадает с текущим (${old_port})"
    fi

    if is_port_busy "$new_port"; then
        die "Порт ${new_port} уже занят"
    fi

    ensure_sshd_config

    local backup_file
    backup_file="/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"
    cp /etc/ssh/sshd_config "$backup_file"

    sed -i '/^[[:space:]]*Port[[:space:]]\+[0-9]\+/d' /etc/ssh/sshd_config
    echo "Port ${new_port}" >> /etc/ssh/sshd_config

    if ! sshd -t; then
        cp "$backup_file" /etc/ssh/sshd_config
        die "Конфигурация sshd некорректна, изменения отменены"
    fi

    open_tcp_port "$new_port"
    close_tcp_port "$old_port"
    close_tcp_port 22

    if ! systemctl restart ssh 2>/dev/null; then
        systemctl restart sshd
    fi

    log INFO "Порт SSH изменён: ${old_port} -> ${new_port}"
    echo "Новый SSH порт: ${new_port}"
    echo "Старый порт ${old_port} закрыт, порт 22 закрыт"
}

############################
# SSH helpers
############################
ensure_sshd_config() {
    [[ -f /etc/ssh/sshd_config ]] || die "Не найден /etc/ssh/sshd_config"
}

ssh_password_status() {
    ensure_sshd_config

    local value
    value="$(grep -E '^[[:space:]]*PasswordAuthentication[[:space:]]+' /etc/ssh/sshd_config | tail -n1 | awk '{print $2}' || true)"

    if [[ "${value,,}" == "no" ]]; then
        echo "выключено"
    else
        echo "включено"
    fi
}

user_home_dir() {
    local username="$1"
    getent passwd "$username" | cut -d: -f6
}

############################
# Fail2Ban
############################
ensure_fail2ban_config_exists() {
    [[ -f "$FAIL2BAN_CUSTOM_FILE" ]] || die "Файл ${FAIL2BAN_CUSTOM_FILE} не найден. Сначала установи Fail2Ban."
}

fail2ban_get_value() {
    local key="$1"
    ensure_fail2ban_config_exists
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$FAIL2BAN_CUSTOM_FILE" | tail -n1 | cut -d= -f2- | xargs
}

fail2ban_set_value() {
    local key="$1"
    local value="$2"
    ensure_fail2ban_config_exists

    if grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "$FAIL2BAN_CUSTOM_FILE"; then
        sed -i "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$FAIL2BAN_CUSTOM_FILE"
    else
        sed -i "/^\[DEFAULT\]/a ${key} = ${value}" "$FAIL2BAN_CUSTOM_FILE"
    fi
}

restart_fail2ban_service() {
    systemctl enable fail2ban
    systemctl restart fail2ban
    systemctl --no-pager --full status fail2ban >/dev/null 2>&1 || die "Fail2Ban не запустился"
}

fail2ban_install() {
    log STEP "Установка Fail2Ban"
    apt-get update -y
    apt_install fail2ban

    local userip=""
    local useremail=""

    read -r -p "Введи ignoreip (можно несколько значений через пробел, Enter = пусто): " userip
    if ! validate_ip_list_space_separated "$userip"; then
        die "Некорректный формат userip. Используй x.x.x.x или x.x.x.x/x, несколько значений через пробел."
    fi

    while true; do
        read -r -p "Введи email для destemail: " useremail && break
    done

    mkdir -p /etc/fail2ban/jail.d

    cat >"$FAIL2BAN_CUSTOM_FILE" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ${userip}
destemail = ${useremail}
sender = fail2ban@$(hostname -f 2>/dev/null || hostname)
mta = sendmail

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

    restart_fail2ban_service
    log INFO "Fail2Ban установлен и настроен"
}

fail2ban_change_email() {
    ensure_fail2ban_config_exists

    local useremail=""
    while true; do
        read -r -p "Введи новый email для destemail: " useremail
        validate_email "$useremail" && break
        log WARN "Некорректный email"
    done

    fail2ban_set_value "destemail" "$useremail"
    restart_fail2ban_service

    log INFO "destemail обновлён: ${useremail}"
}

fail2ban_add_ip() {
    ensure_fail2ban_config_exists

    local new_ips=""
    read -r -p "Введи IP/CIDR для добавления в ignoreip (через пробел): " new_ips
    validate_ip_list_space_separated "$new_ips" || die "Некорректный список IP"

    local current joined
    current="$(fail2ban_get_value "ignoreip")"

    declare -A seen=()
    declare -a result=()
    local item

    for item in $current $new_ips; do
        [[ -n "$item" ]] || continue
        if [[ -z "${seen[$item]:-}" ]]; then
            seen["$item"]=1
            result+=("$item")
        fi
    done

    joined="${result[*]}"
    fail2ban_set_value "ignoreip" "$joined"
    restart_fail2ban_service

    log INFO "IP добавлены в ignoreip"
}

fail2ban_remove_ip() {
    ensure_fail2ban_config_exists

    local current
    current="$(fail2ban_get_value "ignoreip")"
    [[ -n "$current" ]] || die "Список ignoreip пуст"

    read -r -a ips <<< "$current"
    [[ "${#ips[@]}" -gt 0 ]] || die "Список ignoreip пуст"

    echo
    echo "Текущий список ignoreip:"
    local i
    for i in "${!ips[@]}"; do
        printf "%d) %s\n" "$((i + 1))" "${ips[$i]}"
    done
    echo

    local choice
    read -r -p "Выбери номер IP для удаления: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || die "Некорректный номер"
    (( choice >= 1 && choice <= ${#ips[@]} )) || die "Номер вне диапазона"

    unset 'ips[choice-1]'

    local updated=()
    for i in "${ips[@]}"; do
        [[ -n "$i" ]] && updated+=("$i")
    done

    fail2ban_set_value "ignoreip" "${updated[*]}"
    restart_fail2ban_service

    log INFO "IP удалён из ignoreip"
}

fail2ban_menu() {
    while true; do
        clear
        echo "============================================"
        echo "                Fail2Ban"
        echo "============================================"
        echo "1) Установить Fail2Ban"
        echo "2) Изменить почту"
        echo "3) Добавить IP"
        echo "4) Удалить IP (из списка)"
        echo "0) Назад"
        echo "============================================"

        read -r -p "Выбери подпункт: " subchoice
        echo

        case "$subchoice" in
            1) fail2ban_install; pause_screen ;;
            2) fail2ban_change_email; pause_screen ;;
            3) fail2ban_add_ip; pause_screen ;;
            4) fail2ban_remove_ip; pause_screen ;;
            0) break ;;
            *) log WARN "Неверный подпункт меню"; pause_screen ;;
        esac
    done
}

############################
# Preparation
############################
prepare_system() {
    check_os

    require_cmd apt-get
    require_cmd systemctl
    require_cmd iptables
    require_cmd python3
    require_cmd ss

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        apt-get update -y
        apt_install curl
    fi

    create_shortcut
}

install_base_packages() {
    log STEP "Установка базовых пакетов"
    apt-get update -y
    apt_install ca-certificates curl wget git python3 python3-pip openssh-client iproute2
    log INFO "Базовые пакеты установлены"
}

system_update() {
    log STEP "Обновление пакетов"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y
    log INFO "Пакеты обновлены"
}

############################
# Main modules
############################

install_traffic_guard() {
    log STEP "Установка Traffic Guard"
    fetch_url_head "$TG_INSTALL_URL"
    fetch_url_head "$TG_ANTISCANNER_URL"
    fetch_url_head "$TG_GOV_URL"

    local tmp_script
    tmp_script="$(mktemp)"
    download_file "$TG_INSTALL_URL" "$tmp_script"
    bash "$tmp_script"
    rm -f "$tmp_script"

    require_cmd traffic-guard

    traffic-guard full \
        -u "$TG_ANTISCANNER_URL" \
        -u "$TG_GOV_URL" \
        -u "$TG_SKIPA_URL" \
        --enable-logging

    log INFO "Traffic Guard установлен и настроен"
}

install_pro_manager() {
    run_remote_installer "$PRO_MANAGER_URL" "Traffic-Guard Pro Manager"
    log INFO "Для использования менеджера введи команду: rknpidor"
}

install_mtprotomax() {
    log STEP "Установка MTProtoMax"
    fetch_url_head "$MTPROTOMAX_URL"
    bash -c "$(curl -fsSL "$MTPROTOMAX_URL")"
    log INFO "MTProtoMax: установка завершена"
}

install_yandex_cloud_manager() {
    log STEP "Установка YandexCloudManager скрипта"
    fetch_url_head "$YANDEX_CLOUD_MANAGER_URL"
    curl -fsSL "$YANDEX_CLOUD_MANAGER_URL" | bash
    log INFO "YandexCloudManager скрипт: установка завершена"
}

##################################################################
######Единая функция для установки traffic guard и менеджера######
##################################################################
#install_traffic_guard_and_manager() {
#    install_traffic_guard
#    install_pro_manager
#}

install_geoban() {
    log STEP "Настройка GeoBan"

    ensure_netfilter_persistent
    mkdir -p "$GEOBAN_DIR"

    fetch_url_head "$GEOBAN_LIST_URL"
    download_file "$GEOBAN_LIST_URL" "$GEOBAN_LIST_FILE"

    [[ -s "$GEOBAN_LIST_FILE" ]] || die "Список банов пустой или не скачался: $GEOBAN_LIST_FILE"

    local total=0
    local added=0
    local ip

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        ip="$(echo "$raw_line" | sed 's/#.*//; s/[[:space:]]*$//; s/^[[:space:]]*//')"
        [[ -z "$ip" ]] && continue

        ((total+=1))

        if iptables -t raw -C PREROUTING -s "$ip" -j DROP 2>/dev/null; then
            continue
        fi

        iptables -t raw -I PREROUTING -s "$ip" -j DROP
        ((added+=1))
    done < "$GEOBAN_LIST_FILE"

    save_firewall_rules
    log INFO "GeoBan применён. Всего записей: $total, добавлено новых правил: $added"
}

install_remnawave_reverse_proxy() {
    run_remote_installer "$REMNAWAVE_PROXY_URL" "remnawave-reverse-proxy"
}

install_remnawave_backup_restore() {
    log STEP "Установка remnawave backup & restore"
    fetch_url_head "$REMNAWAVE_BACKUP_RESTORE_URL"

    local backup_script="${HOME}/backup-restore.sh"
    download_file "$REMNAWAVE_BACKUP_RESTORE_URL" "$backup_script"
    chmod +x "$backup_script"
    "$backup_script"

    log INFO "remnawave backup & restore установлен"
}

install_all() {
    install_base_packages
    system_update
    toggle_bbr
    install_traffic_guard
    install_geoban
    fail2ban_install
    install_pro_manager
    log INFO "Все выбранные компоненты установлены"
}

############################
# Port management
############################
ports_close_all_except_defaults() {
    log STEP "Закрытие всех TCP/UDP портов, кроме нужных"

    set_default_ports_policy

    log INFO "Портовая политика применена"
    echo "Разрешены TCP: 22, 2222, 443 и текущий SSH порт"
    echo "Разрешён UDP: 443, 16385"
    show_ports_chain_status
}

ports_open_custom_tcp() {
    local input
    read -r -p "Введи TCP-порты для открытия через запятую (например 80,8080,8443): " input

    local PORTS_ARRAY=()
    parse_ports_csv "$input" || die "Некорректный список портов"

    local p
    for p in "${PORTS_ARRAY[@]}"; do
        open_tcp_port "$p"
        log INFO "Открыт TCP порт ${p}"
    done

    show_ports_chain_status
}

ports_close_custom_tcp() {
    local input
    read -r -p "Введи TCP-порты для закрытия через запятую (например 80,8080,8443): " input

    local PORTS_ARRAY=()
    parse_ports_csv "$input" || die "Некорректный список портов"

    local p
    for p in "${PORTS_ARRAY[@]}"; do
        close_tcp_port "$p"
        log INFO "Закрыт TCP порт ${p}"
    done

    show_ports_chain_status
}

ports_open_custom_udp() {
    local input
    read -r -p "Введи UDP-порты для открытия через запятую (например 80,8080,8443): " input

    local PORTS_ARRAY=()
    parse_ports_csv "$input" || die "Некорректный список портов"

    local p
    for p in "${PORTS_ARRAY[@]}"; do
        open_udp_port "$p"
        log INFO "Открыт UDP порт ${p}"
    done

    show_ports_chain_status
}

ports_close_custom_tcp() {
    local input
    read -r -p "Введи UDP-порты для закрытия через запятую (например 80,8080,8443): " input

    local PORTS_ARRAY=()
    parse_ports_csv "$input" || die "Некорректный список портов"

    local p
    for p in "${PORTS_ARRAY[@]}"; do
        close_udp_port "$p"
        log INFO "Закрыт UDP порт ${p}"
    done

    show_ports_chain_status
}

ports_menu() {
    while true; do
        clear
        echo "============================================"
        echo "           Управление портами"
        echo "============================================"
        echo "1) Закрыть все порты, кроме OpenSSH/22, 2222, 443, 16385"
        echo "2) Открыть TCP-порты (через запятую)"
        echo "3) Закрыть TCP-порты (через запятую)"
        echo "4) Открыть UDP-порты (через запятую)"
        echo "5) Закрыть UDP-порты (через запятую)"
        echo "6) Поменять порт SSH"
        echo "7) Показать статус правил портов"
        echo "0) Назад"
        echo "============================================"

        read -r -p "Выбери подпункт: " subchoice
        echo

        case "$subchoice" in
            1) ports_close_all_except_defaults; pause_screen ;;
            2) ports_open_custom_tcp; pause_screen ;;
            3) ports_close_custom_tcp; pause_screen ;;
            4) ports_open_custom_udp; pause_screen ;;
            5) ports_close_custom_udp; pause_screen ;;
            6) change_ssh_port; pause_screen ;;
            7) show_ports_chain_status; pause_screen ;;
            0) break ;;
            *) log WARN "Неверный подпункт меню"; pause_screen ;;
        esac
    done
}

############################
# Statistics
############################
stats_fail2ban() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        log WARN "fail2ban-client не найден"
        return
    fi
    fail2ban-client status sshd || true
}

stats_trafficguard_manager() {
    if command -v rknpidor >/dev/null 2>&1; then
        rknpidor || true
    else
        log WARN "Команда rknpidor не найдена"
    fi
}

statistics_menu() {
    while true; do
        clear
        echo "============================================"
        echo "         Просмотр статистики"
        echo "============================================"
        echo "1) Статистика Fail2Ban (sshd)"
        echo "2) Статистика TrafficGuard Pro Manager"
        echo "0) Назад"
        echo "============================================"

        read -r -p "Выбери подпункт: " subchoice
        echo

        case "$subchoice" in
            1) stats_fail2ban; pause_screen ;;
            2) stats_trafficguard_manager; pause_screen ;;
            0) break ;;
            *) log WARN "Неверный подпункт меню"; pause_screen ;;
        esac
    done
}

############################
# Useful commands
############################
show_useful_commands() {
    echo
    echo "============================================"
    echo "            Полезные команды"
    echo "============================================"
    echo "Быстрый доступ к меню:"
    echo "  ${SHORTCUT_NAME}"
    echo
    echo "TrafficGuard Pro Manager:"
    echo "  rknpidor"
    echo
    echo "Remnawave reverse proxy installer:"
    echo "  remnawave-reverse"
    echo
    echo "Remnawave backup & restore:"
    echo "  ~/backup-restore.sh"
    echo
    echo "Traffic Guard:"
    echo "  traffic-guard --help"
    echo "  traffic-guard full -u ${TG_ANTISCANNER_URL} -u ${TG_GOV_URL} -u ${TG_SKIPA_URL} --enable-logging"
    echo
    echo "MTProtoMax:"
    echo "  mtproxymax"
    echo
    echo "YandexCloudManager:"
    echo "  vps-watchdog"
    echo
    echo "Fail2Ban:"
    echo "  fail2ban-client status"
    echo "  fail2ban-client status sshd"
    echo
    echo "Проверка правил портов:"
    echo "  iptables -S ${PORTS_CHAIN}"
    echo "  iptables -S INPUT"
    echo
    echo "Сохранение правил:"
    echo "  netfilter-persistent save"
    echo "============================================"
}

############################
# SSH key / password auth
############################
add_ssh_key_for_user() {
    local username
    read -r -p "Введи имя пользователя: " username
    [[ -n "$username" ]] || die "Имя пользователя пустое"

    id "$username" >/dev/null 2>&1 || die "Пользователь '$username' не существует"

    local home_dir
    home_dir="$(user_home_dir "$username")"
    [[ -n "$home_dir" && -d "$home_dir" ]] || die "Не удалось определить домашнюю папку пользователя"

    local ssh_dir="${home_dir}/.ssh"
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    local key_path="${home_dir}/PRIVATEKEY_${ts}"

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    chown "$username:$username" "$ssh_dir"

    ssh-keygen -t ed25519 -N "" -f "$key_path" -C "${username}@$(hostname)" >/dev/null

    cat "${key_path}.pub" >> "${ssh_dir}/authorized_keys"
    chmod 600 "${ssh_dir}/authorized_keys"
    chown "$username:$username" "${ssh_dir}/authorized_keys"
    chown "$username:$username" "$key_path" "${key_path}.pub"
    chmod 600 "$key_path"
    chmod 644 "${key_path}.pub"

    log INFO "SSH-ключ создан для пользователя '$username'"
    echo "Путь к приватному ключу: $key_path"
    echo "Путь к публичному ключу: ${key_path}.pub"
}

set_ssh_password_auth() {
    local mode="$1"
    ensure_sshd_config

    cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"

    if grep -Eq '^[#[:space:]]*PasswordAuthentication[[:space:]]+' /etc/ssh/sshd_config; then
        sed -i "s/^[#[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication ${mode}/" /etc/ssh/sshd_config
    else
        echo "PasswordAuthentication ${mode}" >> /etc/ssh/sshd_config
    fi

    if sshd -t; then
        systemctl restart ssh || systemctl restart sshd
        log INFO "PasswordAuthentication ${mode}"
    else
        die "Конфигурация sshd некорректна, изменения не применены"
    fi
}

toggle_ssh_password_auth() {
    local current
    current="$(ssh_password_status)"

    if [[ "$current" == "включено" ]]; then
        set_ssh_password_auth "no"
        log INFO "Вход по паролю отключён"
    else
        set_ssh_password_auth "yes"
        log INFO "Вход по паролю включён"
    fi
}

ssh_key_menu() {
    while true; do
        clear
        local current_status
        current_status="$(ssh_password_status)"
        echo "============================================"
        echo "          Установить ssh-ключ"
        echo "============================================"
        echo "1) Добавить ключ"
        echo "2) Включить/выключить ssh-вход по паролю (сейчас ${current_status})"
        echo "0) Назад"
        echo "============================================"

        read -r -p "Выбери подпункт: " subchoice
        echo

        case "$subchoice" in
            1) add_ssh_key_for_user; pause_screen ;;
            2) toggle_ssh_password_auth; pause_screen ;;
            0) break ;;
            *) log WARN "Неверный подпункт меню"; pause_screen ;;
        esac
    done
}

############################
# BBR
############################
bbr_is_enabled() {
    local qdisc=""
    local cc=""

    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"

    [[ "$qdisc" == "fq" && "$cc" == "bbr" ]]
}

bbr_status_text() {
    if bbr_is_enabled; then
        echo "включено"
    else
        echo "выключено"
    fi
}

set_sysctl_key() {
    local key="$1"
    local value="$2"

    if grep -Eq "^[#[:space:]]*${key}=" /etc/sysctl.conf; then
        sed -i "s|^[#[:space:]]*${key}=.*|${key}=${value}|" /etc/sysctl.conf
    elif grep -Eq "^[#[:space:]]*${key}[[:space:]]*=" /etc/sysctl.conf; then
        sed -i "s|^[#[:space:]]*${key}[[:space:]]*=.*|${key}=${value}|" /etc/sysctl.conf
    else
        echo "${key}=${value}" >> /etc/sysctl.conf
    fi
}

toggle_bbr() {
    if bbr_is_enabled; then
        set_sysctl_key "net.core.default_qdisc" "pfifo_fast"
        set_sysctl_key "net.ipv4.tcp_congestion_control" "cubic"
        sysctl -p
        log INFO "BBR отключён"
    else
        set_sysctl_key "net.core.default_qdisc" "fq"
        set_sysctl_key "net.ipv4.tcp_congestion_control" "bbr"
        sysctl -p
        log INFO "BBR включён"
    fi
}

############################
# Server tests
############################
run_server_test_ip_clean() {
    log STEP "Тест: чистота IP"
    bash <(curl -Ls IP.Check.Place | sed '/^\s*show_ad\s*$/d') -l en
}

run_server_test_ru_speed() {
    log STEP "Тест: скорость к российским провайдерам"
    wget -qO- bench.openode.xyz | bash
}

run_server_test_foreign_speed() {
    log STEP "Тест: скорость к зарубежным провайдерам"
    wget -qO- bench.sh | bash
}

run_server_test_ip_region() {
    log STEP "Тест: Geo test IP / IP Region"
    bash <(wget -qO- https://github.com/Davoyan/ipregion/raw/main/ipregion.sh)
}

run_server_test_yabs() {
    log STEP "Тест: Yabs"
    curl -sL yabs.sh | bash -s -- -4
}

run_server_test_cpu() {
    log STEP "Тест: CPU через sysbench"

    if ! command -v sysbench >/dev/null 2>&1; then
        log WARN "sysbench не найден, устанавливаю"
        apt-get update -y
        apt_install sysbench
    fi

    echo "Подсказка: можно менять --threads под число ядер CPU"
    sysbench cpu run --threads=1
}

server_tests_menu() {
    while true; do
        clear
        echo "============================================"
        echo "              Тесты сервера"
        echo "============================================"
        echo "1) Чистота IP"
        echo "2) Проверка скорости к российским провайдерам"
        echo "3) Проверка скорости к зарубежным провайдерам"
        echo "4) Гео тест IP (IP Region), проверка региона YouTube и т.д."
        echo "5) Yabs"
        echo "6) Тест на процессор"
        echo "0) Назад"
        echo "============================================"

        read -r -p "Выбери подпункт: " subchoice
        echo

        case "$subchoice" in
            1) run_server_test_ip_clean; pause_screen ;;
            2) run_server_test_ru_speed; pause_screen ;;
            3) run_server_test_foreign_speed; pause_screen ;;
            4) run_server_test_ip_region; pause_screen ;;
            5) run_server_test_yabs; pause_screen ;;
            6) run_server_test_cpu; pause_screen ;;
            0) break ;;
            *) log WARN "Неверный подпункт меню"; pause_screen ;;
        esac
    done
}

############################
# Status
############################
show_status() {
    echo
    echo "========== СТАТУС =========="

    if command -v traffic-guard >/dev/null 2>&1; then
        echo "Traffic Guard: установлен"
    else
        echo "Traffic Guard: не установлен"
    fi

    if command -v rknpidor >/dev/null 2>&1; then
        echo "Traffic-Guard Pro Manager: установлен"
    else
        echo "Traffic-Guard Pro Manager: не найден"
    fi

    if systemctl list-unit-files | grep -q '^fail2ban\.service'; then
        if systemctl is-active --quiet fail2ban; then
            echo "Fail2Ban: активен"
        else
            echo "Fail2Ban: установлен, но не активен"
        fi
    else
        echo "Fail2Ban: не установлен"
    fi

    if [[ -f "$FAIL2BAN_CUSTOM_FILE" ]]; then
        echo "Fail2Ban destemail: $(fail2ban_get_value "destemail" || true)"
        echo "Fail2Ban ignoreip: $(fail2ban_get_value "ignoreip" || true)"
    fi

    if [[ -f "$GEOBAN_LIST_FILE" ]]; then
        echo "GeoBan: список найден ($GEOBAN_LIST_FILE)"
    else
        echo "GeoBan: не настроен"
    fi

    echo "Текущий SSH порт: $(current_ssh_port)"
    echo "SSH password auth: $(ssh_password_status)"
    echo "BBR: $(bbr_status_text)"
    echo "Shortcut: ${SHORTCUT_NAME} -> ${SHORTCUT_PATH}"
    echo "Лог: $LOG_FILE"
    echo "============================"
}

############################
# Menu
############################
print_menu() {
    clear
    echo "============================================"
    echo "        Server Protection Setup"
    echo "============================================"
    echo "1) Установить базовые пакеты"
    echo "2) Обновить пакеты"
    echo "3) Установить Traffic Guard"
    echo "4) Установить Traffic Guard Pro Manager"
    echo "5) Fail2Ban"
    echo "6) Установить GeoBan"
    echo "7) Установить remnawave-reverse-proxy"
    echo "8) Установить remnawave backup & restore"
    echo "9) Управление портами"
    echo "10) Просмотр статистики"
    echo "11) Установить MTProtoMax"
    echo "12) Установить YandexCloudManager скрипт"
    echo "13) Полезные команды"
    echo "14) Установить ssh-ключ"
    echo "15) Включить/Выключить BBR (сейчас $(bbr_status_text))"
    echo "16) Тесты сервера"
    echo "17) Установить всё сразу(кроме утилит remnawave)"
    echo "18) Показать статус"
    echo "0) Выход"
    echo "============================================"
    echo "Команда для быстрого доступа: security-manager"
}

menu_loop() {
    while true; do
        print_menu
        read -r -p "Выбери пункт меню: " choice
        echo

        case "$choice" in
            1) install_base_packages; pause_screen ;;
            2) system_update; pause_screen ;;
            3) install_traffic_guard; pause_screen ;;
            4) install_pro_manager; pause_screen ;;
            5) fail2ban_menu ;;
            6) install_geoban; pause_screen ;;
            7) install_remnawave_reverse_proxy; pause_screen ;;
            8) install_remnawave_backup_restore; pause_screen ;;
            9) ports_menu ;;
            10) statistics_menu ;;
            11) install_mtprotomax; pause_screen ;;
            12) install_yandex_cloud_manager; pause_screen ;;
            13) show_useful_commands; pause_screen ;;
            14) ssh_key_menu ;;
            15) toggle_bbr; pause_screen ;;
            16) server_tests_menu ;;
            17) install_all; pause_screen ;;
            18) show_status; pause_screen ;;
            0)
                log INFO "Выход"
                exit 0
                ;;
            *)
                log WARN "Неверный пункт меню"
                pause_screen
                ;;
        esac
    done
}

main() {
    require_root

    if [[ "${1:-}" == "--install-shortcut-only" ]]; then
        check_os
        install_self_to_system
        exit 0
    fi

    prepare_system
    menu_loop
}

main "$@"
