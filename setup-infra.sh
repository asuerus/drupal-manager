#!/usr/bin/env bash
# setup-infra.sh — Eenmalige infrastructuur setup voor Drupal Manager
# Doelomgeving: Rocky Linux 10 + Traefik als reverse proxy
#
# Gebruik: sudo ./setup-infra.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=config/global.conf
source "${SCRIPT_DIR}/config/global.conf"
# shellcheck source=lib/utils.sh
source "${SCRIPT_DIR}/lib/utils.sh"

check_root

log_header "Drupal Manager — Infrastructuur Setup"
log_info "Rocky Linux 10 | Nginx | PHP 8.3 (REMI) | MariaDB | Composer"
echo ""

# ── EPEL & REMI ───────────────────────────────────────────────────────────────
log_step "EPEL repository installeren..."
dnf install -y epel-release
log_success "EPEL geïnstalleerd."

log_step "REMI repository installeren (Rocky Linux 10)..."
if ! rpm -q remi-release &>/dev/null; then
    dnf install -y "https://rpms.remirepo.net/enterprise/remi-release-10.rpm" \
        || die "REMI kon niet worden geïnstalleerd. Controleer de versie URL voor RL10."
fi
log_success "REMI geïnstalleerd."

# ── Hulpprogramma's ───────────────────────────────────────────────────────────
log_step "Basispakketten installeren..."
dnf install -y git unzip curl wget perl python3 python3-pyyaml
log_success "Basispakketten geïnstalleerd."

# ── Nginx ─────────────────────────────────────────────────────────────────────
log_step "Nginx installeren..."
dnf install -y nginx
systemctl enable nginx
systemctl start nginx

# Schakel de default vhost uit (Traefik handelt routing af)
if [[ -f /etc/nginx/conf.d/default.conf ]]; then
    mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled
    log_info "Default Nginx vhost uitgeschakeld."
fi

# Herstel drupal.conf.bak naar drupal.conf (bestaande site)
if [[ -f /etc/nginx/conf.d/drupal.conf.bak ]] && [[ ! -f /etc/nginx/conf.d/drupal.conf ]]; then
    mv /etc/nginx/conf.d/drupal.conf.bak /etc/nginx/conf.d/drupal.conf
    log_info "drupal.conf.bak hersteld naar drupal.conf."
fi

# Zorg dat nginx.conf een wildcard include gebruikt zodat al onze configs geladen worden
if grep -q "include /etc/nginx/conf.d/drupal.conf;" /etc/nginx/nginx.conf; then
    sed -i 's|include /etc/nginx/conf.d/drupal.conf;|include /etc/nginx/conf.d/*.conf;|' /etc/nginx/nginx.conf
    log_info "nginx.conf bijgewerkt naar wildcard include (*.conf)."
fi

# Verwijder oude port-80 catchall als die er staat — Traefik bezet die poort
rm -f /etc/nginx/conf.d/000-catchall.conf

nginx -t || die "Nginx configuratie test mislukt. Controleer /etc/nginx/nginx.conf en /etc/nginx/conf.d/."
systemctl reload nginx
log_success "Nginx actief."

# ── MariaDB ───────────────────────────────────────────────────────────────────
log_step "MariaDB installeren..."
dnf install -y mariadb-server mariadb
systemctl enable mariadb
systemctl start mariadb

if [[ -f "$DB_ROOT_PASSWORD_FILE" ]]; then
    log_info "MariaDB wachtwoordbestand aanwezig, beveiligingsstap overgeslagen."
elif mysql -uroot -e "SELECT 1;" &>/dev/null; then
    # Root bereikbaar via unix_socket (geen wachtwoord) — stel wachtwoord in
    log_step "MariaDB beveiligen en root wachtwoord instellen..."
    DB_ROOT_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)

    mysql -uroot <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${DB_ROOT_PASS}');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
    echo "$DB_ROOT_PASS" > "$DB_ROOT_PASSWORD_FILE"
    chmod 600 "$DB_ROOT_PASSWORD_FILE"
    log_success "MariaDB beveiligd. Wachtwoord opgeslagen in: ${DB_ROOT_PASSWORD_FILE}"
else
    log_warning "MariaDB root niet bereikbaar via unix_socket én geen wachtwoordbestand gevonden."
    die "Maak het wachtwoordbestand handmatig aan:\n  echo 'JOUW_ROOT_WACHTWOORD' | sudo tee ${DB_ROOT_PASSWORD_FILE}\n  sudo chmod 600 ${DB_ROOT_PASSWORD_FILE}\nDraai daarna setup-infra.sh opnieuw."
fi

# ── PHP 8.3 ───────────────────────────────────────────────────────────────────
log_step "PHP 8.3 installeren via REMI..."
dnf install -y \
    php83-php-fpm \
    php83-php-cli \
    php83-php-gd \
    php83-php-mbstring \
    php83-php-mysqlnd \
    php83-php-opcache \
    php83-php-pdo \
    php83-php-xml \
    php83-php-zip \
    php83-php-intl \
    php83-php-curl \
    php83-php-sodium

# Socket directory klaarzetten
mkdir -p /var/opt/remi/php83/run/php-fpm
chown nginx:nginx /var/opt/remi/php83/run/php-fpm

systemctl enable php83-php-fpm
systemctl start  php83-php-fpm
log_success "PHP 8.3 actief."

# ── Composer ──────────────────────────────────────────────────────────────────
log_step "Composer installeren..."
if [[ ! -f "$COMPOSER_BIN" ]]; then
    PHP83="/opt/remi/php83/root/usr/bin/php"
    EXPECTED_CHECKSUM="$("$PHP83" -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
    "$PHP83" -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');"
    ACTUAL_CHECKSUM="$("$PHP83" -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"

    if [[ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]]; then
        rm -f /tmp/composer-setup.php
        die "Composer installer checksum mismatch — installatie geannuleerd."
    fi

    "$PHP83" /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
    log_success "Composer geïnstalleerd."
else
    log_info "Composer al aanwezig, updaten..."
    "$COMPOSER_BIN" self-update
fi

# ── Log directories ───────────────────────────────────────────────────────────
log_step "Log directories aanmaken..."
mkdir -p /var/log/php-fpm
chown nginx:nginx /var/log/php-fpm

# ── Sites & state directories ─────────────────────────────────────────────────
log_step "Werk directories aanmaken..."
mkdir -p "$SITES_DIR"
mkdir -p "${STATE_DIR}/sites"
chown nginx:nginx "$SITES_DIR"
log_success "Directories aangemaakt."

# ── Traefik dynamic config controleren ───────────────────────────────────────
log_step "Traefik dynamic config controleren..."
[[ -f "$TRAEFIK_DYNAMIC_FILE" ]] \
    || die "Traefik dynamic config niet gevonden: ${TRAEFIK_DYNAMIC_FILE}\nControleer TRAEFIK_DYNAMIC_FILE in config/global.conf."
log_success "Traefik dynamic config gevonden: ${TRAEFIK_DYNAMIC_FILE}"

# ── Catch-all: Nginx foutpagina + Traefik catch-all router ───────────────────
log_step "Catch-all instellen voor onbekende subdomeinen van ${BASE_DOMAIN}..."

# Nginx "site niet gevonden" pagina op CATCHALL_PORT
cat > "${NGINX_CONF_DIR}/000-catchall.conf" << EOF
server {
    listen 127.0.0.1:${CATCHALL_PORT};
    listen ${TRAEFIK_BACKEND_HOST}:${CATCHALL_PORT};
    server_name _;

    default_type text/html;
    return 404 '<!DOCTYPE html>
<html lang="nl">
<head><meta charset="utf-8"><title>Site niet gevonden</title>
<style>body{font-family:sans-serif;max-width:600px;margin:80px auto;color:#333}
h1{color:#c0392b}code{background:#f4f4f4;padding:2px 6px;border-radius:3px}</style>
</head>
<body>
<h1>Site niet gevonden</h1>
<p>Er bestaat geen Drupal-instantie voor <strong>\$host</strong>.</p>
<p>Maak een nieuwe aan met:<br><code>sudo drupal-manager.sh new</code></p>
</body></html>';
}
EOF

nginx -t && systemctl reload nginx
log_success "Catch-all Nginx pagina actief op poort ${CATCHALL_PORT}."

# Catch-all router toevoegen aan Traefik dynamic config (eenmalig)
if python3 -c "
import yaml
with open('${TRAEFIK_DYNAMIC_FILE}') as f:
    cfg = yaml.safe_load(f) or {}
exit(0 if 'drupal-catchall' in cfg.get('http', {}).get('routers', {}) else 1)
" 2>/dev/null; then
    log_info "Traefik catch-all router al aanwezig, overgeslagen."
else
    BASE_DOMAIN="$BASE_DOMAIN" \
    CATCHALL_PORT="$CATCHALL_PORT" \
    TRAEFIK_BACKEND_HOST="$TRAEFIK_BACKEND_HOST" \
    CERT_RESOLVER="$CERT_RESOLVER" \
    TRAEFIK_ENTRYPOINT_HTTPS="$TRAEFIK_ENTRYPOINT_HTTPS" \
    TRAEFIK_DYNAMIC_FILE="$TRAEFIK_DYNAMIC_FILE" \
    python3 - << 'PYEOF'
import yaml, os

f    = os.environ['TRAEFIK_DYNAMIC_FILE']
dom  = os.environ['BASE_DOMAIN']
port = os.environ['CATCHALL_PORT']
host = os.environ['TRAEFIK_BACKEND_HOST']
cert = os.environ['CERT_RESOLVER']
ep   = os.environ['TRAEFIK_ENTRYPOINT_HTTPS']

escaped = dom.replace('.', r'\.')

with open(f) as fh:
    cfg = yaml.safe_load(fh) or {}

http = cfg.setdefault('http', {})
http.setdefault('routers', {})['drupal-catchall'] = {
    'rule':        f'HostRegexp(`^[a-z0-9-]+\\.{escaped}$`)',
    'priority':    1,
    'entryPoints': [ep],
    'service':     'drupal-catchall',
    'tls':         {'certResolver': cert},
}
http.setdefault('services', {})['drupal-catchall'] = {
    'loadBalancer': {'servers': [{'url': f'http://{host}:{port}'}]}
}

with open(f, 'w') as fh:
    yaml.dump(cfg, fh, default_flow_style=False, allow_unicode=True, sort_keys=False)
PYEOF
    log_success "Traefik catch-all router toegevoegd aan ${TRAEFIK_DYNAMIC_FILE}."
fi

# ── Samenvatting ──────────────────────────────────────────────────────────────
echo ""
log_header "Setup voltooid!"
echo "  Nginx:    $(nginx -v 2>&1)"
echo "  PHP 8.3:  $(/opt/remi/php83/root/usr/bin/php -v | head -1)"
echo "  MariaDB:  $(mysql --version)"
echo "  Composer: $("$COMPOSER_BIN" --version)"
echo ""
log_warning "Vergeet niet: voeg één wildcard DNS record toe (eenmalig):"
echo "  Type: A"
echo "  Naam: *.${BASE_DOMAIN}"
echo "  Waarde: $(curl -s ifconfig.me 2>/dev/null || echo '<VPS IP>')"
echo ""
log_info "Daarna: sudo ./drupal-manager.sh new"
