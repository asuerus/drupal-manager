#!/usr/bin/env bash
# Nginx lokale backend configuratie

create_nginx_config() {
    local slug="$1"
    local port="$2"
    local site_dir="$3"
    local socket="$4"
    local conf_file="${NGINX_CONF_DIR}/drupal-${slug}.conf"

    log_step "Nginx backend config aanmaken voor '${slug}' (127.0.0.1:${port})..."

    export SITE_SLUG="$slug"
    export LOCAL_PORT="$port"
    export SITE_DIR="$site_dir"
    export PHP_FPM_SOCKET="$socket"
    export TRAEFIK_BACKEND_HOST

    render_template "${TEMPLATES_DIR}/nginx-backend.conf.tpl" "$conf_file"

    nginx -t || die "Nginx configuratie test mislukt. Controleer ${conf_file}."
    systemctl reload nginx

    log_success "Nginx config aangemaakt: ${conf_file}"
}

remove_nginx_config() {
    local slug="$1"
    local conf_file="${NGINX_CONF_DIR}/drupal-${slug}.conf"

    if [[ -f "$conf_file" ]]; then
        rm -f "$conf_file"
        nginx -t 2>/dev/null && systemctl reload nginx || true
        log_success "Nginx config verwijderd voor '${slug}'."
    fi
}
