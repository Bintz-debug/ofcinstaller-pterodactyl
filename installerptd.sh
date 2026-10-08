#!/bin/bash
###############################################################################
# installerptd.sh
# All-in-one Pterodactyl Installer/Uninstaller - Multi Distro Linux
#
# Mendukung:
#   - Debian family : Ubuntu, Debian, Linux Mint, Pop!_OS (apt)
#   - RHEL family   : Rocky Linux, AlmaLinux, CentOS Stream, RHEL, Fedora (dnf)
#
# Menu:
#   1) Install Panel (resmi, otomatis sampai selesai)
#   2) Install & Aktifkan Wings (pakai kode Configuration dari Node)
#   3) Uninstall Panel (bersih, tidak mengganggu paket dasar VPS)
#
# Jalankan: sudo bash installerptd.sh
###############################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Jalankan script ini sebagai root (sudo).${NC}"
   exit 1
fi

###############################################################################
# DETEKSI OS
###############################################################################
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        echo -e "${RED}Tidak bisa mendeteksi OS (/etc/os-release tidak ditemukan).${NC}"
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID,,}"
    OS_ID_LIKE="${ID_LIKE,,}"
    OS_PRETTY="${PRETTY_NAME}"
    OS_VERSION="${VERSION_ID}"

    case "$OS_ID" in
        ubuntu|debian|linuxmint|pop)
            DISTRO_FAMILY="debian"
            ;;
        rocky|almalinux|centos|rhel|fedora)
            DISTRO_FAMILY="rhel"
            ;;
        *)
            if [[ "$OS_ID_LIKE" == *debian* ]]; then
                DISTRO_FAMILY="debian"
            elif [[ "$OS_ID_LIKE" == *rhel* || "$OS_ID_LIKE" == *fedora* ]]; then
                DISTRO_FAMILY="rhel"
            else
                DISTRO_FAMILY="unsupported"
            fi
            ;;
    esac

    if [[ "$DISTRO_FAMILY" == "unsupported" ]]; then
        echo -e "${RED}OS '${OS_PRETTY}' belum didukung otomatis oleh script ini.${NC}"
        echo "Yang didukung: Ubuntu, Debian, Linux Mint, Pop!_OS, Rocky Linux, AlmaLinux, CentOS Stream, RHEL, Fedora."
        exit 1
    fi

    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        PHP_FPM_SOCK="/run/php/php8.3-fpm.sock"
        PHP_FPM_SERVICE="php8.3-fpm"
        REDIS_SERVICE="redis-server"
    else
        PHP_FPM_SOCK="/run/php-fpm/www.sock"
        PHP_FPM_SERVICE="php-fpm"
        REDIS_SERVICE="redis"
    fi

    echo -e "${CYAN}Terdeteksi OS: ${OS_PRETTY} (keluarga: ${DISTRO_FAMILY})${NC}"
}

###############################################################################
# INSTALL DEPENDENCY SESUAI DISTRO
###############################################################################
install_dependencies_debian() {
    echo -e "${GREEN}Update sistem & dependency dasar (apt)...${NC}"
    apt update -y && apt upgrade -y
    apt install -y curl wget sudo gnupg2 software-properties-common apt-transport-https ca-certificates lsb-release unzip git

    echo -e "${GREEN}Install PHP, MariaDB, Nginx, Redis, Composer...${NC}"

    # Tentukan apakah perlu pakai PHP native (bukan PPA Ondrej).
    # PPA Ondrej biasanya baru menyediakan paket beberapa saat setelah
    # rilis Ubuntu baru, jadi untuk Ubuntu >= 26.04 kita pakai PHP bawaan repo resmi.
    USE_NATIVE_PHP=0
    if [[ "$OS_ID" == "ubuntu" ]]; then
        OLDEST=$(printf '%s\n%s\n' "$OS_VERSION" "26.04" | sort -V | head -n1)
        if [[ "$OLDEST" != "26.04" || "$OS_VERSION" == "26.04" ]]; then
            USE_NATIVE_PHP=1
        fi
    fi

    if [[ "$USE_NATIVE_PHP" -eq 1 ]]; then
        echo -e "${YELLOW}Terdeteksi Ubuntu ${OS_VERSION}. PPA Ondrej kemungkinan belum tersedia untuk versi ini,${NC}"
        echo -e "${YELLOW}jadi PHP akan diinstall langsung dari repo resmi Ubuntu (native), bukan PPA.${NC}"

        apt install -y php php-cli php-gd php-mysql php-mbstring php-bcmath php-xml \
            php-fpm php-curl php-zip php-intl php-sqlite3

        # Deteksi versi PHP yang benar-benar terpasang, supaya nama service & socket tepat
        PHP_VER_DETECTED=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)
        if [[ -n "$PHP_VER_DETECTED" ]]; then
            PHP_FPM_SOCK="/run/php/php${PHP_VER_DETECTED}-fpm.sock"
            PHP_FPM_SERVICE="php${PHP_VER_DETECTED}-fpm"
            echo -e "${CYAN}PHP terdeteksi versi ${PHP_VER_DETECTED} -> service: ${PHP_FPM_SERVICE}, socket: ${PHP_FPM_SOCK}${NC}"
        fi
    else
        LC_ALL=C.UTF-8 add-apt-repository ppa:ondrej/php -y
        apt update -y
        apt install -y php8.3 php8.3-{cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,sqlite3}
    fi

    apt install -y mariadb-server nginx tar redis-server certbot

    if ! command -v composer &> /dev/null; then
        curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    fi

    systemctl enable --now mariadb "$REDIS_SERVICE" nginx "$PHP_FPM_SERVICE"
}

install_dependencies_rhel() {
    echo -e "${GREEN}Update sistem & dependency dasar (dnf)...${NC}"
    dnf update -y
    dnf install -y curl wget sudo gnupg2 ca-certificates tar unzip git policycoreutils-python-utils

    echo -e "${GREEN}Install PHP 8.3, MariaDB, Nginx, Redis, Composer...${NC}"

    if [[ "$OS_ID" == "fedora" ]]; then
        dnf install -y php php-cli php-gd php-mysqlnd php-mbstring php-bcmath php-xml \
            php-fpm php-curl php-zip php-intl php-pdo
    else
        RHEL_VER=$(rpm -E %rhel)
        dnf install -y "https://rpms.remirepo.net/enterprise/remi-release-${RHEL_VER}.rpm" epel-release
        dnf module reset php -y
        dnf module enable php:remi-8.3 -y
        dnf install -y php php-cli php-gd php-mysqlnd php-mbstring php-bcmath php-xml \
            php-fpm php-curl php-zip php-intl php-pdo
    fi

    dnf install -y mariadb-server nginx redis certbot

    if ! command -v composer &> /dev/null; then
        curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    fi

    systemctl enable --now mariadb "$REDIS_SERVICE" nginx "$PHP_FPM_SERVICE"

    echo -e "${YELLOW}Catatan: jika SELinux aktif dan Nginx/PHP-FPM error permission,${NC}"
    echo -e "${YELLOW}jalankan: setsebool -P httpd_can_network_connect 1${NC}"
}

###############################################################################
# 1) INSTALL PANEL
###############################################################################
install_panel() {
    echo -e "${GREEN}=== Install Pterodactyl Panel ===${NC}"
    echo ""

    read -p "Domain Panel (sudah diarahkan ke IP VPS ini, contoh: panel.contoh.com): " FQDN
    read -p "Email untuk sertifikat SSL & akun admin: " EMAIL
    read -p "Nama database (default: panel): " DBNAME
    DBNAME=${DBNAME:-panel}
    read -p "Nama user database (default: pterodactyl): " DBUSER
    DBUSER=${DBUSER:-pterodactyl}
    read -s -p "Password database: " DBPASS
    echo ""
    read -p "Zona waktu (contoh: Asia/Jakarta): " TZONE
    TZONE=${TZONE:-Asia/Jakarta}
    echo ""
    read -p "Domain sudah di-A record ke IP VPS ini? (y/n): " DNS_OK

    if [[ "$DNS_OK" != "y" ]]; then
        echo -e "${RED}Arahkan domain ke IP VPS dulu sebelum lanjut. Dibatalkan.${NC}"
        return
    fi

    echo -e "${YELLOW}Ringkasan: domain=${FQDN}, db=${DBNAME}, dbuser=${DBUSER}, timezone=${TZONE}${NC}"
    sleep 2

    echo -e "${GREEN}[1/6] Install dependency (${DISTRO_FAMILY})...${NC}"
    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        install_dependencies_debian
    else
        install_dependencies_rhel
    fi

    echo -e "${GREEN}[2/6] Setup database...${NC}"
    mysql -u root <<MYSQL_SCRIPT
CREATE USER IF NOT EXISTS '${DBUSER}'@'127.0.0.1' IDENTIFIED BY '${DBPASS}';
CREATE DATABASE IF NOT EXISTS ${DBNAME};
GRANT ALL PRIVILEGES ON ${DBNAME}.* TO '${DBUSER}'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
MYSQL_SCRIPT

    echo -e "${GREEN}[3/6] Download file Panel...${NC}"
    mkdir -p /var/www/pterodactyl
    cd /var/www/pterodactyl
    curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
    tar -xzvf panel.tar.gz
    chmod -R 755 storage/* bootstrap/cache/
    cp .env.example .env
    composer install --no-dev --optimize-autoloader --no-interaction

    echo -e "${GREEN}[4/6] Konfigurasi environment Panel...${NC}"
    php artisan key:generate --force

    php artisan p:environment:setup \
        --author="${EMAIL}" \
        --url="https://${FQDN}" \
        --timezone="${TZONE}" \
        --cache="redis" \
        --session="redis" \
        --queue="redis" \
        --redis-host="localhost" \
        --redis-pass="null" \
        --redis-port="6379" \
        --settings-ui=true

    php artisan p:environment:database \
        --host="127.0.0.1" \
        --port="3306" \
        --database="${DBNAME}" \
        --username="${DBUSER}" \
        --password="${DBPASS}"

    php artisan migrate --seed --force

    echo -e "${GREEN}Buat akun admin Panel. Isi data berikut:${NC}"
    php artisan p:user:make

    chown -R www-data:www-data /var/www/pterodactyl/* 2>/dev/null || chown -R nginx:nginx /var/www/pterodactyl/*

    echo -e "${GREEN}Setup cron job & queue worker...${NC}"
    ( crontab -l 2>/dev/null | grep -v 'pterodactyl/artisan schedule:run' ; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1" ) | crontab -

    cat > /etc/systemd/system/pteroq.service <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis.target

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # Sesuaikan user service untuk RHEL family (biasanya nginx, bukan www-data)
    if [[ "$DISTRO_FAMILY" == "rhel" ]]; then
        sed -i 's/User=www-data/User=nginx/' /etc/systemd/system/pteroq.service
        sed -i 's/Group=www-data/Group=nginx/' /etc/systemd/system/pteroq.service
    fi

    systemctl daemon-reload
    systemctl enable --now pteroq.service

    echo -e "${GREEN}[5/6] Request sertifikat SSL untuk ${FQDN}...${NC}"
    systemctl stop nginx
    certbot certonly --standalone --non-interactive --agree-tos -m "${EMAIL}" -d "${FQDN}"

    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh <<'EOF'
#!/bin/bash
systemctl reload nginx
systemctl restart wings 2>/dev/null || true
EOF
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh

    echo -e "${GREEN}[6/6] Konfigurasi Nginx...${NC}"

    NGINX_TEMPLATE=$(cat <<EOF
server {
    listen 80;
    server_name ${FQDN};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${FQDN};

    root /var/www/pterodactyl/public;
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
    ssl_ciphers EECDH+AESGCM:EDH+AESGCM;
    ssl_prefer_server_ciphers on;

    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

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
}
EOF
)

    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        rm -f /etc/nginx/sites-enabled/default
        echo "$NGINX_TEMPLATE" > /etc/nginx/sites-available/pterodactyl.conf
        ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
    else
        echo "$NGINX_TEMPLATE" > /etc/nginx/conf.d/pterodactyl.conf
    fi

    nginx -t
    systemctl start nginx
    systemctl enable nginx

    # Simpan info instalasi (domain, nama DB, user DB) supaya bisa ditampilkan
    # lagi otomatis saat Uninstall Panel (menu 3), biar tidak perlu diingat manual.
    cat > /root/.installerptd-info <<EOF
PANEL_FQDN="${FQDN}"
PANEL_DB_NAME="${DBNAME}"
PANEL_DB_USER="${DBUSER}"
EOF
    chmod 600 /root/.installerptd-info

    echo ""
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN} Panel berhasil diinstal!${NC}"
    echo -e "${GREEN} Akses: https://${FQDN}${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${YELLOW}Buka firewall untuk port 80 dan 443:${NC}"
    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        echo "  ufw allow 80/tcp && ufw allow 443/tcp"
    else
        echo "  firewall-cmd --permanent --add-port=80/tcp --add-port=443/tcp && firewall-cmd --reload"
    fi
    echo ""
    echo -e "${YELLOW}Lanjut buat Location & Node di Admin Panel, lalu pilih menu 2 (Install Wings) di script ini.${NC}"
}

###############################################################################
# 2) INSTALL & AKTIFKAN WINGS
###############################################################################
install_wings() {
    echo -e "${GREEN}=== Install & Aktifkan Wings ===${NC}"
    echo ""
    echo "Sebelum lanjut, pastikan kamu sudah membuat Node di Panel"
    echo "(Admin > Nodes > Create), lalu buka tab 'Configuration' pada node tsb."
    echo ""

    echo -e "${GREEN}[1/3] Install Docker...${NC}"
    if ! command -v docker &> /dev/null; then
        curl -sSL https://get.docker.com/ | CHANNEL=stable sh
        systemctl enable --now docker
    else
        echo "Docker sudah terinstal, lanjut."
    fi

    echo -e "${GREEN}[2/3] Download binary Wings...${NC}"
    mkdir -p /etc/pterodactyl
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        WINGS_ARCH="amd64"
    else
        WINGS_ARCH="arm64"
    fi
    curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${WINGS_ARCH}"
    chmod u+x /usr/local/bin/wings

    echo -e "${GREEN}[3/3] Konfigurasi Wings dari Panel${NC}"
    echo ""
    echo -e "${CYAN}Buka: Panel > Admin > Nodes > [Node Kamu] > tab 'Configuration'${NC}"
    echo -e "${CYAN}Copy SELURUH baris perintah yang muncul di sana, formatnya seperti ini:${NC}"
    echo -e "${CYAN}  cd /etc/pterodactyl && sudo wings configure --panel-url https://panel.contoh.com --token ptlc_xxxxx --node 1${NC}"
    echo ""
    echo -e "${YELLOW}Catatan: token tersebut hanya berlaku sekitar 5 menit sejak ditampilkan.${NC}"
    echo -e "${YELLOW}Kalau sudah expired/gagal, buka ulang tab Configuration di Panel untuk dapat kode baru,${NC}"
    echo -e "${YELLOW}lalu paste lagi di bawah ini. Kamu akan diberi kesempatan mencoba sampai 3 kali.${NC}"
    echo ""

    MAX_TRY=3
    TRY=1
    SUCCESS=0

    while [[ $TRY -le $MAX_TRY ]]; do
        echo -e "${GREEN}Percobaan ${TRY} dari ${MAX_TRY}${NC}"
        read -p "Paste perintah configuration dari Panel di sini: " WINGS_CONFIG_CMD

        if [[ -z "$WINGS_CONFIG_CMD" ]]; then
            echo -e "${RED}Tidak ada input, coba lagi.${NC}"
            TRY=$((TRY+1))
            continue
        fi

        # Perintah resmi dari Panel selalu mengandung "wings configure",
        # baik diawali "cd /etc/pterodactyl && sudo wings configure ..."
        # atau langsung "sudo wings configure ..."
        if [[ "$WINGS_CONFIG_CMD" != *"wings configure"* ]]; then
            echo -e "${RED}Perintah tidak dikenali (harus mengandung 'wings configure'). Coba lagi.${NC}"
            TRY=$((TRY+1))
            continue
        fi

        echo -e "${GREEN}Menjalankan konfigurasi...${NC}"
        # eval menjalankan perintah apa adanya, termasuk bagian 'cd ... &&' jika ada
        if eval "$WINGS_CONFIG_CMD"; then
            SUCCESS=1
            break
        else
            echo -e "${RED}Gagal mengonfigurasi Wings. Token mungkin sudah expired.${NC}"
            echo -e "${YELLOW}Ambil kode baru dari tab Configuration di Panel, lalu coba lagi.${NC}"
            TRY=$((TRY+1))
        fi
    done

    if [[ $SUCCESS -ne 1 ]]; then
        echo -e "${RED}Gagal konfigurasi Wings setelah ${MAX_TRY} kali percobaan.${NC}"
        echo "Jalankan ulang menu 2 di script ini untuk mencoba lagi."
        return
    fi

    echo -e "${GREEN}Konfigurasi berhasil. Menyiapkan systemd service...${NC}"

    cat > /etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now wings

    sleep 3
    echo ""
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN} Wings berhasil diinstal & dijalankan!${NC}"
    echo -e "${GREEN}=============================================${NC}"
    systemctl status wings --no-pager -l | head -n 10
    echo ""
    echo -e "${YELLOW}Cek Panel: Admin > Nodes > node kamu harus berubah status jadi online/hijau.${NC}"
    echo -e "${YELLOW}Kalau belum, cek log: journalctl -u wings -f${NC}"
    echo ""
    echo -e "${YELLOW}Buka firewall untuk port Daemon (biasanya 8443), 2022 (SFTP), dan port allocation game:${NC}"
    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        echo "  ufw allow 8443/tcp && ufw allow 2022/tcp"
    else
        echo "  firewall-cmd --permanent --add-port=8443/tcp --add-port=2022/tcp && firewall-cmd --reload"
    fi
}

###############################################################################
# 3) UNINSTALL PANEL (bersih, tidak menyentuh paket dasar VPS)
###############################################################################
uninstall_panel() {
    echo -e "${RED}=== Uninstall Pterodactyl Panel ===${NC}"
    echo ""
    echo "Yang akan dihapus (wajib):"
    echo "  - File Panel (/var/www/pterodactyl)"
    echo "  - Database & user Panel"
    echo "  - Konfigurasi Nginx untuk Panel"
    echo "  - Cron job & systemd service (pteroq)"
    echo "  - (opsional) sertifikat SSL domain Panel"
    echo "  - (opsional) paket pendukung: PHP, MariaDB, Nginx, Redis, Composer, Docker"
    echo "  - (opsional) Wings beserta SEMUA container/server game di dalamnya"
    echo ""
    echo -e "${YELLOW}Semua bagian opsional di atas akan ditanya terpisah, default-nya TIDAK dihapus.${NC}"
    echo ""

    read -p "Ketik 'HAPUS' untuk lanjut uninstall Panel: " CONFIRM
    if [[ "$CONFIRM" != "HAPUS" ]]; then
        echo -e "${YELLOW}Dibatalkan.${NC}"
        return
    fi

    # Baca info dari instalasi sebelumnya (dicatat otomatis oleh menu 1),
    # supaya kamu tidak perlu mengingat-ingat nama database/user/domain.
    SAVED_FQDN=""
    SAVED_DBNAME=""
    SAVED_DBUSER=""
    if [[ -f /root/.installerptd-info ]]; then
        # shellcheck disable=SC1091
        source /root/.installerptd-info
        SAVED_FQDN="$PANEL_FQDN"
        SAVED_DBNAME="$PANEL_DB_NAME"
        SAVED_DBUSER="$PANEL_DB_USER"

        echo ""
        echo -e "${CYAN}Info instalasi sebelumnya terdeteksi:${NC}"
        echo "  Domain  : ${SAVED_FQDN:-(tidak tercatat)}"
        echo "  Nama DB : ${SAVED_DBNAME:-(tidak tercatat)}"
        echo "  User DB : ${SAVED_DBUSER:-(tidak tercatat)}"
        echo -e "${YELLOW}Tekan Enter untuk pakai nilai di atas, atau ketik nilai lain untuk override.${NC}"
        echo ""
    else
        echo -e "${YELLOW}Tidak ditemukan catatan instalasi sebelumnya (mungkin Panel diinstal manual/cara lain).${NC}"
        echo ""
    fi

    read -p "Nama database Panel yang mau dihapus (default: ${SAVED_DBNAME:-panel}): " DBNAME
    DBNAME=${DBNAME:-${SAVED_DBNAME:-panel}}
    read -p "Nama user database Panel yang mau dihapus (default: ${SAVED_DBUSER:-pterodactyl}): " DBUSER
    DBUSER=${DBUSER:-${SAVED_DBUSER:-pterodactyl}}
    read -p "Domain Panel (default: ${SAVED_FQDN:-kosongkan jika tidak perlu}): " FQDN
    FQDN=${FQDN:-$SAVED_FQDN}

    echo -e "${GREEN}[1/5] Menghentikan service Panel...${NC}"
    systemctl stop pteroq 2>/dev/null || true
    systemctl disable pteroq 2>/dev/null || true
    rm -f /etc/systemd/system/pteroq.service
    systemctl daemon-reload

    echo -e "${GREEN}[2/5] Menghapus cron job Panel...${NC}"
    ( crontab -l 2>/dev/null | grep -v 'pterodactyl/artisan schedule:run' ) | crontab - 2>/dev/null || true

    echo -e "${GREEN}[3/5] Menghapus file Panel...${NC}"
    rm -rf /var/www/pterodactyl

    echo -e "${GREEN}[4/5] Menghapus database & user Panel...${NC}"
    DB_DROP_OK=0
    if command -v mysql &> /dev/null && systemctl is-active --quiet mariadb 2>/dev/null; then
        if mysql -u root <<MYSQL_SCRIPT 2>/dev/null
DROP DATABASE IF EXISTS ${DBNAME};
DROP USER IF EXISTS '${DBUSER}'@'127.0.0.1';
FLUSH PRIVILEGES;
MYSQL_SCRIPT
        then
            DB_DROP_OK=1
        fi
    fi
    if [[ $DB_DROP_OK -eq 1 ]]; then
        echo "Database & user berhasil dihapus."
    else
        echo -e "${YELLOW}Lewati drop database (MariaDB tidak aktif atau tidak terinstal). Tidak masalah jika kamu akan hapus paket database sepenuhnya di langkah berikutnya.${NC}"
    fi

    echo -e "${GREEN}[5/5] Menghapus konfigurasi Nginx untuk Panel...${NC}"
    rm -f /etc/nginx/sites-enabled/pterodactyl.conf
    rm -f /etc/nginx/sites-available/pterodactyl.conf
    rm -f /etc/nginx/conf.d/pterodactyl.conf
    systemctl reload nginx 2>/dev/null || true

    if [[ -n "$FQDN" ]]; then
        read -p "Hapus juga sertifikat SSL untuk ${FQDN}? (y/n): " RM_SSL
        if [[ "$RM_SSL" == "y" ]]; then
            if command -v certbot &> /dev/null; then
                certbot delete --cert-name "$FQDN" --non-interactive 2>/dev/null || true
            fi
            rm -rf "/etc/letsencrypt/live/${FQDN}"
            rm -rf "/etc/letsencrypt/archive/${FQDN}"
            rm -f "/etc/letsencrypt/renewal/${FQDN}.conf"
        fi
    fi

    echo ""
    echo -e "${GREEN}Bagian Panel (file, database, Nginx config) sudah bersih.${NC}"
    echo ""

    WINGS_REMOVED=0
    echo -e "${YELLOW}Mau hapus juga Wings beserta SEMUA container/server game di dalamnya?${NC}"
    echo -e "${RED}Data world, plugin, dan save game di tiap server AKAN HILANG PERMANEN.${NC}"
    read -p "Hapus Wings + semua container game? (y/n): " RM_WINGS

    if [[ "$RM_WINGS" == "y" ]]; then
        read -p "Konfirmasi sekali lagi, ketik 'HAPUS' untuk benar-benar menghapus Wings: " CONFIRM_WINGS
        if [[ "$CONFIRM_WINGS" == "HAPUS" ]]; then
            remove_wings
            WINGS_REMOVED=1
        else
            echo -e "${YELLOW}Dibatalkan, Wings tidak jadi dihapus.${NC}"
        fi
    else
        echo -e "${YELLOW}Wings tetap dipertahankan.${NC}"
    fi

    echo ""
    echo -e "${YELLOW}Mau hapus juga paket pendukung (PHP, MariaDB, Nginx, Redis, Composer)?${NC}"
    echo -e "${YELLOW}Pilih 'y' hanya kalau VPS ini TIDAK dipakai untuk hal lain selain Panel.${NC}"
    read -p "Hapus paket pendukung juga? (y/n): " RM_PKG

    if [[ "$RM_PKG" == "y" ]]; then
        if [[ "$DISTRO_FAMILY" == "debian" ]]; then
            remove_support_packages_debian "$WINGS_REMOVED"
        else
            remove_support_packages_rhel "$WINGS_REMOVED"
        fi
    else
        echo -e "${YELLOW}Paket pendukung (PHP, MariaDB, Nginx, Redis) tetap dipertahankan.${NC}"
    fi

    rm -f /root/.installerptd-info

    echo ""
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN} Uninstall Panel selesai.${NC}"
    if [[ $WINGS_REMOVED -eq 1 ]]; then
        echo -e "${GREEN} Wings beserta container game juga sudah dihapus.${NC}"
    else
        echo -e "${GREEN} Wings tetap utuh (tidak dihapus).${NC}"
    fi
    echo -e "${GREEN}=============================================${NC}"
}

###############################################################################
# Hapus Wings + semua container game (dipanggil hanya jika user konfirmasi)
###############################################################################
remove_wings() {
    echo -e "${GREEN}Menghapus Wings & container game...${NC}"

    systemctl stop wings 2>/dev/null || true
    systemctl disable wings 2>/dev/null || true
    rm -f /etc/systemd/system/wings.service
    systemctl daemon-reload

    if command -v docker &> /dev/null; then
        CONTAINERS=$(docker ps -aq --filter "label=Service=Pterodactyl" 2>/dev/null || true)
        if [[ -n "$CONTAINERS" ]]; then
            docker rm -f $CONTAINERS 2>/dev/null || true
        fi
    fi

    rm -rf /etc/pterodactyl
    rm -f /usr/local/bin/wings
    rm -rf /var/lib/pterodactyl
    rm -rf /var/log/pterodactyl

    echo -e "${GREEN}Wings & container game berhasil dihapus.${NC}"
}

###############################################################################
# Hapus paket pendukung dengan aman (anti-error saat purge MariaDB)
###############################################################################
remove_support_packages_debian() {
    local WINGS_ALREADY_REMOVED="${1:-0}"
    echo -e "${GREEN}Menghapus paket pendukung (Debian family)...${NC}"

    # Matikan service dulu, jangan langsung purge selagi service jalan -
    # ini penyebab paling umum error dpkg/mysqld saat purge mariadb-server
    systemctl stop nginx "$PHP_FPM_SERVICE" "$REDIS_SERVICE" mariadb 2>/dev/null || true
    systemctl disable nginx "$PHP_FPM_SERVICE" "$REDIS_SERVICE" mariadb 2>/dev/null || true

    # Pastikan proses mysqld benar-benar mati sebelum purge,
    # supaya dpkg tidak macet nunggu/gagal shutdown
    pkill -9 -f mysqld 2>/dev/null || true
    pkill -9 -f mariadbd 2>/dev/null || true
    sleep 2

    export DEBIAN_FRONTEND=noninteractive

    # Purge satu per satu dengan '|| true' supaya satu paket gagal
    # tidak menghentikan seluruh proses (dan tidak bikin dpkg nyangkut)
    apt-get remove --purge -y mariadb-server mariadb-client mariadb-common mariadb-server-core-* mariadb-client-core-* 2>/dev/null || true
    apt-get remove --purge -y nginx nginx-common nginx-core 2>/dev/null || true
    apt-get remove --purge -y redis-server redis-tools 2>/dev/null || true
    apt-get remove --purge -y 'php8.3*' 2>/dev/null || true

    # Perbaiki state dpkg kalau ada paket yang setengah ke-purge
    dpkg --configure -a 2>/dev/null || true
    apt-get -f install -y 2>/dev/null || true

    apt-get autoremove -y 2>/dev/null || true
    apt-get autoclean -y 2>/dev/null || true

    rm -f /usr/local/bin/composer
    rm -rf /etc/nginx
    rm -rf /etc/mysql /var/lib/mysql /var/log/mysql

    echo -e "${GREEN}Paket pendukung (Debian family) berhasil dihapus.${NC}"
    offer_remove_docker "$WINGS_ALREADY_REMOVED"
}

remove_support_packages_rhel() {
    local WINGS_ALREADY_REMOVED="${1:-0}"
    echo -e "${GREEN}Menghapus paket pendukung (RHEL family)...${NC}"

    systemctl stop nginx "$PHP_FPM_SERVICE" "$REDIS_SERVICE" mariadb 2>/dev/null || true
    systemctl disable nginx "$PHP_FPM_SERVICE" "$REDIS_SERVICE" mariadb 2>/dev/null || true

    pkill -9 -f mysqld 2>/dev/null || true
    pkill -9 -f mariadbd 2>/dev/null || true
    sleep 2

    dnf remove -y mariadb-server mariadb 2>/dev/null || true
    dnf remove -y nginx 2>/dev/null || true
    dnf remove -y redis 2>/dev/null || true
    dnf remove -y php php-cli php-gd php-mysqlnd php-mbstring php-bcmath php-xml \
        php-fpm php-curl php-zip php-intl php-pdo 2>/dev/null || true

    dnf module reset php -y 2>/dev/null || true
    dnf autoremove -y 2>/dev/null || true

    rm -f /usr/local/bin/composer
    rm -rf /etc/nginx
    rm -rf /var/lib/mysql /var/log/mariadb /etc/my.cnf.d /etc/my.cnf

    echo -e "${GREEN}Paket pendukung (RHEL family) berhasil dihapus.${NC}"
    offer_remove_docker "$WINGS_ALREADY_REMOVED"
}

offer_remove_docker() {
    local WINGS_ALREADY_REMOVED="${1:-0}"
    if command -v docker &> /dev/null; then
        echo ""
        if [[ "$WINGS_ALREADY_REMOVED" == "1" ]]; then
            echo -e "${YELLOW}Docker terdeteksi terinstal. Wings sudah kamu hapus duluan.${NC}"
        else
            echo -e "${YELLOW}Docker terdeteksi terinstal. Wings masih ada dan butuh Docker untuk jalan.${NC}"
        fi
        read -p "Hapus Docker juga? (y/n): " RM_DOCKER
        if [[ "$RM_DOCKER" == "y" ]]; then
            systemctl stop docker 2>/dev/null || true
            if [[ "$DISTRO_FAMILY" == "debian" ]]; then
                apt-get remove --purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true
                apt-get autoremove -y 2>/dev/null || true
            else
                dnf remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true
            fi
            rm -rf /var/lib/docker /etc/docker
            echo -e "${GREEN}Docker dihapus.${NC}"
        fi
    fi
}

###############################################################################
# MENU UTAMA
###############################################################################
detect_os

clear
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}       installerptd.sh - Pterodactyl Tool${NC}"
echo -e "${CYAN}       OS terdeteksi: ${OS_PRETTY}${NC}"
echo -e "${CYAN}=============================================${NC}"
echo "1) Install Panel"
echo "2) Install & Aktifkan Wings"
echo "3) Uninstall Panel"
echo "0) Keluar"
echo ""
read -p "Pilih opsi [0-3]: " OPSI

case $OPSI in
    1) install_panel ;;
    2) install_wings ;;
    3) uninstall_panel ;;
    0) echo "Keluar."; exit 0 ;;
    *) echo -e "${RED}Pilihan tidak valid.${NC}"; exit 1 ;;
esac
