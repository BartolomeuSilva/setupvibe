#!/bin/bash


# ==============================================================================
# SETUPVIBE.DEV - LINUX SERVER EDITION
# ==============================================================================
# Maintainer:    promovaweb.com
# Contact:       contato@promovaweb.com
# Contributing:  https://github.com/promovaweb/setupvibe/blob/main/CONTRIBUTING.md
# ------------------------------------------------------------------------------
# Compatibility: Ubuntu 24.04+, Debian 12+, Fedora 41+, Arch/Manjaro
# Architectures: x86_64 (amd64) & ARM64 (aarch64/arm64)
# Target:        Linux servers — no desktop or dev language tools
# ==============================================================================


# --- COLORS & STYLE ---
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color


# --- VERSION ---
VERSION="0.42.0"
INSTALL_URL="https://server.setupvibe.dev"

# --- ARGUMENT PARSING ---
SWARM_MANAGER=false
for arg in "$@"; do
    case "$arg" in
        --manager) SWARM_MANAGER=true ;;
    esac
done

echo -e "${CYAN}SetupVibe Server Edition v${VERSION}${NC}"
[[ "$SWARM_MANAGER" == "true" ]] && echo -e "${YELLOW}  → Docker Swarm Manager mode enabled${NC}"
echo ""

# --- ENVIRONMENT ---
export COMPOSER_ALLOW_SUPERUSER=1

# --- HELPERS ---

# Run as real user (handles both running as root and running as user)
user_do() {
    if [[ "$(id -u)" -eq 0 && -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
        sudo -u "$REAL_USER" -H "$@"
    else
        "$@"
    fi
}

# Run with elevated privileges (only use sudo if not already root)
sys_do() {
    if [[ "$(id -u)" -ne 0 ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

# Ensure cron is active and has example tasks
cron_ensure() {
    echo "Ensuring cron service is active and configured..."
    # Cron package is already installed in step_1
    sys_do systemctl enable --now cron 2>/dev/null || true

    # Add example tasks to crontab if they don't exist
    # 1. A simple heartbeat to /tmp/cron-heartbeat.log every hour
    # 2. A disk usage snapshot to ~/cron-disk-usage.log every day at midnight
    
    local CRON_HEARTBEAT="0 * * * * echo \"Cron heartbeat: \$(date)\" >> /tmp/cron-heartbeat.log"
    local CRON_DISK="0 0 * * * df -h > \$HOME/cron-disk-usage.log"

    # Get current crontab
    local CURRENT_CRON
    CURRENT_CRON=$(user_do crontab -l 2>/dev/null || echo "")

    local NEW_CRON="$CURRENT_CRON"
    local CHANGED=false

    if [[ ! "$CURRENT_CRON" == *"/tmp/cron-heartbeat.log"* ]]; then
        echo "Adding example cron task: hourly heartbeat"
        NEW_CRON="${NEW_CRON}
${CRON_HEARTBEAT}"
        CHANGED=true
    fi

    if [[ ! "$CURRENT_CRON" == *"cron-disk-usage.log"* ]]; then
        echo "Adding example cron task: daily disk usage snapshot"
        NEW_CRON="${NEW_CRON}
${CRON_DISK}"
        CHANGED=true
    fi

    if [ "$CHANGED" = true ]; then
        # Filter empty lines and install new crontab
        echo "$NEW_CRON" | grep -v '^$' | user_do crontab -
        echo -e "${GREEN}✔ Crontab updated with example tasks.${NC}"
    else
        echo "Crontab already has example tasks."
    fi
}

# --- DETECT OS & DISTRO ---
OS_TYPE=$(uname -s)
if [[ "$OS_TYPE" != "Linux" ]]; then
    echo -e "${RED}Error: This script is for Linux servers only.${NC}"
    exit 1
fi

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    DISTRO_ID=$ID
    DISTRO_CODENAME=${VERSION_CODENAME:-$VERSION_ID}
    
    # Determine Family
    if [[ "$ID" == "ubuntu" || "$ID" == "debian" || "$ID_LIKE" == *"ubuntu"* || "$ID_LIKE" == *"debian"* ]]; then
        DISTRO_FAMILY="debian"
    elif [[ "$ID" == "fedora" || "$ID_LIKE" == *"fedora"* ]]; then
        DISTRO_FAMILY="fedora"
    elif [[ "$ID" == "arch" || "$ID_LIKE" == *"arch"* ]]; then
        DISTRO_FAMILY="arch"
    else
        DISTRO_FAMILY="unknown"
    fi
else
    DISTRO_ID="unknown"
    DISTRO_FAMILY="unknown"
fi

# --- PKG MANAGEMENT HELPERS ---

wait_for_pkg_lock() {
    local max_retries=30
    local retry_count=0
    local lock_files=()

    case "$DISTRO_FAMILY" in
        debian)
            lock_files=("/var/lib/apt/lists/lock" "/var/lib/dpkg/lock-frontend" "/var/lib/dpkg/lock")
            ;;
        fedora)
            lock_files=("/var/run/dnf.pid")
            ;;
        arch)
            lock_files=("/var/lib/pacman/db.lck")
            # Special check for Arch: if lock file exists but pacman/pamac is NOT running, it's stale
            if [[ -f /var/lib/pacman/db.lck ]]; then
                if ! pgrep -xE "pacman|pamac|makepkg" > /dev/null; then
                    echo -e "${YELLOW}Removing stale pacman lock file...${NC}"
                    sys_do rm -f /var/lib/pacman/db.lck
                fi
            fi
            ;;
        *) return 0 ;;
    esac

    for lock_file in "${lock_files[@]}"; do
        while [[ -f "$lock_file" ]]; do
            if (( retry_count >= max_retries )); then
                echo -e "${YELLOW}⚠ Package manager lock ($lock_file) still exists after $max_retries attempts.${NC}"
                echo -e "${YELLOW}If you are sure no other package manager is running, you can manually remove it:${NC}"
                echo -e "${CYAN}  sudo rm $lock_file${NC}"
                return 1
            fi
            echo -e "${CYAN}Waiting for package manager lock ($lock_file)... ($((retry_count + 1))/$max_retries)${NC}"
            sleep 2
            ((retry_count++))
        done
    done
    return 0
}

pkg_update() {
    wait_for_pkg_lock
    case "$DISTRO_FAMILY" in
        debian) sys_do apt-get update -y -qq ;;
        fedora) sys_do dnf check-update -y -q || true ;;
        arch)   sys_do pacman -Sy --noconfirm ;;
    esac
}

pkg_install() {
    wait_for_pkg_lock
    case "$DISTRO_FAMILY" in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            sys_do apt-get install -y -q "$@"
            ;;
        fedora)
            sys_do dnf install -y -q "$@"
            ;;
        arch)
            sys_do pacman -S --noconfirm --needed "$@"
            ;;
        *)
            echo -e "${YELLOW}⚠ Unknown distro family — skipping: pkg_install $*${NC}"
            ;;
    esac
}

# Helper to install GPG keys safely (APT/Debian specific)
install_key() {
    local url=$1
    local dest=$2
    [[ "$DISTRO_FAMILY" != "debian" ]] && return 0
    echo -e "${YELLOW}Installing key:${NC} $url ➜ $dest"
    sys_do mkdir -p -m 755 /etc/apt/keyrings
    if [[ -n "$GPG_CMD" ]] && command -v "$GPG_CMD" >/dev/null 2>&1; then
        if curl -fsSL "$url" | "$GPG_CMD" --dearmor --yes | sys_do tee "$dest" > /dev/null; then
            sys_do chmod a+r "$dest"
            return 0
        fi
    fi
    if curl -fsSL "$url" | sys_do tee "$dest" > /dev/null; then
        sys_do chmod a+r "$dest"
        return 0
    fi
    return 1
}

# --- CLEANUP APT (Debian Only) ---
if [[ "$DISTRO_FAMILY" == "debian" ]]; then
    echo -e "${YELLOW}Preparing APT environment...${NC}"
    sys_do mkdir -p -m 755 /etc/apt/keyrings
    sys_do grep -rl 'docker\|nodesource\|charm\.sh\|cli\.github\|ansible\|codeiumdata\|windsurf\|antigravity\|pkg\.dev' \
        /etc/apt/sources.list.d/ 2>/dev/null | xargs -I {} sys_do rm -f "{}" 2>/dev/null || true

    # Lock waiting is now handled globally in pkg_update/pkg_install
    pkg_update
    pkg_install gnupg gnupg2 curl ca-certificates lsb-release software-properties-common apt-transport-https
    GPG_CMD=$(which gpg 2>/dev/null || which gpg2 2>/dev/null || echo "/usr/bin/gpg")
fi


# --- STEPS CONFIGURATION ---
STEPS=(
    "SetupVibe: Prerequisites & Arch Check"
    "Base System & Build Tools"
    "Docker, Ansible & GitHub CLI"
    "Network, Monitoring & Tailscale"
    "SSH Server"
    "Shell (ZSH & Starship Config)"
    "Tmux & Plugins"
    "AI CLI Tools"
    "Finalization & Cleanup"
)

if [[ "$SWARM_MANAGER" == "true" ]]; then
    STEPS+=("Docker Swarm Manager Setup")
fi


# Variable to track status
declare -a STEP_STATUS


# --- DETECT REAL USER ---
if [[ -n "$SUDO_USER" ]]; then
    REAL_USER="$SUDO_USER"
elif [[ "$(id -u)" -eq 0 ]]; then
    _LOGNAME=$(logname 2>/dev/null)
    _WHO=$(who am i 2>/dev/null | awk '{print $1}')
    if [[ -n "$_LOGNAME" && "$_LOGNAME" != "root" ]]; then
        REAL_USER="$_LOGNAME"
    elif [[ -n "$_WHO" && "$_WHO" != "root" ]]; then
        REAL_USER="$_WHO"
    else
        REAL_USER=$(whoami)
    fi
else
    REAL_USER=$(whoami)
fi
REAL_HOME=$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)
[[ -z "$REAL_HOME" ]] && REAL_HOME="$HOME"


# Already detected above
echo -e "${GREEN}Detected Distro: $DISTRO_ID ($DISTRO_FAMILY)${NC}"


# Detect Architecture
ARCH_RAW=$(uname -m)
if [[ "$ARCH_RAW" == "x86_64" ]]; then
    ARCH_GO="amd64"
elif [[ "$ARCH_RAW" == "aarch64" || "$ARCH_RAW" == "arm64" ]]; then
    ARCH_GO="arm64"
else
    echo -e "${RED}Error: Architecture $ARCH_RAW is not supported.${NC}"
    exit 1
fi


# --- INSTALL FIGLET & GIT ---
# --- INSTALL FIGLET & GIT ---
case "$DISTRO_FAMILY" in
    debian) pkg_install figlet git >/dev/null 2>&1 ;;
    fedora) pkg_install figlet git >/dev/null 2>&1 ;;
    arch)   pkg_install figlet git >/dev/null 2>&1 ;;
esac


# --- UI & LOGIC FUNCTIONS ---

# Helper to install GPG keys safely
install_key() {
    local url=$1
    local dest=$2
    echo -e "${YELLOW}Installing key:${NC} $url ➜ $dest"
    sys_do mkdir -p -m 755 /etc/apt/keyrings
    # Try dearmor if GPG is available
    if [[ -n "$GPG_CMD" ]] && command -v "$GPG_CMD" >/dev/null 2>&1; then
        if curl -fsSL "$url" | "$GPG_CMD" --dearmor --yes | sys_do tee "$dest" > /dev/null; then
            sys_do chmod a+r "$dest"
            return 0
        fi
    fi
    # Fallback: download as-is (modern APT handles armored keys)
    if curl -fsSL "$url" | sys_do tee "$dest" > /dev/null; then
        sys_do chmod a+r "$dest"
        return 0
    fi
    echo -e "${RED}✘ Failed to install key from $url${NC}"
    return 1
}

header() {
    clear
    echo -e "${MAGENTA}"
    figlet "SETUPVIBE" 2>/dev/null || echo "SETUPVIBE.DEV"
    echo -e "${NC}"
    echo -e "${CYAN}:: Linux Server Edition ::${NC}"
    echo -e "${YELLOW}Maintained by PromovaWeb.com | Contact: contato@promovaweb.com${NC}"
    echo "--------------------------------------------------------"
    echo "OS: $DISTRO_ID $DISTRO_CODENAME | Arch: $ARCH_RAW | User: $REAL_USER"
    echo "--------------------------------------------------------"
}


show_roadmap_and_wait() {
    header
    echo -e "${BOLD}SetupVibe Server - Installation Roadmap:${NC}\n"
    for i in "${!STEPS[@]}"; do
        echo -e "  [$(($i+1))/${#STEPS[@]}] ${STEPS[$i]}"
    done
    echo ""
    echo -e "--------------------------------------------------------"
    echo -e "${YELLOW}  ➜ Press [ENTER] to start SetupVibe Server Edition.${NC}"
    echo -e "${RED}  ➜ Type 'q' + ENTER to cancel.${NC}"
    echo -e "--------------------------------------------------------"

    read -r key < /dev/tty
    if [[ "$key" == "q" || "$key" == "Q" ]]; then
        echo -e "\n${RED}[CANCELLED] See you next time!${NC}"
        exit 0
    fi
}


configure_git_interactive() {
    echo ""
    echo -e "${BLUE}=== Checking Git Identity ===${NC}"

    CURRENT_NAME=$(user_do git config --global user.name)
    CURRENT_EMAIL=$(user_do git config --global user.email)

    if [[ -n "$CURRENT_NAME" && -n "$CURRENT_EMAIL" ]]; then
        echo -e "${GREEN}✔ Git configured:${NC} $CURRENT_NAME ($CURRENT_EMAIL)"
    else
        echo -e "${YELLOW}⚠ Git not configured. Let's fix that now.${NC}"
        echo ""

        GIT_NAME=""
        GIT_EMAIL=""

        while [[ -z "$GIT_NAME" ]]; do
            echo -ne "Enter your Full Name: "
            read GIT_NAME < /dev/tty
        done

        while [[ -z "$GIT_EMAIL" ]]; do
            echo -ne "Enter your Email: "
            read GIT_EMAIL < /dev/tty
        done

        user_do git config --global user.name "$GIT_NAME"
        user_do git config --global user.email "$GIT_EMAIL"
        user_do git config --global init.defaultBranch main

        echo -e "${GREEN}✔ Git configured!${NC}"
    fi
    sleep 1
}


run_section() {
    local index=$1
    local title="${STEPS[$index]}"
    echo ""
    echo -e "${BLUE}========================================================${NC}"
    echo -e "${BOLD}▶ [$(($index+1))/${#STEPS[@]}] $title ${NC}"
    echo -e "${BLUE}========================================================${NC}"
    if $2; then
        STEP_STATUS[$index]="${GREEN}✔ OK${NC}"
    else
        STEP_STATUS[$index]="${RED}✘ Error${NC}"
    fi
}


git_ensure() {
    local repo=$1
    local dest=$2
    if [ -d "$dest" ]; then
        echo "Updating: $dest..."
        user_do git -C "$dest" pull --quiet
    else
        echo "Cloning: $repo..."
        user_do git clone "$repo" "$dest" --quiet
    fi
    sys_do chown -R $REAL_USER:$(id -gn $REAL_USER) "$dest" 2>/dev/null || true
}

safe_download() {
    local url=$1
    local dest=$2
    local min_bytes=${3:-100}
    local tmp
    tmp=$(mktemp)

    echo "Downloading: $url"
    if ! curl -fsSL --max-time 30 "$url" -o "$tmp" 2>/dev/null; then
        echo -e "${RED}✘ Download failed: $url${NC}"
        rm -f "$tmp"
        return 1
    fi

    # Reject empty or suspiciously small files (e.g. GitHub 404 HTML pages)
    local size
    size=$(wc -c < "$tmp")
    if [ "$size" -lt "$min_bytes" ]; then
        echo -e "${RED}✘ Downloaded file is too small (${size} bytes) — skipping: $dest${NC}"
        rm -f "$tmp"
        return 1
    fi

    # Reject HTML error responses (GitHub returns 200 with HTML on 404)
    if head -1 "$tmp" | grep -qi "<!doctype\|<html"; then
        echo -e "${RED}✘ Downloaded file appears to be an HTML error page — skipping: $dest${NC}"
        rm -f "$tmp"
        return 1
    fi

    # Ensure parent directory exists and is writable
    local dest_dir
    dest_dir=$(dirname "$dest")
    if [ ! -d "$dest_dir" ]; then
        user_do mkdir -p "$dest_dir"
    fi

    user_do mv "$tmp" "$dest"
    echo -e "${GREEN}✔ Downloaded: $dest${NC}"
    return 0
}


# --- INSTALLATION STEPS ---


step_0() {
    echo "Architecture detected: $ARCH_RAW"
    echo "Operating System: Linux"
    echo "Distribution: $DISTRO_ID $DISTRO_CODENAME"
    echo "Real user: $REAL_USER"
    echo "Home directory: $REAL_HOME"
    return 0
}


step_1() {
    echo "Updating package manager..."
    pkg_update

    case "$DISTRO_FAMILY" in
        debian)
            echo "Installing Build Essentials & Core Server Tools (APT)..."
            pkg_install build-essential git wget unzip fontconfig curl sshpass \
                libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
                libncurses5-dev xz-utils libffi-dev liblzma-dev \
                libyaml-dev autoconf procps file tmux fzf \
                python3 python3-pip python3-venv python-is-python3 \
                cron logrotate rsyslog
            ;;
        fedora)
            echo "Installing Development Tools & Core Server Tools (DNF)..."
            sys_do dnf groupinstall -y "Development Tools"
            pkg_install git wget unzip fontconfig curl sshpass dnf-plugins-core \
                openssl-devel zlib-devel bzip2-devel readline-devel sqlite-devel \
                ncurses-devel xz-devel libffi-devel \
                libyaml-devel gdbm-devel gmp-devel autoconf procps-ng file tmux fzf \
                python3 python3-pip cronie logrotate rsyslog
            ;;
        arch)
            echo "Installing Base-Devel & Core Server Tools (Pacman)..."
            pkg_install base-devel git wget unzip fontconfig curl sshpass \
                openssl zlib bzip2 readline sqlite ncurses xz libffi \
                libyaml autoconf procps-ng file tmux fzf \
                python python-pip cronie logrotate rsyslog
            ;;
    esac

    echo "Installing zoxide..."
    if ! command -v zoxide &>/dev/null; then
        curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | user_do sh
    fi

    echo "Setup uv (Python Package Manager)..."
    if ! user_do bash -c "export PATH=\$HOME/.local/bin:\$PATH; command -v uv" &> /dev/null; then
        user_do bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
    else
        user_do bash -c "export PATH=\$HOME/.local/bin:\$PATH; uv self update"
    fi
    export PATH="$REAL_HOME/.local/bin:$PATH"

    echo "Installing Cronboard (Cron TUI)..."
    if ! user_do bash -c "export PATH=\$HOME/.local/bin:\$PATH; command -v cronboard" &> /dev/null; then
        user_do bash -c "export PATH=\$HOME/.local/bin:\$PATH; uv tool install git+https://github.com/antoniorodr/cronboard"
    fi

    cron_ensure
}


step_2() {
    # Docker Strategy
    echo "Configuring Docker..."
    case "$DISTRO_FAMILY" in
        debian)
            DOCKER_CODENAME="$DISTRO_CODENAME"
            [[ "$DISTRO_ID" == "debian" ]] && case "$DISTRO_CODENAME" in trixie|forky|sid|experimental) DOCKER_CODENAME="bookworm" ;; esac
            install_key "https://download.docker.com/linux/$DISTRO_ID/gpg" "/etc/apt/keyrings/docker.gpg"
            echo "deb [arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$DISTRO_ID $DOCKER_CODENAME stable" | sys_do tee /etc/apt/sources.list.d/docker.list
            pkg_update
            pkg_install docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin
            ;;
        fedora)
            sys_do dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            pkg_install docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin
            ;;
        arch)
            pkg_install docker docker-compose
            ;;
    esac
    sys_do usermod -aG docker "$REAL_USER" || true
    sys_do systemctl enable --now docker 2>/dev/null || true

    # Ansible Strategy
    echo "Configuring Ansible..."
    case "$DISTRO_FAMILY" in
        debian)
            if [[ "$DISTRO_ID" == "ubuntu" ]]; then
                sys_do add-apt-repository --yes --update ppa:ansible/ansible
                pkg_install ansible
            else
                pkg_install ansible-core
            fi
            ;;
        fedora)
            pkg_install ansible
            ;;
        arch)
            pkg_install ansible
            ;;
    esac

    # GitHub CLI
    echo "Installing GitHub CLI..."
    case "$DISTRO_FAMILY" in
        debian)
            wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sys_do tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
            sys_do chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
            echo "deb [arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sys_do tee /etc/apt/sources.list.d/github-cli.list > /dev/null
            pkg_update && pkg_install gh
            ;;
        fedora)
            sys_do dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
            pkg_install gh
            ;;
        arch)
            pkg_install github-cli
            ;;
    esac

    # Portainer Setup
    echo "Configuring Portainer..."
    user_do mkdir -p "$REAL_HOME/.setupvibe/portainer_data"
    safe_download https://raw.githubusercontent.com/promovaweb/setupvibe/main/conf/portainer-compose.yml "$REAL_HOME/.setupvibe/portainer-compose.yml"
    sys_do chown -R "$REAL_USER:$(id -gn $REAL_USER)" "$REAL_HOME/.setupvibe"

    # Try to start Portainer if docker is running
    if command -v docker &>/dev/null && sys_do docker info &>/dev/null; then
        echo "Starting Portainer..."
        sys_do docker compose -f "$REAL_HOME/.setupvibe/portainer-compose.yml" up -d
        echo -e "${GREEN}✔ Portainer is running at http://localhost:9000 and https://localhost:9443${NC}"
    else
        echo -e "${YELLOW}⚠ Docker is not running or socket is not ready. Portainer will be ready to start later with:${NC}"
        echo -e "${CYAN}  docker compose -f ~/.setupvibe/portainer-compose.yml up -d${NC}"
    fi
}


step_3() {
    echo "Installing Network & Monitoring Tools..."
    pkg_install rsync net-tools nmap tcpdump iftop nload iotop sysstat whois glances htop btop || true
    
    case "$DISTRO_FAMILY" in
        debian) pkg_install dnsutils mtr-tiny iputils-ping speedtest-cli ;;
        fedora) pkg_install bind-utils mtr iputils speedtest-cli ;;
        arch)   pkg_install bind mtr iputils ;;
    esac

    echo "Installing ctop for $ARCH_GO..."
    if ! command -v ctop &>/dev/null && [ ! -f "$REAL_HOME/.local/bin/ctop" ]; then
        user_do mkdir -p "$REAL_HOME/.local/bin"
        wget -q "https://github.com/bcicen/ctop/releases/download/v0.7.7/ctop-0.7.7-linux-${ARCH_GO}" -O /tmp/ctop
        user_do mv /tmp/ctop "$REAL_HOME/.local/bin/ctop"
        user_do chmod +x "$REAL_HOME/.local/bin/ctop"
    fi

    echo "Installing Tailscale..."
    if ! command -v tailscale &>/dev/null; then
        if [[ "$DISTRO_FAMILY" == "arch" ]]; then
            pkg_install tailscale
            sys_do systemctl enable --now tailscaled 2>/dev/null || true
        else
            user_do curl -fsSL https://tailscale.com/install.sh | sys_do sh
        fi
    else
        echo "Tailscale already installed."
    fi
}


step_4() {
    echo "Setting up SSH Server..."

    case "$DISTRO_FAMILY" in
        debian) pkg_install openssh-server openssh-client ;;
        fedora) pkg_install openssh-server openssh-clients ;;
        arch)   pkg_install openssh ;;
    esac

    echo "Enabling SSH service..."
    sys_do systemctl enable ssh 2>/dev/null || sys_do systemctl enable sshd 2>/dev/null
    sys_do systemctl start ssh 2>/dev/null || sys_do systemctl start sshd 2>/dev/null

    if [ ! -f /etc/ssh/sshd_config.backup ]; then
        sys_do cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
        echo "Backed up original sshd_config"
    fi

    echo "Configuring SSH to allow root login..."
    sys_do sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
    sys_do sed -i 's/^PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
    sys_do sed -i 's/^#PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config
    sys_do sed -i 's/^PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config

    echo "Enabling password authentication for SSH..."
    sys_do sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sys_do sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config

    if sys_do sshd -t &> /dev/null; then
        sys_do systemctl restart ssh 2>/dev/null || sys_do systemctl restart sshd 2>/dev/null
        echo -e "${GREEN}✔ SSH Server configured and running${NC}"
    else
        echo -e "${RED}Error: SSH configuration failed validation${NC}"
        echo "Restoring original configuration..."
        sys_do cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
        sys_do systemctl restart ssh 2>/dev/null || sys_do systemctl restart sshd 2>/dev/null
        return 1
    fi
}


step_5() {
    echo "Installing ZSH..."
    case "$DISTRO_FAMILY" in
        debian) pkg_install zsh ;;
        fedora) pkg_install zsh ;;
        arch)   pkg_install zsh ;;
    esac

    if [ ! -d "$REAL_HOME/.oh-my-zsh" ]; then
        user_do sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    fi

    git_ensure "https://github.com/zsh-users/zsh-autosuggestions" "$REAL_HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions"
    git_ensure "https://github.com/zsh-users/zsh-syntax-highlighting" "$REAL_HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting"

    echo "Configuring Starship..."
    if ! command -v starship &>/dev/null && [ ! -f "$REAL_HOME/.local/bin/starship" ]; then
        user_do mkdir -p "$REAL_HOME/.local/bin"
        curl -sS https://starship.rs/install.sh | user_do sh -s -- -y --bin-dir "$REAL_HOME/.local/bin"
    fi
    user_do mkdir -p "$REAL_HOME/.config"

    echo "Applying Starship Preset: Gruvbox Rainbow..."
    user_do starship preset gruvbox-rainbow -o "$REAL_HOME/.config/starship.toml"
    sed -i 's/╭/┌/g; s/╰/└/g' "$REAL_HOME/.config/starship.toml"

    # Server ZSHRC
    safe_download https://raw.githubusercontent.com/promovaweb/setupvibe/main/conf/zshrc-server.zsh "$REAL_HOME/.zshrc"
    sys_do chown $REAL_USER:$REAL_USER "$REAL_HOME/.zshrc"

    # Ensure ~/.local/bin is in .bashrc so tools like uv are accessible in bash sessions
    if ! grep -q '\.local/bin' "$REAL_HOME/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' | user_do tee -a "$REAL_HOME/.bashrc" > /dev/null
    fi

    if [ "$SHELL" != "/bin/zsh" ] && [ "$SHELL" != "/usr/bin/zsh" ]; then
        ZSH_PATH=$(which zsh)
        if ! grep -qF "$ZSH_PATH" /etc/shells; then
            echo "$ZSH_PATH" | sys_do tee -a /etc/shells > /dev/null
        fi
        # Try chsh first, fall back to usermod
        if ! sys_do chsh -s "$ZSH_PATH" "$REAL_USER"; then
            echo -e "${YELLOW}chsh failed, trying usermod as fallback...${NC}"
            sys_do usermod -s "$ZSH_PATH" "$REAL_USER" 2>/dev/null || true
        fi
    fi
}


step_6() {
    echo "Installing TPM (Tmux Plugin Manager)..."
    git_ensure "https://github.com/tmux-plugins/tpm" "$REAL_HOME/.tmux/plugins/tpm"

    echo "Downloading tmux-server.conf..."
    safe_download https://raw.githubusercontent.com/promovaweb/setupvibe/main/conf/tmux-server.conf "$REAL_HOME/.tmux.conf"

    # Also install to /root if running as root with a different REAL_HOME
    if [[ "$(id -u)" -eq 0 && "$REAL_HOME" != "/root" ]]; then
        mkdir -p /root/.tmux/plugins
        cp "$REAL_HOME/.tmux.conf" /root/.tmux.conf
        [[ -d "$REAL_HOME/.tmux/plugins/tpm" ]] && \
            ln -sfn "$REAL_HOME/.tmux/plugins/tpm" /root/.tmux/plugins/tpm 2>/dev/null || true
    fi

    sys_do chown -R $REAL_USER:$(id -gn $REAL_USER) "$REAL_HOME/.tmux" 2>/dev/null || true
    sys_do chown $REAL_USER:$(id -gn $REAL_USER) "$REAL_HOME/.tmux.conf" 2>/dev/null || true

    echo "Restarting tmux to apply new config..."
    user_do pkill -x tmux 2>/dev/null || true
}


step_7() {
    echo "Setup Node.js..."
    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        echo "Setup NodeSource (Debian)..."
        install_key "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" "/etc/apt/keyrings/nodesource.gpg"
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" | sys_do tee /etc/apt/sources.list.d/nodesource.list
        pkg_update
        pkg_install nodejs
    elif [[ "$DISTRO_FAMILY" == "fedora" ]]; then
        echo "Setup NodeSource (Fedora)..."
        curl -fsSL https://rpm.nodesource.com/setup_24.x | sys_do bash -
        pkg_install nodejs
    elif [[ "$DISTRO_FAMILY" == "arch" ]]; then
        echo "Setup Node.js (Arch)..."
        pkg_install nodejs npm
    fi

    local NPM_BIN
    NPM_BIN=$(command -v npm 2>/dev/null)

    if [ -z "$NPM_BIN" ]; then
        echo -e "${RED}✘ npm not found after Node.js installation — skipping AI CLI Tools.${NC}"
        return 1
    fi

    # Configure npm for user-writable directory if not root
    if [[ "$(id -u)" -ne 0 ]]; then
        user_do mkdir -p "$REAL_HOME/.npm-global"
        user_do "$NPM_BIN" config set prefix "$REAL_HOME/.npm-global"
        export PATH="$REAL_HOME/.npm-global/bin:$PATH"
    fi

    AI_TOOLS=(
        "@anthropic-ai/claude-code"
        "@google/gemini-cli"
        "@openai/codex"
        "@githubnext/github-copilot-cli"
    )

    for pkg in "${AI_TOOLS[@]}"; do
        echo "Installing $pkg..."
        user_do "$NPM_BIN" install -g "$pkg" 2>/dev/null || echo -e "${YELLOW}⚠ Failed to install $pkg${NC}"
    done
}


step_8() {
    echo "Cleaning package manager cache..."
    case "$DISTRO_FAMILY" in
        debian)
            sys_do apt-get autoremove -y -qq
            sys_do apt-get autoclean -qq
            sys_do apt-get clean -qq
            sys_do rm -rf /var/lib/apt/lists/*
            ;;
        fedora)
            sys_do dnf autoremove -y -q
            sys_do dnf clean all -q
            ;;
        arch)
            sys_do pacman -Rns $(pacman -Qtdq) --noconfirm 2>/dev/null || true
            sys_do pacman -Scc --noconfirm
            ;;
    esac

    echo "Cleaning temp and log junk..."
    sys_do rm -rf /tmp/ctop /tmp/starship 2>/dev/null || true
    sys_do journalctl --vacuum-time=7d 2>/dev/null || true

    echo "Cleaning user caches..."
    rm -rf "$REAL_HOME/.cache/pip" 2>/dev/null || true
    rm -rf "$REAL_HOME/.cache/composer" 2>/dev/null || true
    rm -rf "$REAL_HOME/.npm/_npx" 2>/dev/null || true
    rm -rf "$REAL_HOME/.bundle/cache" 2>/dev/null || true
}


step_swarm() {
    echo "Detecting public IP address..."
    PUBLIC_IP=""
    for service in \
        "https://api.ipify.org" \
        "https://ifconfig.me" \
        "https://icanhazip.com" \
        "https://checkip.amazonaws.com" \
        "https://ipecho.net/plain"; do
        PUBLIC_IP=$(curl -fsSL --max-time 10 "$service" 2>/dev/null | tr -d '[:space:]')
        if [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo -e "${GREEN}✔ Public IP detected: $PUBLIC_IP (via $service)${NC}"
            break
        fi
        PUBLIC_IP=""
    done

    if [[ -z "$PUBLIC_IP" ]]; then
        echo -e "${RED}✘ Could not determine public IP address. Aborting Swarm setup.${NC}"
        return 1
    fi

    echo "Initializing Docker Swarm (advertise address: $PUBLIC_IP)..."
    if docker info 2>/dev/null | grep -q "Swarm: active"; then
        echo -e "${YELLOW}⚠ Docker Swarm is already active — skipping init.${NC}"
    else
        if ! sys_do docker swarm init --advertise-addr "$PUBLIC_IP"; then
            echo -e "${RED}✘ Docker Swarm init failed.${NC}"
            return 1
        fi
        echo -e "${GREEN}✔ Docker Swarm initialized as manager node.${NC}"
    fi

    echo "Creating overlay network: network_swarm_public..."
    if docker network ls --format '{{.Name}}' | grep -q "^network_swarm_public$"; then
        echo -e "${YELLOW}⚠ Overlay network 'network_swarm_public' already exists — skipping.${NC}"
    else
        if ! sys_do docker network create \
            --driver overlay \
            --attachable \
            network_swarm_public; then
            echo -e "${RED}✘ Failed to create overlay network.${NC}"
            return 1
        fi
        echo -e "${GREEN}✔ Overlay network 'network_swarm_public' created.${NC}"
    fi

    echo ""
    echo -e "${CYAN}Docker Swarm join token (worker):${NC}"
    sys_do docker swarm join-token worker
    echo ""
    echo -e "${CYAN}Docker Swarm join token (manager):${NC}"
    sys_do docker swarm join-token manager
}


# --- MAIN EXECUTION ---


show_roadmap_and_wait
configure_git_interactive


echo -e "\n${GREEN}Starting SetupVibe Server installation...${NC}"


# Execution Loop
run_section 0 step_0
run_section 1 step_1
run_section 2 step_2
run_section 3 step_3
run_section 4 step_4
run_section 5 step_5
run_section 6 step_6
run_section 7 step_7
run_section 8 step_8

if [[ "$SWARM_MANAGER" == "true" ]]; then
    run_section 9 step_swarm
fi


# --- DOCKER SWARM PROMPT (only if --manager was not passed) ---
if [[ "$SWARM_MANAGER" == "false" ]]; then
    echo ""
    echo -e "${BLUE}========================================================${NC}"
    echo -e "${BOLD}         DOCKER SWARM MANAGER SETUP (OPTIONAL)         ${NC}"
    echo -e "${BLUE}========================================================${NC}"
    echo -e "${YELLOW}Do you want to configure this machine as a Docker Swarm Manager?${NC}"
    echo -e "  This will:"
    echo -e "  - Detect the public IP of this server"
    echo -e "  - Initialize Docker Swarm (${CYAN}docker swarm init${NC})"
    echo -e "  - Create overlay network ${CYAN}network_swarm_public${NC}"
    echo ""
    echo -ne "${BOLD}Configure as Swarm Manager? [y/N]: ${NC}"
    read -r SWARM_ANSWER < /dev/tty
    if [[ "$SWARM_ANSWER" =~ ^[yYsS]$ ]]; then
        SWARM_MANAGER=true
        STEPS+=("Docker Swarm Manager Setup")
        run_section 9 step_swarm
    else
        echo -e "${YELLOW}Skipping Docker Swarm setup.${NC}"
    fi
fi


# --- FINALIZATION ---
echo ""
echo -e "${BLUE}========================================================${NC}"
echo -e "${BOLD}         SETUPVIBE SERVER - INSTALLATION SUMMARY        ${NC}"
echo -e "${BLUE}========================================================${NC}"
for i in "${!STEPS[@]}"; do
    echo -e "  [$(($i+1))] ${STEPS[$i]} ... ${STEP_STATUS[$i]}"
done
echo ""
echo -e "${GREEN}${BOLD}SetupVibe Server Edition Completed Successfully! 🚀${NC}"
echo ""
echo -e "${YELLOW}${BOLD}IMPORTANT - Apply changes to your shell:${NC}"
echo -e "${CYAN}Reload ZSH now:${NC}   exec zsh"
echo -e "${CYAN}Or for Bash:${NC}      source ~/.bashrc"
echo ""
echo -e "${YELLOW}Or restart your terminal / logout and login again.${NC}"
