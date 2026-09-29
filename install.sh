#!/bin/bash
#=================================================
# Paqet Tunnel Manager
# Version: 7.3 (Fixed IPv4/IPv6 handling)
# Auto-install dependencies + Auto credentials
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
readonly NC='\033[0m'

readonly SCRIPT_VERSION="7.3"
readonly CONFIG_DIR="/etc/paqet"
readonly SERVICE_DIR="/etc/systemd/system"
readonly BIN_DIR="/usr/local/bin"
readonly INSTALL_DIR="/opt/paqet"
readonly BACKUP_DIR="/root/paqet-backups"
readonly GITHUB_REPO="hanselime/paqet"
readonly SYSCTL_FILE="/etc/sysctl.d/99-paqet-tunnel.conf"
readonly LIMITS_FILE="/etc/security/limits.d/99-paqet.conf"

# ═══════════════════════════════════════════════
# AUTO CONFIGURATION (No prompts)
# ═══════════════════════════════════════════════
readonly DEFAULT_CONFIG_NAME="fghj"
readonly DEFAULT_SECRET_KEY="pQwOPDE5zQq3xaC2UFvnCpmDqyxB1lin"
readonly DEFAULT_LISTEN_PORT="8888"
readonly DEFAULT_KCP_MODE="fast"
readonly DEFAULT_ENCRYPTION="aes-128-gcm"
readonly DEFAULT_CONNECTIONS="2"
readonly DEFAULT_MTU="1300"
readonly DEFAULT_AUTO_RESTART_INTERVAL="6hour"
readonly DEFAULT_V2RAY_PORTS="9090"

declare -A KCP_MODES=(
    ["0"]="normal:Normal speed / Low CPU"
    ["1"]="fast:Balanced (Recommended)"
    ["2"]="fast2:High speed / Medium CPU"
    ["3"]="fast3:Max speed / HIGH CPU ⚠️"
    ["4"]="manual:Advanced settings"
)

declare -A ENCRYPTION_OPTIONS=(
    ["1"]="aes-128-gcm:Very fast / Recommended"
    ["2"]="aes:High security / Medium speed"
    ["3"]="aes-128:Fast / Low CPU"
    ["4"]="aes-256:Max security / Slower"
    ["5"]="none:No encryption / Max speed ⚠️"
)

declare -A RESTART_INTERVALS=(
    ["1hour"]="0 */1 * * *"
    ["3hour"]="0 */3 * * *"
    ["6hour"]="0 */6 * * *"
    ["12hour"]="0 */12 * * *"
    ["1day"]="0 0 * * *"
)

readonly IP_SERVICES=("ifconfig.me" "icanhazip.com" "api.ipify.org")
readonly MTU_TESTS=("1500" "1400" "1350" "1300" "1200" "1100")

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
    echo "╔══════════════════════════════════════════════╗"
    echo "║   ██████╗  █████╗  ██████╗ ███████╗███████╗  ║"
    echo "║   ██╔══██╗██╔══██╗██╔═══██╗██╔════╝╚══███╔╝  ║"
    echo "║   ██████╔╝███████║██║   ██║█████╗     ███╔╝   ║"
    echo "║   ██╔═══╝ ██╔══██║██║▄▄ ██║██╔══╝    ███╔╝    ║"
    echo "║   ██║     ██║  ██║╚██████╔╝███████╗ ███████╗  ║"
    echo "║   ╚═╝     ╚═╝  ╚═╝ ╚══▀▀═╝ ╚══════╝ ╚══════╝  ║"
    echo "║         Paqet Tunnel Manager v${SCRIPT_VERSION}           ║"
    echo "╚══════════════════════════════════════════════╝"
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
    else
        echo "unknown"
    fi
}

detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armhf) echo "armv7" ;;
        i386|i686) echo "386" ;;
        *) echo "$arch" ;;
    esac
}

get_public_ip() {
    for service in "${IP_SERVICES[@]}"; do
        local ip=$(curl -4 -s --max-time 3 "$service" 2>/dev/null)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"; return 0
        fi
    done
    hostname -I 2>/dev/null | awk '{print $1}'
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
    [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        [[ $octet -lt 0 || $octet -gt 255 ]] && return 1
    done
    return 0
}

# NEW: Validate IPv6 address
validate_ipv6() {
    local ip=$1
    # Basic IPv6 validation
    if [[ $ip =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]] || [[ $ip =~ ^([0-9a-fA-F]{0,4}:){1,6}:[0-9a-fA-F]{0,4}$ ]]; then
        return 0
    fi
    # IPv6 with :: (compressed)
    if [[ $ip == *"::"* ]] && [[ $ip =~ ^([0-9a-fA-F]*:){0,7}:[0-9a-fA-F]*(:[0-9a-fA-F]+){0,6}$ ]]; then
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

normalize_port() {
    local input="$1"
    input=$(echo "$input" | tr -cd '0-9')
    [[ "$input" =~ ^[1-9][0-9]{0,4}$ && "$input" -le 65535 ]] && echo "$input" || echo ""
}

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
    done

    if (( dangerous > 0 )); then
        print_error "❌ Configuration aborted due to loop detection."
        pause
        return 1
    fi
    print_success "No traffic loops detected ✓"
    return 0
}

get_latest_paqet_version() {
    local version=$(curl -s --max-time 10 "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
    [ -n "$version" ] && echo "$version" || echo "v1.0.0-alpha.16"
}

get_all_paqet_services() {
    systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | \
        grep -E '^paqet-.*\.service' | awk '{print $1}' || true
}

# ================================================
# SILENT AUTO-INSTALL (No prompts)
# ================================================
install_dependencies_silent() {
    print_step "Auto-installing dependencies..."
    local os=$(detect_os)
    
    case $os in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            apt update -qq >/dev/null 2>&1
            apt install -y curl wget libpcap-dev iptables lsof iproute2 cron dnsutils iptables-persistent >/dev/null 2>&1
            ;;
        centos|rhel|fedora|rocky|almalinux)
            yum install -y curl wget libpcap-devel iptables lsof iproute cronie bind-utils iptables-services >/dev/null 2>&1
            systemctl enable iptables 2>/dev/null
            ;;
    esac
    
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/30-ip_forward.conf
    
    print_success "Dependencies installed"
}

install_paqet_silent() {
    [ -f "$BIN_DIR/paqet" ] && { print_success "Paqet already installed"; return 0; }
    
    print_step "Auto-installing Paqet core..."
    local arch=$(detect_arch)
    local latest=$(get_latest_paqet_version)
    
    local arch_name=""
    case $arch in
        amd64) arch_name="amd64" ;;
        arm64) arch_name="arm64" ;;
        armv7) arch_name="arm32" ;;
        386) arch_name="386" ;;
        *) arch_name="$arch" ;;
    esac
    
    local url="https://github.com/${GITHUB_REPO}/releases/download/${latest}/paqet-linux-${arch_name}-${latest}.tar.gz"
    print_info "Downloading $latest for $arch_name..."
    
    if ! curl -fsSL --retry 3 --retry-delay 2 "$url" -o "/tmp/paqet.tar.gz" 2>/dev/null; then
        print_error "Download failed"
        return 1
    fi
    
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR"/*
    
    if ! tar -xzf /tmp/paqet.tar.gz -C "$INSTALL_DIR" 2>/dev/null; then
        print_error "Extraction failed"
        rm -f /tmp/paqet.tar.gz
        return 1
    fi
    
    local binary=$(find "$INSTALL_DIR" -type f -name "*paqet*" | head -1)
    [ -z "$binary" ] && binary=$(find "$INSTALL_DIR" -type f -executable | head -1)
    
    if [ -n "$binary" ]; then
        cp "$binary" "$BIN_DIR/paqet"
        chmod +x "$BIN_DIR/paqet"
        print_success "Paqet installed"
    else
        print_error "Binary not found"
        rm -f /tmp/paqet.tar.gz
        return 1
    fi
    
    rm -f /tmp/paqet.tar.gz
    return 0
}

ensure_paqet_ready() {
    install_dependencies_silent
    install_paqet_silent || return 1
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

add_auto_restart_cronjob() {
    local service_name="$1"
    local cron_interval="$2"
    local cron_command="systemctl restart ${service_name}"
    local cron_line="${RESTART_INTERVALS[$cron_interval]} $cron_command"
    [ -z "$cron_line" ] && return 1
    crontab -l 2>/dev/null | grep -v "$cron_command" | crontab - 2>/dev/null
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
    print_success "Cronjob added: $cron_interval restart"
}

save_iptables() {
    command -v iptables-save &>/dev/null || return 1
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null
    chmod 600 /etc/iptables/rules.v4 2>/dev/null
}

# ================================================
# QUICK SETUP SERVER (NO IPv4/IPv6 question)
# ================================================
quick_setup_server() {
    clear; show_banner
    echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║ Quick Server Setup (Kharej - Auto-Install)    ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}\n"
    
    ensure_paqet_ready || { print_error "Setup failed"; pause; return 1; }
    get_network_info
    local public_ip=$(get_public_ip)
    
    echo -e "${CYAN}Network:${NC} $NETWORK_INTERFACE | ${CYAN}IP:${NC} $LOCAL_IP | ${CYAN}Public:${NC} $public_ip\n"
    
    # AUTO: Tunnel Name
    local config_name="$DEFAULT_CONFIG_NAME"
    echo -e "${YELLOW}[✓] Tunnel Name:${NC} ${GREEN}$config_name${NC} (auto)"
    
    # AUTO: Secret Key
    local secret_key="$DEFAULT_SECRET_KEY"
    echo -e "${YELLOW}[✓] Secret Key:${NC} ${GREEN}$secret_key${NC} (auto)"
    
    # ASK: Listen Port
    echo -en "\n${YELLOW}[?] Listen Port [$DEFAULT_LISTEN_PORT]: ${NC}"
    read -r port
    port="${port:-$DEFAULT_LISTEN_PORT}"
    if ! validate_port "$port"; then
        print_error "Invalid port"; return 1
    fi
    check_port_conflict "$port" || return 1
    
    # Summary
    echo -e "\n${CYAN}═══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}Configuration Summary:${NC}"
    echo -e "  • Tunnel Name: ${GREEN}$config_name${NC}"
    echo -e "  • Secret Key: ${GREEN}${secret_key:0:15}...${NC}"
    echo -e "  • Listen Port: ${GREEN}$port${NC}"
    echo -e "  • KCP Mode: ${GREEN}fast / MTU $DEFAULT_MTU${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}\n"
    
    read -p "Apply these settings? (Y/n): " confirm
    [[ "${confirm,,}" == "n" ]] && return 1
    
    configure_iptables "$port" "tcp"
    mkdir -p "$CONFIG_DIR"
    
    # Server config - uses IPv4 (simple, universal)
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
        
        echo -e "\n${GREEN}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║ ✅ Server Ready!                              ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}\n"
        
        echo -e "  ${CYAN}Tunnel Name:${NC}  $config_name"
        echo -e "  ${CYAN}Public IP:${NC}    $public_ip"
        echo -e "  ${CYAN}Port:${NC}         $port"
        echo -e "  ${CYAN}Secret:${NC}       ${GREEN}$secret_key${NC}"
        echo -e "\n${YELLOW}⚡ Save this Secret Key for client!${NC}"
        echo -e "${YELLOW}   $secret_key${NC}\n"
        pause
    else
        print_error "Service failed to start"
        systemctl status "$svc" --no-pager -l
        pause
    fi
}

# ================================================
# QUICK SETUP CLIENT (IPv4/IPv6 question for SERVER IP)
# ================================================
quick_setup_client() {
    clear; show_banner
    echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║ Quick Client Setup (Iran - Auto-Install)      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}\n"
    
    ensure_paqet_ready || { print_error "Setup failed"; pause; return 1; }
    get_network_info
    
    # AUTO: Tunnel Name
    local config_name="$DEFAULT_CONFIG_NAME"
    echo -e "${YELLOW}[✓] Tunnel Name:${NC} ${GREEN}$config_name${NC} (auto)"
    
    # AUTO: Secret Key
    local secret_key="$DEFAULT_SECRET_KEY"
    echo -e "${YELLOW}[✓] Secret Key:${NC} ${GREEN}$secret_key${NC} (auto)"
    
    # ASK: Server IP Version (Kharej server)
    echo -e "\n${CYAN}═══════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Select IP version of the remote server (Kharej):${NC}"
    echo -e "  [1] IPv4 (default - most common)"
    echo -e "  [2] IPv6 (if server uses IPv6 address)"
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}\n"
    read -p "Choose [1-2] (default 1): " ip_version
    ip_version="${ip_version:-1}"
    
    # ASK: Server IP (Kharej) - based on IP version
    local server_ip=""
    if [ "$ip_version" = "2" ]; then
        echo -en "\n${YELLOW}[?] Server IPv6 Address (Kharej): ${NC}"
        read -r server_ip
        [ -z "$server_ip" ] && { print_error "IPv6 address required"; return 1; }
        if ! validate_ipv6 "$server_ip"; then
            print_error "Invalid IPv6 address format"
            print_info "Example: 2001:db8::1 or 2604:a880:2:d0::2a16:5001"
            return 1
        fi
    else
        echo -en "\n${YELLOW}[?] Server IPv4 Address (Kharej): ${NC}"
        read -r server_ip
        [ -z "$server_ip" ] && { print_error "Server IP required"; return 1; }
        if ! validate_ip "$server_ip"; then
            print_error "Invalid IPv4 address format"
            return 1
        fi
    fi
    
    # ASK: Server Port
    echo -en "${YELLOW}[?] Server Port [$DEFAULT_LISTEN_PORT]: ${NC}"
    read -r server_port
    server_port="${server_port:-$DEFAULT_LISTEN_PORT}"
    validate_port "$server_port" || { print_error "Invalid port"; return 1; }
    
    # Build server address based on IP version
    local server_addr=""
    if [ "$ip_version" = "2" ]; then
        # IPv6: wrap in brackets
        server_addr="[$server_ip]:$server_port"
        echo -e "${GREEN}✓ Server Endpoint:${NC} $server_addr"
    else
        # IPv4: standard format
        server_addr="$server_ip:$server_port"
        echo -e "${GREEN}✓ Server Endpoint:${NC} $server_addr"
    fi
    
    # ASK: Forward Ports (with comma)
    echo -e "\n${YELLOW}Forward Ports Configuration:${NC}"
    echo -e "${CYAN}Enter the ports you want to tunnel (comma-separated)${NC}"
    echo -e "${CYAN}Example: 1080,443,8443,2053${NC}\n"
    echo -en "${YELLOW}[?] Enter forward port(s): ${NC}"
    read -r forward_ports
    
    forward_ports=$(clean_port_list "$forward_ports")
    if [ -z "$forward_ports" ]; then
        print_warning "Using default: $DEFAULT_V2RAY_PORTS"
        forward_ports="$DEFAULT_V2RAY_PORTS"
    fi
    echo -e "${GREEN}✓ Forward ports:${NC} $forward_ports"
    
    traffic_type="1"
    validate_forward_rules || return 1
    
    # ASK: Protocol for each port
    echo -e "\n${CYAN}Protocol Selection for each port:${NC}"
    echo -e "  [1] TCP (default)"
    echo -e "  [2] UDP"
    echo -e "  [3] TCP + UDP (both)"
    
    local forward_entries=""
    IFS=',' read -ra PORTS <<< "$forward_ports"
    for p in "${PORTS[@]}"; do
        p=$(echo "$p" | tr -d '[:space:]')
        echo -en "${YELLOW}Port $p → protocol [1-3] (default 1): ${NC}"
        read -r proto_choice
        proto_choice="${proto_choice:-1}"
        
        case $proto_choice in
            1) forward_entries+="  - listen: \"0.0.0.0:$p\"
    target: \"127.0.0.1:$p\"
    protocol: \"tcp\"
" ;;
            2) forward_entries+="  - listen: \"0.0.0.0:$p\"
    target: \"127.0.0.1:$p\"
    protocol: \"udp\"
" ;;
            3) forward_entries+="  - listen: \"0.0.0.0:$p\"
    target: \"127.0.0.1:$p\"
    protocol: \"tcp\"
  - listen: \"0.0.0.0:$p\"
    target: \"127.0.0.1:$p\"
    protocol: \"udp\"
" ;;
        esac
    done
    
    # Summary
    echo -e "\n${CYAN}═══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}Configuration Summary:${NC}"
    echo -e "  • Tunnel Name: ${GREEN}$config_name${NC}"
    echo -e "  • Server: ${GREEN}$server_addr${NC}"
    echo -e "  • Forward: ${GREEN}$forward_ports${NC}"
    echo -e "  • KCP: ${GREEN}fast / MTU $DEFAULT_MTU${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}\n"
    
    read -p "Apply these settings? (Y/n): " confirm
    [[ "${confirm,,}" == "n" ]] && return 1
    
    mkdir -p "$CONFIG_DIR"
    
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
  addr: "$server_addr"
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
        
        echo -e "\n${GREEN}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║ ✅ Client Ready - Tunnel Established!         ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}\n"
        
        echo -e "  ${CYAN}Tunnel Name:${NC}  $config_name"
        echo -e "  ${CYAN}Server:${NC}       $server_addr"
        echo -e "  ${CYAN}Forward:${NC}      $forward_ports\n"
        pause
    else
        print_error "Client failed to start"
        systemctl status "$svc" --no-pager -l
        pause
    fi
}

# ================================================
# SERVICE MANAGEMENT
# ================================================
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
            echo -e "\n${GREEN}Managing: $name${NC}"
            echo " 1. Start  2. Stop  3. Restart  4. Status  5. Logs  6. Delete  0. Back"
            read -p "Choose: " action
            case "$action" in
                0) ;;
                1) systemctl start "$svc"; print_success "Started"; sleep 1 ;;
                2) systemctl stop "$svc"; print_success "Stopped"; sleep 1 ;;
                3) systemctl restart "$svc"; print_success "Restarted"; sleep 1 ;;
                4) systemctl status "$svc" --no-pager -l; pause ;;
                5) journalctl -u "$svc" -n 25 --no-pager; pause ;;
                6) read -p "Delete? (y/N): " c
                   if [[ "$c" =~ ^[Yy]$ ]]; then
                       systemctl stop "$svc" 2>/dev/null
                       rm -f "$SERVICE_DIR/$svc" "$CONFIG_DIR/$name.yaml"
                       systemctl daemon-reload
                       print_success "Deleted"
                   fi ;;
            esac
        fi
    done
}

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
        echo " 1. Start All  2. Stop All  3. Restart All  4. Delete All  0. Back"
        read -p "Choose: " choice
        
        case $choice in
            0) return ;;
            1) for svc in "${services[@]}"; do systemctl start "$svc" 2>/dev/null; done; print_success "Started"; pause ;;
            2) for svc in "${services[@]}"; do systemctl stop "$svc" 2>/dev/null; done; print_success "Stopped"; pause ;;
            3) for svc in "${services[@]}"; do systemctl restart "$svc" 2>/dev/null; done; print_success "Restarted"; pause ;;
            4) read -p "Type 'yes' to confirm: " confirm
               if [ "$confirm" = "yes" ]; then
                   for svc in "${services[@]}"; do
                       local name="${svc#paqet-}"; name="${name%.service}"
                       systemctl stop "$svc" 2>/dev/null
                       rm -f "$SERVICE_DIR/$svc" "$CONFIG_DIR/$name.yaml"
                   done
                   systemctl daemon-reload
                   print_success "All deleted"
               fi
               pause ;;
        esac
    done
}

test_connection() {
    clear; show_banner
    echo -e "${GREEN}Connection Tests${NC}\n"
    echo -en "Remote Server IP: "
    read -r remote_ip
    echo -e "\n${YELLOW}Testing $remote_ip...${NC}\n"
    local ping_output=$(ping -c 5 -W 2 "$remote_ip" 2>&1)
    local packet_loss=$(echo "$ping_output" | grep -o "[0-9]*% packet loss" | grep -o "[0-9]*" || echo "100")
    local avg_ping=$(echo "$ping_output" | grep "rtt" | awk -F'/' '{print $5}' 2>/dev/null)
    echo -e "  ICMP: Loss=${packet_loss}% RTT=${avg_ping:-N/A}ms"
    pause
}

optimize_server() {
    clear; show_banner
    echo -e "${GREEN}Apply Kernel Optimizations?${NC}\n"
    read -p "Continue? (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    
    mkdir -p "$BACKUP_DIR"
    
    cat > "$SYSCTL_FILE" << 'EOF'
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
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
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
EOF
    
    print_success "Optimizations applied! Reboot recommended."
    pause
}

uninstall_paqet() {
    clear; show_banner
    echo -e "${RED}Uninstall Paqet?${NC}"
    read -p "Confirm (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    
    local services=()
    mapfile -t services < <(get_all_paqet_services)
    for svc in "${services[@]}"; do
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
# MAIN MENU
# ================================================
main_menu() {
    while true; do
        clear; show_banner
        
        if [ -f "$BIN_DIR/paqet" ]; then
            local ver=$("$BIN_DIR/paqet" version 2>/dev/null | grep "^Version:" | head -1 | cut -d':' -f2 | xargs)
            echo -e "${GREEN}✅ Paqet installed${NC} ${CYAN}${ver:-unknown}${NC}"
        else
            echo -e "${YELLOW}⚠️ Paqet not installed (will auto-install)${NC}"
        fi
        echo ""
        
        echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║              MAIN MENU (v${SCRIPT_VERSION})                ║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║${NC} ${GREEN}QUICK SETUP (Auto-Install)${NC}                      ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  Q1. ⚡ Quick Server Setup (Kharej)             ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  Q2. ⚡ Quick Client Setup (Iran)               ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}                                                 ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC} ${YELLOW}MANAGEMENT${NC}                                      ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  3. 🛠️  Manage Services                         ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  4. 🔄 Manage All Services                     ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  5. 📊 Test Connection                         ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  6. 🚀 Optimize Server                         ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  7. 🗑️  Uninstall                               ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  0. 🚪 Exit                                    ${CYAN}║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
        echo ""
        read -p "Select: " choice
        
        case $choice in
            [Qq]1|q1) quick_setup_server ;;
            [Qq]2|q2) quick_setup_client ;;
            3) manage_services ;;
            4) manage_all_services ;;
            5) test_connection ;;
            6) optimize_server ;;
            7) uninstall_paqet ;;
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
