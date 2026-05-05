#!/usr/bin/env bash
# MariaDB database beheer

_get_db_root_password() {
    [[ -f "$DB_ROOT_PASSWORD_FILE" ]] \
        || die "DB root wachtwoord bestand niet gevonden: ${DB_ROOT_PASSWORD_FILE}\nDraai eerst setup-infra.sh."
    cat "$DB_ROOT_PASSWORD_FILE"
}

_mysql() {
    # MYSQL_PWD voorkomt bash-interpolatie van speciale tekens in het wachtwoord
    MYSQL_PWD="$(_get_db_root_password)" mysql -uroot "$@"
}

create_database() {
    local slug="$1"

    # Vervang koppeltekens door underscores (MySQL staat geen - toe in namen)
    local safe_slug="${slug//-/_}"
    DB_NAME="drupal_${safe_slug}"
    DB_USER="drupal_${safe_slug}"

    # MySQL max 32 tekens voor gebruikersnaam
    DB_USER="${DB_USER:0:32}"

    DB_PASS=$(generate_password)

    log_step "Database aanmaken: ${DB_NAME} (user: ${DB_USER})..."

    _mysql <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

    log_success "Database aangemaakt: ${DB_NAME}."
}

remove_database() {
    local db_name="$1"
    local db_user="$2"

    log_step "Database verwijderen: ${db_name}..."

    _mysql <<EOF
DROP DATABASE IF EXISTS \`${db_name}\`;
DROP USER IF EXISTS '${db_user}'@'localhost';
FLUSH PRIVILEGES;
EOF

    log_success "Database verwijderd: ${db_name}."
}
