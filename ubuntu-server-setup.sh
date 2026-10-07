#!/usr/bin/env bash
#
# ubuntu-server-setup.sh
# Interactive Ubuntu server configuration tool for dev / test / production boxes.
# Pulled and run via bootstrap.sh from https://github.com/iprimo/build-scripts
#
set -uo pipefail

SCRIPT_VERSION="1.0.0"

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
    ip -4 route list default | awk '{print $5; exit}'
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

    read -rp "Interface to configure (e.g. eth0): " iface
    read -rp "New static IP with CIDR (e.g. 192.168.1.50/24): " ipcidr
    read -rp "Gateway (e.g. 192.168.1.1): " gateway

    if [[ -z "$iface" || -z "$ipcidr" || -z "$gateway" ]]; then
        echo -e "${RED}All fields are required. Aborting.${NC}"
        press_enter
        return
    fi

    cp "$npf" "${npf}.bak.$(date +%s)"
    echo "Backed up existing netplan file."

    cat > "$npf" <<EOF
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

    chmod 600 "$npf"
    echo "Applying netplan configuration..."
    if netplan apply; then
        echo -e "${GREEN}Network configuration applied.${NC}"
    else
        echo -e "${RED}netplan apply failed. Restoring backup.${NC}"
        cp "${npf}.bak."* "$npf" 2>/dev/null
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
    read -rp "Interface to apply DNS to (e.g. eth0): " iface
    read -rp "DNS servers, comma separated (e.g. 8.8.8.8,1.1.1.1): " dns

    if [[ -z "$iface" || -z "$dns" ]]; then
        echo -e "${RED}All fields are required. Aborting.${NC}"
        press_enter
        return
    fi

    local dns_yaml
    dns_yaml=$(echo "$dns" | tr ',' '\n' | sed 's/^[[:space:]]*/        - /')

    cp "$npf" "${npf}.bak.$(date +%s)"

    if grep -q "^\s*${iface}:" "$npf"; then
        python3 - "$npf" "$iface" "$dns" <<'PYEOF'
import sys, re
path, iface, dns = sys.argv[1], sys.argv[2], sys.argv[3]
servers = [s.strip() for s in dns.split(',') if s.strip()]
with open(path) as f:
    text = f.read()
block = "      nameservers:\n        addresses: [" + ", ".join(servers) + "]\n"
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
            echo -e "${RED}Could not update that interface block automatically. Restoring backup.${NC}"
            cp "${npf}.bak."* "$npf" 2>/dev/null
            press_enter
            return
        fi
    else
        echo -e "${RED}Interface '$iface' not found in $npf. Aborting.${NC}"
        press_enter
        return
    fi

    echo "Applying netplan configuration..."
    if netplan apply; then
        echo -e "${GREEN}DNS configuration applied.${NC}"
    else
        echo -e "${RED}netplan apply failed. Restoring backup.${NC}"
        cp "${npf}.bak."* "$npf" 2>/dev/null
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

add_ssh_key() {
    clear
    echo -e "${YELLOW}--- Add SSH public key ---${NC}"
    echo "Paste the public key (single line, e.g. 'ssh-ed25519 AAAA... comment'):"
    read -r pubkey

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

    press_enter
}

# ---------------------------------------------------------------------------
# 7) Setup insecure docker registries
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

    read -rp "Registries to mark insecure, comma separated (e.g. registry.local:5000,10.0.0.5:5000): " regs

    if [[ -z "$regs" ]]; then
        echo -e "${RED}No registries provided. Aborting.${NC}"
        press_enter
        return
    fi

    mkdir -p /etc/docker
    if [[ -f /etc/docker/daemon.json ]]; then
        cp /etc/docker/daemon.json /etc/docker/daemon.json.bak.$(date +%s)
    fi

    python3 - "$regs" <<'PYEOF'
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

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF

    echo "Restarting Docker daemon..."
    systemctl restart docker

    echo -e "${GREEN}Insecure registries configured:${NC}"
    grep -A10 'insecure-registries' /etc/docker/daemon.json | sed 's/^/  /'
    press_enter
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------

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
        echo "  7) Setup insecure Docker registries"
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
            7) setup_insecure_registries ;;
            0) echo "Bye."; exit 0 ;;
            *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
        esac
    done
}

require_root
main_menu
