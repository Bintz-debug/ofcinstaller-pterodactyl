#!/usr/bin/env bash
###############################################################################
# installerptd.sh  (v2.0)
# All-in-one Pterodactyl Installer / Uninstaller - Multi Distro Linux
#
# Keluarga distro yang didukung (semua versi yang masih mendapat update):
#   - Debian family : Ubuntu 20.04+, Debian 11+, Linux Mint, Pop!_OS, Zorin,
#                     dan turunan Debian/Ubuntu lain (apt)
#   - RHEL family   : Rocky, AlmaLinux, CentOS Stream, RHEL, Oracle Linux 8+,
#                     Fedora 38+ (dnf)
#
# Menu:
#   1) Install Panel   (domain, SSL, database, admin - semua otomatis)
#   2) Install Wings   (Docker + Wings + konfigurasi dari Node)
#   3) Uninstall Panel (bersih total, hanya paket yang dipasang script ini)
#   4) Uninstall Wings (Wings + container game + opsional Docker)
#
# Jalankan: sudo bash installerptd.sh
# Log lengkap: /var/log/installerptd.log
###############################################################################

set -uo pipefail

readonly SCRIPT_VERSION="2.0"
readonly LOG_FILE="/var/log/installerptd.log"
readonly STATE_FILE="/root/.installerptd-info"
readonly PANEL_DIR="/var/www/pterodactyl"
readonly ACME_ROOT="/var/www/_letsencrypt"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# Variabel global (diisi saat runtime)
OS_ID=""; OS_LIKE=""; OS_VERSION="0"; OS_MAJOR="0"; OS_CODENAME=""; OS_PRETTY=""
DISTRO_FAMILY=""; EL_MAJOR=0
PHP_VER=""; PHP_BIN=""; PHP_FPM_SERVICE=""; PHP_FPM_SOCK=""
DB_SERVICE=""; REDIS_SERVICE=""; WEB_USER=""; WEB_GROUP=""
USE_SSL=0; IGNORE_PHP_PLATFORM=0

###############################################################################
# UTILITAS DASAR
###############################################################################
log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true; }
info() { echo -e "${CYAN}[i]${NC} $*"; log "INFO: $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; log "OK: $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; log "WARN: $*"; }
err()  { echo -e "${RED}[X]${NC} $*" >&2; log "ERR: $*"; }
die()  { err "$*"; echo -e "    Log lengkap: ${LOG_FILE}" >&2; exit 1; }
step() { echo -e "\n${GREEN}==> $*${NC}"; log "STEP: $*"; }

# run "Deskripsi" perintah args...   -> output ke log, tampil OK / GAGAL
run() {
    local desc="$1"; shift
    printf '  %-58s ' "$desc ..."
    log "RUN: $desc :: $*"
    if "$@" >>"$LOG_FILE" 2>&1; then
        echo -e "${GREEN}OK${NC}"
        return 0
    else
        local rc=$?
        echo -e "${RED}GAGAL${NC} (kode ${rc})"
        tail -n 12 "$LOG_FILE" 2>/dev/null | sed 's/^/      | /'
        return "$rc"
    fi
}
run_or_die() { local d="$1"; run "$@" || die "Langkah gagal: ${d}"; }
run_soft()   { run "$@" || true; }

trim() {
    local s="$1"
    s="${s//$'\r'/}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ask VAR "Prompt" "default" [validator] [pesan_error]
ask() {
    local __var="$1" __prompt="$2" __def="${3:-}" __validator="${4:-}"
    local __errmsg="${5:-Input tidak valid, coba lagi.}" __in
    while true; do
        if [[ -n "$__def" ]]; then
            read -r -p "$__prompt [$__def]: " __in || die "Input dihentikan."
        else
            read -r -p "$__prompt: " __in || die "Input dihentikan."
        fi
        __in="$(trim "$__in")"
        [[ -z "$__in" ]] && __in="$__def"
        if [[ -z "$__in" ]]; then warn "Wajib diisi."; continue; fi
        if [[ -n "$__validator" ]] && ! "$__validator" "$__in"; then
            warn "$__errmsg"; continue
        fi
        printf -v "$__var" '%s' "$__in"
        return 0
    done
}

# ask_secret VAR "Prompt" [validator] [pesan_error]   (minta konfirmasi ulang)
ask_secret() {
    local __var="$1" __prompt="$2" __validator="${3:-}" __errmsg="${4:-Input tidak valid.}" a b
    while true; do
        read -r -s -p "$__prompt: " a || die "Input dihentikan."; echo
        a="${a//$'\r'/}"
        if [[ -z "$a" ]]; then warn "Wajib diisi."; continue; fi
        if [[ -n "$__validator" ]] && ! "$__validator" "$a"; then warn "$__errmsg"; continue; fi
        read -r -s -p "Ulangi password: " b || die "Input dihentikan."; echo
        b="${b//$'\r'/}"
        if [[ "$a" != "$b" ]]; then warn "Password tidak sama, ulangi."; continue; fi
        printf -v "$__var" '%s' "$a"
        return 0
    done
}

# confirm "Pertanyaan" [y|n default]
confirm() {
    local p="$1" d="${2:-n}" a hint="[y/N]"
    [[ "$d" == "y" ]] && hint="[Y/n]"
    while true; do
        read -r -p "$p $hint: " a || die "Input dihentikan."
        a="$(trim "$a")"; a="${a,,}"
        [[ -z "$a" ]] && a="$d"
        case "$a" in
            y|yes|ya) return 0 ;;
            n|no|tidak) return 1 ;;
        esac
    done
}

random_pass() {
    local p
    p="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24)" || true
    printf '%s' "$p"
}

###############################################################################
# VALIDATOR INPUT
###############################################################################
is_email() {
    local re='^[A-Za-z0-9_%+-]+(\.[A-Za-z0-9_%+-]+)*@([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$'
    [[ "$1" =~ $re ]]
}
is_fqdn() {
    local re='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$'
    [[ "$1" =~ $re ]]
}
is_ipv4() {
    local re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    [[ "$1" =~ $re ]]
}
is_host()  { is_fqdn "$1" || is_ipv4 "$1"; }
is_ident() { local re='^[A-Za-z0-9_]{1,32}$'; [[ "$1" =~ $re ]]; }
is_username() { local re='^[A-Za-z0-9]([A-Za-z0-9_.-]*[A-Za-z0-9])?$'; [[ "$1" =~ $re && ${#1} -ge 3 ]]; }
is_nonempty() { [[ -n "$(trim "$1")" ]]; }
is_tz() {
    local re='^[A-Za-z0-9_+/-]+$'
    [[ "$1" =~ $re ]] || return 1
    [[ ! -d /usr/share/zoneinfo ]] && return 0
    [[ -f "/usr/share/zoneinfo/$1" ]]
}
is_db_pass() {
    case "$1" in
        *\'*|*\"*|*\\*|*" "*|*\$*|*\`*) return 1 ;;
    esac
    [[ ${#1} -ge 8 ]]
}
is_admin_pass() { [[ ${#1} -ge 8 && "$1" =~ [A-Z] && "$1" =~ [a-z] && "$1" =~ [0-9] ]]; }

###############################################################################
# STATE FILE (dipakai uninstall supaya tahu persis apa yang dipasang script)
###############################################################################
state_set() {
    local k="$1" v="$2"
    touch "$STATE_FILE"; chmod 600 "$STATE_FILE"
    sed -i "/^${k}=/d" "$STATE_FILE"
    printf '%s=%q\n' "$k" "$v" >>"$STATE_FILE"
}
state_set_once() { grep -q "^$1=" "$STATE_FILE" 2>/dev/null || state_set "$1" "$2"; }
state_append() {   # state_append KEY item   (daftar dipisah spasi, tanpa duplikat)
    local k="$1" item="$2" cur=""
    [[ -f "$STATE_FILE" ]] && cur="$(grep "^${k}=" "$STATE_FILE" | head -1 | sed -E "s/^${k}=//" | tr -d "'\"\\\\")"
    case " $cur " in *" $item "*) return 0 ;; esac
    state_set "$k" "$(trim "$cur $item")"
}
state_load() {
    # shellcheck disable=SC1090
    [[ -f "$STATE_FILE" ]] && . "$STATE_FILE"
    return 0
}
flag_preexisting() {  # flag_preexisting INST_KEY "perintah-cek"  -> 1 jika script yang memasang
    local key="$1"; shift
    if "$@" >/dev/null 2>&1; then state_set_once "$key" 0; else state_set_once "$key" 1; fi
}

###############################################################################
# DETEKSI OS
###############################################################################
detect_os() {
    [[ -f /etc/os-release ]] || die "Tidak bisa mendeteksi OS (/etc/os-release tidak ada)."
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"; OS_ID="${OS_ID,,}"
    OS_LIKE="${ID_LIKE:-}"; OS_LIKE="${OS_LIKE,,}"
    OS_VERSION="${VERSION_ID:-0}"
    OS_MAJOR="${OS_VERSION%%.*}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VERSION}"
    UBUNTU_CODENAME="${UBUNTU_CODENAME:-}"
    DEBIAN_CODENAME="${DEBIAN_CODENAME:-}"

    case "$OS_ID" in
        amzn|alpine|arch|manjaro|opensuse*|sles|gentoo|void|nixos)
            DISTRO_FAMILY="unsupported" ;;
        ubuntu|debian|linuxmint|pop|raspbian|zorin|elementary|neon|kali|ubuntu-core)
            DISTRO_FAMILY="debian" ;;
        rhel|centos|rocky|almalinux|ol|fedora|eurolinux|scientific)
            DISTRO_FAMILY="rhel" ;;
        *)
            if   [[ "$OS_LIKE" == *debian* || "$OS_LIKE" == *ubuntu* ]]; then DISTRO_FAMILY="debian"
            elif [[ "$OS_LIKE" == *rhel* || "$OS_LIKE" == *fedora* || "$OS_LIKE" == *centos* ]]; then DISTRO_FAMILY="rhel"
            else DISTRO_FAMILY="unsupported"; fi ;;
    esac

    if [[ "$DISTRO_FAMILY" == "unsupported" ]]; then
        err "OS '${OS_PRETTY}' belum didukung."
        echo "Didukung: keluarga Debian/Ubuntu (apt) dan keluarga RHEL/Fedora (dnf)."
        exit 1
    fi
    [[ -d /run/systemd/system ]] || die "Sistem ini tidak memakai systemd (container/WSL?). Pterodactyl butuh systemd."

    if [[ "$DISTRO_FAMILY" == "rhel" ]]; then
        command -v dnf >/dev/null 2>&1 || die "dnf tidak ditemukan (RHEL/CentOS 7 sudah EOL & tidak didukung)."
        [[ "$OS_ID" == "fedora" ]] && EL_MAJOR=0 || EL_MAJOR="$OS_MAJOR"
        WEB_USER="nginx"; WEB_GROUP="nginx"
    else
        command -v apt-get >/dev/null 2>&1 || die "apt-get tidak ditemukan."
        WEB_USER="www-data"; WEB_GROUP="www-data"
    fi

    check_min_version
}

is_ubuntu_like() { [[ "$OS_ID" == "ubuntu" || "$OS_LIKE" == *ubuntu* ]]; }

check_min_version() {
    local too_old=0
    case "$OS_ID" in
        ubuntu) [[ "$OS_MAJOR" =~ ^[0-9]+$ ]] && (( OS_MAJOR < 20 )) && too_old=1 ;;
        debian) [[ "$OS_MAJOR" =~ ^[0-9]+$ ]] && (( OS_MAJOR > 0 && OS_MAJOR < 11 )) && too_old=1 ;;
        fedora) [[ "$OS_MAJOR" =~ ^[0-9]+$ ]] && (( OS_MAJOR < 38 )) && too_old=1 ;;
        rhel|centos|rocky|almalinux|ol|eurolinux) [[ "$OS_MAJOR" =~ ^[0-9]+$ ]] && (( OS_MAJOR < 8 )) && too_old=1 ;;
    esac
    if (( too_old )); then
        warn "${OS_PRETTY} sudah EOL / terlalu lama; paket PHP 8.2+ mungkin tidak tersedia."
        confirm "Tetap lanjut dengan risiko sendiri?" n || exit 1
    fi
}

###############################################################################
# ABSTRAKSI PAKET
###############################################################################
apt_get() {
    DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=300 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}
pkg_update()  { if [[ "$DISTRO_FAMILY" == "debian" ]]; then apt_get update; else dnf -y makecache; fi; }
pkg_install() { if [[ "$DISTRO_FAMILY" == "debian" ]]; then apt_get install "$@"; else dnf -y install "$@"; fi; }
pkg_installed() {
    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        dpkg -s "$1" 2>/dev/null | grep -q '^Status: install ok installed'
    else
        rpm -q "$1" >/dev/null 2>&1
    fi
}
pkg_has_candidate() {
    local p="$1" c
    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        c="$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/ {print $2}')"
        [[ -n "$c" && "$c" != "(none)" ]]
    else
        dnf -q list --available "$p" >/dev/null 2>&1 || rpm -q "$p" >/dev/null 2>&1
    fi
}
# Daftar paket terpasang yang cocok dengan regex nama (aman, tidak menyentuh paket lain)
pkgs_matching() {
    local re="$1"
    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        dpkg-query -W -f='${Package}\t${db:Status-Abbrev}\n' 2>/dev/null \
            | awk -F'\t' '$2 ~ /^(ii|rc)/ {print $1}' | sed 's/:.*//' | grep -E "$re" | sort -u
    else
        rpm -qa --qf '%{NAME}\n' 2>/dev/null | grep -E "$re" | sort -u
    fi
}
pkgs_purge() {   # pkgs_purge pkg...
    (( $# )) || return 0
    if [[ "$DISTRO_FAMILY" == "debian" ]]; then apt_get purge "$@"; else dnf -y remove "$@"; fi
}

svc_exists() { systemctl cat "$1.service" >/dev/null 2>&1; }
first_service() { local s; for s in "$@"; do svc_exists "$s" && { printf '%s' "$s"; return 0; }; done; return 1; }

detect_services() {
    DB_SERVICE="$(first_service mariadb mysql mysqld || true)"
    REDIS_SERVICE="$(first_service redis-server redis valkey-server valkey || true)"
    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        PHP_FPM_SERVICE="php${PHP_VER}-fpm"
        PHP_FPM_SOCK="/run/php/php${PHP_VER}-fpm.sock"
    else
        PHP_FPM_SERVICE="php-fpm"
        PHP_FPM_SOCK="/run/php-fpm/pterodactyl.sock"
    fi
}

mysql_bin() { command -v mariadb 2>/dev/null || command -v mysql 2>/dev/null; }
mysql_root() { local b; b="$(mysql_bin)" || return 127; "$b" -u root "$@"; }

ensure_mysql_access() {   # coba socket auth; kalau gagal minta password root
    mysql_root -e 'SELECT 1' >/dev/null 2>&1 && return 0
    warn "Tidak bisa login MariaDB sebagai root tanpa password."
    local p; read -r -s -p "Password root MariaDB (kosong = batal): " p; echo
    [[ -z "$p" ]] && return 1
    export MYSQL_PWD="$p"
    mysql_root -e 'SELECT 1' >/dev/null 2>&1
}

###############################################################################
# FIREWALL & SELINUX
###############################################################################
fw_open() {   # fw_open STATE_KEY 80/tcp 443/tcp  (hanya mencatat rule yang benar-benar kita tambah)
    local key="$1" p; shift
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        state_set_once FW_TOOL ufw
        for p in "$@"; do
            ufw status | grep -qE "^${p%/*}(/${p#*/})?[[:space:]]+ALLOW" && continue
            ufw allow "$p" >>"$LOG_FILE" 2>&1 && state_append "$key" "$p"
        done
        info "Firewall (ufw): port $* dibuka."
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        state_set_once FW_TOOL firewalld
        for p in "$@"; do
            firewall-cmd --query-port="$p" >/dev/null 2>&1 && continue
            firewall-cmd --permanent --add-port="$p" >>"$LOG_FILE" 2>&1 && state_append "$key" "$p"
        done
        firewall-cmd --reload >>"$LOG_FILE" 2>&1
        info "Firewall (firewalld): port $* dibuka."
    else
        info "Tidak ada firewall aktif (ufw/firewalld). Pastikan port $* terbuka di panel provider VPS."
    fi
}
fw_close_recorded() {   # fw_close_recorded STATE_KEY
    local key="$1" p ports="${!1:-}"
    [[ -n "${FW_TOOL:-}" && -n "$ports" ]] || return 0
    for p in $ports; do
        if [[ "$FW_TOOL" == "ufw" ]] && command -v ufw >/dev/null 2>&1; then
            ufw --force delete allow "$p" >>"$LOG_FILE" 2>&1 || true
        elif [[ "$FW_TOOL" == "firewalld" ]] && command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --permanent --remove-port="$p" >>"$LOG_FILE" 2>&1 || true
        fi
    done
    [[ "$FW_TOOL" == "firewalld" ]] && { firewall-cmd --reload >>"$LOG_FILE" 2>&1 || true; }
    ok "Rule firewall yang dibuat script ini dihapus (${ports})."
}

selinux_active() { command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; }
setup_selinux() {
    selinux_active || return 0
    info "SELinux aktif - menyesuaikan konteks untuk Panel..."
    setsebool -P httpd_can_network_connect 1 >>"$LOG_FILE" 2>&1 || true
    setsebool -P httpd_can_network_connect_db 1 >>"$LOG_FILE" 2>&1 || true
    if command -v semanage >/dev/null 2>&1; then
        semanage fcontext -a -t httpd_sys_rw_content_t "${PANEL_DIR}(/.*)?" >>"$LOG_FILE" 2>&1 \
            || semanage fcontext -m -t httpd_sys_rw_content_t "${PANEL_DIR}(/.*)?" >>"$LOG_FILE" 2>&1 || true
        state_set SELINUX_FCONTEXT 1
    fi
    restorecon -R "$PANEL_DIR" >>"$LOG_FILE" 2>&1 || true
}

###############################################################################
# PHP
###############################################################################
find_php_version() {   # find_php_version 8.3 8.2 ... -> set PHP_VER
    local v
    for v in "$@"; do
        if pkg_has_candidate "php${v}-cli" && pkg_has_candidate "php${v}-fpm"; then
            PHP_VER="$v"; return 0
        fi
    done
    return 1
}

add_php_repo_debian() {
    local codename
    if is_ubuntu_like; then
        run "Install software-properties-common" pkg_install software-properties-common || return 1
        run "Tambah PPA ondrej/php" env LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php || return 1
        state_set REPO_PHP ondrej
    else
        codename="${DEBIAN_CODENAME:-$OS_CODENAME}"
        [[ -n "$codename" ]] || return 1
        run "Unduh keyring sury.org" curl -fsSLo /tmp/debsuryorg-archive-keyring.deb \
            https://packages.sury.org/debsuryorg-archive-keyring.deb || return 1
        run "Pasang keyring sury.org" dpkg -i /tmp/debsuryorg-archive-keyring.deb || return 1
        echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ ${codename} main" \
            >/etc/apt/sources.list.d/php-sury.list
        state_set REPO_PHP sury
    fi
    run_soft "Update daftar paket" pkg_update
    return 0
}

remove_php_repo_debian() {
    rm -f /etc/apt/sources.list.d/ondrej-*.list /etc/apt/sources.list.d/ondrej-*.sources \
          /etc/apt/trusted.gpg.d/ondrej-* /etc/apt/keyrings/ondrej-* \
          /etc/apt/sources.list.d/php-sury.list /etc/apt/sources.list.d/php.list \
          /usr/share/keyrings/deb.sury.org-php.gpg
    dpkg -P debsuryorg-archive-keyring >>"$LOG_FILE" 2>&1 || true
}

install_php_debian() {
    PHP_VER=""
    find_php_version 8.3 8.2 || true
    if [[ -z "$PHP_VER" ]]; then
        info "PHP 8.2/8.3 tidak ada di repo bawaan ${OS_PRETTY}; mencoba repo PHP tambahan (Ondrej/Sury)..."
        add_php_repo_debian || warn "Repo PHP tambahan gagal ditambahkan; mencoba paket yang tersedia."
        find_php_version 8.3 8.2 8.4 8.5 || true
        if [[ -z "$PHP_VER" ]]; then
            remove_php_repo_debian; run_soft "Update daftar paket" pkg_update
            die "Tidak menemukan PHP 8.2+ untuk ${OS_PRETTY}."
        fi
    fi
    info "PHP yang dipakai: ${PHP_VER}"
    flag_preexisting INST_PHP pkg_installed "php${PHP_VER}-cli"
    local pk=(cli fpm common gd mysql mbstring bcmath xml curl zip)
    local list=() p
    for p in "${pk[@]}"; do list+=("php${PHP_VER}-${p}"); done
    run_or_die "Install PHP ${PHP_VER} + ekstensi" pkg_install "${list[@]}"
    pkg_has_candidate "php${PHP_VER}-intl" && run_soft "Install php${PHP_VER}-intl" pkg_install "php${PHP_VER}-intl"
    PHP_BIN="$(command -v "php${PHP_VER}" || true)"
    [[ -n "$PHP_BIN" ]] || PHP_BIN="$(command -v php)"
    state_set PANEL_PHP_VER "$PHP_VER"
}

install_epel_rhel() {
    [[ "$OS_ID" == "fedora" ]] && return 0
    rpm -q epel-release >/dev/null 2>&1 && return 0
    if run "Install EPEL" dnf -y install epel-release; then :
    elif [[ "$OS_ID" == "ol" ]] && run "Install EPEL (Oracle)" dnf -y install "oracle-epel-release-el${EL_MAJOR}"; then :
    else
        run "Install EPEL (URL)" dnf -y install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${EL_MAJOR}.noarch.rpm" || return 1
    fi
    state_set REPO_EPEL 1
    run_soft "Aktifkan CRB/PowerTools" bash -c 'dnf -y install dnf-plugins-core; (crb enable || dnf config-manager --set-enabled crb || dnf config-manager --set-enabled powertools)'
    return 0
}

install_php_rhel() {
    local streams stream=""
    PHP_VER=""
    flag_preexisting INST_PHP rpm -q php-cli
    if [[ "$OS_ID" != "fedora" ]] && (( EL_MAJOR < 10 )); then
        streams="$(dnf -q module list --all php 2>/dev/null | awk '$1=="php"{print $2}' | sort -u)"
        if   grep -qx '8.3' <<<"$streams"; then stream="8.3"
        elif grep -qx '8.2' <<<"$streams"; then stream="8.2"
        else
            info "Modul PHP 8.2/8.3 tidak ada di repo bawaan; memakai repo Remi."
            run_or_die "Pasang repo Remi" dnf -y install "https://rpms.remirepo.net/enterprise/remi-release-${EL_MAJOR}.rpm"
            state_set REPO_REMI 1
            stream="remi-8.3"
        fi
        run_or_die "Aktifkan modul php:${stream}" bash -c "dnf -y module reset php && dnf -y module enable php:${stream}"
        state_set PHP_MODULE_ENABLED "$stream"
    fi
    run_or_die "Install PHP + ekstensi" pkg_install php-cli php-fpm php-common php-gd php-mysqlnd php-mbstring php-bcmath php-xml php-pdo
    local o
    for o in php-zip php-intl php-process php-opcache php-sodium; do
        pkg_has_candidate "$o" && run_soft "Install $o" pkg_install "$o"
    done
    PHP_BIN="$(command -v php)"
    PHP_VER="$("$PHP_BIN" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
    state_set PANEL_PHP_VER "$PHP_VER"
}

configure_phpfpm_rhel() {
    mkdir -p /run/php-fpm
    cat >/etc/php-fpm.d/pterodactyl.conf <<EOF
[pterodactyl]
user = ${WEB_USER}
group = ${WEB_GROUP}
listen = ${PHP_FPM_SOCK}
listen.owner = ${WEB_USER}
listen.group = ${WEB_GROUP}
listen.mode = 0660
pm = dynamic
pm.max_children = 20
pm.start_servers = 3
pm.min_spare_servers = 2
pm.max_spare_servers = 6
EOF
    state_set PHPFPM_POOL 1
    systemctl enable "$PHP_FPM_SERVICE" >>"$LOG_FILE" 2>&1
    systemctl restart "$PHP_FPM_SERVICE"
}

check_php_policy() {
    case "$PHP_VER" in
        8.2|8.3) IGNORE_PHP_PLATFORM=0 ;;
        *) IGNORE_PHP_PLATFORM=1
           warn "PHP ${PHP_VER} lebih baru dari yang dijamin Panel (8.2/8.3). Instalasi tetap dicoba, jika ada masalah gunakan PHP 8.3." ;;
    esac
}

###############################################################################
# DEPENDENCY
###############################################################################
port_owner() {
    ss -ltnpH "( sport = :$1 )" 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | head -1 | cut -d'"' -f2
}
free_web_ports() {
    local port owner
    for port in 80 443; do
        owner="$(port_owner "$port" || true)"
        [[ -z "$owner" || "$owner" == "nginx" ]] && continue
        warn "Port ${port} sedang dipakai oleh '${owner}'."
        case "$owner" in
            apache2|httpd)
                if confirm "Stop & nonaktifkan ${owner} supaya Nginx bisa jalan?" y; then
                    systemctl disable --now apache2 httpd >>"$LOG_FILE" 2>&1 || true
                else die "Port ${port} harus bebas untuk Nginx."; fi ;;
            *) die "Hentikan '${owner}' dulu, lalu jalankan ulang script ini." ;;
        esac
    done
}

install_base_packages() {
    local need=() c
    for c in curl wget tar unzip git; do command -v "$c" >/dev/null 2>&1 || need+=("$c"); done
    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        need+=(ca-certificates gnupg cron openssl iproute2)
        run_soft "Update daftar paket" pkg_update
        run_or_die "Install paket dasar" pkg_install "${need[@]}"
        systemctl enable --now cron >>"$LOG_FILE" 2>&1 || true
    else
        need+=(ca-certificates gnupg2 cronie openssl iproute policycoreutils-python-utils)
        run_or_die "Install paket dasar" pkg_install "${need[@]}"
        systemctl enable --now crond >>"$LOG_FILE" 2>&1 || true
    fi
}

install_composer() {
    flag_preexisting INST_COMPOSER command -v composer
    if ! command -v composer >/dev/null 2>&1; then
        run_or_die "Unduh Composer" curl -fsSL https://getcomposer.org/download/latest-stable/composer.phar -o /usr/local/bin/composer
        chmod +x /usr/local/bin/composer
    fi
    run_or_die "Cek Composer" "$PHP_BIN" /usr/local/bin/composer --version
}

install_dependencies() {
    step "Memasang dependency (${DISTRO_FAMILY})"
    install_base_packages
    free_web_ports

    flag_preexisting INST_NGINX   command -v nginx
    flag_preexisting INST_MARIADB bash -c 'command -v mariadbd || command -v mysqld || [[ -x /usr/sbin/mariadbd || -x /usr/sbin/mysqld ]]'
    flag_preexisting INST_REDIS   bash -c 'command -v redis-server || command -v valkey-server'
    flag_preexisting INST_CERTBOT command -v certbot

    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        install_php_debian
        run_or_die "Install MariaDB" pkg_install mariadb-server
        run_or_die "Install Nginx" pkg_install nginx
        if   pkg_has_candidate redis-server; then run_or_die "Install Redis" pkg_install redis-server
        elif pkg_has_candidate valkey-server; then run_or_die "Install Valkey (pengganti Redis)" pkg_install valkey-server
        else die "Paket Redis/Valkey tidak ditemukan."; fi
        (( USE_SSL )) && run_or_die "Install Certbot" pkg_install certbot
    else
        install_epel_rhel || warn "EPEL gagal dipasang; Certbot mungkin tidak tersedia."
        install_php_rhel
        run_or_die "Install MariaDB" pkg_install mariadb-server
        run_or_die "Install Nginx" pkg_install nginx
        if   pkg_has_candidate redis;  then run_or_die "Install Redis" pkg_install redis
        elif pkg_has_candidate valkey; then run_or_die "Install Valkey (pengganti Redis)" pkg_install valkey
        else die "Paket Redis/Valkey tidak ditemukan."; fi
        if (( USE_SSL )); then run_soft "Install Certbot" pkg_install certbot; fi
        # MariaDB di RHEL secara default listen ke semua interface -> kunci ke localhost
        mkdir -p /etc/my.cnf.d
        printf '[mysqld]\nbind-address=127.0.0.1\n' >/etc/my.cnf.d/zz-pterodactyl-bind.cnf
        state_set MARIADB_BIND_CNF 1
    fi

    detect_services
    [[ -n "$DB_SERVICE" ]]    || die "Service MariaDB tidak ditemukan."
    [[ -n "$REDIS_SERVICE" ]] || die "Service Redis/Valkey tidak ditemukan."
    check_php_policy
    install_composer

    [[ "$DISTRO_FAMILY" == "rhel" ]] && configure_phpfpm_rhel
    run_or_die "Aktifkan MariaDB & Redis & PHP-FPM" systemctl enable --now "$DB_SERVICE" "$REDIS_SERVICE" "$PHP_FPM_SERVICE"
    state_set PANEL_WEB_USER "$WEB_USER"
}

###############################################################################
# NGINX
###############################################################################
nginx_supports_http2_directive() {   # nginx >= 1.25.1 memakai 'http2 on;'
    local v
    v="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    [[ -n "$v" ]] || return 1
    [[ "$(printf '%s\n%s\n' "1.25.1" "$v" | sort -V | head -1)" == "1.25.1" ]]
}

nginx_conf_path() {
    if [[ -d /etc/nginx/sites-enabled ]]; then echo "/etc/nginx/sites-available/pterodactyl.conf"
    else echo "/etc/nginx/conf.d/pterodactyl.conf"; fi
}

nginx_php_locations() {
    cat <<EOF
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:${PHP_FPM_SOCK};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
EOF
}

# write_nginx_conf http|ssl
write_nginx_conf() {
    local mode="$1" conf listen_ssl="listen 443 ssl http2;" http2_line=""
    conf="$(nginx_conf_path)"
    if nginx_supports_http2_directive; then listen_ssl="listen 443 ssl;"; http2_line="    http2 on;"; fi
    mkdir -p "$ACME_ROOT" "$(dirname "$conf")"

    if [[ "$mode" == "ssl" ]]; then
        cat >"$conf" <<EOF
server {
    listen 80;
    server_name ${FQDN};

    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    ${listen_ssl}
${http2_line}
    server_name ${FQDN};

    root ${PANEL_DIR}/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    ssl_certificate /etc/letsencrypt/live/${FQDN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${FQDN}/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;

    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

$(nginx_php_locations)
}
EOF
    else
        cat >"$conf" <<EOF
server {
    listen 80;
    server_name ${FQDN};

    root ${PANEL_DIR}/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        try_files \$uri =404;
    }

    add_header X-Content-Type-Options nosniff;
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

$(nginx_php_locations)
}
EOF
    fi

    if [[ "$conf" == /etc/nginx/sites-available/* ]]; then
        ln -sf "$conf" /etc/nginx/sites-enabled/pterodactyl.conf
        # site default hanya dihapus jika Nginx dipasang oleh script ini
        if [[ "${INST_NGINX:-0}" == "1" ]]; then rm -f /etc/nginx/sites-enabled/default; fi
    fi
    state_set PANEL_NGINX_CONF "$conf"
}

nginx_apply() {
    nginx -t >>"$LOG_FILE" 2>&1 || { nginx -t 2>&1 | tail -n 8; return 1; }
    systemctl enable nginx >>"$LOG_FILE" 2>&1
    systemctl restart nginx
}

setup_ssl() {
    USE_SSL=0
    [[ "$WANT_SSL" == "1" ]] || return 0
    command -v certbot >/dev/null 2>&1 || { warn "Certbot tidak tersedia, lanjut tanpa SSL (HTTP)."; return 0; }
    if run "Minta sertifikat Let's Encrypt untuk ${FQDN}" certbot certonly --webroot -w "$ACME_ROOT" \
        -d "$FQDN" --non-interactive --agree-tos --no-eff-email -m "$EMAIL"; then
        write_nginx_conf ssl
        if nginx_apply; then
            USE_SSL=1
            state_set PANEL_SSL 1
            enable_cert_renewal
        else
            warn "Konfigurasi SSL gagal dites, kembali ke HTTP."
            write_nginx_conf http; nginx_apply || true
        fi
    else
        warn "Sertifikat SSL gagal (DNS belum mengarah ke VPS ini / port 80 tertutup?)."
        warn "Panel dipasang dengan HTTP dulu. Setelah DNS benar jalankan: certbot certonly --webroot -w ${ACME_ROOT} -d ${FQDN}"
    fi
}

enable_cert_renewal() {
    if systemctl list-unit-files 2>/dev/null | grep -q '^certbot.timer'; then
        systemctl enable --now certbot.timer >>"$LOG_FILE" 2>&1 || true
    elif systemctl list-unit-files 2>/dev/null | grep -q '^certbot-renew.timer'; then
        systemctl enable --now certbot-renew.timer >>"$LOG_FILE" 2>&1 || true
    else
        printf '0 3 * * * root certbot renew -q --deploy-hook "systemctl reload nginx"\n' >/etc/cron.d/installerptd-certbot
        chmod 644 /etc/cron.d/installerptd-certbot
    fi
}

###############################################################################
# 1) INSTALL PANEL
###############################################################################
resolve_ipv4() { getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}'; }
public_ipv4()  { curl -fsS4 --max-time 6 https://api.ipify.org 2>/dev/null || curl -fsS4 --max-time 6 https://ifconfig.me 2>/dev/null; }

collect_panel_inputs() {
    echo -e "${CYAN}Isi data berikut. Tekan Enter untuk memakai nilai default [dalam kurung].${NC}\n"
    ask FQDN "Domain Panel (contoh: panel.contoh.com) atau IP VPS" "" is_host "Domain/IP tidak valid."
    FQDN="${FQDN,,}"
    ask EMAIL "Email (untuk SSL, author egg, dan akun admin)" "" is_email "Format email tidak valid (contoh: nama@domain.com)."
    ask ADMIN_USER "Username admin Panel" "admin" is_username "Username min. 3 karakter (huruf/angka/_ . -)."
    ask ADMIN_FIRST "Nama depan admin" "Admin" is_nonempty
    ask ADMIN_LAST "Nama belakang admin" "User" is_nonempty
    ask_secret ADMIN_PASS "Password admin Panel (min 8, huruf besar+kecil+angka)" is_admin_pass \
        "Password harus min. 8 karakter dan mengandung huruf besar, huruf kecil, dan angka."
    ask DBNAME "Nama database" "panel" is_ident "Hanya huruf/angka/underscore (maks 32)."
    ask DBUSER "Nama user database" "pterodactyl" is_ident "Hanya huruf/angka/underscore (maks 32)."

    local p
    while true; do
        read -r -s -p "Password database (kosong = dibuat acak otomatis): " p || die "Input dihentikan."; echo
        p="${p//$'\r'/}"
        if [[ -z "$p" ]]; then DBPASS="$(random_pass)"; DBPASS_GENERATED=1; break; fi
        if is_db_pass "$p"; then DBPASS="$p"; DBPASS_GENERATED=0; break; fi
        warn "Min. 8 karakter, tanpa spasi dan tanpa karakter  ' \" \\ \$ \`"
    done

    local def_tz="Asia/Jakarta"
    [[ -r /etc/timezone ]] && is_tz "$(cat /etc/timezone)" && def_tz="$(cat /etc/timezone)"
    ask TZONE "Zona waktu" "$def_tz" is_tz "Zona waktu tidak dikenal (contoh: Asia/Jakarta)."

    WANT_SSL=0
    if is_fqdn "$FQDN"; then
        if confirm "Pasang SSL gratis Let's Encrypt (HTTPS)?" y; then WANT_SSL=1; fi
        local dns_ip my_ip
        dns_ip="$(resolve_ipv4 "$FQDN")"; my_ip="$(public_ipv4 || true)"
        if [[ -z "$dns_ip" ]]; then
            warn "Domain ${FQDN} belum punya A record."
        elif [[ -n "$my_ip" && "$dns_ip" != "$my_ip" ]]; then
            warn "Domain mengarah ke ${dns_ip}, sedangkan IP VPS ini ${my_ip}."
            warn "Jika memakai proxy Cloudflare abaikan; selain itu SSL akan gagal."
        else
            ok "DNS ${FQDN} -> ${dns_ip} sesuai."
        fi
    else
        info "Memakai IP address -> SSL dinonaktifkan (Let's Encrypt butuh domain)."
    fi

    echo ""
    echo -e "${YELLOW}Ringkasan:${NC}"
    echo "  Domain   : ${FQDN}   (SSL: $([[ $WANT_SSL == 1 ]] && echo ya || echo tidak))"
    echo "  Email    : ${EMAIL}"
    echo "  Admin    : ${ADMIN_USER} (${ADMIN_FIRST} ${ADMIN_LAST})"
    echo "  Database : ${DBNAME} / user ${DBUSER}"
    echo "  Timezone : ${TZONE}"
    echo ""
    confirm "Lanjut instalasi?" y || { warn "Dibatalkan."; exit 0; }
}

db_create() {
    local esc="${DBPASS//\\/\\\\}"; esc="${esc//\'/\\\'}"
    mysql_root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DBNAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DBUSER}'@'127.0.0.1' IDENTIFIED BY '${esc}';
ALTER USER '${DBUSER}'@'127.0.0.1' IDENTIFIED BY '${esc}';
GRANT ALL PRIVILEGES ON \`${DBNAME}\`.* TO '${DBUSER}'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
}

download_panel() {
    mkdir -p "$PANEL_DIR"
    cd "$PANEL_DIR" || return 1
    curl -fsSL --retry 3 -o panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz || return 1
    tar -xzf panel.tar.gz || return 1
    rm -f panel.tar.gz
    chmod -R 755 storage/* bootstrap/cache/
    cp .env.example .env
}

composer_install_panel() {
    cd "$PANEL_DIR" || return 1
    export COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_MEMORY_LIMIT=-1
    local extra=()
    (( IGNORE_PHP_PLATFORM )) && extra+=(--ignore-platform-req=php)
    if ! "$PHP_BIN" /usr/local/bin/composer install --no-dev --optimize-autoloader --no-interaction ${extra[@]+"${extra[@]}"}; then
        echo "Composer gagal, mencoba ulang dengan --ignore-platform-req=php ..."
        "$PHP_BIN" /usr/local/bin/composer install --no-dev --optimize-autoloader --no-interaction --ignore-platform-req=php
    fi
}

# Pastikan email lolos FILTER_VALIDATE_EMAIL milik PHP (validator yang dipakai Panel)
ensure_php_valid_email() {
    while ! "$PHP_BIN" -r 'exit(filter_var($argv[1], FILTER_VALIDATE_EMAIL) ? 0 : 1);' "$EMAIL" 2>/dev/null; do
        warn "Email '${EMAIL}' ditolak validator PHP/Panel."
        ask EMAIL "Masukkan email lain" "" is_email "Format email tidak valid."
    done
}

configure_panel_env() {
    cd "$PANEL_DIR" || return 1
    local url="http://${FQDN}"
    (( USE_SSL )) && url="https://${FQDN}"
    ensure_php_valid_email

    "$PHP_BIN" artisan key:generate --force --no-interaction || return 1

    # SEMUA opsi diberikan -> tidak ada prompt interaktif yang bisa gagal
    "$PHP_BIN" artisan p:environment:setup --no-interaction \
        --new-salt \
        --author="$EMAIL" \
        --url="$url" \
        --timezone="$TZONE" \
        --cache=redis --session=redis --queue=redis \
        --redis-host=127.0.0.1 --redis-pass=null --redis-port=6379 \
        --settings-ui=true \
        --telemetry=0 || return 1

    "$PHP_BIN" artisan p:environment:database --no-interaction \
        --host=127.0.0.1 --port=3306 \
        --database="$DBNAME" --username="$DBUSER" --password="$DBPASS" || return 1

    "$PHP_BIN" artisan migrate --seed --force --no-interaction || return 1

    "$PHP_BIN" artisan p:user:make --no-interaction \
        --email="$EMAIL" --username="$ADMIN_USER" \
        --name-first="$ADMIN_FIRST" --name-last="$ADMIN_LAST" \
        --password="$ADMIN_PASS" --admin=1 || return 1
}

setup_panel_services() {
    chown -R "${WEB_USER}:${WEB_GROUP}" "$PANEL_DIR"
    chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache"

    printf '* * * * * %s %s %s/artisan schedule:run >> /dev/null 2>&1\n' "$WEB_USER" "$PHP_BIN" "$PANEL_DIR" >/etc/cron.d/pterodactyl
    chmod 644 /etc/cron.d/pterodactyl

    cat >/etc/systemd/system/pteroq.service <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=${REDIS_SERVICE}.service ${DB_SERVICE}.service

[Service]
User=${WEB_USER}
Group=${WEB_GROUP}
Restart=always
ExecStart=${PHP_BIN} ${PANEL_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now pteroq.service
}

install_panel() {
    step "Install Pterodactyl Panel"
    if [[ -f "$PANEL_DIR/artisan" || -f "$PANEL_DIR/.env" ]]; then
        err "Panel sudah ada di ${PANEL_DIR}."
        echo "Jalankan menu 3 (Uninstall Panel) dulu jika ingin install ulang dari nol."
        return 1
    fi

    collect_panel_inputs
    state_set PANEL_FQDN "$FQDN"; state_set PANEL_DB_NAME "$DBNAME"; state_set PANEL_DB_USER "$DBUSER"
    state_set DISTRO_FAMILY_USED "$DISTRO_FAMILY"; state_set PANEL_SSL 0

    install_dependencies

    step "Menyiapkan database"
    ensure_mysql_access || die "Tidak bisa mengakses MariaDB sebagai root."
    run_or_die "Buat database & user" db_create

    step "Mengunduh Panel & library (Composer)"
    run_or_die "Unduh & ekstrak Panel" download_panel
    echo "  Menjalankan composer install (beberapa menit)..."
    composer_install_panel >>"$LOG_FILE" 2>&1 || die "composer install gagal. Lihat ${LOG_FILE}."
    ok "Library Panel terpasang."

    step "Konfigurasi Nginx & SSL"
    write_nginx_conf http
    nginx_apply || die "Konfigurasi Nginx tidak valid."
    setup_ssl
    fw_open FW_PORTS_PANEL 80/tcp 443/tcp

    step "Konfigurasi environment Panel"
    configure_panel_env || die "Konfigurasi environment/migrasi/admin gagal. Lihat output di atas dan ${LOG_FILE}."
    ok "Environment, database & akun admin siap."

    step "Service & permission"
    setup_selinux
    run_or_die "Cron + queue worker (pteroq)" setup_panel_services
    state_set PANEL_INSTALLED 1

    local scheme="http"; (( USE_SSL )) && scheme="https"
    echo ""
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN} Panel berhasil diinstal!${NC}"
    echo -e "${GREEN} Akses     : ${scheme}://${FQDN}${NC}"
    echo -e "${GREEN} Admin     : ${ADMIN_USER}  (${EMAIL})${NC}"
    echo -e "${GREEN} Database  : ${DBNAME} / ${DBUSER}${NC}"
    if [[ "${DBPASS_GENERATED:-0}" == "1" ]]; then
        echo -e "${GREEN} DB Pass   : ${DBPASS}   (dibuat otomatis, CATAT sekarang)${NC}"
    fi
    echo -e "${GREEN}=============================================${NC}"
    (( USE_SSL )) || warn "Panel masih HTTP. Aktifkan HTTPS setelah DNS benar (lihat pesan di atas)."
    echo -e "${YELLOW}Lanjut: buat Location & Node di Admin Panel, lalu pilih menu 2 (Install Wings).${NC}"
    echo -e "${YELLOW}Jika ada firewall di panel provider VPS, buka port 80 & 443.${NC}"
}

###############################################################################
# 2) INSTALL WINGS
###############################################################################
install_docker() {
    flag_preexisting INST_DOCKER command -v docker
    if command -v docker >/dev/null 2>&1; then
        info "Docker sudah terpasang."
    else
        run_or_die "Unduh installer Docker" curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        if ! run "Install Docker (get.docker.com)" sh /tmp/get-docker.sh; then
            warn "get.docker.com gagal, mencoba cara manual..."
            if [[ "$DISTRO_FAMILY" == "debian" ]]; then
                run_or_die "Install docker.io" pkg_install docker.io
            else
                local repo="centos"; [[ "$OS_ID" == "fedora" ]] && repo="fedora"
                run_or_die "Tambah repo Docker" curl -fsSL "https://download.docker.com/linux/${repo}/docker-ce.repo" -o /etc/yum.repos.d/docker-ce.repo
                run_or_die "Install Docker CE" pkg_install docker-ce docker-ce-cli containerd.io
            fi
        fi
        rm -f /tmp/get-docker.sh
    fi
    run_or_die "Aktifkan Docker" systemctl enable --now docker
}

wings_arg() {   # wings_arg --panel-url "<cmd>"
    grep -oE -- "$1[= ]+[^ ]+" <<<"$2" | head -1 | sed -E "s/^$1[= ]+//; s/^[\"']//; s/[\"']\$//"
}

install_wings() {
    step "Install & Aktifkan Wings"
    echo "Pastikan Node sudah dibuat di Panel (Admin > Nodes > Create),"
    echo "lalu buka tab 'Configuration' pada node tersebut."
    echo ""

    local arch warch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) warch="amd64" ;;
        aarch64|arm64) warch="arm64" ;;
        *) die "Arsitektur ${arch} tidak didukung Wings." ;;
    esac

    if [[ "$DISTRO_FAMILY" == "debian" ]]; then run_soft "Update daftar paket" pkg_update; fi
    local need=() c
    for c in curl tar; do command -v "$c" >/dev/null 2>&1 || need+=("$c"); done
    (( ${#need[@]} )) && run_or_die "Install paket dasar" pkg_install "${need[@]}" ca-certificates

    install_docker

    mkdir -p /etc/pterodactyl
    run_or_die "Unduh binary Wings" curl -fsSL --retry 3 -o /usr/local/bin/wings \
        "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${warch}"
    chmod u+x /usr/local/bin/wings
    state_set WINGS_INSTALLED 1

    echo -e "\n${CYAN}Copy SELURUH perintah dari tab 'Configuration' di Panel, contoh:${NC}"
    echo -e "${CYAN}  cd /etc/pterodactyl && sudo wings configure --panel-url https://panel.contoh.com --token ptlc_xxxxx --node 1${NC}"
    echo -e "${YELLOW}Token hanya berlaku beberapa menit. Kamu punya 3 kali percobaan.${NC}\n"

    local try=1 cmd url token node insecure_flag success=0
    while (( try <= 3 )); do
        echo -e "${GREEN}Percobaan ${try} dari 3${NC}"
        read -r -p "Paste perintah configuration: " cmd || die "Input dihentikan."
        cmd="$(trim "$cmd")"
        if [[ "$cmd" != *"wings configure"* ]]; then
            warn "Perintah harus mengandung 'wings configure'."; try=$((try+1)); continue
        fi
        url="$(wings_arg --panel-url "$cmd")"; token="$(wings_arg --token "$cmd")"; node="$(wings_arg --node "$cmd")"
        if [[ ! "$url" =~ ^https?:// || -z "$token" || ! "$node" =~ ^[0-9]+$ ]]; then
            warn "Tidak bisa membaca --panel-url / --token / --node dari perintah itu."; try=$((try+1)); continue
        fi
        insecure_flag=()
        [[ "$cmd" == *"--allow-insecure"* || "$url" == http://* ]] && insecure_flag=(--allow-insecure)
        if (cd /etc/pterodactyl && /usr/local/bin/wings configure --panel-url "$url" --token "$token" --node "$node" ${insecure_flag[@]+"${insecure_flag[@]}"}); then
            success=1; break
        fi
        warn "Konfigurasi gagal (token expired / Panel tidak terjangkau). Ambil kode baru di Panel."
        try=$((try+1))
    done
    if (( ! success )); then
        err "Wings belum terkonfigurasi. Jalankan menu 2 lagi untuk mencoba ulang."
        return 1
    fi

    cat >/etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    run_or_die "Jalankan Wings" systemctl enable --now wings

    local api_port sftp_port cfg=/etc/pterodactyl/config.yml
    api_port="$(awk '/^api:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^ +port:/{print $2;exit}' "$cfg" 2>/dev/null)"
    sftp_port="$(awk '/^ +sftp:/{f=1;next} f&&/bind_port:/{print $2;exit}' "$cfg" 2>/dev/null)"
    api_port="${api_port:-8080}"; sftp_port="${sftp_port:-2022}"
    fw_open FW_PORTS_WINGS "${api_port}/tcp" "${sftp_port}/tcp"

    sleep 3
    echo ""
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN} Wings terpasang & berjalan!${NC}"
    echo -e "${GREEN}=============================================${NC}"
    systemctl --no-pager -l status wings 2>/dev/null | head -n 8
    echo ""
    echo -e "${YELLOW}Cek Panel: Admin > Nodes, status node harus hijau. Log: journalctl -u wings -f${NC}"
    echo -e "${YELLOW}Buka juga port allocation game di firewall/panel provider VPS.${NC}"
}

###############################################################################
# UNINSTALL - helper
###############################################################################
HAVE_STATE=0
NOSTATE_REMOVE_PKGS=0

want_remove() {   # want_remove INST_KEY -> true bila script ini yang memasang (atau user minta hapus semua)
    if (( HAVE_STATE )); then [[ "${!1:-0}" == "1" ]]
    else [[ "$NOSTATE_REMOVE_PKGS" == "1" ]]; fi
}

env_val() { [[ -f "$PANEL_DIR/.env" ]] && grep -E "^$1=" "$PANEL_DIR/.env" | head -1 | cut -d= -f2- | tr -d "\"'"; }

nginx_has_other_sites() {
    local f
    for f in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
        [[ -e "$f" ]] || continue
        case "$(basename "$f")" in default|default.conf|pterodactyl.conf) continue ;; esac
        return 0
    done
    return 1
}

other_certs_exist() {
    [[ -d /etc/letsencrypt/live ]] || return 1
    [[ -n "$(find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)" ]]
}

stop_units() {   # stop_units unit...   (abaikan unit yang tidak ada)
    local u
    for u in "$@"; do
        systemctl disable --now "$u" >>"$LOG_FILE" 2>&1 || true
    done
}

###############################################################################
# UNINSTALL - langkah-langkah
###############################################################################
un_services_and_cron() {
    stop_units pteroq.service
    rm -f /etc/systemd/system/pteroq.service /etc/cron.d/pterodactyl /etc/cron.d/installerptd-certbot
    ( crontab -l 2>/dev/null | grep -v 'pterodactyl/artisan schedule:run' ) | crontab - 2>/dev/null || true
    systemctl daemon-reload
    systemctl reset-failed >>"$LOG_FILE" 2>&1 || true
}

un_nginx_site() {
    rm -f /etc/nginx/sites-enabled/pterodactyl.conf /etc/nginx/sites-available/pterodactyl.conf \
          /etc/nginx/conf.d/pterodactyl.conf /var/log/nginx/pterodactyl.app-*.log*
    rm -rf "$ACME_ROOT"
    if systemctl is-active --quiet nginx 2>/dev/null; then
        nginx -t >>"$LOG_FILE" 2>&1 && systemctl reload nginx >>"$LOG_FILE" 2>&1 || true
    fi
}

un_database() {
    command -v "$(basename "$(mysql_bin 2>/dev/null || echo mysql)")" >/dev/null 2>&1 || { warn "Client MariaDB tidak ada, lewati drop database."; return 0; }
    systemctl is-active --quiet "${DB_SERVICE:-mariadb}" 2>/dev/null || systemctl start "${DB_SERVICE:-mariadb}" >>"$LOG_FILE" 2>&1 || true
    if ! ensure_mysql_access; then
        warn "Tidak bisa login MariaDB. Hapus manual nanti: DROP DATABASE \`${DBNAME}\`; DROP USER '${DBUSER}'@'127.0.0.1';"
        return 0
    fi
    mysql_root <<SQL
DROP DATABASE IF EXISTS \`${DBNAME}\`;
DROP USER IF EXISTS '${DBUSER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
}

un_ssl() {
    [[ -n "${FQDN:-}" ]] || return 0
    if command -v certbot >/dev/null 2>&1; then
        certbot delete --cert-name "$FQDN" --non-interactive >>"$LOG_FILE" 2>&1 || true
    fi
    rm -rf "/etc/letsencrypt/live/${FQDN}" "/etc/letsencrypt/archive/${FQDN}" "/etc/letsencrypt/renewal/${FQDN}.conf"
    rm -f /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh
}

un_panel_files() {
    rm -rf "$PANEL_DIR"
    rmdir /var/www 2>/dev/null || true
    if command -v semanage >/dev/null 2>&1 && [[ "${SELINUX_FCONTEXT:-0}" == "1" ]]; then
        semanage fcontext -d "${PANEL_DIR}(/.*)?" >>"$LOG_FILE" 2>&1 || true
    fi
    rm -f /etc/php-fpm.d/pterodactyl.conf /etc/my.cnf.d/zz-pterodactyl-bind.cnf
}

un_composer() {
    rm -f /usr/local/bin/composer
    rm -rf /root/.composer /root/.config/composer /root/.cache/composer
}

un_php() {
    local s v list
    for s in $(systemctl list-unit-files --no-legend 'php*fpm*.service' 2>/dev/null | awk '{print $1}'); do
        stop_units "$s"
    done
    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        v="${PANEL_PHP_VER:-}"
        if [[ -n "$v" ]]; then list="$(pkgs_matching "^php${v//./\\.}(-.*)?\$")"
        else list="$(pkgs_matching '^php[0-9]+\.[0-9]+(-.*)?$')"; fi
        # shellcheck disable=SC2086
        pkgs_purge $list
        # jika tidak ada versi PHP lain tersisa, buang juga paket generik (php-common, dll)
        if [[ -z "$(pkgs_matching '^php[0-9]+\.[0-9]+-cli$')" ]]; then
            list="$(pkgs_matching '^php(-.*)?$')"
            # shellcheck disable=SC2086
            pkgs_purge $list
            rm -rf /etc/php /var/lib/php /var/log/php* /run/php
        else
            [[ -n "$v" ]] && rm -rf "/etc/php/${v}" "/var/log/php${v}-fpm.log"
        fi
    else
        list="$(pkgs_matching '^php(-.*)?$')"
        # shellcheck disable=SC2086
        pkgs_purge $list
        dnf -y module reset php >>"$LOG_FILE" 2>&1 || true
        rm -rf /etc/php-fpm.d /etc/php.d /etc/php.ini /etc/php-zts.d /var/lib/php /var/log/php-fpm /run/php-fpm
    fi
}

un_nginx_pkg() {
    stop_units nginx.service
    local list; list="$(pkgs_matching '^(nginx(-.*)?|libnginx-mod-.*)$')"
    # shellcheck disable=SC2086
    pkgs_purge $list
    rm -rf /etc/nginx /var/log/nginx /var/lib/nginx /usr/share/nginx
}

un_mariadb_pkg() {
    stop_units mariadb.service mysql.service mysqld.service
    pkill -9 -x mariadbd 2>/dev/null || true
    pkill -9 -x mysqld 2>/dev/null || true
    sleep 2
    local list; list="$(pkgs_matching '^(mariadb(-.*)?|galera(-[0-9]+)?|mysql-common)$')"
    # shellcheck disable=SC2086
    pkgs_purge $list
    rm -rf /var/lib/mysql /etc/mysql /var/log/mysql /var/log/mariadb /etc/my.cnf.d /run/mysqld /run/mariadb
    [[ -f /etc/my.cnf && "$DISTRO_FAMILY" == "rhel" ]] && rm -f /etc/my.cnf
}

un_redis_pkg() {
    stop_units redis-server.service redis.service valkey-server.service valkey.service
    local list; list="$(pkgs_matching '^(redis(-.*)?|valkey(-.*)?)$')"
    # shellcheck disable=SC2086
    pkgs_purge $list
    rm -rf /var/lib/redis /etc/redis /var/log/redis /var/lib/valkey /etc/valkey /var/log/valkey
}

un_certbot_pkg() {
    stop_units certbot.timer certbot-renew.timer
    local list; list="$(pkgs_matching '^(certbot|python3-certbot.*)$')"
    # shellcheck disable=SC2086
    pkgs_purge $list
    rm -rf /etc/letsencrypt /var/lib/letsencrypt /var/log/letsencrypt
}

un_third_party_repos() {
    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        if [[ -n "${REPO_PHP:-}" ]] && want_remove INST_PHP; then
            remove_php_repo_debian
            ok "Repo PHP tambahan (${REPO_PHP}) dihapus."
        fi
    else
        if [[ "${REPO_REMI:-0}" == "1" ]] && want_remove INST_PHP; then
            dnf -y remove remi-release >>"$LOG_FILE" 2>&1 || true
            rm -f /etc/yum.repos.d/remi*.repo
            ok "Repo Remi dihapus."
        fi
        if [[ "${REPO_EPEL:-0}" == "1" ]] && (( HAVE_STATE )); then
            dnf -y remove epel-release >>"$LOG_FILE" 2>&1 || true
        fi
    fi
    [[ "$DISTRO_FAMILY" == "debian" ]] && { apt_get update >>"$LOG_FILE" 2>&1 || true; }
}

###############################################################################
# 3) UNINSTALL PANEL
###############################################################################
# Daftar user yang punya hak ke database tertentu (nama harus sudah lolos is_ident)
db_users_of() {   # db_users_of NAME
    is_ident "$1" || return 0
    mysql_root -N -e "SELECT GROUP_CONCAT(DISTINCT User SEPARATOR ', ') FROM mysql.db WHERE REPLACE(Db,'\\\\','')='$1'" 2>/dev/null \
        | grep -vx 'NULL' || true
}

# Info ringkas database: jumlah tabel & ukuran (MB)
db_summary() {   # db_summary NAME
    is_ident "$1" || return 0
    mysql_root -N -e "SELECT CONCAT(COUNT(*), ' tabel, ', ROUND(IFNULL(SUM(data_length+index_length),0)/1024/1024,2), ' MB') FROM information_schema.tables WHERE table_schema='$1'" 2>/dev/null
}

# Tampilkan daftar database yang terpasang di MariaDB lalu minta user memilih
# (nomor atau ketik nama). Mengisi DBNAME dan DBUSER, dan menampilkan nama database terpilih.
pick_database() {   # pick_database "default_db" "default_user"
    local def_db="$1" def_user="$2" dbs=() d i in_ users sel found sum
    local can_list=0
    detect_services_for_uninstall
    if [[ -n "$(mysql_bin 2>/dev/null)" ]]; then
        systemctl is-active --quiet "${DB_SERVICE:-mariadb}" 2>/dev/null || systemctl start "${DB_SERVICE:-mariadb}" >>"$LOG_FILE" 2>&1 || true
        if ensure_mysql_access; then
            can_list=1
            mapfile -t dbs < <(mysql_root -N -e 'SHOW DATABASES' 2>/dev/null \
                | grep -Ev '^(information_schema|mysql|performance_schema|sys|test)$')
        fi
    fi

    echo ""
    if [[ -n "$def_db" ]]; then
        echo -e "${CYAN}Database Panel terdeteksi (dari catatan/.env):${NC} ${GREEN}${def_db}${NC}${def_user:+  (user: ${def_user})}"
    fi

    if (( ! can_list || ${#dbs[@]} == 0 )); then
        warn "Daftar database tidak bisa ditampilkan (MariaDB tidak aktif / tidak bisa login / belum ada database)."
        ask DBNAME "Nama database Panel yang mau dihapus" "${def_db:-panel}" is_ident "Hanya huruf/angka/underscore (maks 32)."
        ask DBUSER "User database Panel yang mau dihapus" "${def_user:-pterodactyl}" is_ident "Hanya huruf/angka/underscore (maks 32)."
        echo -e "${YELLOW}Database terpilih: ${GREEN}${DBNAME}${YELLOW} | user: ${GREEN}${DBUSER}${NC}"
        return 0
    fi

    echo -e "${CYAN}Database yang terpasang di MariaDB:${NC}"
    i=1
    for d in "${dbs[@]}"; do
        users="$(db_users_of "$d")"
        sum="$(db_summary "$d")"
        printf '  %2d) %-26s user: %-16s %s%s\n' "$i" "$d" "${users:--}" "${sum:+[$sum]}" \
            "$([[ "$d" == "$def_db" ]] && echo '  <- database Panel')"
        i=$((i+1))
    done
    echo ""

    while true; do
        read -r -p "Pilih nomor atau ketik nama database yang mau dihapus [${def_db:-panel}]: " in_ || die "Input dihentikan."
        in_="$(trim "$in_")"; [[ -z "$in_" ]] && in_="${def_db:-panel}"
        if [[ "$in_" =~ ^[0-9]+$ ]] && (( in_ >= 1 && in_ <= ${#dbs[@]} )); then
            sel="${dbs[$((in_-1))]}"
        else
            sel="$in_"; found=0
            for d in "${dbs[@]}"; do [[ "$d" == "$sel" ]] && found=1; done
            if (( ! found )); then
                warn "Database '${sel}' tidak ada di daftar di atas."
                confirm "Tetap pakai nama itu?" n || continue
            fi
        fi
        is_ident "$sel" || { warn "Nama database hanya boleh huruf/angka/underscore."; continue; }
        DBNAME="$sel"; break
    done

    # tampilkan nama database yang dipilih beserta detailnya
    users="$(db_users_of "$DBNAME")"
    sum="$(db_summary "$DBNAME")"
    echo ""
    echo -e "${GREEN}Database terpilih : ${DBNAME}${NC}"
    [[ -n "$sum" ]]   && echo -e "${GREEN}Isi               : ${sum}${NC}"
    [[ -n "$users" ]] && echo -e "${GREEN}User terkait      : ${users}${NC}"
    echo ""

    # tebak user dari grant database terpilih
    users="$(mysql_root -N -e "SELECT DISTINCT User FROM mysql.db WHERE REPLACE(Db,'\\\\','')='${DBNAME}'" 2>/dev/null)"
    if [[ -n "$users" && "$(wc -l <<<"$users")" -eq 1 ]]; then
        def_user="$users"
        info "User database terdeteksi: ${def_user}"
    fi
    ask DBUSER "User database yang mau dihapus" "${def_user:-pterodactyl}" is_ident "Hanya huruf/angka/underscore (maks 32)."
    echo -e "${YELLOW}Akan dihapus: database '${GREEN}${DBNAME}${YELLOW}' dan user '${GREEN}${DBUSER}${YELLOW}'.${NC}"
}

uninstall_panel() {
    step "Uninstall Pterodactyl Panel (bersih total)"
    state_load
    [[ -f "$STATE_FILE" ]] && HAVE_STATE=1

    FQDN="${PANEL_FQDN:-}"; DBNAME="${PANEL_DB_NAME:-}"; DBUSER="${PANEL_DB_USER:-}"
    if [[ -z "$PANEL_DIR" ]]; then die "PANEL_DIR kosong."; fi
    if (( ! HAVE_STATE )); then
        warn "Catatan instalasi tidak ditemukan (Panel dipasang manual / script versi lama)."
        local u; u="$(env_val APP_URL)"; u="${u#*://}"; u="${u%%/*}"
        FQDN="${u:-}"; DBNAME="$(env_val DB_DATABASE)"; DBUSER="$(env_val DB_USERNAME)"
        ask FQDN "Domain Panel" "${FQDN:-panel.contoh.com}" is_host
        if confirm "Hapus juga paket pendukung (PHP, Nginx, MariaDB, Redis, Certbot, Composer)? Pilih y hanya jika VPS ini khusus Panel" n; then
            NOSTATE_REMOVE_PKGS=1
        fi
    fi

    pick_database "$DBNAME" "$DBUSER"

    local has_wings=0 has_docker=0 rm_wings=0 rm_docker=0
    [[ -x /usr/local/bin/wings || -d /etc/pterodactyl ]] && has_wings=1
    command -v docker >/dev/null 2>&1 && has_docker=1

    echo ""
    echo "Yang akan DIHAPUS:"
    echo "  - File Panel (${PANEL_DIR}), service pteroq, cron, config Nginx, log Panel"
    echo "  - Database '${DBNAME}' & user '${DBUSER}'"
    echo "  - Sertifikat SSL '${FQDN:-(tidak ada)}', rule firewall & konteks SELinux yang dibuat script"
    local k name; local pk=()
    for k in "INST_PHP:PHP" "INST_NGINX:Nginx" "INST_MARIADB:MariaDB" "INST_REDIS:Redis/Valkey" "INST_CERTBOT:Certbot" "INST_COMPOSER:Composer"; do
        name="${k#*:}"; want_remove "${k%%:*}" && pk+=("$name")
    done
    if (( ${#pk[@]} )); then
        echo "  - Paket yang dulu dipasang script ini: ${pk[*]}"
        echo "    (paket yang sudah ada sebelum script dijalankan TIDAK disentuh)"
    else
        echo "  - Paket pendukung: tidak dihapus (sudah ada sebelum script / tidak dipilih)"
    fi
    echo ""

    if (( has_wings )); then
        warn "Wings terdeteksi di VPS ini."
        if confirm "Hapus juga Wings + SEMUA server game (data world/plugin hilang permanen)?" n; then
            read -r -p "Ketik 'HAPUS WINGS' untuk konfirmasi: " c
            [[ "$(trim "$c")" == "HAPUS WINGS" ]] && rm_wings=1 || warn "Wings dipertahankan."
        fi
    fi
    if (( has_docker )) && [[ "${INST_DOCKER:-}" == "1" || $HAVE_STATE -eq 0 ]]; then
        if confirm "Hapus juga Docker (beserta semua image/container)?" n; then rm_docker=1; fi
    fi

    read -r -p "Ketik 'HAPUS' untuk memulai uninstall: " c
    [[ "$(trim "$c")" == "HAPUS" ]] || { warn "Dibatalkan."; return 0; }

    detect_services_for_uninstall

    echo ""
    run_soft "Hentikan service, hapus cron & unit systemd" un_services_and_cron
    run_soft "Hapus konfigurasi & log Nginx Panel" un_nginx_site
    run_soft "Hapus database & user Panel" un_database
    run_soft "Hapus sertifikat SSL" un_ssl
    run_soft "Hapus file Panel & config pendukung" un_panel_files
    fw_close_recorded FW_PORTS_PANEL

    if (( rm_wings )); then run_soft "Hapus Wings & container game" remove_wings; fi

    # ---- paket pendukung ----
    if want_remove INST_NGINX; then
        if nginx_has_other_sites; then warn "Ada site Nginx lain -> Nginx dipertahankan."
        else run_soft "Hapus Nginx" un_nginx_pkg; fi
    fi
    if want_remove INST_MARIADB; then
        local others=""
        if systemctl is-active --quiet "${DB_SERVICE:-mariadb}" 2>/dev/null && ensure_mysql_access; then
            others="$(mysql_root -N -e 'SHOW DATABASES' 2>/dev/null | grep -Ev '^(information_schema|mysql|performance_schema|sys|test)$' || true)"
        fi
        if [[ -n "$others" ]]; then
            warn "MariaDB masih berisi database lain:"; echo "$others" | sed 's/^/     - /'
            if confirm "Tetap hapus MariaDB beserta SEMUA database di atas?" n; then run_soft "Hapus MariaDB" un_mariadb_pkg
            else info "MariaDB dipertahankan."; fi
        else
            run_soft "Hapus MariaDB" un_mariadb_pkg
        fi
    fi
    want_remove INST_REDIS && run_soft "Hapus Redis/Valkey" un_redis_pkg
    if want_remove INST_PHP; then run_soft "Hapus PHP" un_php
    else systemctl list-unit-files --no-legend 'php*fpm*.service' >/dev/null 2>&1 && systemctl reload "php-fpm" >>"$LOG_FILE" 2>&1 || true; fi
    if want_remove INST_CERTBOT; then
        if other_certs_exist; then warn "Masih ada sertifikat lain -> Certbot dipertahankan."
        else run_soft "Hapus Certbot" un_certbot_pkg; fi
    fi
    want_remove INST_COMPOSER && run_soft "Hapus Composer & cache" un_composer
    un_third_party_repos

    if (( rm_docker )); then run_soft "Hapus Docker" remove_docker; fi

    if confirm "Jalankan autoremove untuk membersihkan dependency yatim?" y; then
        if [[ "$DISTRO_FAMILY" == "debian" ]]; then run_soft "apt autoremove" apt_get autoremove --purge
        else run_soft "dnf autoremove" dnf -y autoremove; fi
    fi

    rm -f "$STATE_FILE"
    verify_clean
    echo ""
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN} Uninstall Panel selesai.${NC}"
    (( rm_wings )) && echo -e "${GREEN} Wings & container game ikut dihapus.${NC}"
    (( has_wings && ! rm_wings )) && echo -e "${YELLOW} Wings dipertahankan (hapus lewat menu 4).${NC}"
    echo -e "${GREEN}=============================================${NC}"
    rm -f "$LOG_FILE"
}

detect_services_for_uninstall() {
    DB_SERVICE="$(first_service mariadb mysql mysqld || true)"
    REDIS_SERVICE="$(first_service redis-server redis valkey-server valkey || true)"
}

verify_clean() {
    local left=() p
    for p in "$PANEL_DIR" /etc/systemd/system/pteroq.service /etc/cron.d/pterodactyl \
             /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf \
             /etc/nginx/conf.d/pterodactyl.conf /etc/php-fpm.d/pterodactyl.conf "$ACME_ROOT"; do
        [[ -e "$p" ]] && left+=("$p")
    done
    if (( ${#left[@]} )); then
        warn "Masih ada sisa, hapus manual:"; printf '     %s\n' "${left[@]}"
    else
        ok "Verifikasi: tidak ada sisa file/konfigurasi Panel."
    fi
}

###############################################################################
# 4) UNINSTALL WINGS
###############################################################################
wings_cfg_dirs() {
    local cfg=/etc/pterodactyl/config.yml
    [[ -f "$cfg" ]] || return 0
    grep -E '^[[:space:]]+(root_directory|log_directory|data|archive_directory|backup_directory|tmp_directory):' "$cfg" \
        | awk '{print $2}' | tr -d "\"'"
}

remove_wings() {
    local d
    stop_units wings.service
    rm -f /etc/systemd/system/wings.service
    systemctl daemon-reload
    if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
        local ids; ids="$(docker ps -aq --filter 'label=Service=Pterodactyl' 2>/dev/null || true)"
        # shellcheck disable=SC2086
        [[ -n "$ids" ]] && docker rm -f $ids >>"$LOG_FILE" 2>&1
        docker network rm pterodactyl_nw >>"$LOG_FILE" 2>&1 || true
    fi
    for d in $(wings_cfg_dirs); do
        [[ "$d" == /* && "$d" != "/" && "$d" == *pterodactyl* ]] && rm -rf "$d"
    done
    rm -f /usr/local/bin/wings
    rm -rf /etc/pterodactyl /var/lib/pterodactyl /var/log/pterodactyl /tmp/pterodactyl /var/run/wings /run/wings
    if id pterodactyl >/dev/null 2>&1; then userdel pterodactyl >>"$LOG_FILE" 2>&1 || true; fi
    getent group pterodactyl >/dev/null 2>&1 && groupdel pterodactyl >>"$LOG_FILE" 2>&1 || true
    fw_close_recorded FW_PORTS_WINGS
}

remove_docker() {
    stop_units docker.service docker.socket containerd.service
    local list; list="$(pkgs_matching '^(docker-ce.*|docker\.io|docker-compose.*|docker-buildx-plugin|docker-model-plugin|containerd(\.io)?)$')"
    # shellcheck disable=SC2086
    pkgs_purge $list
    rm -rf /var/lib/docker /var/lib/containerd /etc/docker /run/docker /run/docker.sock
    rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.sources \
          /etc/apt/keyrings/docker.asc /etc/apt/keyrings/docker.gpg /etc/yum.repos.d/docker-ce.repo
    getent group docker >/dev/null 2>&1 && groupdel docker >>"$LOG_FILE" 2>&1 || true
}

uninstall_wings() {
    step "Uninstall Wings"
    state_load
    if [[ ! -x /usr/local/bin/wings && ! -d /etc/pterodactyl ]]; then
        warn "Wings tidak ditemukan di VPS ini."; return 0
    fi
    warn "Semua server game (container + data world/plugin) AKAN HILANG PERMANEN."
    local c rm_docker=0
    read -r -p "Ketik 'HAPUS WINGS' untuk lanjut: " c
    [[ "$(trim "$c")" == "HAPUS WINGS" ]] || { warn "Dibatalkan."; return 0; }
    if command -v docker >/dev/null 2>&1 && confirm "Hapus juga Docker (termasuk image/container lain)?" n; then rm_docker=1; fi

    run_soft "Hapus Wings, container & data" remove_wings
    (( rm_docker )) && run_soft "Hapus Docker" remove_docker
    state_set WINGS_INSTALLED 0
    ok "Wings berhasil dihapus."
}

###############################################################################
# MENU UTAMA
###############################################################################
main() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Jalankan script ini sebagai root (sudo bash installerptd.sh).${NC}"; exit 1
    fi
    mkdir -p "$(dirname "$LOG_FILE")"; : >>"$LOG_FILE"; chmod 600 "$LOG_FILE"
    trap 'echo; warn "Dibatalkan oleh user."; exit 130' INT

    # Jika dijalankan lewat pipe (curl | bash), ambil input dari terminal
    if [[ ! -t 0 ]]; then
        if [[ -r /dev/tty ]]; then exec </dev/tty; else die "Butuh terminal interaktif."; fi
    fi

    detect_os
    local opsi="${1:-}"
    if [[ -z "$opsi" ]]; then
        clear 2>/dev/null || true
        echo -e "${CYAN}=============================================${NC}"
        echo -e "${CYAN}   installerptd.sh v${SCRIPT_VERSION} - Pterodactyl Tool${NC}"
        echo -e "${CYAN}   OS: ${OS_PRETTY} (${DISTRO_FAMILY})${NC}"
        echo -e "${CYAN}=============================================${NC}"
        echo "1) Install Panel"
        echo "2) Install & Aktifkan Wings"
        echo "3) Uninstall Panel (bersih total)"
        echo "4) Uninstall Wings"
        echo "0) Keluar"
        echo ""
        read -r -p "Pilih opsi [0-4]: " opsi || exit 1
        opsi="$(trim "$opsi")"
    fi

    case "$opsi" in
        1) install_panel ;;
        2) install_wings ;;
        3) uninstall_panel ;;
        4) uninstall_wings ;;
        0) echo "Keluar."; exit 0 ;;
        *) err "Pilihan tidak valid."; exit 1 ;;
    esac
}

# Jalankan main hanya bila file dieksekusi langsung (bukan di-source untuk test)
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
