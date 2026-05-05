#!/usr/bin/env bash
# drupal-manager.sh — Drupal instance manager
#
# Gebruik:
#   sudo ./drupal-manager.sh           # interactief menu
#   sudo ./drupal-manager.sh new       # nieuwe instance
#   sudo ./drupal-manager.sh list      # overzicht
#   sudo ./drupal-manager.sh remove    # verwijderen

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# shellcheck source=config/global.conf
source "${SCRIPT_DIR}/config/global.conf"
# shellcheck source=lib/utils.sh
source "${SCRIPT_DIR}/lib/utils.sh"
# shellcheck source=lib/php.sh
source "${SCRIPT_DIR}/lib/php.sh"
# shellcheck source=lib/nginx.sh
source "${SCRIPT_DIR}/lib/nginx.sh"
# shellcheck source=lib/database.sh
source "${SCRIPT_DIR}/lib/database.sh"
# shellcheck source=lib/composer.sh
source "${SCRIPT_DIR}/lib/composer.sh"
# shellcheck source=lib/traefik.sh
source "${SCRIPT_DIR}/lib/traefik.sh"
# shellcheck source=lib/authentik.sh
source "${SCRIPT_DIR}/lib/authentik.sh"

# Absolute paden voor templates en profielen
export TEMPLATES_DIR="${SCRIPT_DIR}/templates"
PROFILES_DIR="${SCRIPT_DIR}/profiles"

check_root

# ── Profiel kiezen ────────────────────────────────────────────────────────────
choose_profile() {
    log_header "Kies een profiel"

    local profiles=()
    local names=()
    local i=1

    for f in "${PROFILES_DIR}"/*.conf; do
        [[ -f "$f" ]] || continue
        local name
        name=$(grep "^PROFILE_NAME=" "$f" | cut -d'"' -f2)
        profiles+=("$f")
        names+=("$name")
        printf "  %d) %s\n" "$i" "$name"
        ((i++))
    done

    echo ""
    read -rp "Keuze [1-$((i-1))]: " choice

    [[ "$choice" =~ ^[0-9]+$ ]] \
        && [[ "$choice" -ge 1 ]] \
        && [[ "$choice" -lt "$i" ]] \
        || die "Ongeldige keuze: ${choice}"

    CHOSEN_PROFILE="${profiles[$((choice-1))]}"
    # shellcheck source=/dev/null
    source "$CHOSEN_PROFILE"
    log_success "Geselecteerd profiel: ${PROFILE_NAME}"
}

# ── Nieuwe instance aanmaken ──────────────────────────────────────────────────
cmd_new() {
    log_header "Nieuwe Drupal instance aanmaken"

    choose_profile

    # Gebruikersinvoer
    echo ""
    read -rp "Hostnaam (bijv. 'mijnsite' → mijnsite.${BASE_DOMAIN}): " hostname
    [[ -n "$hostname" ]] || die "Hostnaam mag niet leeg zijn."
    # Alleen letters, cijfers en koppeltekens toegestaan
    [[ "$hostname" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
        || die "Ongeldige hostnaam '${hostname}'. Gebruik alleen kleine letters, cijfers en koppeltekens."

    DOMAIN="${hostname}.${BASE_DOMAIN}"
    SITE_SLUG=$(domain_to_slug "$hostname")
    SITE_DIR="${SITES_DIR}/${SITE_SLUG}"

    if [[ -f "${STATE_DIR}/sites/${SITE_SLUG}.conf" ]]; then
        die "Site '${SITE_SLUG}' bestaat al. Verwijder eerst met:\n  sudo $0 remove ${SITE_SLUG}"
    fi

    read -rp "Naam van de site (bijv. Mijn Website) [${DOMAIN}]: " SITE_TITLE
    SITE_TITLE="${SITE_TITLE:-${DOMAIN}}"

    read -rp "PHP versie [${PHP_VERSION}]: " input_php
    PHP_VERSION="${input_php:-${PHP_VERSION}}"
    PHP_VERSION_SHORT=$(php_version_short "$PHP_VERSION")

    echo ""
    read -rsp "Admin wachtwoord (Enter = automatisch genereren): " input_admin_pass
    echo ""
    ADMIN_PASS="${input_admin_pass:-$(generate_password)}"

    # Authentik ForwardAuth (alleen tonen als Authentik geconfigureerd is)
    AUTHENTIK_FORWARDAUTH=false
    if [[ "${AUTHENTIK_ENABLED}" == "true" ]]; then
        read -rp "Authentik ForwardAuth activeren voor deze site? [j/N]: " use_auth
        [[ "${use_auth,,}" == "j" ]] && AUTHENTIK_FORWARDAUTH=true
    fi

    # Bevestiging
    echo ""
    log_info "Overzicht — dit gaat geïnstalleerd worden:"
    echo ""
    printf "  %-18s %s\n" "Domein:"   "$DOMAIN"
    printf "  %-18s %s\n" "Sitenaam:" "$SITE_TITLE"
    printf "  %-18s %s\n" "Slug:"     "$SITE_SLUG"
    printf "  %-18s %s\n" "Map:"      "$SITE_DIR"
    printf "  %-18s %s\n" "Profiel:"  "$PROFILE_NAME"
    printf "  %-18s %s\n" "PHP:"      "$PHP_VERSION"
    printf "  %-18s %s\n" "Auth:"     "$AUTHENTIK_FORWARDAUTH"
    echo ""
    read -rp "Bevestigen met 'ja': " confirm
    [[ "${confirm,,}" == "ja" ]] || { log_info "Geannuleerd."; exit 0; }

    # ── Installatiestappen ────────────────────────────────────────────────────

    LOCAL_PORT=$(next_available_port)
    log_info "Lokale backend poort: ${LOCAL_PORT}"

    # 1. PHP versie beschikbaar maken
    ensure_php_version "$PHP_VERSION"
    PHP_BIN=$(php_bin "$PHP_VERSION")

    # 2. Database aanmaken
    create_database "$SITE_SLUG"
    # DB_NAME, DB_USER, DB_PASS zijn nu gezet door create_database()
    local db_url="mysql://${DB_USER}:${DB_PASS}@${DB_HOST}/${DB_NAME}"

    # 3. Composer create-project
    install_drupal "$SITE_SLUG" "$SITE_DIR" "$DRUPAL_PROJECT" "$DRUPAL_VERSION" "$PHP_VERSION"

    # 4. PHP-FPM pool aanmaken
    PHP_FPM_SOCKET=$(create_php_fpm_pool "$SITE_SLUG" "$PHP_VERSION" "$SITE_DIR")

    # 5. Nginx backend config aanmaken
    create_nginx_config "$SITE_SLUG" "$LOCAL_PORT" "$SITE_DIR" "$PHP_FPM_SOCKET"

    # 6. Drupal installeren via drush
    run_drush_install \
        "$SITE_DIR" "$INSTALL_PROFILE" "$SITE_TITLE" \
        "$db_url" "$ADMIN_USERNAME" "$ADMIN_PASS" "$PHP_BIN"

    # 7. settings.php aanpassen
    configure_settings "$SITE_DIR" "$DOMAIN"

    # 8. Bestandspermissies
    set_file_permissions "$SITE_DIR"

    # 9. Authentik Provider + Application (indien ForwardAuth)
    if [[ "$AUTHENTIK_FORWARDAUTH" == "true" ]]; then
        create_authentik_app "$SITE_SLUG" "$DOMAIN"
    fi

    # 10. Traefik dynamic config aanmaken
    create_traefik_config "$SITE_SLUG" "$DOMAIN" "$LOCAL_PORT" "$AUTHENTIK_FORWARDAUTH"

    # 11. State opslaan
    PROFILE="$CHOSEN_PROFILE"
    save_site_state "$SITE_SLUG"

    # ── Klaar ─────────────────────────────────────────────────────────────────
    echo ""
    log_header "Installatie voltooid!"
    printf "  %-18s %s\n" "URL:"          "https://${DOMAIN}"
    printf "  %-18s %s\n" "Admin user:"   "$ADMIN_USERNAME"
    printf "  %-18s %s\n" "Admin wachtwrd:" "$ADMIN_PASS"
    printf "  %-18s %s\n" "Bestanden:"    "$SITE_DIR"
    printf "  %-18s %s\n" "Database:"     "$DB_NAME"
    echo ""
    log_warning "Sla het admin wachtwoord op — dit wordt niet opnieuw getoond."
}

# ── Instance verwijderen ──────────────────────────────────────────────────────
cmd_remove() {
    log_header "Drupal instance verwijderen"

    local slug="${1:-}"
    if [[ -z "$slug" ]]; then
        list_sites
        echo ""
        read -rp "Slug van te verwijderen site: " slug
    fi
    [[ -n "$slug" ]] || die "Geen slug opgegeven."

    load_site_state "$slug"

    echo ""
    log_warning "Dit verwijdert ALLES: bestanden, database, Nginx/Traefik/PHP-FPM config."
    printf "  Site:   %s\n" "$SITE_SLUG"
    printf "  Domein: %s\n" "$DOMAIN"
    printf "  Map:    %s\n" "$SITE_DIR"
    echo ""
    read -rp "Typ de slug ter bevestiging (${SITE_SLUG}): " confirm
    [[ "$confirm" == "$SITE_SLUG" ]] || { log_info "Geannuleerd."; exit 0; }

    remove_traefik_config "$SITE_SLUG"
    if [[ "${AUTHENTIK_FORWARDAUTH:-false}" == "true" ]]; then
        remove_authentik_app "$SITE_SLUG"
    fi
    remove_nginx_config "$SITE_SLUG"
    remove_php_fpm_pool "$SITE_SLUG" "$PHP_VERSION"
    remove_database "$DB_NAME" "$DB_USER"

    if [[ -d "$SITE_DIR" ]]; then
        rm -rf "$SITE_DIR"
        log_success "Bestanden verwijderd: ${SITE_DIR}"
    fi

    rm -f "${STATE_DIR}/sites/${SITE_SLUG}.conf"
    log_success "State verwijderd."
    log_success "Site '${SITE_SLUG}' volledig verwijderd."
}

# ── Overzicht ─────────────────────────────────────────────────────────────────
cmd_list() {
    log_header "Actieve Drupal instances"
    list_sites
    echo ""
}

# ── Help ──────────────────────────────────────────────────────────────────────
cmd_help() {
    cat << EOF
Gebruik: $(basename "$0") [commando] [opties]

Commando's:
  new              Nieuwe Drupal instance aanmaken (interactief)
  remove [slug]    Instance verwijderen
  list             Overzicht van alle instances
  help             Deze helptekst

Zonder commando wordt het interactieve menu getoond.

Voorbeelden:
  sudo $(basename "$0") new
  sudo $(basename "$0") remove mijnsite-example-com
  sudo $(basename "$0") list
EOF
}

# ── Interactief hoofdmenu ─────────────────────────────────────────────────────
main_menu() {
    while true; do
        log_header "Drupal Manager"
        list_sites
        echo ""
        echo "  1) Nieuwe instance aanmaken"
        echo "  2) Instance verwijderen"
        echo "  3) Overzicht vernieuwen"
        echo "  4) Afsluiten"
        echo ""
        read -rp "Keuze: " choice

        case "$choice" in
            1) cmd_new ;;
            2) cmd_remove ;;
            3) continue ;;
            4) exit 0 ;;
            *) log_error "Ongeldige keuze: ${choice}" ;;
        esac
    done
}

# ── Router ────────────────────────────────────────────────────────────────────
case "${1:-menu}" in
    new)         cmd_new ;;
    remove)      cmd_remove "${2:-}" ;;
    list)        cmd_list ;;
    help|-h|--help) cmd_help ;;
    menu)        main_menu ;;
    *)           log_error "Onbekend commando: $1"; cmd_help; exit 1 ;;
esac
