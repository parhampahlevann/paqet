#!/bin/bash
#=================================================
# Paqet Tunnel Manager
# Version: 7.1 (Fixed & Optimized)
# Fixes: 38 bugs, Simplified menu, Optimized defaults
#=================================================

set -o pipefail

# ═══════════════════════════════════════════════
# CONFIGURATION DEFAULTS
# ═══════════════════════════════════════════════
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly WHITE='\033[1;37m'
readonly ORANGE='\033[0;33m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

readonly SCRIPT_VERSION="7.1"
readonly MANAGER_NAME="paqet-manager"
readonly MANAGER_PATH="/usr/local/bin/$MANAGER_NAME"
readonly CONFIG_DIR="/etc/paqet"
readonly SERVICE_DIR="/etc/systemd/system"
readonly BIN_DIR="/usr/local/bin"
readonly INSTALL_DIR="/opt/paqet"
readonly BACKUP_DIR="/root/paqet-backups"
readonly GITHUB_REPO="hanselime/paqet"
readonly MANAGER_GITHUB_REPO="behzadea12/Paqet-Tunnel-Manager"
readonly SYSCTL_FILE="/etc/sysctl.d/99-paqet-tunnel.conf"
readonly LIMITS_FILE="/etc/security/limits.d/99-paqet.conf"
readonly BACKUP_SYSCTL="${BACKUP_DIR}/sysctl-backup-$(date +%Y%m%d-%H%M%S)"
readonly BACKUP_LIMITS="${BACKUP_DIR}/limits-backup-$(date +%Y%m%d-%H%M%S)"

# ═══════════════════════════════════════════════
# OPTIMIZED DEFAULTS (v7.1)
# ═══════════════════════════════════════════════
readonly DEFAULT_LISTEN_PORT="8888"
readonly DEFAULT_KCP_MODE="fast"
readonly DEFAULT_ENCRYPTION="aes-128-gcm"
readonly DEFAULT_CONNECTIONS="2"
readonly DEFAULT_MTU="1300"
readonly DEFAULT_PCAP_SOCKBUF_SERVER="4194304"
readonly DEFAULT_PCAP_SOCKBUF_CLIENT="2097152"
readonly DEFAULT_TRANSPORT_TCPBUF="4096"
readonly DEFAULT_TRANSPORT_UDPBUF="2048"
readonly DEFAULT_AUTO_RESTART_INTERVAL="6hour"
readonly DEFAULT_V2RAY_PORTS="9090"
readonly DEFAULT_SOCKS5_PORT="1080"

declare -A KCP_MODES=(
    ["0"]="normal:Normal speed / Normal latency / Low CPU"
    ["1"]="fast:Balanced speed / Low latency / Normal CPU (Recommended)"
    ["2"]="fast2:High speed / Lower latency / Medium CPU"
    ["3"]="fast3:Max speed / Very low latency / HIGH CPU ⚠️"
    ["4"]="manual:Advanced settings (expert)"
)

declare -A ENCRYPTION_OPTIONS=(
    ["1"]="aes-128-gcm:Very high security / Very fast / Recommended"
    ["2"]="aes:High security / Medium speed / General use"
    ["3"]="aes-128:High security / Fast / Low CPU"
    ["4"]="aes-192:Very high security / Medium speed"
    ["5"]="aes-256:Maximum security / Slower / Higher CPU"
    ["6"]="none:No encryption / Max speed / INSECURE ⚠️"
    ["7"]="null:No encryption / Max speed / INSECURE ⚠️"
)

declare -A RESTART_INTERVALS=(
    ["1min"]="*/1 * * * *"
    ["5min"]="*/5 * * * *"
    ["15min"]="*/15 * * * *"
    ["30min"]="*/30 * * * *"
    ["1hour"]="0 */1 * * *"
    ["3hour"]="0 */3 * * *"
    ["6hour"]="0 */6 * * *"
    ["12hour"]="0 */12 * * *"
    ["1day"]="0 0 * * *"
)

readonly IP_SERVICES=("ifconfig.me" "icanhazip.com" "api.ipify.org" "checkip.amazonaws.com")
readonly TEST_DOMAINS=("google.com" "github.com" "cloudflare.com" "wikipedia.org")
readonly DNS_SERVERS=("8.8.8.8" "1.1.1.1" "208.67.222.222" "system")
readonly MTU_TESTS=("1500" "1470" "1400" "1350" "1300" "1280" "1200" "1100")
readonly COMMON_PORTS=("443" "80" "22" "53")

declare -A MANAGER_VERSIONS=(
    ["latest"]="https://raw.githubusercontent.com/behzadea12/Paqet-Tunnel-Manager/main/paqet-manager.sh"
    ["6.0"]="https://raw.githubusercontent.com/behzadea12/Paqet-Tunnel-Manager/main/paqet-manager6-0.sh"
    ["5.1"]="https://raw.githubusercontent.com/behzadea12/Paqet-Tunnel-Manager/main/paqet-manager5-1.sh"
)

# Telegram Bot
readonly BOT_CONFIG_DIR="/etc/telegram-paqet-bot"
readonly BOT_CONFIG_FILE="$BOT_CONFIG_DIR/config.conf"
readonly BOT_LOG_FILE="/var/log/telegram-paqet-bot.log"
readonly BOT_SERVICE="telegram-paqet-bot"
readonly BOT_SCRIPT="/usr/local/bin/telegram-paqet-bot"

# ================================================
# UTILITY FUNCTIONS
# ================================================
print_step() { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${CYAN}[i]${NC} $1"; }

pause() {
    local msg="${1:-Press Enter to continue...}"
    echo ""
    read -p "$msg" </dev/tty
}

show_banner() {
    clear
    echo -e "${MAGENTA}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║     ██████╗  █████╗  ██████╗ ███████╗████████╗               ║"
    echo "║     ██╔══██╗██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝               ║"
    echo "║     ██████╔╝███████║██║   ██║█████╗     ██║                  ║"
    echo "║     ██╔═══╝ ██╔══██║██║▄▄ ██║██╔══╝     ██║                  ║"
    echo "║     ██║     ██║  ██║╚██████╔╝███████╗   ██║                  ║"
    echo "║     ╚═╝     ╚═╝  ╚═╝ ╚══▀▀═╝ ╚══════╝   ╚═╝                  ║"
    echo "║          Raw Packet Tunnel - Manager v${SCRIPT_VERSION}              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    else
        echo "$(uname -s | tr '[:upper:]' '[:lower:]')"
    fi
}

detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64|x86-64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armhf) echo "armv7" ;;
        i386|i686) echo "386" ;;
        *) print_error "Unsupported architecture: $arch"; return 1 ;;
    esac
}

get_public_ip() {
    for service in "${IP_SERVICES[@]}"; do
        local ip=$(curl -4 -s --max-time 3 "$service" 2>/dev/null)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"; return 0
        fi
    done
    local ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"; return 0
    fi
    echo "Not Detected"
}

get_network_info() {
    NETWORK_INTERFACE=""
    LOCAL_IP=""
    GATEWAY_IP=""
    GATEWAY_MAC=""
    if command -v ip &>/dev/null; then
        NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
        LOCAL_IP=$(ip -4 addr show "$NETWORK_INTERFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        GATEWAY_IP=$(ip route | grep default | awk '{print $3}' | head -1)
        if [ -n "$GATEWAY_IP" ]; then
            ping -c 1 -W 1 "$GATEWAY_IP" >/dev/null 2>&1 || true
            GATEWAY_MAC=$(ip neigh show "$GATEWAY_IP" 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1)
            if [ -z "$GATEWAY_MAC" ] && command -v arp &>/dev/null; then
                GATEWAY_MAC=$(arp -n "$GATEWAY_IP" 2>/dev/null | awk "/^$GATEWAY_IP/ {print \$3}" | head -1)
            fi
        fi
    fi
    NETWORK_INTERFACE="${NETWORK_INTERFACE:-eth0}"
}

validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            [[ $octet -lt 0 || $octet -gt 255 ]] && return 1
        done
        return 0
    fi
    return 1
}

validate_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

clean_port_list() {
    local ports="$1"
    ports=$(echo "$ports" | tr -d ' ')
    local cleaned=""
    IFS=',' read -ra port_array <<< "$ports"
    for port in "${port_array[@]}"; do
        if validate_port "$port"; then
            cleaned="${cleaned:+$cleaned,}$port"
        else
            print_warning "Invalid port '$port' removed"
        fi
    done
    echo "$cleaned"
}

clean_config_name() {
    local name="$1"
    name=$(echo "$name" | tr -cd '[:alnum:]-_')
    echo "${name:-default}"
}

check_port_conflict() {
    local port="$1"
    if ss -tuln 2>/dev/null | grep -q ":${port} "; then
        print_warning "Port $port is already in use!"
        local pid=$(lsof -t -i:"$port" 2>/dev/null | head -1)
        if [ -n "$pid" ]; then
            local pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
            print_info "Process: $pname (PID: $pid)"
            read -p "Kill this process? (y/N): " kill_choice
            if [[ "$kill_choice" =~ ^[Yy]$ ]]; then
                kill -9 "$pid" 2>/dev/null || true
                sleep 1
                print_success "Process killed"
            else
                return 1
            fi
        else
            return 1
        fi
    fi
    return 0
}

normalize_host_for_compare() {
    local host="$1"
    host=$(echo "$host" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    case "$host" in
        ""|"localhost"|"0.0.0.0"|"::") echo "127.0.0.1" ;;
        *) echo "$host" ;;
    esac
}

normalize_port() {
    local input="$1"
    input=$(echo "$input" | tr -cd '0-9')
    [[ "$input" =~ ^[1-9][0-9]{0,4}$ && "$input" -le 65535 ]] && echo "$input" || echo ""
}

# FIXED: Better traffic loop detection
validate_forward_rules() {
    [[ "$traffic_type" != "1" ]] && return 0
    local srv_port=$(normalize_port "$server_port")
    [ -z "$srv_port" ] && return 0

    echo -e "${CYAN}Checking for traffic loops...${NC}"
    local dangerous=0
    IFS=',' read -ra PORTS <<< "$forward_ports"
    for p in "${PORTS[@]}"; do
        p=$(echo "$p" | tr -d '[:space:]')
        validate_port "$p" || continue
        if [ "$p" = "$srv_port" ]; then
            print_error "⚠️ TRAFFIC LOOP: Forward port $p = Tunnel port $srv_port"
            ((dangerous++))
        fi
        if ss -tuln 2>/dev/null | grep -q ":${p} "; then
            print_warning "⚠️ Port $p already in use"
        fi
    done

    if (( dangerous > 0 )); then
        print_error "❌ Configuration aborted due to loop detection."
        pause
        return 1
    fi
    print_success "No traffic loops detected ✓"
    return 0
}

generate_secret_key() {
    if command -v openssl &>/dev/null; then
        openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32
    else
        tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 32
    fi
}

get_latest_paqet_version() {
    local version=$(curl -s --max-time 10 "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
    [ -n "$version" ] && echo "$version" || echo "v1.0.0-alpha.16"
}

# FIXED: Float comparison using awk (always available)
compare_floats() {
    local value=$1 threshold=$2 comparison=$3
    case $comparison in
        "lt") awk "BEGIN{exit !($value < $threshold)}" ;;
        "le") awk "BEGIN{exit !($value <= $threshold)}" ;;
        "gt") awk "BEGIN{exit !($value > $threshold)}" ;;
        "ge") awk "BEGIN{exit !($value >= $threshold)}" ;;
        *) return 1 ;;
    esac
}

# FIXED: Helper to get all paqet services
get_all_paqet_services() {
    systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | \
        grep -E '^paqet-.*\.service' | awk '{print $1}' || true
}

# ================================================
# CONFIGURATION FUNCTIONS
# ================================================
configure_iptables() {
    local port="$1"
    local protocol="$2"
    command -v iptables &>/dev/null || return 0

    local protocols=()
    [ "$protocol" = "both" ] && protocols=("tcp" "udp") || protocols=("$protocol")

    for proto in "${protocols[@]}"; do
        iptables -t raw -D PREROUTING -p "$proto" --dport "$port" -j NOTRACK 2>/dev/null || true
        iptables -t raw -D OUTPUT -p "$proto" --sport "$port" -j NOTRACK 2>/dev/null || true
        iptables -t raw -A PREROUTING -p "$proto" --dport "$port" -j NOTRACK
        iptables -t raw -A OUTPUT -p "$proto" --sport "$port" -j NOTRACK
        if [ "$proto" = "tcp" ]; then
            iptables -t mangle -D OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP 2>/dev/null || true
            iptables -t mangle -A OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP
        fi
    done
    save_iptables
}

# FIXED: Optimized systemd service
create_systemd_service() {
    local config_name="$1"
    local service_name="paqet-${config_name}"
    cat > "$SERVICE_DIR/${service_name}.service" << EOF
[Unit]
Description=Paqet Tunnel (${config_name})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
ExecStart=$BIN_DIR/paqet run -c $CONFIG_DIR/${config_name}.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=16384
Nice=-5
Environment="GOMAXPROCS=1"
MemoryMax=512M
CPUQuota=80%

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    print_success "Service created: ${service_name}"
}

# ================================================
# CRONJOB MANAGEMENT
# ================================================
add_auto_restart_cronjob() {
    local service_name="$1"
    local cron_interval="$2"
    local cron_command="systemctl restart ${service_name}"
    local cron_line="${RESTART_INTERVALS[$cron_interval]} $cron_command"
    [ -z "$cron_line" ] && { print_error "Invalid cron interval"; return 1; }
    crontab -l 2>/dev/null | grep -v "$cron_command" | crontab - 2>/dev/null
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
    print_success "Cronjob added: $cron_interval restart"
}

remove_cronjob() {
    local service_name="$1"
    local cron_command="systemctl restart ${service_name}"
    if crontab -l 2>/dev/null | grep -q "$cron_command"; then
        crontab -l 2>/dev/null | grep -v "$cron_command" | crontab -
        return 0
    fi
    return 1
}

view_cronjob() {
    local service_name="$1"
    local cron_command="systemctl restart ${service_name}"
    if crontab -l 2>/dev/null | grep -q "$cron_command"; then
        crontab -l 2>/dev/null | grep "$cron_command"
    else
        print_info "No cronjob found"
    fi
}

manage_cronjob() {
    local service_name="$1"
    local display_name="$2"
    while true; do
        clear; show_banner
        echo -e "${YELLOW}Manage Cronjob: $display_name${NC}\n"
        echo -e "${CYAN}Current:${NC}"
        view_cronjob "$service_name"
        echo -e "\n${CYAN}Options:${NC}"
        local i=1
        local intervals=("1min" "5min" "15min" "30min" "1hour" "3hour" "6hour" "12hour" "1day")
        for interval in "${intervals[@]}"; do
            echo " $((i++)). $interval"
        done
        echo " $i. Remove cronjob"
        echo " 0. Back"
        read -p "Choose [0-$i]: " cron_choice
        [ "$cron_choice" = "0" ] && return
        if [ "$cron_choice" -eq "$i" ]; then
            remove_cronjob "$service_name"
            pause
        elif [ "$cron_choice" -ge 1 ] && [ "$cron_choice" -lt "$i" ]; then
            add_auto_restart_cronjob "$service_name" "${intervals[$((cron_choice-1))]}"
            pause
        fi
    done
}

# ================================================
# SERVICE MANAGEMENT
# ================================================
get_service_details() {
    local service_name="$1"
    local config_name="${service_name#paqet-}"
    local config_file="$CONFIG_DIR/$config_name.yaml"
    local type="unknown" mode="fast" mtu="-" conn="-" cron="No"
    if [ -f "$config_file" ]; then
        type=$(grep "^role:" "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "unknown")
        local mode_line=$(grep "mode:" "$config_file" 2>/dev/null | head -1)
        [ -n "$mode_line" ] && mode=$(echo "$mode_line" | awk '{print $2}' | tr -d '"')
        if grep -q "mtu:" "$config_file" 2>/dev/null; then
            mtu=$(grep "mtu:" "$config_file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
        fi
        if grep -q "conn:" "$config_file" 2>/dev/null; then
            conn=$(grep "conn:" "$config_file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
        fi
    fi
    crontab -l 2>/dev/null | grep -q "systemctl restart $service_name" && cron="Yes"
    echo "$type $mode $mtu $conn $cron"
}

manage_single_service() {
    local selected_service="$1"
    local display_name="$2"
    while true; do
        clear; show_banner
        echo -e "${GREEN}Managing: $display_name${NC}\n"
        local status=$(systemctl is-active "$selected_service" 2>/dev/null || echo "unknown")
        case "$status" in
            active) echo -e "Status: ${GREEN}🟢 Active${NC}" ;;
            failed) echo -e "Status: ${RED}🔴 Failed${NC}" ;;
            inactive) echo -e "Status: ${YELLOW}🟡 Inactive${NC}" ;;
            *) echo -e "Status: ${WHITE}⚪ Unknown${NC}" ;;
        esac
        local details=$(get_service_details "${selected_service%.service}")
        echo -e "Type: $(echo "$details" | awk '{print $1}') | Mode: $(echo "$details" | awk '{print $2}') | MTU: $(echo "$details" | awk '{print $3}') | Conn: $(echo "$details" | awk '{print $4}')"
        echo -e "\nActions:"
        echo " 1. Start  2. Stop  3. Restart  4. Status  5. Logs"
        echo " 6. Edit Config  7. View Config  8. Cronjob  9. Delete  0. Back"
        read -p "Choose [0-9]: " action
        case "$action" in
            0) return ;;
            1) systemctl start "$selected_service" 2>/dev/null; print_success "Started"; sleep 1 ;;
            2) systemctl stop "$selected_service" 2>/dev/null; print_success "Stopped"; sleep 1 ;;
            3) systemctl restart "$selected_service" 2>/dev/null; print_success "Restarted"; sleep 1 ;;
            4) systemctl status "$selected_service" --no-pager -l; pause ;;
            5) journalctl -u "$selected_service" -n 25 --no-pager; pause ;;
            6) local cfg="$CONFIG_DIR/$display_name.yaml"
               [ -f "$cfg" ] && { nano "$cfg" 2>/dev/null || vi "$cfg"; read -p "Restart? (y/N): " r; [[ "$r" =~ ^[Yy]$ ]] && systemctl restart "$selected_service"; } ;;
            7) local cfg="$CONFIG_DIR/$display_name.yaml"; [ -f "$cfg" ] && cat "$cfg"; pause ;;
            8) manage_cronjob "${selected_service%.service}" "$display_name" ;;
            9) read -p "Delete? (y/N): " c
               if [[ "$c" =~ ^[Yy]$ ]]; then
                   remove_cronjob "${selected_service%.service}" 2>/dev/null
                   systemctl stop "$selected_service" 2>/dev/null
                   systemctl disable "$selected_service" 2>/dev/null
                   rm -f "$SERVICE_DIR/$selected_service" "$CONFIG_DIR/$display_name.yaml"
                   systemctl daemon-reload
                   print_success "Deleted"; return
               fi ;;
        esac
    done
}

manage_services() {
    while true; do
        clear; show_banner
        echo -e "${GREEN}Paqet Services${NC}\n"
        local services=()
        mapfile -t services < <(get_all_paqet_services)
        if [[ ${#services[@]} -eq 0 ]]; then
            print_warning "No services found"; pause; return
        fi
        local i=1
        for svc in "${services[@]}"; do
            local name="${svc#paqet-}"; name="${name%.service}"
            local status=$(systemctl is-active "$svc" 2>/dev/null || echo "?")
            printf " %2d. %-20s [%s]\n" "$i" "$name" "$status"
            ((i++))
        done
        echo "  0. Back"
        read -p "Select [0-${#services[@]}]: " choice
        [ "$choice" = "0" ] && return
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#services[@]} ]; then
            local svc="${services[$((choice-1))]}"
            local name="${svc#paqet-}"; name="${name%.service}"
            manage_single_service "$svc" "$name"
        fi
    done
}

# ================================================
# KCP MANUAL SETTINGS
# ================================================
get_manual_kcp_settings() {
    local nodelay="" interval="" resend="" nocongestion="" rcvwnd="" sndwnd="" acknodelay=""
    
    read -p "nodelay [0-2] (default 1): " input; nodelay="${input:-1}"
    read -p "interval ms (default 20): " input; interval="${input:-20}"
    read -p "resend (default 2): " input; resend="${input:-2}"
    read -p "nocongestion [0/1] (default 1): " input; nocongestion="${input:-1}"
    read -p "rcvwnd (default 1024): " input; rcvwnd="${input:-1024}"
    read -p "sndwnd (default 1024): " input; sndwnd="${input:-1024}"
    read -p "acknodelay [true/false] (default true): " input; acknodelay="${input:-true}"

    echo "mode: \"manual\""
    [ -n "$nodelay" ] && echo "nodelay: $nodelay"
    [ -n "$interval" ] && echo "interval: $interval"
    [ -n "$resend" ] && echo "resend: $resend"
    [ -n "$nocongestion" ] && echo "nocongestion: $nocongestion"
    [ -n "$rcvwnd" ] && echo "rcvwnd: $rcvwnd"
    [ -n "$sndwnd" ] && echo "sndwnd: $sndwnd"
    [ -n "$acknodelay" ] && echo "acknodelay: $acknodelay"
}

# ================================================
# QUICK SETUP (SIMPLIFIED)
# ================================================
quick_setup_server() {
    clear; show_banner
    echo -e "${GREEN}Quick Server Setup (3 steps)${NC}\n"
    get_network_info
    local public_ip=$(get_public_ip)
    echo -e "Network: $NETWORK_INTERFACE | IP: $LOCAL_IP | Public: $public_ip\n"

    echo -en "[1/3] Service Name [server]: "
    read -r config_name
    config_name=$(clean_config_name "${config_name:-server}")

    echo -en "[2/3] Listen Port [$DEFAULT_LISTEN_PORT]: "
    read -r port
    port="${port:-$DEFAULT_LISTEN_PORT}"
    validate_port "$port" || { print_error "Invalid port"; return 1; }
    check_port_conflict "$port" || return 1

    local secret_key=$(generate_secret_key)
    echo -e "[3/3] Secret Key: ${GREEN}$secret_key${NC} (auto-generated)"
    echo -e "\nDefaults: KCP=fast, MTU=$DEFAULT_MTU, Conn=$DEFAULT_CONNECTIONS, AES-128-GCM"
    read -p "Apply? (Y/n): " confirm
    [[ "${confirm,,}" == "n" ]] && return 1

    [ ! -f "$BIN_DIR/paqet" ] && { install_paqet || return 1; }
    configure_iptables "$port" "tcp"
    mkdir -p "$CONFIG_DIR"

    cat > "$CONFIG_DIR/${config_name}.yaml" << EOF
role: "server"
log:
  level: "info"
listen:
  addr: ":$port"
network:
  interface: "$NETWORK_INTERFACE"
  ipv4:
    addr: "$LOCAL_IP:$port"
    router_mac: "$GATEWAY_MAC"
  tcp:
    local_flag: ["PA"]
transport:
  protocol: "kcp"
  conn: $DEFAULT_CONNECTIONS
  kcp:
    key: "$secret_key"
    mode: "$DEFAULT_KCP_MODE"
    block: "$DEFAULT_ENCRYPTION"
    mtu: $DEFAULT_MTU
EOF

    create_systemd_service "$config_name"
    local svc="paqet-${config_name}"
    systemctl enable "$svc" --now >/dev/null 2>&1

    if systemctl is-active --quiet "$svc"; then
        add_auto_restart_cronjob "$svc" "$DEFAULT_AUTO_RESTART_INTERVAL" >/dev/null 2>&1
        echo -e "\n${GREEN}✅ Server Ready!${NC}"
        echo -e "  IP: $public_ip | Port: $port"
        echo -e "  Secret: ${GREEN}$secret_key${NC}"
        pause
    else
        print_error "Failed to start"
        systemctl status "$svc" --no-pager -l
        pause
    fi
}

quick_setup_client() {
    clear; show_banner
    echo -e "${GREEN}Quick Client Setup (4 steps)${NC}\n"
    get_network_info

    echo -en "[1/4] Service Name [client]: "
    read -r config_name
    config_name=$(clean_config_name "${config_name:-client}")

    echo -en "[2/4] Server IP (Kharej): "
    read -r server_ip
    validate_ip "$server_ip" || { print_error "Invalid IP"; return 1; }

    echo -en "[3/4] Server Port [$DEFAULT_LISTEN_PORT]: "
    read -r server_port
    server_port="${server_port:-$DEFAULT_LISTEN_PORT}"

    echo -en "[4/4] Secret Key: "
    read -r secret_key
    [ -z "$secret_key" ] && { print_error "Required"; return 1; }

    echo -en "\nForward Ports [$DEFAULT_V2RAY_PORTS]: "
    read -r forward_ports
    forward_ports=$(clean_port_list "${forward_ports:-$DEFAULT_V2RAY_PORTS}")
    [ -z "$forward_ports" ] && { print_error "No valid ports"; return 1; }

    traffic_type="1"
    validate_forward_rules || return 1

    read -p "Apply? (Y/n): " confirm
    [[ "${confirm,,}" == "n" ]] && return 1

    [ ! -f "$BIN_DIR/paqet" ] && { install_paqet || return 1; }
    mkdir -p "$CONFIG_DIR"

    local forward_entries=""
    IFS=',' read -ra PORTS <<< "$forward_ports"
    for p in "${PORTS[@]}"; do
        p=$(echo "$p" | tr -d '[:space:]')
        forward_entries+="  - listen: \"0.0.0.0:$p\"\n    target: \"127.0.0.1:$p\"\n    protocol: \"tcp\"\n"
    done

    cat > "$CONFIG_DIR/${config_name}.yaml" << EOF
role: "client"
log:
  level: "info"
forward:
$(echo -e "$forward_entries")network:
  interface: "$NETWORK_INTERFACE"
  ipv4:
    addr: "$LOCAL_IP:0"
    router_mac: "$GATEWAY_MAC"
  tcp:
    local_flag: ["PA"]
    remote_flag: ["PA"]
server:
  addr: "$server_ip:$server_port"
transport:
  protocol: "kcp"
  conn: $DEFAULT_CONNECTIONS
  kcp:
    key: "$secret_key"
    mode: "$DEFAULT_KCP_MODE"
    block: "$DEFAULT_ENCRYPTION"
    mtu: $DEFAULT_MTU
EOF

    create_systemd_service "$config_name"
    local svc="paqet-${config_name}"
    systemctl enable "$svc" --now >/dev/null 2>&1

    if systemctl is-active --quiet "$svc"; then
        add_auto_restart_cronjob "$svc" "$DEFAULT_AUTO_RESTART_INTERVAL" >/dev/null 2>&1
        echo -e "\n${GREEN}✅ Client Ready!${NC}"
        echo -e "  Server: $server_ip:$server_port | Forward: $forward_ports"
        pause
    else
        print_error "Failed to start"
        systemctl status "$svc" --no-pager -l
        pause
    fi
}

# ================================================
# ADVANCED CONFIGURATION
# ================================================
configure_server() {
    while true; do
        clear; show_banner
        echo -e "${GREEN}Configure Server (Advanced)${NC}\n"
        get_network_info
        local public_ip=$(get_public_ip)

        echo -en "[1/10] Service Name: "
        read -r config_name
        config_name=$(clean_config_name "${config_name:-server}")
        [ -f "$CONFIG_DIR/${config_name}.yaml" ] && { read -p "Overwrite? (y/N): " ow; [[ ! "$ow" =~ ^[Yy]$ ]] && continue; }

        echo -en "[2/10] Port [$DEFAULT_LISTEN_PORT]: "
        read -r port; port="${port:-$DEFAULT_LISTEN_PORT}"
        validate_port "$port" || { print_error "Invalid"; continue; }
        check_port_conflict "$port" || continue

        local secret_key=$(generate_secret_key)
        echo -e "[3/10] Secret: ${GREEN}$secret_key${NC} (Enter=use, or type custom)"
        read -r custom_key
        [ -n "$custom_key" ] && secret_key="$custom_key"

        echo -e "\n[4/10] KCP Mode: [0]normal [1]fast [2]fast2 [3]fast3 [4]manual"
        read -p "Choose [0-4] (default 1): " mode_choice; mode_choice="${mode_choice:-1}"
        local mode_name kcp_fragment=""
        case $mode_choice in
            0) mode_name="normal" ;; 1) mode_name="fast" ;; 2) mode_name="fast2" ;;
            3) mode_name="fast3" ;; 4) mode_name="manual"; kcp_fragment=$(get_manual_kcp_settings) ;;
            *) mode_name="fast" ;;
        esac

        echo -en "[5/10] Connections [$DEFAULT_CONNECTIONS]: "
        read -r conn_input; local conn="${conn_input:-$DEFAULT_CONNECTIONS}"

        echo -en "[6/10] MTU [$DEFAULT_MTU]: "
        read -r mtu_input; local mtu="${mtu_input:-$DEFAULT_MTU}"

        echo -e "\n[7/10] Encryption: [1]aes-128-gcm [2]aes [3]aes-128 [4]aes-192 [5]aes-256 [6]none"
        read -p "Choose [1-6] (default 1): " enc_choice; enc_choice="${enc_choice:-1}"
        local block; IFS=':' read -r block _ <<< "${ENCRYPTION_OPTIONS[$enc_choice]}"; block="${block:-aes-128-gcm}"

        echo -en "[8/10] pcap sockbuf [$DEFAULT_PCAP_SOCKBUF_SERVER]: "
        read -r pcap_input; local pcap_sockbuf="${pcap_input:-$DEFAULT_PCAP_SOCKBUF_SERVER}"

        echo -en "[9/10] tcpbuf [$DEFAULT_TRANSPORT_TCPBUF]: "
        read -r tcpbuf_input; local transport_tcpbuf="${tcpbuf_input:-$DEFAULT_TRANSPORT_TCPBUF}"

        echo -en "[10/10] udpbuf [$DEFAULT_TRANSPORT_UDPBUF]: "
        read -r udpbuf_input; local transport_udpbuf="${udpbuf_input:-$DEFAULT_TRANSPORT_UDPBUF}"

        [ ! -f "$BIN_DIR/paqet" ] && { install_paqet || continue; }
        configure_iptables "$port" "tcp"
        mkdir -p "$CONFIG_DIR"

        {
            echo "role: \"server\""
            echo "log:"; echo "  level: \"info\""
            echo "listen:"; echo "  addr: \":$port\""
            echo "network:"
            echo "  interface: \"$NETWORK_INTERFACE\""
            echo "  ipv4:"; echo "    addr: \"$LOCAL_IP:$port\""
            echo "    router_mac: \"$GATEWAY_MAC\""
            echo "  tcp:"; echo "    local_flag: [\"PA\"]"
            [[ -n "$pcap_sockbuf" ]] && { echo "  pcap:"; echo "    sockbuf: $pcap_sockbuf"; }
            echo "transport:"; echo "  protocol: \"kcp\""
            [[ -n "$conn" ]] && echo "  conn: $conn"
            [[ -n "$transport_tcpbuf" ]] && echo "  tcpbuf: $transport_tcpbuf"
            [[ -n "$transport_udpbuf" ]] && echo "  udpbuf: $transport_udpbuf"
            echo "  kcp:"; echo "    key: \"$secret_key\""
            if [ "$mode_name" = "manual" ] && [ -n "$kcp_fragment" ]; then
                echo "    mode: \"manual\""; echo "    block: \"$block\""
                [[ -n "$mtu" ]] && echo "    mtu: $mtu"
                while IFS= read -r line; do
                    [[ -n "$line" ]] && ! echo "$line" | grep -q "mode:" && echo "    $line"
                done <<< "$kcp_fragment"
            else
                echo "    mode: \"$mode_name\""; echo "    block: \"$block\""
                [[ -n "$mtu" ]] && echo "    mtu: $mtu"
            fi
        } > "$CONFIG_DIR/${config_name}.yaml"

        create_systemd_service "$config_name"
        local svc="paqet-${config_name}"
        systemctl enable "$svc" --now >/dev/null 2>&1

        if systemctl is-active --quiet "$svc"; then
            add_auto_restart_cronjob "$svc" "$DEFAULT_AUTO_RESTART_INTERVAL" >/dev/null 2>&1
            echo -e "\n${GREEN}✅ Server Ready!${NC} IP: $public_ip | Port: $port | Secret: $secret_key"
        else
            print_error "Failed"; systemctl status "$svc" --no-pager -l
        fi
        pause; return 0
    done
}

configure_client() {
    while true; do
        clear; show_banner
        echo -e "${GREEN}Configure Client (Advanced)${NC}\n"
        get_network_info

        echo -en "[1/13] Service Name: "
        read -r config_name
        config_name=$(clean_config_name "${config_name:-client}")
        [ -f "$CONFIG_DIR/${config_name}.yaml" ] && { read -p "Overwrite? (y/N): " ow; [[ ! "$ow" =~ ^[Yy]$ ]] && continue; }

        echo -en "[2/13] Server IP: "
        read -r server_ip
        validate_ip "$server_ip" || { print_error "Invalid"; continue; }

        echo -en "[3/13] Server Port [$DEFAULT_LISTEN_PORT]: "
        read -r server_port; server_port="${server_port:-$DEFAULT_LISTEN_PORT}"

        echo -en "[4/13] Secret Key: "
        read -r secret_key
        [ -z "$secret_key" ] && { print_error "Required"; continue; }

        echo -e "\n[5/13] KCP Mode: [0]normal [1]fast [2]fast2 [3]fast3 [4]manual"
        read -p "Choose (default 1): " mode_choice; mode_choice="${mode_choice:-1}"
        local mode_name kcp_fragment=""
        case $mode_choice in
            0) mode_name="normal" ;; 1) mode_name="fast" ;; 2) mode_name="fast2" ;;
            3) mode_name="fast3" ;; 4) mode_name="manual"; kcp_fragment=$(get_manual_kcp_settings) ;;
            *) mode_name="fast" ;;
        esac

        echo -en "[6/13] Connections [$DEFAULT_CONNECTIONS]: "
        read -r conn_input; local conn="${conn_input:-$DEFAULT_CONNECTIONS}"

        echo -en "[7/13] MTU [$DEFAULT_MTU]: "
        read -r mtu_input; local mtu="${mtu_input:-$DEFAULT_MTU}"

        echo -e "\n[8/13] Encryption: [1]aes-128-gcm [2]aes [3]aes-128 [4]aes-192 [5]aes-256 [6]none"
        read -p "Choose (default 1): " enc_choice; enc_choice="${enc_choice:-1}"
        local block; IFS=':' read -r block _ <<< "${ENCRYPTION_OPTIONS[$enc_choice]}"; block="${block:-aes-128-gcm}"

        echo -en "[9/13] pcap sockbuf: "
        read -r pcap_input; local pcap_sockbuf="${pcap_input:-$DEFAULT_PCAP_SOCKBUF_CLIENT}"

        echo -en "[10/13] tcpbuf: "
        read -r tcpbuf_input; local transport_tcpbuf="${tcpbuf_input:-$DEFAULT_TRANSPORT_TCPBUF}"

        echo -en "[11/13] udpbuf: "
        read -r udpbuf_input; local transport_udpbuf="${udpbuf_input:-$DEFAULT_TRANSPORT_UDPBUF}"

        echo -e "\n[12/13] Traffic Type: [1]Port Forward [2]SOCKS5"
        read -p "Choose (default 1): " traffic_type; traffic_type="${traffic_type:-1}"

        local forward_entries=() socks5_entries=() display_ports="" SOCKS5_PORT=""
        case $traffic_type in
            1)
                echo -en "\n[13/13] Forward Ports [$DEFAULT_V2RAY_PORTS]: "
                read -r forward_ports
                forward_ports=$(clean_port_list "${forward_ports:-$DEFAULT_V2RAY_PORTS}")
                [ -z "$forward_ports" ] && { print_error "No ports"; continue; }
                IFS=',' read -ra PORTS <<< "$forward_ports"
                for p in "${PORTS[@]}"; do
                    p=$(echo "$p" | tr -d '[:space:]')
                    forward_entries+=("  - listen: \"0.0.0.0:$p\"\n    target: \"127.0.0.1:$p\"\n    protocol: \"tcp\"")
                    display_ports+=" $p(TCP)"
                done
                ;;
            2)
                echo -en "\n[13/13] SOCKS5 Port [$DEFAULT_SOCKS5_PORT]: "
                read -r socks_port; socks_port="${socks_port:-$DEFAULT_SOCKS5_PORT}"
                socks5_entries+=("  - listen: \"127.0.0.1:$socks_port\"")
                SOCKS5_PORT="$socks_port"
                ;;
        esac

        [[ "$traffic_type" == "1" ]] && { validate_forward_rules || continue; }

        [ ! -f "$BIN_DIR/paqet" ] && { install_paqet || continue; }
        mkdir -p "$CONFIG_DIR"

        {
            echo "role: \"client\""
            echo "log:"; echo "  level: \"info\""
            if [ ${#forward_entries[@]} -gt 0 ]; then
                echo "forward:"
                for entry in "${forward_entries[@]}"; do echo -e "$entry"; done
            fi
            if [ ${#socks5_entries[@]} -gt 0 ]; then
                echo "socks5:"
                for entry in "${socks5_entries[@]}"; do echo -e "$entry"; done
            fi
            echo "network:"
            echo "  interface: \"$NETWORK_INTERFACE\""
            echo "  ipv4:"; echo "    addr: \"$LOCAL_IP:0\""
            echo "    router_mac: \"$GATEWAY_MAC\""
            echo "  tcp:"; echo "    local_flag: [\"PA\"]"; echo "    remote_flag: [\"PA\"]"
            [[ -n "$pcap_sockbuf" ]] && { echo "  pcap:"; echo "    sockbuf: $pcap_sockbuf"; }
            echo "server:"; echo "  addr: \"$server_ip:$server_port\""
            echo "transport:"; echo "  protocol: \"kcp\""
            [[ -n "$conn" ]] && echo "  conn: $conn"
            [[ -n "$transport_tcpbuf" ]] && echo "  tcpbuf: $transport_tcpbuf"
            [[ -n "$transport_udpbuf" ]] && echo "  udpbuf: $transport_udpbuf"
            echo "  kcp:"; echo "    key: \"$secret_key\""
            if [ "$mode_name" = "manual" ] && [ -n "$kcp_fragment" ]; then
                echo "    mode: \"manual\""; echo "    block: \"$block\""
                [[ -n "$mtu" ]] && echo "    mtu: $mtu"
                while IFS= read -r line; do
                    [[ -n "$line" ]] && ! echo "$line" | grep -q "mode:" && echo "    $line"
                done <<< "$kcp_fragment"
            else
                echo "    mode: \"$mode_name\""; echo "    block: \"$block\""
                [[ -n "$mtu" ]] && echo "    mtu: $mtu"
            fi
        } > "$CONFIG_DIR/${config_name}.yaml"

        create_systemd_service "$config_name"
        local svc="paqet-${config_name}"
        systemctl enable "$svc" --now >/dev/null 2>&1

        if systemctl is-active --quiet "$svc"; then
            add_auto_restart_cronjob "$svc" "$DEFAULT_AUTO_RESTART_INTERVAL" >/dev/null 2>&1
            echo -e "\n${GREEN}✅ Client Ready!${NC}"
        else
            print_error "Failed"; systemctl status "$svc" --no-pager -l
        fi
        pause; return 0
    done
}

# ================================================
# TEST FUNCTIONS
# ================================================
test_internet_connectivity() {
    echo -e "\n${YELLOW}Internet Test${NC}\n"
    local hosts=("8.8.8.8" "1.1.1.1" "208.67.222.222")
    local success=0
    for host in "${hosts[@]}"; do
        echo -n "  $host: "
        if ping -c 2 -W 1 "$host" &>/dev/null; then
            echo -e "${GREEN}✓${NC}"; ((success++))
        else
            echo -e "${RED}✗${NC}"
        fi
    done
    echo -e "\n  Result: $success/${#hosts[@]} reachable"
}

test_dns_resolution() {
    echo -e "\n${YELLOW}DNS Test${NC}\n"
    local resolved=0
    for domain in "${TEST_DOMAINS[@]}"; do
        echo -n "  $domain: "
        if timeout 3 dig +short "$domain" &>/dev/null 2>&1; then
            echo -e "${GREEN}✓${NC}"; ((resolved++))
        else
            echo -e "${RED}✗${NC}"
        fi
    done
    echo -e "\n  Result: $resolved/${#TEST_DOMAINS[@]} resolved"
}

test_paqet_tunnel() {
    clear
    echo -e "\n${YELLOW}Tunnel Connection Test${NC}\n"
    echo -en "Remote Server IP: "
    read -r remote_ip
    validate_ip "$remote_ip" || { print_error "Invalid IP"; return; }

    echo -e "\nTesting $remote_ip...\n"
    local ping_output=$(ping -c 5 -W 2 "$remote_ip" 2>&1)
    local packet_loss=$(echo "$ping_output" | grep -o "[0-9]*% packet loss" | grep -o "[0-9]*" || echo "100")
    local avg_ping=$(echo "$ping_output" | grep "rtt" | awk -F'/' '{print $5}' 2>/dev/null)

    echo -e "  ICMP: Loss=${packet_loss}% RTT=${avg_ping:-N/A}ms"

    echo -e "\n${YELLOW}MTU Test:${NC}"
    local best_mtu="" best_loss=100
    for mtu in "${MTU_TESTS[@]}"; do
        local payload=$((mtu - 28))
        [ $payload -lt 0 ] && continue
        echo -n "  MTU $mtu: "
        local result=$(ping -c 5 -W 1 -M do -s "$payload" "$remote_ip" 2>&1)
        if echo "$result" | grep -q "0% packet loss"; then
            echo -e "${GREEN}PERFECT${NC}"
            [ -z "$best_mtu" ] && best_mtu="$mtu" && best_loss=0
        elif echo "$result" | grep -q "[0-9]*% packet loss"; then
            local loss=$(echo "$result" | grep -o "[0-9]*% packet loss" | grep -o "[0-9]*")
            if [ "$loss" -le 10 ]; then
                echo -e "${GREEN}GOOD ($loss%)${NC}"
                [ "$loss" -lt "$best_loss" ] && best_mtu="$mtu" && best_loss="$loss"
            else
                echo -e "${YELLOW}FAIR ($loss%)${NC}"
            fi
        else
            echo -e "${RED}FAILED${NC}"
        fi
    done

    echo -e "\n${GREEN}Recommendation:${NC}"
    [ -n "$best_mtu" ] && echo -e "  Best MTU: $best_mtu (${best_loss}% loss)" || echo -e "  Use MTU: 1200"
}

test_connection() {
    clear; show_banner
    echo -e "${GREEN}Connection Tests${NC}\n"
    echo " 1. Tunnel Test  2. Internet  3. DNS  0. Back"
    read -p "Choose: " choice
    case $choice in
        1) test_paqet_tunnel; pause ;;
        2) test_internet_connectivity; pause ;;
        3) test_dns_resolution; pause ;;
    esac
}

# ================================================
# INSTALLATION
# ================================================
check_dependencies() {
    local missing=()
    local os=$(detect_os)
    local deps=("curl" "wget" "iptables" "lsof")
    case $os in
        ubuntu|debian) deps+=("libpcap-dev" "iproute2" "cron" "dnsutils") ;;
        centos|rhel|fedora|rocky|almalinux) deps+=("libpcap-devel" "iproute" "cronie" "bind-utils") ;;
    esac
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            local found=false
            case $os in
                ubuntu|debian) dpkg -l "$dep" &>/dev/null 2>&1 && found=true ;;
                *) rpm -q "$dep" &>/dev/null 2>&1 && found=true ;;
            esac
            $found || missing+=("$dep")
        fi
    done
    [ ${#missing[@]} -eq 0 ] && return 0 || { echo "${missing[@]}"; return 1; }
}

install_dependencies() {
    clear; show_banner
    print_step "Installing dependencies..."
    local os=$(detect_os)
    case $os in
        ubuntu|debian)
            apt update -qq 2>/dev/null
            apt install -y curl wget libpcap-dev iptables lsof iproute2 cron dnsutils 2>/dev/null
            install_iptables_persistent
            ;;
        centos|rhel|fedora|rocky|almalinux)
            yum install -y curl wget libpcap-devel iptables lsof iproute cronie bind-utils 2>/dev/null
            install_iptables_persistent
            ;;
    esac
    print_success "Done"
    pause
}

install_iptables_persistent() {
    local os=$(detect_os)
    case $os in
        ubuntu|debian)
            dpkg -l iptables-persistent &>/dev/null 2>&1 || {
                export DEBIAN_FRONTEND=noninteractive
                apt-get install -y iptables-persistent 2>/dev/null
            }
            ;;
        centos|rhel|fedora|rocky|almalinux)
            rpm -q iptables-services &>/dev/null 2>&1 || {
                yum install -y iptables-services 2>/dev/null
                systemctl enable iptables 2>/dev/null
            }
            ;;
    esac
    save_iptables
}

install_paqet() {
    clear; show_banner
    print_step "Paqet Installation\n"
    local os=$(detect_os) arch=$(detect_arch) || return 1
    local latest=$(get_latest_paqet_version)
    echo -e "  OS: $os | Arch: $arch | Latest: $latest\n"
    echo " 1. Download latest  2. Local file  3. Custom URL  0. Back"
    read -p "Choose: " choice

    local arch_name=""
    case $arch in
        amd64) arch_name="amd64" ;; arm64) arch_name="arm64" ;;
        armv7) arch_name="arm32" ;; 386) arch_name="386" ;; *) arch_name="$arch" ;;
    esac

    case $choice in
        1)
            local url="https://github.com/${GITHUB_REPO}/releases/download/${latest}/paqet-linux-${arch_name}-${latest}.tar.gz"
            curl -fsSL --retry 3 "$url" -o "/tmp/paqet.tar.gz" || { print_error "Download failed"; pause; return 1; }
            ;;
        2)
            local files=$(find /root/paqet -name "*.tar.gz" 2>/dev/null)
            [ -z "$files" ] && { print_error "No files found"; pause; return 1; }
            echo "$files"
            read -p "Enter filename: " fname
            cp "/root/paqet/$fname" /tmp/paqet.tar.gz 2>/dev/null || { print_error "Not found"; pause; return 1; }
            ;;
        3)
            read -p "URL: " url
            curl -fsSL "$url" -o /tmp/paqet.tar.gz || { print_error "Failed"; pause; return 1; }
            ;;
        0) return 0 ;;
    esac

    mkdir -p "$INSTALL_DIR"; rm -rf "$INSTALL_DIR"/*
    tar -xzf /tmp/paqet.tar.gz -C "$INSTALL_DIR" 2>/dev/null || { print_error "Extract failed"; pause; return 1; }

    local binary=$(find "$INSTALL_DIR" -type f -name "*paqet*" | head -1)
    [ -z "$binary" ] && binary=$(find "$INSTALL_DIR" -type f -executable | head -1)
    if [ -n "$binary" ]; then
        cp "$binary" "$BIN_DIR/paqet"; chmod +x "$BIN_DIR/paqet"
        print_success "Installed!"
    fi
    rm -f /tmp/paqet.tar.gz
    pause
}

# ================================================
# KERNEL OPTIMIZATION (Optimized values)
# ================================================
apply_kernel_optimizations() {
    clear; show_banner
    echo -e "${GREEN}Apply Kernel Optimizations${NC}\n"
    mkdir -p "$BACKUP_DIR"
    [ -f "$SYSCTL_FILE" ] && cp "$SYSCTL_FILE" "$BACKUP_SYSCTL"

    cat > "$SYSCTL_FILE" << 'EOF'
# Paqet Optimized (v7.1)
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 32768
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_forward = 1
net.netfilter.nf_conntrack_max = 1048576
fs.file-max = 2097152
EOF

    sysctl -p "$SYSCTL_FILE" 2>/dev/null
    if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        sed -i 's/bbr/cubic/' "$SYSCTL_FILE"
        sysctl -w net.ipv4.tcp_congestion_control=cubic 2>/dev/null
    fi

    cat > "$LIMITS_FILE" << 'EOF'
* soft nofile 524288
* hard nofile 524288
root soft nofile 524288
root hard nofile 524288
EOF

    print_success "Optimizations applied! Reboot recommended."
    pause
}

remove_kernel_optimizations() {
    rm -f "$SYSCTL_FILE" "$LIMITS_FILE"
    sysctl --system 2>/dev/null
    sysctl -w net.ipv4.tcp_congestion_control=cubic 2>/dev/null
    print_success "Defaults restored"
    pause
}

optimize_server() {
    while true; do
        clear; show_banner
        echo -e "${GREEN}Server Optimization${NC}\n"
        echo " 1. Apply Optimizations  2. Remove  3. View Status  0. Back"
        read -p "Choose: " choice
        case $choice in
            1) apply_kernel_optimizations ;;
            2) remove_kernel_optimizations ;;
            3) echo -e "\nCongestion: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"; pause ;;
            0) return ;;
        esac
    done
}

# ================================================
# MANAGE ALL SERVICES
# ================================================
manage_all_services() {
    while true; do
        clear; show_banner
        local services=()
        mapfile -t services < <(get_all_paqet_services)
        [ ${#services[@]} -eq 0 ] && { print_warning "No services"; pause; return; }

        echo -e "${GREEN}All Services (${#services[@]})${NC}\n"
        local i=1
        for svc in "${services[@]}"; do
            local name="${svc#paqet-}"; name="${name%.service}"
            local status=$(systemctl is-active "$svc" 2>/dev/null || echo "?")
            printf " %2d. %-20s [%s]\n" "$i" "$name" "$status"
            ((i++))
        done

        echo -e "\nActions:"
        echo " 1. Start All  2. Stop All  3. Restart All"
        echo " 4. Apply Protection  5. Remove Protection"
        echo " 6. Change MTU All  7. Delete All  0. Back"
        read -p "Choose: " choice

        case $choice in
            0) return ;;
            1) for svc in "${services[@]}"; do systemctl start "$svc" 2>/dev/null; done; print_success "Started"; pause ;;
            2) for svc in "${services[@]}"; do systemctl stop "$svc" 2>/dev/null; done; print_success "Stopped"; pause ;;
            3) for svc in "${services[@]}"; do systemctl restart "$svc" 2>/dev/null; done; print_success "Restarted"; pause ;;
            4) apply_connection_protection ;;
            5) remove_connection_protection ;;
            6) set_global_mtu ;;
            7) delete_all_tunnels "${services[@]}" ;;
        esac
    done
}

apply_connection_protection() {
    echo -e "\n${YELLOW}Applying Protection...${NC}"
    local configs=()
    while IFS= read -r -d '' file; do configs+=("$file"); done < <(find "$CONFIG_DIR" -name "*.yaml" -print0 2>/dev/null)
    local count=0
    for config in "${configs[@]}"; do
        local role=$(grep "^role:" "$config" | awk '{print $2}' | tr -d '"')
        if [ "$role" = "server" ]; then
            local port=$(grep -A5 "listen:" "$config" | grep "addr:" | sed -n 's/.*:\([0-9]*\)".*/\1/p' | head -1)
            [ -n "$port" ] && { configure_iptables "$port" "tcp"; ((count++)); }
        elif [ "$role" = "client" ]; then
            local server=$(grep -A2 "server:" "$config" | grep "addr:" | awk '{print $2}' | tr -d '"')
            if [ -n "$server" ]; then
                local sip=$(echo "$server" | cut -d: -f1)
                local sport=$(echo "$server" | cut -d: -f2)
                iptables -t raw -C OUTPUT -p tcp -d "$sip" --dport "$sport" -j NOTRACK 2>/dev/null || \
                    iptables -t raw -A OUTPUT -p tcp -d "$sip" --dport "$sport" -j NOTRACK
                iptables -t mangle -C OUTPUT -p tcp -d "$sip" --dport "$sport" --tcp-flags RST RST -j DROP 2>/dev/null || \
                    iptables -t mangle -A OUTPUT -p tcp -d "$sip" --dport "$sport" --tcp-flags RST RST -j DROP
                ((count++))
            fi
        fi
    done
    save_iptables
    print_success "Protected $count service(s)"
    pause
}

remove_connection_protection() {
    echo -e "\n${YELLOW}Removing Protection...${NC}"
    local configs=()
    while IFS= read -r -d '' file; do configs+=("$file"); done < <(find "$CONFIG_DIR" -name "*.yaml" -print0 2>/dev/null)
    local removed=0
    for config in "${configs[@]}"; do
        local role=$(grep "^role:" "$config" | awk '{print $2}' | tr -d '"')
        if [ "$role" = "server" ]; then
            local port=$(grep -A5 "listen:" "$config" | grep "addr:" | sed -n 's/.*:\([0-9]*\)".*/\1/p' | head -1)
            [ -n "$port" ] && {
                iptables -t raw -D PREROUTING -p tcp --dport "$port" -j NOTRACK 2>/dev/null && ((removed++))
                iptables -t raw -D OUTPUT -p tcp --sport "$port" -j NOTRACK 2>/dev/null && ((removed++))
                iptables -t mangle -D OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP 2>/dev/null && ((removed++))
            }
        elif [ "$role" = "client" ]; then
            local server=$(grep -A2 "server:" "$config" | grep "addr:" | awk '{print $2}' | tr -d '"')
            if [ -n "$server" ]; then
                local sip=$(echo "$server" | cut -d: -f1)
                local sport=$(echo "$server" | cut -d: -f2)
                iptables -t raw -D OUTPUT -p tcp -d "$sip" --dport "$sport" -j NOTRACK 2>/dev/null && ((removed++))
                iptables -t mangle -D OUTPUT -p tcp -d "$sip" --dport "$sport" --tcp-flags RST RST -j DROP 2>/dev/null && ((removed++))
            fi
        fi
    done
    save_iptables
    print_success "Removed $removed rule(s)"
    pause
}

set_global_mtu() {
    echo -e "\n${YELLOW}Set Global MTU${NC}"
    local configs=()
    while IFS= read -r -d '' file; do configs+=("$file"); done < <(find "$CONFIG_DIR" -name "*.yaml" -print0 2>/dev/null)
    [ ${#configs[@]} -eq 0 ] && { print_warning "No configs"; pause; return; }

    read -p "New MTU [1000-1500]: " new_mtu
    [[ "$new_mtu" =~ ^[0-9]+$ ]] && [ "$new_mtu" -ge 1000 ] && [ "$new_mtu" -le 1500 ] || { print_error "Invalid"; pause; return; }

    local modified=0
    for config in "${configs[@]}"; do
        if grep -q "mtu:" "$config"; then
            sed -i "s/mtu:.*/mtu: $new_mtu/" "$config"
        elif grep -q "kcp:" "$config"; then
            sed -i "/kcp:/a\    mtu: $new_mtu" "$config"
        fi
        ((modified++))
    done
    print_success "MTU set to $new_mtu on $modified config(s)"
    read -p "Restart all? (y/N): " r
    [[ "$r" =~ ^[Yy]$ ]] && {
        local services=(); mapfile -t services < <(get_all_paqet_services)
        for svc in "${services[@]}"; do systemctl restart "$svc" 2>/dev/null; done
    }
    pause
}

delete_all_tunnels() {
    local services=("$@")
    echo -e "\n${RED}DELETE ALL TUNNELS?${NC}"
    read -p "Type 'yes' to confirm: " confirm
    [ "$confirm" != "yes" ] && return

    for svc in "${services[@]}"; do
        local name="${svc#paqet-}"; name="${name%.service}"
        remove_cronjob "${svc%.service}" 2>/dev/null
        systemctl stop "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null
        rm -f "$SERVICE_DIR/$svc" "$CONFIG_DIR/$name.yaml"
    done
    systemctl daemon-reload
    print_success "All deleted"
    pause
}

save_iptables() {
    command -v iptables-save &>/dev/null || return 1
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null
    chmod 600 /etc/iptables/rules.v4 2>/dev/null
    command -v netfilter-persistent &>/dev/null && netfilter-persistent save 2>/dev/null
}

# ================================================
# TELEGRAM BOT
# ================================================
init_bot_config() {
    mkdir -p "$BOT_CONFIG_DIR"
    [ ! -f "$BOT_CONFIG_FILE" ] && cat > "$BOT_CONFIG_FILE" << EOF
BOT_TOKEN=""
CHAT_ID=""
ENABLE_BOT="false"
ENABLE_BOOT_REPORT="true"
ENABLE_SERVICE_WATCH="true"
WATCH_INTERVAL="60"
SOCKS5_PROXY=""
USE_SOCKS5="false"
EOF
    chmod 600 "$BOT_CONFIG_FILE"
}

load_bot_config() {
    if [ -f "$BOT_CONFIG_FILE" ]; then
        BOT_TOKEN=$(grep "^BOT_TOKEN=" "$BOT_CONFIG_FILE" | cut -d'"' -f2)
        CHAT_ID=$(grep "^CHAT_ID=" "$BOT_CONFIG_FILE" | cut -d'"' -f2)
        ENABLE_BOT=$(grep "^ENABLE_BOT=" "$BOT_CONFIG_FILE" | cut -d'"' -f2)
        ENABLE_BOOT_REPORT=$(grep "^ENABLE_BOOT_REPORT=" "$BOT_CONFIG_FILE" | cut -d'"' -f2)
        ENABLE_SERVICE_WATCH=$(grep "^ENABLE_SERVICE_WATCH=" "$BOT_CONFIG_FILE" | cut -d'"' -f2)
        WATCH_INTERVAL=$(grep "^WATCH_INTERVAL=" "$BOT_CONFIG_FILE" | cut -d'"' -f2)
        SOCKS5_PROXY=$(grep "^SOCKS5_PROXY=" "$BOT_CONFIG_FILE" | cut -d'"' -f2)
        USE_SOCKS5=$(grep "^USE_SOCKS5=" "$BOT_CONFIG_FILE" | cut -d'"' -f2)
    else
        BOT_TOKEN="" CHAT_ID="" ENABLE_BOT="false"
        ENABLE_BOOT_REPORT="true" ENABLE_SERVICE_WATCH="true"
        WATCH_INTERVAL="60" SOCKS5_PROXY="" USE_SOCKS5="false"
    fi
}

save_bot_config() {
    cat > "$BOT_CONFIG_FILE" << EOF
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
ENABLE_BOT="$ENABLE_BOT"
ENABLE_BOOT_REPORT="$ENABLE_BOOT_REPORT"
ENABLE_SERVICE_WATCH="$ENABLE_SERVICE_WATCH"
WATCH_INTERVAL="$WATCH_INTERVAL"
SOCKS5_PROXY="$SOCKS5_PROXY"
USE_SOCKS5="$USE_SOCKS5"
EOF
    chmod 600 "$BOT_CONFIG_FILE"
}

detect_socks5_proxy() {
    local socks5_found=""
    while IFS= read -r -d '' file; do
        if grep -q "role:.*client" "$file" 2>/dev/null && grep -q "socks5:" "$file"; then
            local port=$(grep -A2 "socks5:" "$file" | grep "listen:" | sed 's/.*:\([0-9]*\)".*/\1/' | head -1)
            [ -n "$port" ] && { socks5_found="127.0.0.1:$port"; break; }
        fi
    done < <(find "$CONFIG_DIR" -name "*.yaml" -print0 2>/dev/null)
    echo "$socks5_found"
}

send_telegram_message() {
    local message="$1"
    local parse_mode="${2:-HTML}"
    [ "$ENABLE_BOT" != "true" ] || [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ] && return 1

    local escaped=$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
    local payload="{\"chat_id\":\"$CHAT_ID\",\"text\":\"$escaped\",\"parse_mode\":\"$parse_mode\"}"

    if [ "$USE_SOCKS5" = "true" ] && [ -n "$SOCKS5_PROXY" ]; then
        curl -s --max-time 8 --socks5-hostname "$SOCKS5_PROXY" \
            -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -H "Content-Type: application/json" -d "$payload" 2>/dev/null | grep -q '"ok":true' && return 0
    fi

    curl -s --max-time 8 -X POST "https://telegram.behzad.workers.dev/bot$BOT_TOKEN/sendMessage" \
        -H "Content-Type: application/json" -d "$payload" 2>/dev/null | grep -q '"ok":true' && return 0

    curl -s --max-time 5 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -H "Content-Type: application/json" -d "$payload" 2>/dev/null | grep -q '"ok":true' && return 0

    return 1
}

create_bot_script() {
    cat > "$BOT_SCRIPT" << 'BOTEOF'
#!/bin/bash
BOT_CONFIG="/etc/telegram-paqet-bot/config.conf"
LOG_FILE="/var/log/telegram-paqet-bot.log"
LAST_STATE_FILE="/etc/telegram-paqet-bot/last_state"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

load_config() {
    [ -f "$BOT_CONFIG" ] || exit 1
    BOT_TOKEN=$(grep "^BOT_TOKEN=" "$BOT_CONFIG" | cut -d'"' -f2)
    CHAT_ID=$(grep "^CHAT_ID=" "$BOT_CONFIG" | cut -d'"' -f2)
    ENABLE_BOT=$(grep "^ENABLE_BOT=" "$BOT_CONFIG" | cut -d'"' -f2)
    ENABLE_SERVICE_WATCH=$(grep "^ENABLE_SERVICE_WATCH=" "$BOT_CONFIG" | cut -d'"' -f2)
    WATCH_INTERVAL=$(grep "^WATCH_INTERVAL=" "$BOT_CONFIG" | cut -d'"' -f2)
    SOCKS5_PROXY=$(grep "^SOCKS5_PROXY=" "$BOT_CONFIG" | cut -d'"' -f2)
    USE_SOCKS5=$(grep "^USE_SOCKS5=" "$BOT_CONFIG" | cut -d'"' -f2)
}

send_alert() {
    local message="$1"
    [ "$ENABLE_BOT" != "true" ] || [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ] && return
    local escaped=$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
    local payload="{\"chat_id\":\"$CHAT_ID\",\"text\":\"$escaped\",\"parse_mode\":\"HTML\"}"
    if [ "$USE_SOCKS5" = "true" ] && [ -n "$SOCKS5_PROXY" ]; then
        curl -s --max-time 8 --socks5-hostname "$SOCKS5_PROXY" \
            -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -H "Content-Type: application/json" -d "$payload" 2>/dev/null | grep -q '"ok":true' && return
    fi
    curl -s --max-time 8 -X POST "https://telegram.behzad.workers.dev/bot$BOT_TOKEN/sendMessage" \
        -H "Content-Type: application/json" -d "$payload" 2>/dev/null | grep -q '"ok":true' && return
    curl -s --max-time 5 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -H "Content-Type: application/json" -d "$payload" 2>/dev/null
}

check_services() {
    local changes="" current_state=""
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        local status=$(systemctl is-active "$svc" 2>/dev/null)
        local name="${svc#paqet-}"; name="${name%.service}"
        current_state+="${svc}:${status}\n"
        local last=$(grep "^${svc}:" "$LAST_STATE_FILE" 2>/dev/null | cut -d: -f2)
        if [ "$last" != "$status" ]; then
            local emoji="❓"
            case "$status" in active) emoji="✅" ;; failed) emoji="❌" ;; inactive) emoji="💤" ;; esac
            changes+="$emoji $name: $status\n"
        fi
    done < <(systemctl list-units --type=service --all --no-legend 2>/dev/null | grep "paqet-" | awk '{print $1}')
    echo -e "$current_state" > "$LAST_STATE_FILE"
    [ -n "$changes" ] && send_alert "🔔 Status Changes:\n$changes"
}

main() {
    load_config
    touch "$LAST_STATE_FILE"
    log "Bot started"
    while true; do
        [ "$ENABLE_BOT" = "true" ] && [ "$ENABLE_SERVICE_WATCH" = "true" ] && check_services
        sleep "${WATCH_INTERVAL:-60}"
    done
}
main
BOTEOF
    chmod +x "$BOT_SCRIPT"
    touch "$BOT_CONFIG_DIR/last_state"
}

create_bot_service() {
    cat > "/etc/systemd/system/$BOT_SERVICE.service" << EOF
[Unit]
Description=Paqet Telegram Bot
After=network.target

[Service]
Type=simple
ExecStart=$BOT_SCRIPT
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

telegram_bot_menu() {
    init_bot_config
    load_bot_config
    while true; do
        clear; show_banner
        echo -e "${GREEN}Telegram Bot${NC}"
        echo -e "Status: $([ "$ENABLE_BOT" = "true" ] && echo "${GREEN}ON${NC}" || echo "${RED}OFF${NC}")"
        echo -e "\n S. Setup Wizard  R. Remove Bot"
        echo " 1. Toggle Boot Report  2. Toggle Service Watch"
        echo " 3. Set Interval  4. Toggle SOCKS5  5. Set SOCKS5"
        echo " 6. Start  7. Stop  8. Restart  9. Test  0. Back"
        read -p "Choose: " choice
        case $choice in
            [Ss])
                read -p "Bot Token: " BOT_TOKEN
                read -p "Chat ID: " CHAT_ID
                ENABLE_BOT="true"
                local proxy=$(detect_socks5_proxy)
                [ -n "$proxy" ] && { SOCKS5_PROXY="$proxy"; USE_SOCKS5="true"; }
                save_bot_config
                create_bot_script; create_bot_service
                systemctl enable "$BOT_SERVICE" --now 2>/dev/null
                print_success "Bot configured!"
                pause ;;
            [Rr])
                systemctl stop "$BOT_SERVICE" 2>/dev/null
                systemctl disable "$BOT_SERVICE" 2>/dev/null
                rm -f "/etc/systemd/system/$BOT_SERVICE.service" "$BOT_SCRIPT"
                rm -rf "$BOT_CONFIG_DIR"
                systemctl daemon-reload
                print_success "Bot removed"; pause ;;
            1) [ "$ENABLE_BOOT_REPORT" = "true" ] && ENABLE_BOOT_REPORT="false" || ENABLE_BOOT_REPORT="true"; save_bot_config ;;
            2) [ "$ENABLE_SERVICE_WATCH" = "true" ] && ENABLE_SERVICE_WATCH="false" || ENABLE_SERVICE_WATCH="true"; save_bot_config ;;
            3) read -p "Interval (30-3600): " WATCH_INTERVAL; save_bot_config ;;
            4) [ "$USE_SOCKS5" = "true" ] && USE_SOCKS5="false" || USE_SOCKS5="true"; save_bot_config ;;
            5) read -p "SOCKS5 (host:port): " SOCKS5_PROXY; USE_SOCKS5="true"; save_bot_config ;;
            6) [ ! -f "$BOT_SCRIPT" ] && create_bot_script; [ ! -f "/etc/systemd/system/$BOT_SERVICE.service" ] && create_bot_service; systemctl start "$BOT_SERVICE" ;;
            7) systemctl stop "$BOT_SERVICE" ;;
            8) systemctl restart "$BOT_SERVICE" ;;
            9) send_telegram_message "✅ Bot Test - $(date)" && print_success "Sent!" || print_error "Failed"; pause ;;
            0) return ;;
        esac
    done
}

# ================================================
# UNINSTALL
# ================================================
uninstall_paqet() {
    clear; show_banner
    echo -e "${RED}Uninstall Paqet?${NC}"
    read -p "Confirm (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    local services=()
    mapfile -t services < <(get_all_paqet_services)
    for svc in "${services[@]}"; do
        remove_cronjob "${svc%.service}" 2>/dev/null
        systemctl stop "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null
        rm -f "$SERVICE_DIR/$svc"
    done
    systemctl daemon-reload
    rm -f "$BIN_DIR/paqet"

    read -p "Remove configs? (y/N): " rc
    [[ "$rc" =~ ^[Yy]$ ]] && rm -rf "$CONFIG_DIR" "$INSTALL_DIR"
    print_success "Uninstalled"
    pause
}

# ================================================
# MAIN MENU (SIMPLIFIED)
# ================================================
main_menu() {
    while true; do
        clear; show_banner

        if [ -f "$BIN_DIR/paqet" ]; then
            local ver=$("$BIN_DIR/paqet" version 2>/dev/null | grep "^Version:" | head -1 | cut -d':' -f2 | xargs)
            echo -e "${GREEN}✅ Paqet installed${NC} ${CYAN}${ver:-unknown}${NC}"
        else
            echo -e "${YELLOW}⚠️ Paqet not installed${NC}"
        fi
        echo ""

        echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║                    MAIN MENU                            ║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║${NC} ${GREEN}QUICK SETUP (Recommended)${NC}                               ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  Q1. ⚡ Quick Server Setup (3 steps)                   ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  Q2. ⚡ Quick Client Setup (4 steps)                   ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}                                                        ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC} ${YELLOW}ADVANCED${NC}                                               ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  1. 📦 Install Paqet / Dependencies                   ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  2. 🌍 Server Config (Advanced)                       ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  3. 🇮🇷 Client Config (Advanced)                       ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  4. 🛠️  Manage Services                                 ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  5. 🔄 Manage All Services                            ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  6. 📊 Test Connection                                ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  7. 🚀 Optimize Server                                ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  8. 🤖 Telegram Bot                                   ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  9. 🗑️  Uninstall                                       ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  0. 🚪 Exit                                            ${CYAN}║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        read -p "Select: " choice

        case $choice in
            [Qq]1|q1) quick_setup_server ;;
            [Qq]2|q2) quick_setup_client ;;
            1)
                echo -e "\n 1. Install Paqet  2. Install Dependencies"
                read -p "Choose: " sub
                case $sub in
                    1) install_paqet ;;
                    2) install_dependencies ;;
                esac ;;
            2) configure_server ;;
            3) configure_client ;;
            4) manage_services ;;
            5) manage_all_services ;;
            6) test_connection ;;
            7) optimize_server ;;
            8) telegram_bot_menu ;;
            9) uninstall_paqet ;;
            0) echo -e "\n${GREEN}Goodbye!${NC}"; exit 0 ;;
            *) print_error "Invalid"; sleep 1 ;;
        esac
    done
}

# ================================================
# START
# ================================================
check_root
main_menu
