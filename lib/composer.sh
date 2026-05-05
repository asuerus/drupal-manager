#!/usr/bin/env bash
# Composer en Drupal installatie

install_drupal() {
    local slug="$1"
    local site_dir="$2"
    local drupal_project="$3"
    local drupal_version="$4"
    local php_version="$5"
    local bin
    bin=$(php_bin "$php_version")

    log_step "Composer create-project: ${drupal_project}:${drupal_version}"
    log_info "Doelmap:   ${site_dir}"
    log_info "PHP binary: ${bin}"

    [[ -f "$bin" ]] || die "PHP binary niet gevonden: ${bin}\nControleer of PHP ${php_version} is geïnstalleerd."

    # Verwijder bestaande map zodat Composer niet klaagt
    [[ -d "$site_dir" ]] && rm -rf "$site_dir"
    mkdir -p "$(dirname "$site_dir")"

    "$bin" "${COMPOSER_BIN}" create-project \
        --no-interaction \
        --prefer-dist \
        --stability stable \
        "${drupal_project}:${drupal_version}" \
        "$site_dir" \
        || die "Composer create-project mislukt."

    log_success "Drupal gedownload naar: ${site_dir}"
}

run_drush_install() {
    local site_dir="$1"
    local install_profile="$2"
    local site_name="$3"
    local db_url="$4"
    local admin_user="$5"
    local admin_pass="$6"
    local php_bin_path="$7"
    local db_root_pass
    db_root_pass=$(cat "$DB_ROOT_PASSWORD_FILE")

    log_step "drush site:install (profiel: ${install_profile})..."

    cd "$site_dir" || die "Kan niet naar ${site_dir} navigeren."

    # vendor/bin/drush is a bash wrapper — call drush.php directly with the
    # correct PHP binary to avoid PHP trying to execute a shell script.
    # --db-su/--db-su-pw: drush uses root to drop/create the DB, then writes
    # the site user credentials to settings.php.
    "$php_bin_path" vendor/drush/drush/drush.php site:install "${install_profile}" \
        --db-url="${db_url}" \
        --db-su=root \
        --db-su-pw="${db_root_pass}" \
        --site-name="${site_name}" \
        --account-name="${admin_user}" \
        --account-pass="${admin_pass}" \
        --yes \
        || die "drush site:install mislukt."

    log_success "Drupal installatie voltooid via drush."
}

configure_settings() {
    local site_dir="$1"
    local domain="$2"
    local settings_file="${site_dir}/web/sites/default/settings.php"

    log_step "settings.php aanpassen (trusted hosts, reverse proxy)..."

    # Maak tijdelijk schrijfbaar
    chmod 644 "$settings_file"

    local escaped_domain
    escaped_domain=$(escape_domain_for_php "$domain")

    cat >> "$settings_file" << EOF

// ── Drupal Manager (automatisch gegenereerd) ──────────────────────────────────
\$settings['trusted_host_patterns'] = [
  '^${escaped_domain}\$',
];

// Traefik reverse proxy: vertrouw het doorgestuurde protocol en IP
\$settings['reverse_proxy'] = TRUE;
\$settings['reverse_proxy_addresses'] = ['127.0.0.1'];
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
  \$_SERVER['HTTPS'] = 'on';
}
EOF

    chmod 444 "$settings_file"
    log_success "settings.php geconfigureerd."
}

set_file_permissions() {
    local site_dir="$1"

    log_step "Bestandspermissies instellen (eigenaar: nginx)..."

    chown -R nginx:nginx "$site_dir"

    local files_dir="${site_dir}/web/sites/default/files"
    if [[ -d "$files_dir" ]]; then
        find "$files_dir" -type d -exec chmod 755 {} \;
        find "$files_dir" -type f -exec chmod 644 {} \;
    fi

    log_success "Permissies ingesteld."
}
