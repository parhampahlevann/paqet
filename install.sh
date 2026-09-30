#!/bin/bash
#=================================================
# Paqet Tunnel Manager
# Version: 8.0
# Raw-packet KCP tunnel manager (Iran client <-> Kharej server)
#=================================================

export LC_ALL=C
set -o pipefail

# ------------------------------------------------
# COLORS (plain ANSI, no emoji)
# ------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'

# ------------------------------------------------
# CONSTANTS
# ------------------------------------------------
readonly SCRIPT_VERSION="8.0"
readonly GITHUB_REPO="hanselime/paqet"
readonly FALLBACK_VERSION="v1.0.0-alpha.16"
readonly CONFIG_DIR="/etc/paqet"
readonly SERVICE_DIR="/etc/systemd/system"
readonly BIN_DIR="/usr/local/bin"
readonly BACKUP_DIR="/root/paqet-backups"
readonly CRON_DIR="/etc/cron.d"
readonly SYSCTL_FILE="/etc/sysctl.d/99-paqet-tunnel.conf"
readonly LIMITS_FILE="/etc/security/limits.d/99-paqet.conf"

# ------------------------------------------------
# DEFAULTS (used when you just press Enter)
# ------------------------------------------------
readonly DEFAULT_CONFIG_NAME="fghj"
readonly DEFAULT_SECRET_KEY="pQwOPDE5zQq3xaC2UFvnCpmDqyxB1lin"
readonly DEFAULT_LISTEN_PORT="8888"
readonly DEFAULT_KCP_MODE="fast"
readonly DEFAULT_ENCRYPTION="aes-128-gcm"
readonly DEFAULT_CONNECTIONS="2"
readonly DEFAULT_MTU="1300"
readonly DEFAULT_AUTO_RESTART="6hour"
readonly DEFAULT_FORWARD_PORTS="9090"

# Ports that must never be used as the tunnel port: the firewall rules
# (NOTRACK / RST drop) would break normal traffic on them.
readonly RESERVED_PORTS=" 20 21 22 25 53 80 110 143 443 465 587 993 995 3306 5432 "

declare -A RESTART_CRON=(
    ["1hour"]="0 * * * *"
    ["3hour"]="0 */3 * * *"
    ["6hour"]="0 */6 * * *"
    ["12hour"]="0 */12 * * *"
    ["1day"]="0 4 * * *"
)

# Detected network values (filled by detect_network)
NETWORK_INTERFACE=""
LOCAL_IP=""
GATEWAY_IP=""
GATEWAY_MAC=""
PKG_MGR=""

# ================================================
# UTILITY FUNCTIONS
# ================================================
print_step()    { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[+]${NC} $1"; }
print_error()   { echo -e "${RED}[-]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info()    { echo -e "${CYAN}[i]${NC} $1"; }

pause() {
    echo ""
    read -r -p "${1:-Press Enter to continue...}" _ </dev/tty || true
}

# ask VAR "prompt" [default]  - always reads from the terminal
ask() {
    local __v=""
    echo -en "${YELLOW}$2${NC}"
    if ! IFS= read -r __v </dev/tty; then
        echo ""
        exit 0
    fi
    __v="${__v//$'\r'/}"
    __v="${__v#"${__v%%[![:space:]]*}"}"
    __v="${__v%"${__v##*[![:space:]]}"}"
    printf -v "$1" '%s' "${__v:-$3}"
}

# confirm "question" [y|n]  - returns 0 for yes
confirm() {
    local def="${2:-y}" hint="[Y/n]" ans=""
    [ "$def" = "n" ] && hint="[y/N]"
    ask ans "$1 $hint: " "$def"
    [[ "${ans,,}" == y* ]]
}

show_banner() {
    clear 2>/dev/null || true
    echo -e "${MAGENTA}"
    echo "=================================================="
    echo "          Paqet Tunnel Manager v${SCRIPT_VERSION}"
    echo "      Raw-packet KCP tunnel (Iran <-> Kharej)"
    echo "=================================================="
    echo -e "${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        print_error "systemd (systemctl) is required"
        exit 1
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armhf)  echo "armv7" ;;
        i386|i686)     echo "386" ;;
        *)             uname -m ;;
    esac
}

# ================================================
# VALIDATION
# ================================================
validate_ipv4() {
    local ip="$1" o
    [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}

validate_ipv6() {
    local ip="${1//[\[\]]/}" n groups g c=0
    [[ $ip == *:* ]] || return 1
    [[ $ip =~ ^[0-9a-fA-F:]+$ ]] || return 1
    [[ $ip == *":::"* ]] && return 1
    [[ $ip == :* && $ip != ::* ]] && return 1
    [[ $ip == *: && $ip != *:: ]] && return 1
    n=$(grep -o '::' <<<"$ip" | wc -l)
    (( n <= 1 )) || return 1
    IFS=: read -ra groups <<<"$ip"
    for g in "${groups[@]}"; do
        [ -z "$g" ] && continue
        (( ${#g} <= 4 )) || return 1
        c=$((c + 1))
    done
    if (( n == 0 )); then
        (( c == 8 )) || return 1
    else
        (( c <= 7 )) || return 1
    fi
    return 0
}

validate_mac() {
    [[ "$1" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# Prints a cleaned, de-duplicated, comma separated list of valid ports
clean_port_list() {
    local list="${1//[[:space:]]/}" p out="" seen=","
    local -a arr
    IFS=',' read -ra arr <<<"$list"
    for p in "${arr[@]}"; do
        [ -z "$p" ] && continue
        if validate_port "$p"; then
            p=$((10#$p))
            [[ "$seen" == *",$p,"* ]] && continue
            seen+="$p,"
            out="${out:+$out,}$p"
        else
            print_warning "Invalid port '$p' removed" >&2
        fi
    done
    echo "$out"
}

port_in_use() {  # port proto(tcp|udp)
    local flag="-lnt"
    [ "$2" = "udp" ] && flag="-lnu"
    ss -H $flag 2>/dev/null | awk -v p="$1" '$4 ~ (":" p "$") {f=1} END{exit !f}'
}

port_owner() {  # port
    ss -H -lntup 2>/dev/null | awk -v p="$1" '$5 ~ (":" p "$") {print $7; exit}' \
        | sed -E 's/users:\(\("([^"]*)",pid=([0-9]+).*/\1 (pid \2)/'
}

generate_key() {
    head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32
}

# ================================================
# PACKAGES / DEPENDENCIES
# ================================================
detect_pkg_mgr() {
    if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"
    else PKG_MGR=""
    fi
}

pkg_install() {
    case "$PKG_MGR" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1 ;;
        dnf) dnf install -y -q "$@" >/dev/null 2>&1 ;;
        yum) yum install -y -q "$@" >/dev/null 2>&1 ;;
        *)   return 1 ;;
    esac
}

dep_pkg_name() {  # command -> package name
    if [ "$PKG_MGR" = "apt" ]; then
        case "$1" in
            ip|ss) echo "iproute2" ;;
            ping)  echo "iputils-ping" ;;
            *)     echo "$1" ;;
        esac
    else
        case "$1" in
            ip|ss)  echo "iproute" ;;
            ping)   echo "iputils" ;;
            *)      echo "$1" ;;
        esac
    fi
}

install_dependencies() {
    print_step "Checking dependencies..."
    detect_pkg_mgr
    local need=() cmd
    for cmd in curl tar ip ss iptables ping; do
        command -v "$cmd" >/dev/null 2>&1 || need+=("$cmd")
    done

    if [ ${#need[@]} -gt 0 ]; then
        print_step "Installing missing packages: ${need[*]}"
        if [ -z "$PKG_MGR" ]; then
            print_error "No supported package manager found (apt/dnf/yum). Install manually: ${need[*]}"
            return 1
        fi
        if [ "$PKG_MGR" = "apt" ]; then
            timeout 180 apt-get update -qq -o Acquire::Retries=1 -o Acquire::http::Timeout=15 >/dev/null 2>&1 \
                || print_warning "apt update failed or timed out (mirror problem?), trying to install anyway"
        fi
        for cmd in "${need[@]}"; do
            pkg_install "$(dep_pkg_name "$cmd")" || print_warning "Could not install package for '$cmd'"
        done
    fi

    for cmd in curl tar ip ss iptables; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            print_error "Required command is still missing: $cmd"
            print_info "Fix the package mirror / DNS on this server, then run again."
            return 1
        fi
    done
    print_success "Dependencies OK"
    return 0
}

ensure_cron() {
    if systemctl list-unit-files 2>/dev/null | grep -qE '^(cron|crond)\.service'; then
        :
    else
        detect_pkg_mgr
        if [ "$PKG_MGR" = "apt" ]; then pkg_install cron; else pkg_install cronie; fi
    fi
    local u
    for u in cron crond; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${u}\.service"; then
            systemctl enable --now "$u" >/dev/null 2>&1 || true
            return 0
        fi
    done
    print_warning "cron service not found, auto-restart will not work"
    return 1
}

# ================================================
# PAQET BINARY INSTALL
# ================================================
is_elf() {
    [ -f "$1" ] && [ "$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]
}

fix_missing_libs() {
    ldd "$BIN_DIR/paqet" 2>&1 | grep -q 'not found' || return 0
    print_warning "Paqet needs libpcap, installing..."
    detect_pkg_mgr
    local p
    for p in libpcap0.8t64 libpcap0.8 libpcap libpcap-dev; do
        pkg_install "$p" && break
    done
}

# Extract the paqet ELF binary from an archive (or a raw binary) and install it
install_binary_from_file() {
    local src="$1" tmp bin="" f rc
    tmp=$(mktemp -d /tmp/paqet.XXXXXX) || return 1

    if is_elf "$src"; then
        cp "$src" "$tmp/paqet_bin"
    elif ! tar -xzf "$src" -C "$tmp" 2>/dev/null; then
        print_error "File is neither an ELF binary nor a valid .tar.gz archive"
        rm -rf "$tmp"
        return 1
    fi

    while IFS= read -r f; do
        if is_elf "$f"; then bin="$f"; break; fi
    done < <(find "$tmp" -type f -name '*paqet*' 2>/dev/null | sort)

    if [ -z "$bin" ]; then
        while IFS= read -r f; do
            if is_elf "$f"; then bin="$f"; break; fi
        done < <(find "$tmp" -type f 2>/dev/null | sort)
    fi

    if [ -z "$bin" ]; then
        print_error "No executable binary found inside the archive"
        rm -rf "$tmp"
        return 1
    fi

    chmod +x "$bin"
    timeout 10 "$bin" version >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
        print_error "Binary cannot run on this system (exit code $rc): wrong CPU architecture or missing library"
        rm -rf "$tmp"
        return 1
    fi

    mkdir -p "$BIN_DIR"
    if ! install -m 755 "$bin" "$BIN_DIR/paqet.new" || ! mv -f "$BIN_DIR/paqet.new" "$BIN_DIR/paqet"; then
        print_error "Could not write $BIN_DIR/paqet"
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"
    fix_missing_libs
    return 0
}

# Prints candidate download URLs, best first
find_release_urls() {
    local arch pat an api tag t
    arch=$(detect_arch)
    case "$arch" in
        amd64) pat='amd64|x86_64'; an="amd64" ;;
        arm64) pat='arm64|aarch64'; an="arm64" ;;
        armv7) pat='arm32|armv7|armhf|arm'; an="arm32" ;;
        386)   pat='386|i386|i686'; an="386" ;;
        *)     pat="$arch"; an="$arch" ;;
    esac

    # /releases (not /releases/latest) so that pre-releases are included
    api=$(curl -fsSL --connect-timeout 8 --max-time 20 \
        "https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=5" 2>/dev/null)
    if [ -n "$api" ]; then
        printf '%s\n' "$api" | grep -oE '"browser_download_url": *"[^"]+"' | cut -d'"' -f4 \
            | grep -iE 'linux' | grep -iE "(${pat})" | grep -iE '\.(tar\.gz|tgz)$'
    fi

    tag=$(curl -fsSLI --connect-timeout 8 --max-time 15 -o /dev/null -w '%{url_effective}' \
        "https://github.com/${GITHUB_REPO}/releases/latest" 2>/dev/null | sed -n 's#.*/tag/##p')
    for t in "$tag" "$FALLBACK_VERSION"; do
        [ -n "$t" ] && echo "https://github.com/${GITHUB_REPO}/releases/download/${t}/paqet-linux-${an}-${t}.tar.gz"
    done
}

download_and_install_paqet() {
    local url tmpf
    tmpf=$(mktemp /tmp/paqet-dl.XXXXXX) || return 1
    while IFS= read -r url; do
        [ -z "$url" ] && continue
        print_info "Downloading: $url"
        if curl -fL --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 240 -o "$tmpf" "$url" 2>/dev/null; then
            if install_binary_from_file "$tmpf"; then
                rm -f "$tmpf"
                return 0
            fi
        else
            print_warning "Download failed"
        fi
    done < <(find_release_urls | awk '!seen[$0]++')
    rm -f "$tmpf"
    return 1
}

manual_install_paqet() {
    echo ""
    print_info "Give a direct download URL or a local file path."
    print_info "Accepted: paqet .tar.gz release archive, or the raw paqet binary."
    print_info "If GitHub is blocked here: download the release on another machine and upload it with scp."
    local src tmpf
    ask src "URL or local path (empty = cancel): " ""
    [ -z "$src" ] && return 1

    if [[ "$src" =~ ^https?:// ]]; then
        tmpf=$(mktemp /tmp/paqet-dl.XXXXXX) || return 1
        if curl -fL --retry 2 --connect-timeout 10 --max-time 300 -o "$tmpf" "$src" 2>/dev/null; then
            install_binary_from_file "$tmpf"
            local rc=$?
            rm -f "$tmpf"
            return $rc
        fi
        rm -f "$tmpf"
        print_error "Download failed"
        return 1
    elif [ -f "$src" ]; then
        install_binary_from_file "$src"
    else
        print_error "File not found: $src"
        return 1
    fi
}

install_paqet() {  # [force]
    local rc
    if [ -x "$BIN_DIR/paqet" ] && [ "$1" != "force" ]; then
        timeout 10 "$BIN_DIR/paqet" version >/dev/null 2>&1
        rc=$?
        if [ "$rc" -ne 126 ] && [ "$rc" -ne 127 ]; then
            print_success "Paqet binary is installed"
            return 0
        fi
        print_warning "Installed paqet binary does not run, reinstalling"
    fi

    print_step "Installing Paqet binary..."
    if download_and_install_paqet; then
        print_success "Paqet installed"
        return 0
    fi
    print_error "Automatic download failed (GitHub blocked or slow from this server?)"
    if manual_install_paqet; then
        print_success "Paqet installed"
        return 0
    fi
    return 1
}

ensure_paqet_ready() {
    install_dependencies || return 1
    install_paqet || return 1
    return 0
}

# ================================================
# NETWORK DETECTION
# ================================================
field_after() {  # field_after KEY  (stdin: one line)
    awk -v k="$1" '{for(i=1;i<NF;i++) if($i==k){print $(i+1); exit}}'
}

find_mac_in() {
    grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1 | tr 'A-F' 'a-f'
}

resolve_gateway_mac() {  # ver gateway iface
    local ver="$1" gw="$2" iface="$3" mac="" i
    [ -z "$gw" ] && return 1
    for i in 1 2 3; do
        ping -"$ver" -c 1 -W 1 -I "$iface" "$gw" >/dev/null 2>&1 || true
        mac=$(ip -"$ver" neigh show "$gw" dev "$iface" 2>/dev/null | find_mac_in)
        if [ -n "$mac" ]; then echo "$mac"; return 0; fi
        sleep 1
    done
    if [ "$ver" = "4" ] && command -v arping >/dev/null 2>&1; then
        mac=$(arping -c 2 -w 3 -I "$iface" "$gw" 2>/dev/null | find_mac_in)
        [ -z "$mac" ] && mac=$(arping -c 2 -i "$iface" "$gw" 2>/dev/null | find_mac_in)
        if [ -n "$mac" ]; then echo "$mac"; return 0; fi
    fi
    if [ "$ver" = "4" ] && command -v arp >/dev/null 2>&1; then
        mac=$(arp -n "$gw" 2>/dev/null | find_mac_in)
        if [ -n "$mac" ]; then echo "$mac"; return 0; fi
    fi
    return 1
}

detect_network() {  # ver (4|6)
    local ver="$1" route probe
    NETWORK_INTERFACE=""; LOCAL_IP=""; GATEWAY_IP=""; GATEWAY_MAC=""
    command -v ip >/dev/null 2>&1 || return 1

    if [ "$ver" = "6" ]; then probe="2606:4700:4700::1111"; else probe="1.1.1.1"; fi

    route=$(ip -"$ver" route get "$probe" 2>/dev/null | head -1)
    NETWORK_INTERFACE=$(field_after dev <<<"$route")
    LOCAL_IP=$(field_after src <<<"$route")
    GATEWAY_IP=$(field_after via <<<"$route")

    if [ -z "$NETWORK_INTERFACE" ]; then
        route=$(ip -"$ver" route show default 2>/dev/null | head -1)
        NETWORK_INTERFACE=$(field_after dev <<<"$route")
        GATEWAY_IP=$(field_after via <<<"$route")
    fi
    if [ -z "$LOCAL_IP" ] && [ -n "$NETWORK_INTERFACE" ]; then
        LOCAL_IP=$(ip -"$ver" -o addr show dev "$NETWORK_INTERFACE" scope global 2>/dev/null \
            | awk '{print $4}' | cut -d/ -f1 | head -1)
    fi
    if [ -n "$GATEWAY_IP" ] && [ -n "$NETWORK_INTERFACE" ]; then
        GATEWAY_MAC=$(resolve_gateway_mac "$ver" "$GATEWAY_IP" "$NETWORK_INTERFACE")
    fi
    return 0
}

manual_network() {  # ver
    local ver="$1" ok=0
    echo ""
    print_info "Enter the values manually. Helpful commands:"
    print_info "  ip route get 1.1.1.1      (interface, local IP, gateway)"
    print_info "  ip neigh show             (gateway MAC address)"
    ask NETWORK_INTERFACE "Interface [${NETWORK_INTERFACE}]: " "$NETWORK_INTERFACE"
    ask LOCAL_IP "Local IPv${ver} address [${LOCAL_IP}]: " "$LOCAL_IP"
    ask GATEWAY_MAC "Gateway MAC (aa:bb:cc:dd:ee:ff) [${GATEWAY_MAC}]: " "$GATEWAY_MAC"
    GATEWAY_MAC="${GATEWAY_MAC,,}"
    LOCAL_IP="${LOCAL_IP//[\[\]]/}"

    if [ ! -d "/sys/class/net/$NETWORK_INTERFACE" ]; then
        print_error "Interface '$NETWORK_INTERFACE' does not exist"; ok=1
    fi
    if [ "$ver" = "6" ]; then
        validate_ipv6 "$LOCAL_IP" || { print_error "Invalid IPv6 address"; ok=1; }
    else
        validate_ipv4 "$LOCAL_IP" || { print_error "Invalid IPv4 address"; ok=1; }
    fi
    validate_mac "$GATEWAY_MAC" || { print_error "Invalid MAC address"; ok=1; }
    return $ok
}

confirm_network() {  # ver
    local ver="$1"
    print_step "Detecting network settings (IPv${ver})..."
    detect_network "$ver"
    while true; do
        echo ""
        echo "  Interface   : ${NETWORK_INTERFACE:-<not found>}"
        echo "  Local IP    : ${LOCAL_IP:-<not found>}"
        echo "  Gateway IP  : ${GATEWAY_IP:-<not found>}"
        echo "  Gateway MAC : ${GATEWAY_MAC:-<not found>}"
        echo ""
        if [ -n "$NETWORK_INTERFACE" ] && [ -n "$LOCAL_IP" ] && validate_mac "$GATEWAY_MAC"; then
            confirm "Use these values?" y && return 0
        else
            print_warning "Some values could not be detected automatically."
        fi
        if ! manual_network "$ver"; then
            confirm "Try again?" y || return 1
        fi
    done
}

get_public_ip() {  # ver
    local ver="${1:-4}" svc ip
    for svc in api.ipify.org ifconfig.me icanhazip.com; do
        ip=$(curl -"$ver" -s --max-time 4 "https://$svc" 2>/dev/null | tr -d '[:space:]')
        if [ "$ver" = "6" ]; then
            validate_ipv6 "$ip" && { echo "$ip"; return 0; }
        else
            validate_ipv4 "$ip" && { echo "$ip"; return 0; }
        fi
    done
    echo "$LOCAL_IP"
}

# ================================================
# CONFIG / FIREWALL / SERVICE WRITERS
# ================================================
net_block() {  # ver iface ip port mac
    local ver="$1" iface="$2" ip="$3" port="$4" mac="$5" blk addr
    if [ "$ver" = "6" ]; then blk="ipv6"; addr="[$ip]:$port"; else blk="ipv4"; addr="$ip:$port"; fi
    printf 'network:\n  interface: "%s"\n  %s:\n    addr: "%s"\n    router_mac: "%s"\n' \
        "$iface" "$blk" "$addr" "$mac"
}

transport_block() {  # key with_conn(yes|no)
    printf 'transport:\n  protocol: "kcp"\n'
    [ "$2" = "yes" ] && printf '  conn: %s\n' "$DEFAULT_CONNECTIONS"
    printf '  kcp:\n    mode: "%s"\n    block: "%s"\n    mtu: %s\n    key: "%s"\n' \
        "$DEFAULT_KCP_MODE" "$DEFAULT_ENCRYPTION" "$DEFAULT_MTU" "$1"
}

validate_yaml_file() {
    command -v python3 >/dev/null 2>&1 || return 0
    python3 -c 'import yaml' >/dev/null 2>&1 || return 0
    if ! python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$1" 2>/tmp/paqet-yaml.err; then
        print_error "Generated config is not valid YAML:"
        cat /tmp/paqet-yaml.err
        return 1
    fi
    return 0
}

backup_existing() {  # name
    local f="$CONFIG_DIR/$1.yaml"
    [ -f "$f" ] || return 0
    mkdir -p "$BACKUP_DIR"
    cp "$f" "$BACKUP_DIR/$1-$(date +%Y%m%d-%H%M%S).yaml" 2>/dev/null
}

# Firewall helper script, applied automatically every time the service starts
write_fw_script() {  # name role ver server_ip port
    local name="$1" role="$2" ver="$3" srv="$4" port="$5" ipt="iptables"
    [ "$ver" = "6" ] && ipt="ip6tables"
    {
        printf '#!/bin/bash\n# Generated by Paqet Tunnel Manager: firewall rules for tunnel %s\n' "$name"
        printf 'IPT="%s"\n' "$ipt"
        cat <<'EOF'
ACTION="${1:-apply}"
FAIL=0
command -v "$IPT" >/dev/null 2>&1 || { echo "$IPT not found"; exit 0; }
rule() {
    local tbl="$1" chain="$2"; shift 2
    case "$ACTION" in
        apply)
            "$IPT" -w -t "$tbl" -C "$chain" "$@" 2>/dev/null || "$IPT" -w -t "$tbl" -A "$chain" "$@" || FAIL=1 ;;
        remove)
            while "$IPT" -w -t "$tbl" -C "$chain" "$@" 2>/dev/null; do
                "$IPT" -w -t "$tbl" -D "$chain" "$@" || break
            done ;;
        check)
            if "$IPT" -w -t "$tbl" -C "$chain" "$@" 2>/dev/null; then
                echo "ok:      $tbl $chain $*"
            else
                echo "MISSING: $tbl $chain $*"; FAIL=1
            fi ;;
    esac
}
EOF
        if [ "$role" = "server" ]; then
            printf 'rule raw PREROUTING -p tcp --dport %s -j NOTRACK\n' "$port"
            printf 'rule raw OUTPUT -p tcp --sport %s -j NOTRACK\n' "$port"
            printf 'rule mangle OUTPUT -p tcp --sport %s --tcp-flags RST RST -j DROP\n' "$port"
        else
            printf 'rule raw PREROUTING -p tcp -s %s --sport %s -j NOTRACK\n' "$srv" "$port"
            printf 'rule raw OUTPUT -p tcp -d %s --dport %s -j NOTRACK\n' "$srv" "$port"
            printf 'rule mangle OUTPUT -p tcp -d %s --dport %s --tcp-flags RST RST -j DROP\n' "$srv" "$port"
        fi
        echo 'exit $FAIL'
    } > "$CONFIG_DIR/${name}.fw.sh"
    chmod 700 "$CONFIG_DIR/${name}.fw.sh"
}

run_fw() {  # name action
    [ -f "$CONFIG_DIR/$1.fw.sh" ] && bash "$CONFIG_DIR/$1.fw.sh" "$2"
}

create_systemd_service() {  # name
    local name="$1" svc="paqet-$1"
    cat > "$SERVICE_DIR/${svc}.service" <<EOF
[Unit]
Description=Paqet Tunnel (${name})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=-/bin/bash ${CONFIG_DIR}/${name}.fw.sh apply
ExecStart=${BIN_DIR}/paqet run -c ${CONFIG_DIR}/${name}.yaml
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

set_auto_restart() {  # service_name key|off
    local svc="$1" key="$2" f="$CRON_DIR/${1}-restart"
    rm -f "$f"
    # remove legacy crontab entries created by older versions
    if crontab -l 2>/dev/null | grep -q "systemctl restart ${svc}\$"; then
        crontab -l 2>/dev/null | grep -v "systemctl restart ${svc}\$" | crontab - 2>/dev/null
    fi
    [ "$key" = "off" ] && return 0
    [ -z "${RESTART_CRON[$key]}" ] && return 1
    ensure_cron || return 1
    mkdir -p "$CRON_DIR"
    printf 'SHELL=/bin/bash\nPATH=/usr/sbin:/usr/bin:/sbin:/bin\n%s root systemctl restart %s\n' \
        "${RESTART_CRON[$key]}" "$svc" > "$f"
    chmod 644 "$f"
    return 0
}

explain_failure() {  # service
    local log
    log=$(journalctl -u "$1" -n 60 --no-pager 2>/dev/null)
    echo ""
    local hit=0
    if grep -qiE 'address already in use|failed to bind' <<<"$log"; then
        print_warning "A port is already in use by another program. Free it or remove it from the config."; hit=1
    fi
    if grep -qiE 'yaml|unmarshal|invalid config|config' <<<"$log"; then
        print_warning "Config problem. View it from the tunnel menu (Show config) and check every value."; hit=1
    fi
    if grep -qiE 'mac' <<<"$log"; then
        print_warning "Gateway MAC problem. Re-run setup and enter the MAC manually (ip neigh show)."; hit=1
    fi
    if grep -qiE 'no such device|interface|device' <<<"$log"; then
        print_warning "Network interface problem. Check the interface name in the config."; hit=1
    fi
    if grep -qiE 'permission|not permitted' <<<"$log"; then
        print_warning "Permission problem. Raw packets need root, and some containers/VPS types block them."; hit=1
    fi
    if grep -qiE 'pcap|libpcap|shared libraries' <<<"$log"; then
        print_warning "libpcap problem. Try: apt install libpcap0.8 (or libpcap0.8t64)."; hit=1
    fi
    if [ "$hit" -eq 0 ]; then
        print_info "No known error pattern found. See full log: journalctl -u $1 -n 100 --no-pager"
    fi
}

start_and_verify() {  # service
    local svc="$1" i state="" restarts
    systemctl daemon-reload
    systemctl enable "$svc" >/dev/null 2>&1
    systemctl reset-failed "$svc" >/dev/null 2>&1 || true
    systemctl restart "$svc" >/dev/null 2>&1
    print_step "Waiting for the service to stabilize..."
    for i in 1 2 3 4 5 6; do
        sleep 1
        state=$(systemctl is-active "$svc" 2>/dev/null)
        [ "$state" != "active" ] && break
    done
    restarts=$(systemctl show "$svc" -p NRestarts --value 2>/dev/null)
    restarts="${restarts:-0}"
    if [ "$state" = "active" ] && [ "$restarts" = "0" ]; then
        print_success "Service $svc is running"
        return 0
    fi
    print_error "Service is not running correctly (state: ${state:-unknown}, restarts: $restarts)"
    echo ""
    journalctl -u "$svc" -n 15 --no-pager 2>/dev/null
    explain_failure "$svc"
    return 1
}

# Refuse / warn when a tunnel with this name already exists
handle_existing_tunnel() {  # name
    local name="$1" svc="paqet-$1"
    if [ -f "$CONFIG_DIR/$name.yaml" ] || [ -f "$SERVICE_DIR/$svc.service" ]; then
        print_warning "Tunnel '$name' already exists."
        confirm "Replace it? (old config will be backed up)" y || return 1
        backup_existing "$name"
        systemctl stop "$svc" >/dev/null 2>&1 || true
    fi
    return 0
}

ask_secret_key() {  # var_name allow_generate(yes|no)
    local k=""
    echo ""
    echo "Secret key (must be IDENTICAL on server and client):"
    echo "  Enter  = use the built-in default key"
    [ "$2" = "yes" ] && echo "  g      = generate a new random key"
    echo "  or type/paste your own key"
    ask k "Secret key: " ""
    case "$k" in
        "") k="$DEFAULT_SECRET_KEY" ;;
        g|G) if [ "$2" = "yes" ]; then k=$(generate_key); print_info "Generated key: $k"; fi ;;
    esac
    if [ "${#k}" -lt 8 ] || [[ "$k" == *\"* ]] || [[ "$k" == *\\* ]] || [[ "$k" == *[[:space:]]* ]]; then
        print_error "Key must be at least 8 characters, without spaces, quotes or backslashes"
        return 1
    fi
    printf -v "$1" '%s' "$k"
}

# ================================================
# SETUP: SERVER (KHAREJ)
# ================================================
quick_setup_server() {
    show_banner
    echo -e "${GREEN}Server Setup (Kharej / foreign server)${NC}\n"
    ensure_paqet_ready || { print_error "Preparation failed"; pause; return 1; }

    local name="$DEFAULT_CONFIG_NAME" svc="paqet-$DEFAULT_CONFIG_NAME"
    local cfg="$CONFIG_DIR/$DEFAULT_CONFIG_NAME.yaml"
    local ver_choice ver=4 port key public_ip owner

    handle_existing_tunnel "$name" || { pause; return 1; }

    echo ""
    echo "IP version used for the tunnel on this server:"
    echo "  1) IPv4 (default)"
    echo "  2) IPv6"
    ask ver_choice "Choose [1-2] (default 1): " "1"
    [ "$ver_choice" = "2" ] && ver=6

    confirm_network "$ver" || { print_error "Network setup cancelled"; pause; return 1; }

    while true; do
        ask port "Tunnel listen port [$DEFAULT_LISTEN_PORT] (0 = cancel): " "$DEFAULT_LISTEN_PORT"
        [ "$port" = "0" ] && return 1
        if ! validate_port "$port"; then print_error "Invalid port"; continue; fi
        port=$((10#$port))
        if [[ "$RESERVED_PORTS" == *" $port "* ]]; then
            print_error "Port $port is a standard service port. Paqet's firewall rules would break it. Choose another (e.g. 8888)."
            continue
        fi
        if port_in_use "$port" tcp; then
            owner=$(port_owner "$port")
            print_error "Port $port is already used by: ${owner:-another program}. Choose another port."
            continue
        fi
        break
    done

    ask_secret_key key yes || { pause; return 1; }

    echo ""
    echo "------------- Summary -------------"
    echo "  Tunnel name : $name"
    echo "  IP version  : IPv$ver"
    echo "  Interface   : $NETWORK_INTERFACE"
    echo "  Local IP    : $LOCAL_IP"
    echo "  Gateway MAC : $GATEWAY_MAC"
    echo "  Listen port : $port (TCP)"
    echo "  Secret key  : ${key:0:8}..."
    echo "-----------------------------------"
    confirm "Apply these settings?" y || return 1

    mkdir -p "$CONFIG_DIR"
    umask 077
    {
        echo 'role: "server"'
        printf 'log:\n  level: "info"\nlisten:\n  addr: ":%s"\n' "$port"
        net_block "$ver" "$NETWORK_INTERFACE" "$LOCAL_IP" "$port" "$GATEWAY_MAC"
        printf '  tcp:\n    local_flag: ["PA"]\n'
        transport_block "$key" no
    } > "$cfg"
    umask 022
    chmod 600 "$cfg"
    validate_yaml_file "$cfg" || { pause; return 1; }

    write_fw_script "$name" server "$ver" "" "$port"
    if run_fw "$name" apply >/dev/null 2>&1 && run_fw "$name" check >/dev/null 2>&1; then
        print_success "Firewall rules applied"
    else
        print_warning "Firewall rules could not be fully applied (some VPS kernels lack raw/mangle tables). The tunnel may be unstable."
    fi

    create_systemd_service "$name"
    if start_and_verify "$svc"; then
        set_auto_restart "$svc" "$DEFAULT_AUTO_RESTART" && print_success "Auto-restart every $DEFAULT_AUTO_RESTART enabled"
        public_ip=$(get_public_ip "$ver")
        echo ""
        echo -e "${GREEN}==================== Server Ready ====================${NC}"
        echo "  Tunnel name : $name"
        echo "  Server IP   : $public_ip"
        echo "  Tunnel port : $port (TCP)"
        echo -e "  Secret key  : ${GREEN}$key${NC}"
        echo -e "${GREEN}======================================================${NC}"
        echo ""
        print_warning "Allow TCP port $port in the cloud provider firewall / security group."
        print_info "Now run option 2 (Client setup) on the Iran server with the values above."
        print_info "The apps you forward (x-ui, v2ray ...) must listen on 127.0.0.1 or 0.0.0.0 here."
    else
        print_error "Server setup failed. Fix the problem above, then run this option again."
    fi
    pause
}

# ================================================
# SETUP: CLIENT (IRAN)
# ================================================
quick_setup_client() {
    show_banner
    echo -e "${GREEN}Client Setup (Iran)${NC}\n"
    ensure_paqet_ready || { print_error "Preparation failed"; pause; return 1; }

    local name="$DEFAULT_CONFIG_NAME" svc="paqet-$DEFAULT_CONFIG_NAME"
    local cfg="$CONFIG_DIR/$DEFAULT_CONFIG_NAME.yaml"
    local ver_choice ver=4 server_ip server_port server_addr key
    local forward_input forward_ports p proto_choice owner
    local forward_yaml="" kept=""

    handle_existing_tunnel "$name" || { pause; return 1; }

    echo ""
    echo "IP version of the remote (Kharej) server address:"
    echo "  1) IPv4 (default)"
    echo "  2) IPv6"
    ask ver_choice "Choose [1-2] (default 1): " "1"
    [ "$ver_choice" = "2" ] && ver=6

    ask server_ip "Kharej server IPv${ver} address: " ""
    server_ip="${server_ip//[\[\]]/}"
    if [ -z "$server_ip" ]; then print_error "Server address is required"; pause; return 1; fi
    if [ "$ver" = "6" ]; then
        validate_ipv6 "$server_ip" || { print_error "Invalid IPv6 address (example: 2001:db8::1)"; pause; return 1; }
    else
        validate_ipv4 "$server_ip" || { print_error "Invalid IPv4 address"; pause; return 1; }
    fi

    ask server_port "Kharej tunnel port (the port chosen in server setup) [$DEFAULT_LISTEN_PORT]: " "$DEFAULT_LISTEN_PORT"
    validate_port "$server_port" || { print_error "Invalid port"; pause; return 1; }
    server_port=$((10#$server_port))
    if [ "$ver" = "6" ]; then server_addr="[$server_ip]:$server_port"; else server_addr="$server_ip:$server_port"; fi

    ask_secret_key key no || { pause; return 1; }
    print_info "The key must match the one printed at the end of the server setup."

    confirm_network "$ver" || { print_error "Network setup cancelled"; pause; return 1; }

    echo ""
    echo "Forward ports = ports users connect to on THIS (Iran) server."
    echo "Traffic is delivered to the same port on 127.0.0.1 of the Kharej server."
    echo "Example: 1080,443,8443,2053"
    ask forward_input "Forward port(s) [$DEFAULT_FORWARD_PORTS]: " "$DEFAULT_FORWARD_PORTS"
    forward_ports=$(clean_port_list "$forward_input")
    if [ -z "$forward_ports" ]; then
        print_warning "No valid port entered, using default: $DEFAULT_FORWARD_PORTS"
        forward_ports="$DEFAULT_FORWARD_PORTS"
    fi

    echo ""
    echo "Protocol for each port:  1) TCP (default)   2) UDP   3) TCP + UDP"
    local -a plist
    IFS=',' read -ra plist <<<"$forward_ports"
    for p in "${plist[@]}"; do
        if [ "$p" = "$server_port" ]; then
            print_error "Port $p equals the tunnel port ($server_port): this would create a traffic loop. Skipped."
            continue
        fi
        ask proto_choice "Port $p protocol [1-3] (default 1): " "1"
        local protos=()
        case "$proto_choice" in
            2) protos=(udp) ;;
            3) protos=(tcp udp) ;;
            *) protos=(tcp) ;;
        esac
        local pr skip=0
        for pr in "${protos[@]}"; do
            if port_in_use "$p" "$pr"; then
                owner=$(port_owner "$p")
                if [[ "$owner" != *paqet* ]]; then
                    print_error "Port $p/$pr is already used by: ${owner:-another program}."
                    if confirm "Skip this port?" y; then skip=1; break; else pause; return 1; fi
                fi
            fi
        done
        [ "$skip" -eq 1 ] && continue
        for pr in "${protos[@]}"; do
            forward_yaml+="  - listen: \"0.0.0.0:$p\""$'\n'
            forward_yaml+="    target: \"127.0.0.1:$p\""$'\n'
            forward_yaml+="    protocol: \"$pr\""$'\n'
        done
        kept="${kept:+$kept,}$p"
    done

    if [ -z "$forward_yaml" ]; then
        print_error "No usable forward ports left. Aborting."
        pause
        return 1
    fi

    echo ""
    echo "------------- Summary -------------"
    echo "  Tunnel name   : $name"
    echo "  Kharej server : $server_addr"
    echo "  Forward ports : $kept"
    echo "  Interface     : $NETWORK_INTERFACE"
    echo "  Local IP      : $LOCAL_IP"
    echo "  Gateway MAC   : $GATEWAY_MAC"
    echo "  Secret key    : ${key:0:8}..."
    echo "-----------------------------------"
    confirm "Apply these settings?" y || return 1

    mkdir -p "$CONFIG_DIR"
    umask 077
    {
        echo 'role: "client"'
        printf 'log:\n  level: "info"\n'
        printf 'forward:\n%s' "$forward_yaml"
        net_block "$ver" "$NETWORK_INTERFACE" "$LOCAL_IP" "0" "$GATEWAY_MAC"
        printf '  tcp:\n    local_flag: ["PA"]\n    remote_flag: ["PA"]\n'
        printf 'server:\n  addr: "%s"\n' "$server_addr"
        transport_block "$key" yes
    } > "$cfg"
    umask 022
    chmod 600 "$cfg"
    validate_yaml_file "$cfg" || { pause; return 1; }

    write_fw_script "$name" client "$ver" "$server_ip" "$server_port"
    run_fw "$name" apply >/dev/null 2>&1 || print_warning "Some firewall rules could not be applied"

    create_systemd_service "$name"
    if start_and_verify "$svc"; then
        set_auto_restart "$svc" "$DEFAULT_AUTO_RESTART" && print_success "Auto-restart every $DEFAULT_AUTO_RESTART enabled"
        echo ""
        print_step "Testing the tunnel to the server (paqet ping)..."
        sleep 2
        if timeout 25 "$BIN_DIR/paqet" ping -c "$cfg" 2>&1 | tail -n 8; then :; fi
        echo ""
        echo -e "${GREEN}==================== Client Ready ====================${NC}"
        echo "  Tunnel name   : $name"
        echo "  Kharej server : $server_addr"
        echo "  Forward ports : $kept"
        echo -e "${GREEN}=======================================================${NC}"
        print_info "If ping fails: make sure the server was set up FIRST, the key matches,"
        print_info "and the tunnel port is open in the Kharej cloud firewall. Use option 5 for diagnostics."
    else
        print_error "Client setup failed. Fix the problem above, then run this option again."
    fi
    pause
}

# ================================================
# SERVICE MANAGEMENT
# ================================================
get_all_paqet_services() {
    systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null \
        | awk '$1 ~ /^paqet-.*\.service$/ {print $1}'
}

svc_state() {
    local s
    s=$(systemctl is-active "$1" 2>/dev/null)
    echo "${s:-unknown}"
}

delete_tunnel() {  # name
    local name="$1" svc="paqet-$1"
    systemctl stop "$svc" >/dev/null 2>&1
    systemctl disable "$svc" >/dev/null 2>&1
    run_fw "$name" remove >/dev/null 2>&1
    rm -f "$SERVICE_DIR/$svc.service" "$CONFIG_DIR/$name.yaml" "$CONFIG_DIR/$name.fw.sh" "$CRON_DIR/${svc}-restart"
    systemctl daemon-reload
    systemctl reset-failed "$svc" >/dev/null 2>&1 || true
}

show_config() {  # name
    local cfg="$CONFIG_DIR/$1.yaml"
    echo ""
    if [ -f "$cfg" ]; then
        echo "----- $cfg -----"
        cat "$cfg"
        echo "-----------------------------"
    else
        print_error "Config file not found: $cfg"
    fi
}

set_restart_interval_menu() {  # service_name
    local svc="$1" c
    echo ""
    echo "Auto-restart interval:"
    echo "  1) Every 1 hour"
    echo "  2) Every 3 hours"
    echo "  3) Every 6 hours"
    echo "  4) Every 12 hours"
    echo "  5) Every day"
    echo "  6) Disable auto-restart"
    echo "  0) Back"
    ask c "Choose: " ""
    case "$c" in
        1) set_auto_restart "$svc" 1hour  && print_success "Set: every 1 hour" ;;
        2) set_auto_restart "$svc" 3hour  && print_success "Set: every 3 hours" ;;
        3) set_auto_restart "$svc" 6hour  && print_success "Set: every 6 hours" ;;
        4) set_auto_restart "$svc" 12hour && print_success "Set: every 12 hours" ;;
        5) set_auto_restart "$svc" 1day   && print_success "Set: every day" ;;
        6) set_auto_restart "$svc" off    && print_success "Auto-restart disabled" ;;
    esac
    sleep 1
}

manage_one_service() {  # unit name (paqet-xxx.service)
    local svc="${1%.service}" name action
    name="${svc#paqet-}"
    while true; do
        show_banner
        echo -e "Tunnel: ${GREEN}$name${NC}    State: $(svc_state "$svc")"
        echo ""
        echo "  1) Start"
        echo "  2) Stop"
        echo "  3) Restart"
        echo "  4) Status"
        echo "  5) Show logs (last 50 lines)"
        echo "  6) Show config"
        echo "  7) Set auto-restart interval"
        echo "  8) Delete tunnel"
        echo "  0) Back"
        ask action "Choose: " ""
        case "$action" in
            1) run_fw "$name" apply >/dev/null 2>&1; start_and_verify "$svc"; pause ;;
            2) systemctl stop "$svc"; print_success "Stopped"; sleep 1 ;;
            3) run_fw "$name" apply >/dev/null 2>&1; start_and_verify "$svc"; pause ;;
            4) systemctl status "$svc" --no-pager -l; pause ;;
            5) journalctl -u "$svc" -n 50 --no-pager; pause ;;
            6) show_config "$name"; pause ;;
            7) set_restart_interval_menu "$svc" ;;
            8) if confirm "Delete tunnel '$name' completely?" n; then
                   delete_tunnel "$name"
                   print_success "Deleted"
                   sleep 1
                   return
               fi ;;
            0) return ;;
            *) print_error "Invalid option"; sleep 1 ;;
        esac
    done
}

manage_services() {
    local services=() svc name i choice
    while true; do
        show_banner
        echo -e "${GREEN}Paqet Tunnels${NC}\n"
        mapfile -t services < <(get_all_paqet_services)
        if [ ${#services[@]} -eq 0 ]; then
            print_warning "No paqet tunnels found"
            pause
            return
        fi
        i=1
        for svc in "${services[@]}"; do
            name="${svc#paqet-}"; name="${name%.service}"
            printf '  %d) %-20s [%s]\n' "$i" "$name" "$(svc_state "$svc")"
            i=$((i + 1))
        done
        echo "  0) Back"
        ask choice "Select [0-${#services[@]}]: " ""
        [ "$choice" = "0" ] && return
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#services[@]}" ]; then
            manage_one_service "${services[$((choice - 1))]}"
        fi
    done
}

manage_all_services() {
    local services=() svc name i choice
    while true; do
        show_banner
        mapfile -t services < <(get_all_paqet_services)
        if [ ${#services[@]} -eq 0 ]; then print_warning "No paqet tunnels found"; pause; return; fi
        echo -e "${GREEN}All Tunnels (${#services[@]})${NC}\n"
        i=1
        for svc in "${services[@]}"; do
            name="${svc#paqet-}"; name="${name%.service}"
            printf '  %d) %-20s [%s]\n' "$i" "$name" "$(svc_state "$svc")"
            i=$((i + 1))
        done
        echo ""
        echo "  1) Start all"
        echo "  2) Stop all"
        echo "  3) Restart all"
        echo "  4) Delete all"
        echo "  0) Back"
        ask choice "Choose: " ""
        case "$choice" in
            1) for svc in "${services[@]}"; do systemctl start "$svc" 2>/dev/null; done; print_success "Started"; pause ;;
            2) for svc in "${services[@]}"; do systemctl stop "$svc" 2>/dev/null; done; print_success "Stopped"; pause ;;
            3) for svc in "${services[@]}"; do systemctl restart "$svc" 2>/dev/null; done; print_success "Restarted"; pause ;;
            4) if confirm "Delete ALL tunnels?" n; then
                   for svc in "${services[@]}"; do
                       name="${svc#paqet-}"; name="${name%.service}"
                       delete_tunnel "$name"
                   done
                   print_success "All deleted"
               fi
               pause ;;
            0) return ;;
            *) print_error "Invalid option"; sleep 1 ;;
        esac
    done
}

# ================================================
# DIAGNOSTICS
# ================================================
select_tunnel() {  # prints chosen name on stdout via global SELECTED_TUNNEL
    local services=() svc name i choice
    SELECTED_TUNNEL=""
    mapfile -t services < <(get_all_paqet_services)
    if [ ${#services[@]} -eq 0 ]; then print_warning "No paqet tunnels found"; return 1; fi
    if [ ${#services[@]} -eq 1 ]; then
        name="${services[0]#paqet-}"; SELECTED_TUNNEL="${name%.service}"
        return 0
    fi
    i=1
    for svc in "${services[@]}"; do
        name="${svc#paqet-}"; name="${name%.service}"
        printf '  %d) %s\n' "$i" "$name"
        i=$((i + 1))
    done
    echo "  0) Back"
    ask choice "Select tunnel: " ""
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#services[@]}" ] || return 1
    name="${services[$((choice - 1))]#paqet-}"
    SELECTED_TUNNEL="${name%.service}"
    return 0
}

diagnose_tunnel() {  # name
    local name="$1" svc="paqet-$1" cfg="$CONFIG_DIR/$1.yaml" role state p line
    echo ""
    echo -e "${CYAN}--- Diagnostics for tunnel '$name' ---${NC}"

    if [ ! -f "$cfg" ]; then print_error "Config file missing: $cfg"; return 1; fi
    print_success "Config file exists"
    validate_yaml_file "$cfg" && print_success "Config is valid YAML"
    role=$(awk -F'"' '/^role:/ {print $2}' "$cfg")
    print_info "Role: ${role:-unknown}"

    if [ -x "$BIN_DIR/paqet" ]; then print_success "Binary present: $BIN_DIR/paqet"; else print_error "Binary missing"; fi

    state=$(svc_state "$svc")
    if [ "$state" = "active" ]; then print_success "Service state: active"; else print_error "Service state: $state"; fi

    local mac
    mac=$(awk -F'"' '/router_mac:/ {print $2; exit}' "$cfg")
    if validate_mac "$mac"; then print_success "router_mac looks valid ($mac)"; else print_error "router_mac is invalid or empty: '$mac'"; fi

    if [ -f "$CONFIG_DIR/$name.fw.sh" ]; then
        echo "Firewall rules:"
        run_fw "$name" check | sed 's/^/    /'
    fi

    if [ "$role" = "client" ]; then
        echo "Forward listeners:"
        while IFS= read -r line; do
            p="${line##*:}"; p="${p%\"}"
            if port_in_use "$p" tcp || port_in_use "$p" udp; then
                print_success "port $p is listening"
            else
                print_error "port $p is NOT listening (service down or crashed?)"
            fi
        done < <(grep -oE '^\s*- listen: "[^"]+"' "$cfg" | sed -E 's/.*listen: "//')
    fi

    if [ "$state" = "active" ]; then
        echo ""
        print_step "paqet ping (single test packet through the tunnel)..."
        timeout 25 "$BIN_DIR/paqet" ping -c "$cfg" 2>&1 | tail -n 8
    fi

    echo ""
    echo "Last log lines:"
    journalctl -u "$svc" -n 12 --no-pager 2>/dev/null | sed 's/^/    /'
    [ "$state" != "active" ] && explain_failure "$svc"
    return 0
}

test_connection() {
    local c ip out loss avg
    while true; do
        show_banner
        echo -e "${GREEN}Connection Tests${NC}\n"
        echo "  1) Full diagnostics for a tunnel"
        echo "  2) Ping a remote IP (ICMP)"
        echo "  3) Show detected network values (IPv4)"
        echo "  0) Back"
        ask c "Choose: " ""
        case "$c" in
            1) if select_tunnel; then diagnose_tunnel "$SELECTED_TUNNEL"; fi; pause ;;
            2) ask ip "Remote IP: " ""
               if [ -n "$ip" ]; then
                   echo ""
                   out=$(ping -c 5 -W 2 "$ip" 2>&1)
                   loss=$(grep -oE '[0-9]+% packet loss' <<<"$out" | grep -oE '^[0-9]+')
                   avg=$(grep 'rtt' <<<"$out" | awk -F'/' '{print $5}')
                   echo "  ICMP: loss=${loss:-100}%  avg RTT=${avg:-N/A} ms"
                   print_info "Note: ICMP can be blocked even when the tunnel works."
               fi
               pause ;;
            3) detect_network 4
               echo ""
               echo "  Interface   : ${NETWORK_INTERFACE:-<not found>}"
               echo "  Local IP    : ${LOCAL_IP:-<not found>}"
               echo "  Gateway IP  : ${GATEWAY_IP:-<not found>}"
               echo "  Gateway MAC : ${GATEWAY_MAC:-<not found>}"
               pause ;;
            0) return ;;
            *) print_error "Invalid option"; sleep 1 ;;
        esac
    done
}

view_config_menu() {
    show_banner
    if select_tunnel; then show_config "$SELECTED_TUNNEL"; fi
    pause
}

# ================================================
# SYSTEM
# ================================================
install_binary_menu() {
    local c
    while true; do
        show_banner
        echo -e "${GREEN}Install / Update Paqet binary${NC}\n"
        if [ -x "$BIN_DIR/paqet" ]; then
            print_info "Current: $(timeout 5 "$BIN_DIR/paqet" version 2>&1 | head -n 1)"
        else
            print_warning "Paqet is not installed"
        fi
        echo ""
        echo "  1) Download latest release from GitHub"
        echo "  2) Install from a local file or direct URL"
        echo "  0) Back"
        ask c "Choose: " ""
        case "$c" in
            1) install_dependencies && install_paqet force; pause ;;
            2) install_dependencies && { manual_install_paqet && print_success "Paqet installed"; }; pause ;;
            0) return ;;
            *) print_error "Invalid option"; sleep 1 ;;
        esac
    done
}

optimize_server() {
    show_banner
    echo -e "${GREEN}Kernel optimization (BBR, larger buffers, file limits)${NC}\n"
    confirm "Apply now?" n || return
    mkdir -p "$BACKUP_DIR"
    [ -f "$SYSCTL_FILE" ] && cp "$SYSCTL_FILE" "$BACKUP_DIR/99-paqet-tunnel.conf.$(date +%s)" 2>/dev/null

    modprobe tcp_bbr 2>/dev/null || true
    modprobe nf_conntrack 2>/dev/null || true
    local cc="cubic"
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && cc="bbr"

    cat > "$SYSCTL_FILE" <<EOF
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 32768
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_congestion_control = ${cc}
net.core.default_qdisc = fq
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_mtu_probing = 1
fs.file-max = 2097152
EOF
    [ -e /proc/sys/net/netfilter/nf_conntrack_max ] && echo "net.netfilter.nf_conntrack_max = 1048576" >> "$SYSCTL_FILE"

    cat > "$LIMITS_FILE" <<'EOF'
* soft nofile 524288
* hard nofile 524288
EOF

    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || print_warning "Some sysctl values were not accepted by this kernel"
    print_success "Optimizations applied (congestion control: $cc). Reboot is recommended."
    pause
}

uninstall_paqet() {
    show_banner
    echo -e "${RED}Uninstall Paqet${NC}\n"
    confirm "Remove ALL tunnels and the paqet binary?" n || return

    local svc name
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        name="${svc#paqet-}"; name="${name%.service}"
        delete_tunnel "$name"
    done < <(get_all_paqet_services)

    rm -f "$BIN_DIR/paqet" "$BIN_DIR/paqet.new"
    if confirm "Also remove config folder, backups and kernel optimization files?" n; then
        rm -rf "$CONFIG_DIR" "$BACKUP_DIR"
        rm -f "$SYSCTL_FILE" "$LIMITS_FILE"
    fi
    systemctl daemon-reload
    print_success "Uninstalled"
    pause
}

# ================================================
# MAIN MENU
# ================================================
main_menu() {
    local choice ver
    while true; do
        show_banner
        if [ -x "$BIN_DIR/paqet" ]; then
            ver=$(timeout 5 "$BIN_DIR/paqet" version 2>/dev/null | head -n 1)
            echo -e "${GREEN}Paqet installed${NC} ${CYAN}${ver}${NC}"
        else
            echo -e "${YELLOW}Paqet not installed (it will be installed automatically)${NC}"
        fi
        echo ""
        echo "  --- Setup ---"
        echo "  1) Setup Server  (Kharej / foreign server)"
        echo "  2) Setup Client  (Iran)"
        echo ""
        echo "  --- Management ---"
        echo "  3) Manage tunnels"
        echo "  4) Manage all tunnels"
        echo "  5) Test connection / diagnostics"
        echo "  6) Show tunnel config"
        echo ""
        echo "  --- System ---"
        echo "  7) Install / update Paqet binary"
        echo "  8) Optimize server (kernel)"
        echo "  9) Uninstall"
        echo "  0) Exit"
        echo ""
        ask choice "Select [0-9]: " ""

        case "$choice" in
            1) quick_setup_server ;;
            2) quick_setup_client ;;
            3) manage_services ;;
            4) manage_all_services ;;
            5) test_connection ;;
            6) view_config_menu ;;
            7) install_binary_menu ;;
            8) optimize_server ;;
            9) uninstall_paqet ;;
            0) echo -e "\n${GREEN}Goodbye${NC}"; exit 0 ;;
            *) print_error "Invalid option"; sleep 1 ;;
        esac
    done
}

main() {
    trap 'echo; exit 130' INT
    check_root
    main_menu
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
