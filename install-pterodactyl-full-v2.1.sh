#!/bin/bash
################################################################################
# AUTO INSTALLER v2.1 - PTERODACTYL PANEL + BLUEPRINT + WINGS + DOCKER + HARDENING
# Target  : Ubuntu 22.04 LTS / 24.04 LTS, root access, 1 VPS baru (Panel & Wings jadi satu)
#
# PERUBAHAN DARI v1:
#   - Cron schedule:run dijamin kepasang (bug grep + set -e sudah diperbaiki)
#   - SSL dicek DI AWAL. Kalau gagal, skrip berhenti sebelum install apa pun
#   - Skrip menolak jalan kalau panel sudah terpasang (biar .env / APP_KEY aman)
#   - Password tidak ditulis di file: di-generate acak (atau isi lewat env var)
#   - Node.js 22 + Blueprint ikut terpasang otomatis
#   - Hardening sysctl ditulis ke file sendiri (aman dijalankan ulang)
#   - Swap file + swappiness otomatis (tetap jalan walau VPS sudah punya swap bawaan)
#   - Helper "wings-check": enable+start Wings, cek crash detection & syarat Schedules
#
# CARA PAKAI:
#   1. Edit bagian "KONFIGURASI" di bawah (minimal FQDN dan ADMIN_EMAIL).
#   2. bash install-pterodactyl-full-v2.sh
#      (opsional password sendiri: ADMIN_PASSWORD='xxx' DB_PASSWORD='yyy' bash ...
#       pakai huruf dan angka saja biar aman)
#   3. Tunggu selesai, catat password di akhir output, lalu ikuti LANGKAH MANUAL.
################################################################################

set -e
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a   # cegah prompt 'restart services' di Ubuntu 22.04/24.04

# ============================================================================
# KONFIGURASI PANEL
# ============================================================================
FQDN="vyron.ikyynxv2.my.id"                  # Domain yang sudah pointing ke IP VPS ini
ADMIN_EMAIL="nurcahyaazis7@gmail.com"
DB_NAME="vyron"
DB_USER="vyron7777"
ADMIN_USERNAME="Vyron"
ADMIN_FIRSTNAME="Vyron"
ADMIN_LASTNAME="Vyron"
TIMEZONE="Asia/Jakarta"
USE_SSL="true"                             # "true" = HTTPS via Let's Encrypt, "false" = HTTP saja

# Password: kosong = di-generate acak (disarankan). Atau isi lewat env var saat menjalankan skrip.
DB_PASSWORD="${DB_PASSWORD:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

# ============================================================================
# KONFIGURASI WINGS / FIREWALL / HARDENING
# ============================================================================
ALLOC_PORT_START=20000                     # Range port buat SEMUA server (Node.js, bot, game, dll)
ALLOC_PORT_END=30000
SSH_PORT=22                                # Ganti kalau mau custom port SSH
WINGS_API_PORT=8080
WINGS_SFTP_PORT=2022
FAIL2BAN_MAXRETRY=3
FAIL2BAN_BANTIME=3600
FAIL2BAN_FINDTIME=600

SWAP_SIZE_GB=2                             # Swap (0 = skip). Chrome/Puppeteer rakus RAM
BOT_IMAGE="vyron-node:22"                  # Nama image Docker custom buat bot (dibuild di BAGIAN 5)
NODE_NEED=22                               # Versi minimal Node.js di host (syarat Blueprint)
INSTALL_BLUEPRINT="true"                   # "false" = skip Node.js + Blueprint (kalau gak butuh tema/ekstensi panel)

# ============================================================================
# JANGAN EDIT DI BAWAH INI KECUALI PAHAM
# ============================================================================

PTERO_DIR="/var/www/pterodactyl"

if [[ $EUID -ne 0 ]]; then
   echo "Jalankan sebagai root." 1>&2
   exit 1
fi

# Guard: jangan timpa panel yang sudah ada
if [ -f "${PTERO_DIR}/.env" ]; then
    echo "!! Panel sudah terpasang di ${PTERO_DIR} (.env ditemukan)."
    echo "!! Skrip ini hanya untuk VPS baru. Menjalankannya lagi akan bikin APP_KEY baru"
    echo "!! dan merusak data terenkripsi di database. Dibatalkan."
    exit 1
fi

genpass() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20; }
[ -z "$DB_PASSWORD" ]    && DB_PASSWORD="$(genpass)"
[ -z "$ADMIN_PASSWORD" ] && ADMIN_PASSWORD="$(genpass)"

echo "################################################################"
echo " BAGIAN 0: PRE-FLIGHT (cek domain & SSL sebelum install)"
echo "################################################################"

PUBLIC_IP="$(curl -4 -s --max-time 5 https://api.ipify.org || true)"
DNS_IP="$(getent ahostsv4 "${FQDN}" | awk '{print $1; exit}' || true)"
if [ -n "$PUBLIC_IP" ] && [ -n "$DNS_IP" ] && [ "$PUBLIC_IP" != "$DNS_IP" ]; then
    echo "!! PERINGATAN: ${FQDN} mengarah ke ${DNS_IP}, tapi IP VPS ini ${PUBLIC_IP}."
    echo "!! Kalau pakai Cloudflare proxy (awan oranye), matikan dulu saat ambil SSL."
elif [ -z "$DNS_IP" ]; then
    echo "!! PERINGATAN: ${FQDN} belum ter-resolve di DNS."
fi

apt-get update -y
apt-get install -y curl ca-certificates gnupg lsb-release

if [ "$USE_SSL" = "true" ]; then
    echo ">>> [0.1] Ambil sertifikat SSL (port 80 harus bebas)..."
    apt-get install -y certbot
    if ! certbot certonly --standalone --non-interactive --agree-tos -m "${ADMIN_EMAIL}" -d "${FQDN}"; then
        echo "!! Gagal ambil SSL. Pastikan ${FQDN} sudah pointing ke ${PUBLIC_IP:-IP VPS ini} dan port 80 terbuka."
        echo "!! Belum ada yang terinstall, jadi aman untuk jalankan ulang skrip ini setelah diperbaiki."
        exit 1
    fi
    [ -f "/etc/letsencrypt/live/${FQDN}/fullchain.pem" ] || { echo "!! Sertifikat tidak ditemukan."; exit 1; }
    echo ">>> SSL OK."
fi

echo "################################################################"
echo " BAGIAN 1: INSTALL PANEL"
echo "################################################################"

echo ">>> [1.1] Update sistem & dependency dasar..."
apt-get update -y && apt-get upgrade -y
apt-get install -y software-properties-common apt-transport-https unzip zip tar git wget

echo ">>> [1.2] Menambahkan repo PHP & Redis..."
LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
curl -fsSL https://packages.redis.io/gpg | gpg --dearmor --yes -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" \
    | tee /etc/apt/sources.list.d/redis.list
apt-get update -y

echo ">>> [1.3] Install PHP 8.3, MariaDB, Nginx, Redis..."
apt-get install -y php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,sqlite3} \
    mariadb-server nginx redis-server cron

echo ">>> [1.4] Install Composer..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

echo ">>> [1.5] Menyiapkan database..."
mysql -u root <<MYSQL_SCRIPT
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
MYSQL_SCRIPT

echo ">>> [1.6] Download & pasang Panel..."
mkdir -p ${PTERO_DIR}
cd ${PTERO_DIR}
curl -fLo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
rm -f panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/
cp .env.example .env

export COMPOSER_ALLOW_SUPERUSER=1
composer install --no-dev --optimize-autoloader --no-interaction

echo ">>> [1.7] Konfigurasi environment..."
php artisan key:generate --force

php artisan p:environment:setup \
    --author="${ADMIN_EMAIL}" \
    --url="$([ "$USE_SSL" = "true" ] && echo https || echo http)://${FQDN}" \
    --timezone="${TIMEZONE}" \
    --cache=redis --session=redis --queue=redis \
    --redis-host=localhost --redis-pass="null" --redis-port=6379 \
    --settings-ui=true --telemetry=false -n

php artisan p:environment:database \
    --host=127.0.0.1 --port=3306 \
    --database="${DB_NAME}" --username="${DB_USER}" --password="${DB_PASSWORD}" -n

echo ">>> [1.8] Migrasi database & bikin akun admin..."
php artisan migrate --seed --force

php artisan p:user:make \
    --email="${ADMIN_EMAIL}" --username="${ADMIN_USERNAME}" \
    --name-first="${ADMIN_FIRSTNAME}" --name-last="${ADMIN_LASTNAME}" \
    --password="${ADMIN_PASSWORD}" --admin=1 -n

chown -R www-data:www-data ${PTERO_DIR}

echo ">>> [1.9] Cron job & queue worker Panel..."
# '|| true' wajib: tanpa ini, grep return 1 saat crontab kosong dan 'set -e' membatalkan baris cron
( crontab -l 2>/dev/null | grep -v 'pterodactyl/artisan schedule:run' || true ; \
  echo "* * * * * php ${PTERO_DIR}/artisan schedule:run >> /dev/null 2>&1" ) | crontab -
crontab -l | grep -q 'schedule:run' || { echo "!! Cron schedule:run gagal terpasang."; exit 1; }

cat > /etc/systemd/system/pteroq.service <<'EOF'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

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

systemctl daemon-reload
systemctl enable --now redis-server
systemctl enable --now pteroq.service

echo ">>> [1.10] Konfigurasi Nginx Panel..."
rm -f /etc/nginx/sites-enabled/default

if [ "$USE_SSL" = "true" ]; then
cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server_tokens off;
server {
    listen 80;
    server_name ${FQDN};
    return 301 https://\$server_name\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${FQDN};
    root ${PTERO_DIR}/public;
    index index.php;
    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;
    client_max_body_size 100m;
    client_body_timeout 120s;
    ssl_certificate /etc/letsencrypt/live/${FQDN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${FQDN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
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
    location ~ /\.ht { deny all; }
}
EOF
else
cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name ${FQDN};
    root ${PTERO_DIR}/public;
    index index.php;
    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;
    client_max_body_size 100m;
    client_body_timeout 120s;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
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
    location ~ /\.ht { deny all; }
}
EOF
fi

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf

if [ "$USE_SSL" = "true" ]; then
    # Sertifikat dibuat pakai --standalone (butuh port 80 bebas), jadi saat perpanjangan Nginx
    # harus dimatikan sebentar. Hook ini dijalankan certbot hanya saat ada sertifikat yang diperpanjang.
    mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/pre/00-stop-nginx.sh <<'HOOK'
#!/bin/sh
systemctl stop nginx
HOOK
    cat > /etc/letsencrypt/renewal-hooks/post/00-start-nginx.sh <<'HOOK'
#!/bin/sh
systemctl start nginx
HOOK
    cat > /etc/letsencrypt/renewal-hooks/deploy/00-restart-wings.sh <<'HOOK'
#!/bin/sh
# Wings baru membaca sertifikat saat start; try-restart = hanya restart kalau Wings sedang jalan
systemctl try-restart wings || true
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/pre/00-stop-nginx.sh \
             /etc/letsencrypt/renewal-hooks/post/00-start-nginx.sh \
             /etc/letsencrypt/renewal-hooks/deploy/00-restart-wings.sh
fi

nginx -t || { echo "!! Konfigurasi Nginx error, cek: nginx -t"; exit 1; }
systemctl restart nginx
systemctl enable nginx mariadb php8.3-fpm

echo "################################################################"
echo " BAGIAN 2: NODE.JS ${NODE_NEED} + BLUEPRINT (opsional, gagal = tidak menghentikan instalasi)"
echo "################################################################"

if [ "$INSTALL_BLUEPRINT" = "true" ]; then
    export PTERO_DIR NODE_NEED
    cat > /tmp/install-blueprint.sh <<'BPSCRIPT'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo ">>> [2.1] Cek versi Node.js..."
NODE_MAJOR=0
if command -v node >/dev/null 2>&1; then
    NODE_MAJOR="$(node -v | sed 's/^v//' | cut -d. -f1)"
fi
if [ "$NODE_MAJOR" -ge "$NODE_NEED" ]; then
    echo "Node.js v${NODE_MAJOR} sudah memenuhi syarat."
else
    echo "Node.js saat ini v${NODE_MAJOR}, install v${NODE_NEED}..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_NEED}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list
    apt-get update -y
    apt-get install -y nodejs
    NODE_MAJOR="$(node -v | sed 's/^v//' | cut -d. -f1)"
    [ "$NODE_MAJOR" -ge "$NODE_NEED" ] || { echo "!! Upgrade Node gagal (v${NODE_MAJOR})."; exit 1; }
fi
command -v yarn >/dev/null 2>&1 || npm i -g yarn
echo "Node.js $(node -v), yarn $(yarn -v)."

echo ">>> [2.2] Install Blueprint..."
cd ${PTERO_DIR}
if command -v blueprint >/dev/null 2>&1 && [ -d "${PTERO_DIR}/.blueprint" ]; then
    echo "Blueprint sudah terpasang, skip."
else
    yarn
    curl -fL https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip -o release.zip
    unzip -o release.zip >/dev/null
    rm -f release.zip
    cat > .blueprintrc <<'EOF'
WEBUSER="www-data";
OWNERSHIP="www-data:www-data";
USERSHELL="/bin/bash";
EOF
    chmod +x blueprint.sh
    # Pertanyaan maintenance mode dijawab 'y' otomatis
    yes y | bash blueprint.sh
    php artisan up >/dev/null 2>&1 || true
fi
command -v blueprint >/dev/null 2>&1 || { echo "!! Blueprint belum terdeteksi."; exit 1; }
chown -R www-data:www-data ${PTERO_DIR}
echo "Blueprint: $(blueprint -v 2>/dev/null | head -n1)"
BPSCRIPT
    if bash /tmp/install-blueprint.sh; then
        echo ">>> Blueprint selesai."
        rm -f /tmp/install-blueprint.sh
    else
        echo "!! PERINGATAN: Node.js/Blueprint gagal dipasang. Panel, Wings, dan firewall tetap dilanjutkan."
        echo "!! Coba ulang nanti dengan: PTERO_DIR=${PTERO_DIR} NODE_NEED=${NODE_NEED} bash /tmp/install-blueprint.sh"
    fi
else
    echo ">>> Blueprint di-skip (INSTALL_BLUEPRINT=false)."
fi


echo "################################################################"
echo " BAGIAN 3: INSTALL DOCKER + WINGS"
echo "################################################################"

echo ">>> [3.1] Install Docker..."
if ! command -v docker &> /dev/null; then
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    systemctl enable --now docker
else
    echo "Docker sudah ada, skip."
fi

echo ">>> [3.2] Install Wings..."
mkdir -p /etc/pterodactyl
mkdir -p /var/lib/pterodactyl/volumes

curl -fL -o /usr/local/bin/wings \
    "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
chmod u+x /usr/local/bin/wings

cat > /etc/systemd/system/wings.service <<'EOF'
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
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
echo "Wings terinstall (belum di-start, tunggu config dari Panel)."

# Aktifkan Wings saat boot (belum di-start sekarang karena config.yml belum ada)
systemctl enable wings >/dev/null 2>&1 || true

echo ">>> [3.3] Pasang helper 'wings-check' (cek Wings, auto-restart, dan syarat jadwal restart)..."
cat > /usr/local/bin/wings-check <<'WCHECK'
#!/bin/bash
# wings-check: cek dan aktifkan Wings, crash detection, serta syarat Schedules di panel
CFG=/etc/pterodactyl/config.yml
ok()   { echo -e "\e[32m[OK]\e[0m $1"; }
warn() { echo -e "\e[33m[!!]\e[0m $1"; }

if [ ! -s "$CFG" ]; then
    warn "Config Wings belum ada. Panel > Admin > Nodes > [node] > Configuration, copy isinya ke $CFG lalu jalankan wings-check lagi."
    exit 1
fi
ok "Config Wings ada."

# 1. Wings aktif saat boot
if systemctl is-enabled --quiet wings; then
    ok "Wings aktif otomatis saat VPS boot."
else
    systemctl enable wings >/dev/null 2>&1 && ok "Wings sekarang diaktifkan saat boot."
fi

# 2. Wings sedang jalan
if systemctl is-active --quiet wings; then
    ok "Wings sedang berjalan."
else
    warn "Wings belum jalan, mencoba start..."
    systemctl start wings
    sleep 3
    if systemctl is-active --quiet wings; then
        ok "Wings berhasil dijalankan."
    else
        warn "Wings gagal start. Cek: journalctl -u wings -n 30 --no-pager"
    fi
fi

# 3. Crash detection (restart otomatis kalau bot crash)
if grep -qE '^\s*crash_detection:' "$CFG"; then
    if grep -A4 -E '^\s*crash_detection:' "$CFG" | grep -qE 'enabled:\s*false'; then
        warn "Crash detection DIMATIKAN di config. Ubah jadi 'enabled: true' lalu: systemctl restart wings"
    else
        ok "Crash detection aktif (diatur di config)."
    fi
else
    ok "Crash detection aktif (pakai default Wings, yaitu aktif)."
fi

# 4. Syarat fitur Schedules di panel
if crontab -l 2>/dev/null | grep -q 'schedule:run'; then
    ok "Cron panel aktif (syarat Schedules)."
else
    warn "Cron panel belum ada, jadwal restart di panel tidak akan jalan."
fi
if systemctl is-active --quiet pteroq; then
    ok "Queue worker panel (pteroq) berjalan."
else
    warn "pteroq tidak berjalan. Cek: systemctl status pteroq"
fi

echo
echo "Jadwal restart dibuat manual per server: Panel > server > Schedules > Create Schedule > task 'Send power action: Restart'."
WCHECK
chmod +x /usr/local/bin/wings-check

echo "################################################################"
echo " BAGIAN 4: FIREWALL & SECURITY HARDENING"
echo "################################################################"

echo ">>> [4.1] Setup UFW..."
apt-get install -y ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP - Panel'
ufw allow 443/tcp comment 'HTTPS - Panel'
ufw allow ${WINGS_API_PORT}/tcp comment 'Wings API'
ufw allow ${WINGS_SFTP_PORT}/tcp comment 'Wings SFTP'
ufw allow ${ALLOC_PORT_START}:${ALLOC_PORT_END}/tcp comment 'Server Allocations TCP'
ufw allow ${ALLOC_PORT_START}:${ALLOC_PORT_END}/udp comment 'Server Allocations UDP'
ufw --force enable

echo ">>> [4.2] Install ufw-docker (biar container Docker/Wings gak bisa skip UFW)..."
curl -fsSL https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker -o /usr/local/bin/ufw-docker
chmod +x /usr/local/bin/ufw-docker
ufw-docker install
# ufw-docker memblokir traffic ke container kecuali ada rule 'route'. Tanpa dua baris ini,
# port allocation gak bisa diakses dari luar walau 'ufw allow' sudah ada.
ufw route allow proto tcp from any to any port ${ALLOC_PORT_START}:${ALLOC_PORT_END}
ufw route allow proto udp from any to any port ${ALLOC_PORT_START}:${ALLOC_PORT_END}
systemctl restart ufw

echo ">>> [4.3] Install fail2ban..."
apt-get install -y fail2ban
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = ${FAIL2BAN_BANTIME}
findtime = ${FAIL2BAN_FINDTIME}
maxretry = ${FAIL2BAN_MAXRETRY}
banaction = ufw

[sshd]
enabled = true
port    = ${SSH_PORT}
filter  = sshd
backend = systemd
maxretry = ${FAIL2BAN_MAXRETRY}
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

echo ">>> [4.4] Hardening jaringan (sysctl)..."
cat > /etc/sysctl.d/99-ptero-hardening.conf <<'EOF'
# --- Hardening tambahan (Pterodactyl production) ---
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.log_martians = 1
EOF
sysctl -p /etc/sysctl.d/99-ptero-hardening.conf

echo ">>> [4.5] Auto security update..."
apt-get install -y unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "################################################################"
echo " BAGIAN 5: SWAP + IMAGE DOCKER KHUSUS BOT (Chrome, ffmpeg, dll)"
echo "################################################################"

# Swap tambahan berupa file /swapfile (jalan walau VPS sudah punya swap bawaan kecil)
if [ "${SWAP_SIZE_GB}" -gt 0 ]; then
    if [ -f /swapfile ] || swapon --show=NAME --noheadings | grep -qx '/swapfile'; then
        echo ">>> [5.1] /swapfile sudah ada, skip bikin swap."
        swapon --show=NAME --noheadings | grep -qx '/swapfile' || swapon /swapfile || true
    else
        echo ">>> [5.1] Bikin swap ${SWAP_SIZE_GB}GB..."
        fallocate -l ${SWAP_SIZE_GB}G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE_GB*1024))
        chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    fi
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    # swappiness rendah: swap hanya dipakai saat RAM hampir habis (selalu diset, apa pun kondisi swap)
    echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf && sysctl -p /etc/sysctl.d/99-swappiness.conf
else
    echo ">>> [5.1] Swap di-skip (SWAP_SIZE_GB=0)."
fi

echo ">>> [5.2] Build image Docker ${BOT_IMAGE}..."
mkdir -p /opt/vyron-yolk
cat > /opt/vyron-yolk/Dockerfile <<'DOCKERFILE'
FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git unzip zip xz-utils tar iproute2 procps \
      build-essential python3 pkg-config \
      ffmpeg imagemagick webp fonts-liberation fonts-noto-color-emoji \
      libcairo2-dev libpango1.0-dev libjpeg-dev libgif-dev librsvg2-dev \
      libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 \
      libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libasound2 \
      libpango-1.0-0 libcairo2 libx11-6 libxcb1 libxext6 libxshmfence1 libxss1 \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -m -d /home/container -s /bin/bash container
USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container
COPY --chown=container:container entrypoint.sh /entrypoint.sh
CMD ["/bin/bash", "/entrypoint.sh"]
DOCKERFILE

cat > /opt/vyron-yolk/entrypoint.sh <<'ENTRY'
#!/bin/bash
cd /home/container
export INTERNAL_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
PARSED=$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g' | eval echo "$(cat -)")
printf "\033[1m\033[33mcontainer@pterodactyl~ \033[0m%s\n" "$PARSED"
exec env ${PARSED}
ENTRY
chmod +x /opt/vyron-yolk/entrypoint.sh
docker build -t "${BOT_IMAGE}" /opt/vyron-yolk

# Simpan kredensial ke file khusus root (bukan di dalam skrip)
CRED_FILE="/root/pterodactyl-credentials.txt"
umask 077
cat > "${CRED_FILE}" <<EOF
Panel URL       : $([ "$USE_SSL" = "true" ] && echo https || echo http)://${FQDN}
Admin email     : ${ADMIN_EMAIL}
Admin username  : ${ADMIN_USERNAME}
Admin password  : ${ADMIN_PASSWORD}
DB name         : ${DB_NAME}
DB user         : ${DB_USER}
DB password     : ${DB_PASSWORD}
EOF
chmod 600 "${CRED_FILE}"

echo ""
echo "################################################################"
echo " INSTALASI SELESAI"
echo "################################################################"
echo " URL Panel   : $([ "$USE_SSL" = "true" ] && echo https || echo http)://${FQDN}"
echo " Login email : ${ADMIN_EMAIL}"
echo " Username    : ${ADMIN_USERNAME}"
echo " Password    : ${ADMIN_PASSWORD}"
echo " (kredensial lengkap tersimpan di ${CRED_FILE}, hanya bisa dibaca root)"
echo " Blueprint   : terpasang, tinggal 'blueprint -install namatema'"
echo " Firewall    : SSH ${SSH_PORT}, 80, 443, ${WINGS_API_PORT}, ${WINGS_SFTP_PORT}, ${ALLOC_PORT_START}-${ALLOC_PORT_END} (TCP+UDP)"
echo " ufw-docker  : aktif (container Docker gak bisa lagi skip UFW)"
echo ""
echo "################################################################"
echo " LANGKAH MANUAL YANG WAJIB (gak bisa diotomatisin dari sini)"
echo "################################################################"
echo "1) Login ke Panel, lalu Admin > Nodes > Create Node"
echo "   - FQDN, SSL, port daemon ${WINGS_API_PORT}, SFTP ${WINGS_SFTP_PORT}"
echo "   - Buka tab 'Configuration', copy isinya ke /etc/pterodactyl/config.yml"
echo "   - Lalu jalankan: wings-check   (otomatis enable + start Wings, cek crash detection, cek syarat jadwal)"
echo ""
echo "2) Admin > Nodes > [node] > Network > Create Allocation"
echo "   - Isi range: ${ALLOC_PORT_START}-${ALLOC_PORT_END}"
echo ""
echo "3) Admin > Nests > Import Egg > pilih egg-vyron-bot.json (image: ${BOT_IMAGE})"
echo ""
echo "   Auto-restart bot:"
echo "   - Restart saat crash: otomatis (crash detection Wings, dicek oleh wings-check)"
echo "   - Restart terjadwal: Panel > server bot > Schedules > Create Schedule > task Send power action: Restart"
echo ""
echo "   (SSL: hook perpanjangan otomatis sudah dipasang. Tes sekali: certbot renew --dry-run)"
echo ""
echo "4) SANGAT DISARANKAN:"
echo "   - Aktifin 2FA di akun admin Panel (Account Settings > 2FA)"
echo "   - Simpan password dari ${CRED_FILE}, lalu hapus file itu: shred -u ${CRED_FILE}"
echo "   - Pindah SSH ke key-based auth kalau sempat"
echo "   - Untuk proteksi DDoS skala besar, pasang Cloudflare Spectrum /"
echo "     OVH Anti-DDoS / TCPShield di depan node ini"
echo "   - Backup rutin & update berkala (apt update && apt upgrade -y)"
echo "################################################################"
