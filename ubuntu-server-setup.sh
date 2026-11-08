#!/usr/bin/env bash
#
# ubuntu-server-setup.sh
# Interactive Ubuntu server configuration tool for dev / test / production boxes.
# Pulled and run via bootstrap.sh from https://github.com/iprimo/build-scripts
#
set -uo pipefail

SCRIPT_VERSION="1.0.0"
DEFAULT_REGISTRY="ci.xigrom.local:5001"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}This script must be run as root. Try: sudo bash $0${NC}" >&2
        exit 1
    fi
}

press_enter() {
    echo
    read -rp "Press Enter to return to the menu..." _
}

invoking_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        echo "$SUDO_USER"
    else
        echo "root"
    fi
}

invoking_home() {
    local user
    user=$(invoking_user)
    getent passwd "$user" | cut -d: -f6
}

netplan_file() {
    ls /etc/netplan/*.yaml 2>/dev/null | head -n1
}

primary_iface() {
    local iface
    iface=$(ip -4 route list default 2>/dev/null | awk '{print $5; exit}')
    if [[ -z "$iface" ]]; then
        # No default route: fall back to the first non-loopback interface that is up
        iface=$(ip -brief link show up 2>/dev/null | awk '$1 != "lo" {print $1; exit}')
    fi
    echo "$iface"
}

# netplan warns "permissions too open" unless every YAML is root-only (0600)
secure_netplan() {
    chmod 600 /etc/netplan/*.yaml 2>/dev/null || true
}

# Back up a netplan file (root-only) and print the backup path
backup_netplan() {
    local bak="$1.bak.$(date +%s)"
    cp "$1" "$bak"
    chmod 600 "$bak"
    echo "$bak"
}

# Prompt for an interface, defaulting to the active one. Result in $iface.
prompt_iface() {
    local prompt=$1 def
    def=$(primary_iface)
    if [[ -n "$def" ]]; then
        read -rp "$prompt [$def]: " iface
        iface=${iface:-$def}
    else
        read -rp "$prompt (e.g. eth0): " iface
    fi
}

# First usable host address of the subnet for an IP/CIDR (e.g. 192.168.1.50/24 -> 192.168.1.1)
first_host_ip() {
    python3 -c '
import sys, ipaddress
try:
    n = ipaddress.ip_interface(sys.argv[1]).network
    print(n.network_address + 1)
except ValueError:
    sys.exit(1)
' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Status overview
# ---------------------------------------------------------------------------

show_config() {
    clear
    echo -e "${BLUE}=============================================================${NC}"
    echo -e "${BLUE}  Ubuntu Server Configuration Overview${NC}"
    echo -e "${BLUE}=============================================================${NC}"

    echo "Hostname        : $(hostnamectl --static 2>/dev/null || hostname)"
    if [[ -f /etc/os-release ]]; then
        echo "OS              : $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
    fi
    echo "Kernel          : $(uname -r)"
    echo "Uptime          : $(uptime -p 2>/dev/null || true)"
    echo

    echo "Network interfaces:"
    ip -brief addr show | sed 's/^/  /'
    echo

    echo "Default gateway:"
    ip route | grep '^default' | sed 's/^/  /' || echo "  (none found)"
    echo

    echo "DNS servers:"
    if command -v resolvectl &>/dev/null; then
        resolvectl status 2>/dev/null | grep -i 'DNS Server' | sed 's/^[[:space:]]*/  /'
    elif [[ -f /etc/resolv.conf ]]; then
        grep -i '^nameserver' /etc/resolv.conf | sed 's/^/  /'
    fi
    echo

    echo "Docker:"
    if command -v docker &>/dev/null; then
        echo "  Engine  : $(docker --version)"
        if docker compose version &>/dev/null; then
            echo "  Compose : $(docker compose version --short 2>/dev/null)"
        else
            echo "  Compose : not installed"
        fi
        if [[ -f /etc/docker/daemon.json ]]; then
            echo "  daemon.json insecure-registries:"
            grep -A5 'insecure-registries' /etc/docker/daemon.json 2>/dev/null | sed 's/^/    /' || echo "    (none configured)"
        fi
    else
        echo "  Not installed"
    fi
    echo

    local home
    home=$(invoking_home)
    echo "SSH authorized_keys ($home/.ssh/authorized_keys):"
    if [[ -f "$home/.ssh/authorized_keys" ]]; then
        echo "  $(wc -l < "$home/.ssh/authorized_keys") key(s) present"
    else
        echo "  none found"
    fi

    echo -e "${BLUE}=============================================================${NC}"
}

# ---------------------------------------------------------------------------
# 1) Modify IP / subnet / gateway
# ---------------------------------------------------------------------------

modify_ip_config() {
    clear
    echo -e "${YELLOW}--- Modify IP address / subnet / gateway ---${NC}"
    local npf
    npf=$(netplan_file)
    if [[ -z "$npf" ]]; then
        echo -e "${RED}No netplan YAML file found under /etc/netplan/. Aborting.${NC}"
        press_enter
        return
    fi
    echo "Using netplan file: $npf"
    echo "Current interfaces:"
    ip -brief addr show | sed 's/^/  /'
    echo

    prompt_iface "Interface to configure"
    read -rp "New static IP with CIDR (e.g. 192.168.1.50/24): " ipcidr

    local def_gw
    def_gw=$(first_host_ip "$ipcidr")
    if [[ -n "$def_gw" ]]; then
        read -rp "Gateway [$def_gw]: " gateway
        gateway=${gateway:-$def_gw}
    else
        read -rp "Gateway (e.g. 192.168.1.1): " gateway
    fi

    if [[ -z "$iface" || -z "$ipcidr" || -z "$gateway" ]]; then
        echo -e "${RED}All fields are required. Aborting.${NC}"
        press_enter
        return
    fi

    local preview
    preview=$(cat <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${iface}:
      dhcp4: no
      addresses:
        - ${ipcidr}
      routes:
        - to: default
          via: ${gateway}
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
EOF
)

    echo
    echo "The following will be written to $npf:"
    echo
    echo "$preview" | sed 's/^/  /'
    echo
    read -rp "Apply this configuration? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted. No changes made."
        press_enter
        return
    fi

    local bak
    bak=$(backup_netplan "$npf")
    echo "Backed up existing netplan file to $bak."

    printf '%s\n' "$preview" > "$npf"

    secure_netplan
    echo "Applying netplan configuration..."
    if netplan apply; then
        echo -e "${GREEN}Network configuration applied.${NC}"
    else
        echo -e "${RED}netplan apply failed. Restoring backup.${NC}"
        cp "$bak" "$npf" 2>/dev/null; secure_netplan
    fi
    press_enter
}

# ---------------------------------------------------------------------------
# 2) Modify DNS
# ---------------------------------------------------------------------------

modify_dns_config() {
    clear
    echo -e "${YELLOW}--- Modify DNS servers ---${NC}"
    local npf
    npf=$(netplan_file)
    if [[ -z "$npf" ]]; then
        echo -e "${RED}No netplan YAML file found under /etc/netplan/. Aborting.${NC}"
        press_enter
        return
    fi
    echo "Using netplan file: $npf"
    prompt_iface "Interface to apply DNS to"
    read -rp "DNS servers, comma separated (e.g. 8.8.8.8,1.1.1.1): " dns
    read -rp "DNS search domains, comma separated (e.g. xigrom.local) [xigrom.local]: " search
    search=${search:-xigrom.local}

    if [[ -z "$iface" || -z "$dns" ]]; then
        echo -e "${RED}Interface and DNS servers are required. Aborting.${NC}"
        press_enter
        return
    fi

    if ! grep -q "^\s*${iface}:" "$npf"; then
        echo -e "${RED}Interface '$iface' not found in $npf. Aborting.${NC}"
        press_enter
        return
    fi

    local tmpfile
    tmpfile=$(mktemp)
    cp "$npf" "$tmpfile"

    python3 - "$tmpfile" "$iface" "$dns" "$search" <<'PYEOF'
import sys, re
path, iface, dns, search = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
servers = [s.strip() for s in dns.split(',') if s.strip()]
domains = [d.strip() for d in search.split(',') if d.strip()]
with open(path) as f:
    text = f.read()
block = "      nameservers:\n        addresses: [" + ", ".join(servers) + "]\n"
if domains:
    block += "        search:\n"
    for d in domains:
        block += "          - " + d + "\n"
pattern = re.compile(r"(^    " + re.escape(iface) + r":\n(?:.*\n)*?)(?=^    \S|\Z)", re.M)
m = pattern.search(text)
if not m:
    print("interface block not found", file=sys.stderr)
    sys.exit(1)
section = m.group(1)
section = re.sub(r"      nameservers:\n(?:        .*\n)*", "", section)
if not section.endswith("\n"):
    section += "\n"
section += block
text = text[:m.start()] + section + text[m.end():]
with open(path, "w") as f:
    f.write(text)
PYEOF
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Could not update that interface block automatically.${NC}"
        rm -f "$tmpfile"
        press_enter
        return
    fi

    echo
    echo "The following will be written to $npf:"
    echo
    sed 's/^/  /' "$tmpfile"
    echo
    read -rp "Apply this configuration? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted. No changes made."
        rm -f "$tmpfile"
        press_enter
        return
    fi

    local bak
    bak=$(backup_netplan "$npf")
    cp "$tmpfile" "$npf"
    rm -f "$tmpfile"
    secure_netplan

    echo "Applying netplan configuration..."
    if netplan apply; then
        echo -e "${GREEN}DNS configuration applied.${NC}"
    else
        echo -e "${RED}netplan apply failed. Restoring backup.${NC}"
        cp "$bak" "$npf" 2>/dev/null; secure_netplan
    fi
    press_enter
}

# ---------------------------------------------------------------------------
# 3) Update hostname
# ---------------------------------------------------------------------------

update_hostname() {
    clear
    echo -e "${YELLOW}--- Update hostname ---${NC}"
    echo "Current hostname: $(hostnamectl --static 2>/dev/null || hostname)"
    read -rp "New hostname: " newhost

    if [[ -z "$newhost" ]]; then
        echo -e "${RED}Hostname cannot be empty. Aborting.${NC}"
        press_enter
        return
    fi

    local oldhost
    oldhost=$(hostnamectl --static 2>/dev/null || hostname)

    echo
    echo "Hostname will be changed: '${oldhost}' -> '${newhost}'"
    echo "/etc/hosts entries matching '${oldhost}' will be updated to '${newhost}'."
    echo
    read -rp "Apply this change? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted. No changes made."
        press_enter
        return
    fi

    hostnamectl set-hostname "$newhost"
    sed -i "s/\b${oldhost}\b/${newhost}/g" /etc/hosts

    if ! grep -q "127.0.1.1[[:space:]]\+${newhost}" /etc/hosts; then
        echo "127.0.1.1	${newhost}" >> /etc/hosts
    fi

    echo -e "${GREEN}Hostname changed from '${oldhost}' to '${newhost}'.${NC}"
    echo "Some shells/services may need a re-login or reboot to fully reflect the change."
    press_enter
}

# ---------------------------------------------------------------------------
# 4) Install essential networking tools
# ---------------------------------------------------------------------------

install_networking_tools() {
    clear
    echo -e "${YELLOW}--- Installing essential networking tools ---${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y \
        net-tools \
        iproute2 \
        dnsutils \
        curl \
        wget \
        traceroute \
        tcpdump \
        iputils-ping \
        telnet \
        nmap \
        htop \
        iftop \
        whois \
        netcat-openbsd \
        rsync

    echo -e "${GREEN}Networking tools installed.${NC}"
    press_enter
}

# ---------------------------------------------------------------------------
# 5) Install Docker + Docker Compose
# ---------------------------------------------------------------------------

install_docker() {
    clear
    echo -e "${YELLOW}--- Installing Docker & Docker Compose ---${NC}"

    if command -v docker &>/dev/null; then
        echo "Docker is already installed: $(docker --version)"
        read -rp "Reinstall / re-run installer anyway? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            press_enter
            return
        fi
    fi

    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh

    systemctl enable docker --now

    local user
    user=$(invoking_user)
    if [[ "$user" != "root" ]]; then
        usermod -aG docker "$user"
        echo "Added '$user' to the docker group (log out/in for it to take effect)."
    fi

    echo -e "${GREEN}Docker installed: $(docker --version)${NC}"
    if docker compose version &>/dev/null; then
        echo -e "${GREEN}Docker Compose plugin: $(docker compose version --short)${NC}"
    else
        echo -e "${RED}Docker Compose plugin not detected after install.${NC}"
    fi
    press_enter
}

# ---------------------------------------------------------------------------
# 6) Add SSH public key
# ---------------------------------------------------------------------------

DEFAULT_SSH_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCmTqkJi1LAzECQc0e1hB/raIjwjyCpEFTxS3Ira8uR72iTRJwZvBG9O6GIXu3gtUwBRvUdIFrzBCyL0fGb+7qIMsoczq/4WQoberX2TXh7EQHgSHQtV7p2zmfuVwrQxxzW27znutHmC0muZ23U8Bb4WB+5kmIS7xGYO52CN+RK0lnmjhx1X9DVmnwF4v/xfBAmYSmV7lr2meDg6Lzuw0k+Bm8z/PUd1d6XXAzkqru0+e/lBfePRl7tnGRh3Hj482pUKWijUa4jzTNX3/YqgQy9KLnBQao28a9iWJSWnlnNhOUzKAU58Re4/PK9gtYIgPWmagqZiEAfsJ+hQTDGdxaYrUky03qDTk2LmakZUZXLjO2iAGKAEBXZEJe185tnOx3mNBESJCXNqF5rgYjODhN6kXSTNpxCujzBpxXaBd5xKRavbep4DuPEvOHrdKeVkwddmru6VKRgMPlGtuSpTJKu9/NDUdIWsAd30qGcy4XBe1GFPPoejjFwKEt37ko3LtE= Ali-HP-Laptop-Public-Key"

add_ssh_key() {
    clear
    echo -e "${YELLOW}--- Add SSH public key ---${NC}"
    echo "Default key: ${DEFAULT_SSH_KEY##* } (${DEFAULT_SSH_KEY:0:40}...)"
    echo "Press Enter to use the default key, or paste a different public key"
    echo "(single line, e.g. 'ssh-ed25519 AAAA... comment'):"
    read -r pubkey
    pubkey=${pubkey:-$DEFAULT_SSH_KEY}

    if [[ -z "$pubkey" ]]; then
        echo -e "${RED}No key provided. Aborting.${NC}"
        press_enter
        return
    fi

    if ! [[ "$pubkey" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]] ]]; then
        echo -e "${RED}That doesn't look like a valid SSH public key. Aborting.${NC}"
        press_enter
        return
    fi

    local user home
    user=$(invoking_user)
    home=$(invoking_home)

    echo
    echo "The following key will be added to authorized_keys for '${user}' and 'root':"
    echo
    echo "  $pubkey"
    echo
    read -rp "Apply this change? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted. No changes made."
        press_enter
        return
    fi

    for target in "${home}:${user}" "/root:root"; do
        dir="${target%%:*}"
        owner="${target##*:}"
        mkdir -p "${dir}/.ssh"
        touch "${dir}/.ssh/authorized_keys"
        if ! grep -qF "$pubkey" "${dir}/.ssh/authorized_keys"; then
            echo "$pubkey" >> "${dir}/.ssh/authorized_keys"
            echo -e "${GREEN}Key added to ${dir}/.ssh/authorized_keys${NC}"
        else
            echo "Key already present in ${dir}/.ssh/authorized_keys"
        fi
        chmod 700 "${dir}/.ssh"
        chmod 600 "${dir}/.ssh/authorized_keys"
        chown -R "${owner}:${owner}" "${dir}/.ssh"
    done

    allow_root_key_login
    press_enter
}

# Make sure sshd lets root in with a key (and never with a password)
allow_root_key_login() {
    echo
    local current
    current=$(sshd -T 2>/dev/null | awk '$1=="permitrootlogin"{print $2}')
    if [[ "$current" == "prohibit-password" || "$current" == "without-password" ]]; then
        echo "sshd already allows root login with a key only (PermitRootLogin ${current})."
        return
    fi

    echo "sshd currently has PermitRootLogin = ${current:-unknown}."
    read -rp "Set PermitRootLogin to 'prohibit-password' (root key login only)? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Skipped. Root key login may be refused by sshd."
        return
    fi

    local files=(/etc/ssh/sshd_config) f changed=0 stamp
    stamp=$(date +%s)
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$f" ]] && files+=("$f")
    done

    for f in "${files[@]}"; do
        if grep -qiE '^[[:space:]]*PermitRootLogin[[:space:]]' "$f"; then
            cp -p "$f" "${f}.bak.${stamp}"
            sed -i -E 's/^([[:space:]]*)PermitRootLogin[[:space:]].*/\1PermitRootLogin prohibit-password/I' "$f"
            changed=1
        fi
    done

    if [[ $changed -eq 0 ]]; then
        cp -p /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.${stamp}"
        echo "PermitRootLogin prohibit-password" >> /etc/ssh/sshd_config
    fi

    if sshd -t; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
        echo -e "${GREEN}sshd updated: root can log in with a key only.${NC}"
    else
        echo -e "${RED}sshd config test failed. Restoring backups.${NC}"
        for f in "${files[@]}"; do
            [[ -f "${f}.bak.${stamp}" ]] && mv "${f}.bak.${stamp}" "$f"
        done
    fi
}

# ---------------------------------------------------------------------------
# 7) Generate a local SSH key pair
# ---------------------------------------------------------------------------

generate_ssh_key() {
    clear
    echo -e "${YELLOW}--- Generate a local SSH key pair ---${NC}"

    local user home ssh_dir
    user=$(invoking_user)
    home=$(invoking_home)
    ssh_dir="${home}/.ssh"

    echo "Key types: ed25519 (recommended), rsa"
    read -rp "Key type [ed25519]: " keytype
    keytype=${keytype:-ed25519}
    if [[ "$keytype" != "ed25519" && "$keytype" != "rsa" ]]; then
        echo -e "${RED}Unsupported key type. Aborting.${NC}"
        press_enter
        return
    fi

    read -rp "Filename [id_${keytype}]: " filename
    filename=${filename:-id_${keytype}}
    read -rp "Comment (e.g. your email) [${user}@$(hostname)]: " comment
    comment=${comment:-${user}@$(hostname)}

    local keypath="${ssh_dir}/${filename}"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    if [[ -f "$keypath" ]]; then
        echo -e "${RED}${keypath} already exists.${NC}"
        read -rp "Overwrite it? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            press_enter
            return
        fi
        rm -f "$keypath" "${keypath}.pub"
    fi

    read -rsp "Passphrase (leave empty for none): " passphrase
    echo

    echo
    echo "About to generate:"
    echo "  Type       : $keytype"
    echo "  Path       : $keypath / ${keypath}.pub"
    echo "  Comment    : $comment"
    echo "  Passphrase : $( [[ -n "$passphrase" ]] && echo "set" || echo "none" )"
    echo
    read -rp "Apply this change? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted. No changes made."
        press_enter
        return
    fi

    local keygen_args=(-t "$keytype" -f "$keypath" -C "$comment" -N "$passphrase")
    if [[ "$keytype" == "rsa" ]]; then
        keygen_args+=(-b 4096)
    fi

    if ssh-keygen "${keygen_args[@]}" >/dev/null; then
        chown "${user}:${user}" "$keypath" "${keypath}.pub"
        chmod 600 "$keypath"
        chmod 644 "${keypath}.pub"
        echo -e "${GREEN}Key pair generated: ${keypath} / ${keypath}.pub${NC}"
        echo
        echo "Public key:"
        echo
        cat "${keypath}.pub"
    else
        echo -e "${RED}ssh-keygen failed.${NC}"
    fi

    press_enter
}

# ---------------------------------------------------------------------------
# 8) Print SSH public key(s) to the screen
# ---------------------------------------------------------------------------

print_ssh_keys() {
    clear
    echo -e "${YELLOW}--- Print SSH public key(s) ---${NC}"

    local home ssh_dir
    home=$(invoking_home)
    ssh_dir="${home}/.ssh"

    if [[ ! -d "$ssh_dir" ]]; then
        echo -e "${RED}No .ssh directory found at ${ssh_dir}.${NC}"
        press_enter
        return
    fi

    local pubkeys=("${ssh_dir}"/*.pub)
    if [[ ! -e "${pubkeys[0]}" ]]; then
        echo -e "${RED}No public key files (*.pub) found in ${ssh_dir}.${NC}"
        press_enter
        return
    fi

    for pub in "${pubkeys[@]}"; do
        echo
        echo -e "${GREEN}${pub}:${NC}"
        cat "$pub"
    done

    press_enter
}

# ---------------------------------------------------------------------------
# 9) Setup insecure docker registries
# ---------------------------------------------------------------------------

setup_insecure_registries() {
    clear
    echo -e "${YELLOW}--- Setup insecure Docker registries ---${NC}"

    if ! command -v docker &>/dev/null; then
        echo -e "${RED}Docker is not installed. Install it first (option 5).${NC}"
        press_enter
        return
    fi

    echo "Current insecure-registries (if any):"
    if [[ -f /etc/docker/daemon.json ]]; then
        grep -A5 'insecure-registries' /etc/docker/daemon.json 2>/dev/null | sed 's/^/  /' || echo "  (none configured)"
    else
        echo "  (no daemon.json yet)"
    fi
    echo

    read -rp "Registries to mark insecure, comma separated [${DEFAULT_REGISTRY}]: " regs
    regs=${regs:-$DEFAULT_REGISTRY}

    if [[ -z "$regs" ]]; then
        echo -e "${RED}No registries provided. Aborting.${NC}"
        press_enter
        return
    fi

    local preview
    preview=$(python3 - "$regs" <<'PYEOF'
import json, sys, os

regs = [r.strip() for r in sys.argv[1].split(',') if r.strip()]
path = "/etc/docker/daemon.json"

data = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        data = {}

existing = set(data.get("insecure-registries", []))
existing.update(regs)
data["insecure-registries"] = sorted(existing)

print(json.dumps(data, indent=2))
PYEOF
)

    echo
    echo "The following will be written to /etc/docker/daemon.json:"
    echo
    echo "$preview" | sed 's/^/  /'
    echo
    read -rp "Apply this configuration and restart Docker? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted. No changes made."
        press_enter
        return
    fi

    mkdir -p /etc/docker
    if [[ -f /etc/docker/daemon.json ]]; then
        cp /etc/docker/daemon.json /etc/docker/daemon.json.bak.$(date +%s)
    fi

    printf '%s\n' "$preview" > /etc/docker/daemon.json

    echo "Restarting Docker daemon..."
    systemctl restart docker

    echo -e "${GREEN}Insecure registries configured:${NC}"
    grep -A10 'insecure-registries' /etc/docker/daemon.json | sed 's/^/  /'
    press_enter
}

# ---------------------------------------------------------------------------
# 10) Deploy Woodpecker CI agent
# ---------------------------------------------------------------------------

deploy_woodpecker_agent() {
    clear
    echo -e "${YELLOW}--- Deploy Woodpecker CI agent (Docker) ---${NC}"

    if ! command -v docker &>/dev/null; then
        echo -e "${RED}Docker is not installed. Install it first (option 5).${NC}"
        press_enter
        return
    fi

    echo "Select environment:"
    echo "  1) Development"
    echo "  2) Test"
    echo "  3) Production"
    read -rp "Choice [1-3]: " envchoice

    local envprefix envlabel
    case "$envchoice" in
        1) envprefix="dev"; envlabel="Development" ;;
        2) envprefix="test"; envlabel="Test" ;;
        3) envprefix="prd"; envlabel="Production" ;;
        *) echo -e "${RED}Invalid choice. Aborting.${NC}"; press_enter; return ;;
    esac

    local base_name default_hostname default_name
    base_name=$(hostnamectl --static 2>/dev/null || hostname)
    default_hostname="${envprefix}-${base_name}-agent"
    default_name="woodpecker-agent"

    read -rp "Container name [${default_name}]: " agent_name
    agent_name=${agent_name:-$default_name}

    read -rp "Agent hostname [${default_hostname}]: " agent_hostname
    agent_hostname=${agent_hostname:-$default_hostname}

    read -rp "Woodpecker server address [192.168.110.44:9000]: " wp_server
    wp_server=${wp_server:-192.168.110.44:9000}

    read -rsp "Woodpecker agent secret: " wp_secret
    echo
    if [[ -z "$wp_secret" ]]; then
        echo -e "${RED}Agent secret is required. Aborting.${NC}"
        press_enter
        return
    fi

    read -rp "Max workflows [4]: " max_wf
    max_wf=${max_wf:-4}

    if docker ps -a --format '{{.Names}}' | grep -qx "$agent_name"; then
        echo -e "${RED}A container named '${agent_name}' already exists.${NC}"
        read -rp "Remove it and redeploy? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            press_enter
            return
        fi
    fi

    echo
    echo "About to run:"
    echo
    echo "  Environment     : $envlabel"
    echo "  Container name  : $agent_name"
    echo "  Agent hostname  : $agent_hostname"
    echo "  Server          : $wp_server"
    echo "  Agent secret    : ********"
    echo "  Max workflows   : $max_wf"
    echo "  deploy_target   : $agent_hostname"
    echo
    read -rp "Deploy this Woodpecker agent container? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted. No changes made."
        press_enter
        return
    fi

    docker rm -f "$agent_name" &>/dev/null

    if docker run -d \
        --name "$agent_name" \
        --restart=always \
        --hostname "$agent_hostname" \
        -e WOODPECKER_SERVER="$wp_server" \
        -e WOODPECKER_AGENT_SECRET="$wp_secret" \
        -e WOODPECKER_BACKEND=docker \
        -e WOODPECKER_MAX_WORKFLOWS="$max_wf" \
        -e WOODPECKER_AGENT_LABELS="deploy_target=${agent_hostname}" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        woodpeckerci/woodpecker-agent:v3 >/dev/null; then
        echo -e "${GREEN}Woodpecker agent '${agent_name}' deployed (hostname: ${agent_hostname}).${NC}"
    else
        echo -e "${RED}docker run failed.${NC}"
    fi

    press_enter
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 11) CI/CD health check
# ---------------------------------------------------------------------------

HC_PASS=0; HC_WARN=0; HC_FAIL=0

hc_pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; HC_PASS=$((HC_PASS + 1)); }
hc_warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; HC_WARN=$((HC_WARN + 1)); }
hc_fail() { echo -e "  ${RED}[FAIL]${NC} $*"; HC_FAIL=$((HC_FAIL + 1)); }
hc_info() { echo -e "         $*"; }
hc_section() { echo; echo -e "${BLUE}== $* ==${NC}"; }

# hc_tcp host port -> 0 if a TCP connection opens within 5s
hc_tcp() { timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

hc_check_system() {
    hc_section "System"

    local pct
    for mp in / /var/lib/docker; do
        [[ -d "$mp" ]] || continue
        pct=$(df -P "$mp" | awk 'NR==2{gsub("%","",$5); print $5}')
        if   (( pct >= 90 )); then hc_fail "Disk $mp is ${pct}% full (builds will fail with 'no space left')"
        elif (( pct >= 80 )); then hc_warn "Disk $mp is ${pct}% full"
        else hc_pass "Disk $mp is ${pct}% full"; fi
        pct=$(df -Pi "$mp" | awk 'NR==2{gsub("%","",$5); print $5}')
        if [[ "$pct" =~ ^[0-9]+$ ]] && (( pct >= 90 )); then hc_fail "Inodes on $mp are ${pct}% used"; fi
    done

    local mem_avail mem_total swap_total
    mem_total=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    mem_avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    swap_total=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
    pct=$(( 100 * mem_avail / mem_total ))
    if   (( pct < 10 )); then hc_fail "Only ${pct}% memory available ($((mem_avail / 1024)) MB) - OOM kills likely"
    elif (( pct < 20 )); then hc_warn "Only ${pct}% memory available ($((mem_avail / 1024)) MB)"
    else hc_pass "Memory available: ${pct}% ($((mem_avail / 1024)) MB)"; fi
    (( swap_total == 0 )) && hc_info "No swap configured (OOM killer acts sooner under load)"

    local load cpus
    load=$(awk '{print $1}' /proc/loadavg)
    cpus=$(nproc)
    if awk -v l="$load" -v c="$cpus" 'BEGIN{exit !(l > c * 2)}'; then
        hc_warn "Load average $load is high for $cpus CPU(s)"
    else
        hc_pass "Load average $load ($cpus CPU(s))"
    fi

    local oom
    oom=$(journalctl -k --since "-24h" --no-pager 2>/dev/null | grep -ci 'out of memory\|oom-kill')
    if (( ${oom:-0} > 0 )); then
        hc_warn "Kernel OOM events in the last 24h: $oom (processes/containers were killed)"
    else
        hc_pass "No kernel OOM events in the last 24h"
    fi

    # Clock skew breaks TLS, registry tokens and agent auth
    if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
        hc_pass "Clock is NTP-synchronised"
    else
        hc_warn "Clock is NOT NTP-synchronised (skew breaks TLS and registry/agent auth). Try: timedatectl set-ntp true"
    fi

    local gw
    gw=$(ip -4 route show default | awk '{print $3; exit}')
    if [[ -z "$gw" ]]; then
        hc_fail "No default gateway"
    elif ping -c2 -W2 "$gw" &>/dev/null; then
        hc_pass "Default gateway $gw reachable"
    else
        hc_fail "Default gateway $gw not reachable"
    fi

    if getent hosts example.com &>/dev/null; then
        hc_pass "DNS resolution works"
    else
        hc_fail "DNS resolution failed (check option 2)"
    fi
}

hc_check_docker() {
    hc_section "Docker"

    if ! command -v docker &>/dev/null; then
        hc_fail "Docker is not installed (option 5)"
        return 1
    fi
    if ! systemctl is-active --quiet docker; then
        hc_fail "Docker service is not running (systemctl status docker)"
        return 1
    fi
    if ! docker info &>/dev/null; then
        hc_fail "Docker daemon is not responding to 'docker info'"
        return 1
    fi
    hc_pass "Docker daemon running ($(docker --version | cut -d, -f1))"

    if docker compose version &>/dev/null; then
        hc_pass "Compose plugin present ($(docker compose version --short))"
    else
        hc_warn "Docker Compose plugin missing"
    fi

    if [[ -f /etc/docker/daemon.json ]]; then
        if python3 -c 'import json,sys; json.load(open("/etc/docker/daemon.json"))' 2>/dev/null; then
            hc_pass "/etc/docker/daemon.json is valid JSON"
        else
            hc_fail "/etc/docker/daemon.json is NOT valid JSON (daemon will not start after a restart)"
        fi
    fi

    local sockperm
    sockperm=$(stat -c '%a' /var/run/docker.sock 2>/dev/null)
    hc_info "docker.sock mode: ${sockperm:-?}"

    local reclaim
    reclaim=$(docker system df --format '{{.Type}}: {{.Reclaimable}}' 2>/dev/null | tr '\n' ';')
    hc_info "Reclaimable space -> ${reclaim:-n/a}  (clean with: docker system prune -af)"

    local dead
    dead=$(docker ps -a --filter status=restarting --format '{{.Names}}' | tr '\n' ' ')
    if [[ -n "$dead" ]]; then hc_warn "Containers stuck restarting: $dead"; else hc_pass "No containers stuck restarting"; fi
    return 0
}

# hc_check_registry host[:port] [user]
hc_check_registry() {
    local reg=$1 host port c_https c_http
    hc_section "Registry: $reg"
    host=${reg%%:*}
    port=${reg##*:}
    [[ "$port" == "$reg" ]] && port=443

    if ! getent hosts "$host" &>/dev/null && [[ ! "$host" =~ ^[0-9.]+$ ]]; then
        hc_fail "Cannot resolve $host"
        return
    fi
    if ! hc_tcp "$host" "$port"; then
        hc_fail "TCP connect to $host:$port failed (firewall / registry down)"
        return
    fi
    hc_pass "TCP connect to $host:$port"

    c_https=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "https://${reg}/v2/" 2>/dev/null)
    c_http=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://${reg}/v2/" 2>/dev/null)

    local insecure_active=0
    if docker info 2>/dev/null | sed -n '/Insecure Registries:/,/^ [A-Za-z]/p' | grep -qF "$reg"; then
        insecure_active=1
    fi
    local insecure_cfg=0
    grep -qF "\"$reg\"" /etc/docker/daemon.json 2>/dev/null && insecure_cfg=1

    if [[ "$c_https" == "200" || "$c_https" == "401" ]]; then
        hc_pass "Registry answers HTTPS /v2/ (HTTP $c_https)"
        if ! curl -s -o /dev/null --max-time 8 "https://${reg}/v2/" 2>/dev/null; then
            if (( insecure_active )); then
                hc_pass "Certificate not trusted, but registry is in the active insecure-registries list"
            else
                hc_fail "Certificate not trusted -> 'x509: certificate signed by unknown authority'. Install the CA in /etc/docker/certs.d/${reg}/ca.crt or use option 9"
            fi
        else
            hc_pass "TLS certificate is trusted"
        fi
    elif [[ "$c_http" == "200" || "$c_http" == "401" ]]; then
        hc_warn "Registry only speaks plain HTTP (HTTP $c_http)"
        if (( insecure_active )); then
            hc_pass "Docker daemon has $reg in its ACTIVE insecure-registries list"
        elif (( insecure_cfg )); then
            hc_fail "$reg is in daemon.json but Docker was not restarted, so the daemon still uses HTTPS for it"
            echo -e "         ${YELLOW}Restarting Docker stops running containers (the Woodpecker agent restarts itself;${NC}"
            echo -e "         ${YELLOW}any running pipeline on this host will be interrupted).${NC}"
            read -rp "         Restart Docker now to apply it? [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                systemctl restart docker
                local i
                for i in 1 2 3 4 5 6 7 8 9 10; do docker info &>/dev/null && break; sleep 1; done
                if docker info 2>/dev/null | sed -n '/Insecure Registries:/,/^ [A-Za-z]/p' | grep -qF "$reg"; then
                    insecure_active=1
                    hc_pass "Docker restarted; $reg is now in the active insecure-registries list"
                else
                    hc_fail "Docker restarted but $reg is still not active - check /etc/docker/daemon.json"
                fi
            else
                hc_info "Skipped. Run later: systemctl restart docker"
            fi
        else
            hc_fail "Reproduces 'server gave HTTP response to HTTPS client': add $reg via option 9 on THIS host"
        fi
    else
        hc_fail "No usable /v2/ endpoint (HTTPS: ${c_https:-none}, HTTP: ${c_http:-none})"
        return
    fi

    # Optional real login test
    local user pass
    read -rp "  Registry username for a login test (blank to skip): " user
    if [[ -n "$user" ]]; then
        read -rsp "  Password: " pass; echo
        if echo "$pass" | docker login "$reg" -u "$user" --password-stdin >/tmp/hc-login.out 2>&1; then
            hc_pass "docker login to $reg succeeded"
            docker logout "$reg" &>/dev/null
        else
            hc_fail "docker login failed: $(tr '\n' ' ' </tmp/hc-login.out | cut -c1-200)"
        fi
        rm -f /tmp/hc-login.out
    fi
}

hc_check_woodpecker() {
    hc_section "Woodpecker agent"

    if ! command -v docker &>/dev/null; then hc_warn "Docker missing, skipping"; return; fi

    local agents name
    agents=$(docker ps -a --format '{{.Names}} {{.Image}}' | awk '/woodpecker-agent/{print $1}')
    if [[ -z "$agents" ]]; then
        hc_warn "No Woodpecker agent container found on this host (option 10)"
        return
    fi

    for name in $agents; do
        echo -e "  ${BLUE}-- container: $name${NC}"
        local state restarts oom started policy server envs
        state=$(docker inspect -f '{{.State.Status}}' "$name")
        restarts=$(docker inspect -f '{{.RestartCount}}' "$name")
        oom=$(docker inspect -f '{{.State.OOMKilled}}' "$name")
        started=$(docker inspect -f '{{.State.StartedAt}}' "$name")
        policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$name")
        envs=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name")
        server=$(echo "$envs" | sed -n 's/^WOODPECKER_SERVER=//p')

        if [[ "$state" == "running" ]]; then hc_pass "Running since $started"; else hc_fail "State is '$state'"; fi
        [[ "$policy" == "always" || "$policy" == "unless-stopped" ]] \
            && hc_pass "Restart policy: $policy" || hc_warn "Restart policy is '$policy' (agent will not come back after reboot)"
        if (( restarts > 3 )); then hc_warn "Container restarted $restarts times (crash-looping?)"; else hc_pass "Restart count: $restarts"; fi
        [[ "$oom" == "true" ]] && hc_fail "Container was OOM-killed"

        docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$name" | grep -q '/var/run/docker.sock' \
            && hc_pass "docker.sock mounted" || hc_fail "docker.sock is not mounted (agent cannot run pipelines)"
        echo "$envs" | grep -q '^WOODPECKER_AGENT_SECRET=.\+' \
            && hc_pass "Agent secret is set" || hc_fail "Agent secret is empty"
        hc_info "Hostname: $(docker inspect -f '{{.Config.Hostname}}' "$name")  Server: ${server:-?}"

        if [[ -n "$server" ]]; then
            local shost sport
            shost=${server%%:*}; sport=${server##*:}
            [[ "$sport" == "$server" ]] && sport=9000
            if hc_tcp "$shost" "$sport"; then
                hc_pass "Server $shost:$sport reachable from host"
            else
                hc_fail "Server $shost:$sport NOT reachable (gRPC port blocked or server down) - top cause of disconnects"
            fi

            # Connection quality: flaky links cause stream drops
            local ping_out loss rtt
            ping_out=$(ping -c 20 -i 0.2 -W 2 "$shost" 2>/dev/null)
            if [[ -n "$ping_out" ]]; then
                loss=$(echo "$ping_out" | sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p')
                rtt=$(echo "$ping_out" | sed -n 's/.*= [0-9.]*\/\([0-9.]*\)\/.*/\1/p')
                if awk -v l="${loss:-0}" 'BEGIN{exit !(l > 0)}'; then
                    hc_warn "Packet loss to server: ${loss}% (avg RTT ${rtt:-?} ms) - causes agent disconnects"
                else
                    hc_pass "No packet loss to server (avg RTT ${rtt:-?} ms)"
                fi
            else
                hc_info "Server does not answer ICMP; skipped loss test"
            fi
        fi

        # Look for disconnect patterns in recent logs
        local logs n_disc n_auth n_err
        logs=$(docker logs --since 24h "$name" 2>&1)
        n_disc=$(echo "$logs" | grep -ciE 'unavailable|connection (reset|refused|closed)|transport is closing|EOF|deadline exceeded|reconnect|disconnect')
        n_auth=$(echo "$logs" | grep -ciE 'unauthenticated|auth.*(fail|invalid)|permission denied|invalid token|secret')
        n_err=$(echo "$logs" | grep -ciE '\berror\b|level=error|"level":"error"')
        if (( n_disc > 0 )); then hc_warn "$n_disc disconnect-style log lines in last 24h"; else hc_pass "No disconnect messages in last 24h"; fi
        (( n_auth > 0 )) && hc_fail "$n_auth auth-related log lines (agent secret mismatch with server?)"
        hc_info "Error lines in last 24h: $n_err"
        if (( n_disc + n_auth > 0 )); then
            hc_info "Last relevant log lines:"
            echo "$logs" | grep -iE 'unavailable|reset|refused|closing|EOF|deadline|reconnect|disconnect|unauthenticated|auth|denied' \
                | tail -n 5 | cut -c1-180 | sed 's/^/           /'
        fi
    done
}

health_check() {
    clear
    echo -e "${YELLOW}--- CI/CD health check ---${NC}"
    HC_PASS=0; HC_WARN=0; HC_FAIL=0

    local reg
    read -rp "Registry host[:port] to test [$DEFAULT_REGISTRY] (type 'none' to skip): " reg
    reg=${reg:-$DEFAULT_REGISTRY}
    [[ "$reg" == "none" ]] && reg=""

    hc_check_system
    if hc_check_docker; then
        [[ -n "$reg" ]] && hc_check_registry "$reg"
        hc_check_woodpecker
    fi

    echo
    echo -e "${BLUE}=============================================================${NC}"
    echo -e "  Summary: ${GREEN}${HC_PASS} passed${NC}, ${YELLOW}${HC_WARN} warnings${NC}, ${RED}${HC_FAIL} failed${NC}"
    if (( HC_FAIL > 0 )); then
        echo -e "  ${RED}Fix the FAIL items above before relying on CI/CD builds on this host.${NC}"
    fi
    echo "  Note: with the docker.sock mount, 'docker login/push' in pipelines uses THIS"
    echo "  host's daemon, so insecure-registries must be configured here (option 9)."
    echo -e "${BLUE}=============================================================${NC}"
    press_enter
}

main_menu() {
    while true; do
        show_config
        echo
        echo "What would you like to do?"
        echo "  1) Modify IP address / subnet / gateway"
        echo "  2) Modify DNS servers"
        echo "  3) Update hostname"
        echo "  4) Install essential networking tools"
        echo "  5) Install Docker & Docker Compose"
        echo "  6) Add SSH public key (current user + root)"
        echo "  7) Generate a local SSH key pair"
        echo "  8) Print SSH public key(s) to screen"
        echo "  9) Setup insecure Docker registries"
        echo " 10) Deploy Woodpecker CI agent"
        echo " 11) CI/CD health check (system, Docker, registry, Woodpecker agent)"
        echo "  0) Exit"
        echo
        read -rp "Choice: " choice
        case "$choice" in
            1) modify_ip_config ;;
            2) modify_dns_config ;;
            3) update_hostname ;;
            4) install_networking_tools ;;
            5) install_docker ;;
            6) add_ssh_key ;;
            7) generate_ssh_key ;;
            8) print_ssh_keys ;;
            9) setup_insecure_registries ;;
            10) deploy_woodpecker_agent ;;
            11) health_check ;;
            0) echo "Bye."; exit 0 ;;
            *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
        esac
    done
}

require_root
main_menu
