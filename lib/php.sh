#!/usr/bin/env bash
# PHP versiebeheer via REMI (Rocky Linux)

# "8.3" → "83"
php_version_short() { echo "${1//./}"; }

# "8.3" → "php83"
php_package_prefix() { echo "php$(php_version_short "$1")"; }

# "8.3" → "php83-php-fpm" (systemd service naam)
php_fpm_service() { echo "$(php_package_prefix "$1")-php-fpm"; }

# Socket directory voor een PHP versie
php_fpm_socket_dir() { echo "/var/opt/remi/php$(php_version_short "$1")/run/php-fpm"; }

# Pool config directory
php_fpm_pool_dir() { echo "/etc/opt/remi/php$(php_version_short "$1")/php-fpm.d"; }

# Pad naar PHP binary
php_bin() { echo "/opt/remi/php$(php_version_short "$1")/root/usr/bin/php"; }

ensure_php_version() {
    local version="$1"
    local prefix
    prefix=$(php_package_prefix "$version")

    if rpm -q "${prefix}-php-fpm" &>/dev/null; then
        log_info "PHP ${version} is al geïnstalleerd."
    else
        log_step "PHP ${version} installeren via REMI..."

        if ! rpm -q remi-release &>/dev/null; then
            dnf install -y "https://rpms.remirepo.net/enterprise/remi-release-10.rpm" \
                || die "REMI repository kon niet worden geïnstalleerd."
        fi

        dnf install -y \
            "${prefix}-php-fpm" \
            "${prefix}-php-cli" \
            "${prefix}-php-gd" \
            "${prefix}-php-mbstring" \
            "${prefix}-php-mysqlnd" \
            "${prefix}-php-opcache" \
            "${prefix}-php-pdo" \
            "${prefix}-php-xml" \
            "${prefix}-php-zip" \
            "${prefix}-php-intl" \
            "${prefix}-php-curl" \
            "${prefix}-php-sodium" \
            || die "PHP ${version} installatie mislukt."

        log_success "PHP ${version} pakketten geïnstalleerd."
    fi

    # Socket directory klaarzetten
    local socket_dir
    socket_dir=$(php_fpm_socket_dir "$version")
    mkdir -p "$socket_dir"
    chown nginx:nginx "$socket_dir"

    local service
    service=$(php_fpm_service "$version")
    systemctl enable "$service"
    if ! systemctl is-active --quiet "$service"; then
        systemctl start "$service"
    fi

    log_success "PHP-FPM ${version} actief (service: ${service})."
}

create_php_fpm_pool() {
    local slug="$1"
    local version="$2"
    local site_dir="$3"

    local pool_dir
    pool_dir=$(php_fpm_pool_dir "$version")
    local pool_file="${pool_dir}/${slug}.conf"
    local socket_dir
    socket_dir=$(php_fpm_socket_dir "$version")
    local socket="${socket_dir}/${slug}.sock"

    log_step "PHP-FPM pool aanmaken voor '${slug}' (PHP ${version})..."

    export SITE_SLUG="$slug"
    export SITE_DIR="$site_dir"
    export PHP_FPM_SOCKET="$socket"
    export PHP_FPM_SOCKET_DIR="$socket_dir"

    render_template "${TEMPLATES_DIR}/php-fpm-pool.conf.tpl" "$pool_file"

    systemctl reload "$(php_fpm_service "$version")" \
        || die "PHP-FPM reload mislukt na aanmaken pool voor ${slug}."

    log_success "PHP-FPM pool aangemaakt: ${pool_file}"
    echo "$socket"
}

remove_php_fpm_pool() {
    local slug="$1"
    local version="$2"
    local pool_file
    pool_file="$(php_fpm_pool_dir "$version")/${slug}.conf"

    if [[ -f "$pool_file" ]]; then
        rm -f "$pool_file"
        systemctl reload "$(php_fpm_service "$version")" 2>/dev/null || true
        log_success "PHP-FPM pool verwijderd voor '${slug}'."
    fi
}
