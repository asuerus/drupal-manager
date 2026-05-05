#!/usr/bin/env bash
# Utility functies voor Drupal Manager

# ── Kleuren & output ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
log_warning() { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}▶ $*${NC}" >&2; }
log_header()  { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════${NC}" >&2; \
                echo -e "${BOLD}${BLUE}  $*${NC}" >&2; \
                echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}\n" >&2; }

die() {
    log_error "$*"
    exit 1
}

check_root() {
    [[ $EUID -eq 0 ]] || die "Dit script moet als root worden uitgevoerd (gebruik sudo)."
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# "mijn.site.nl" → "mijn-site-nl"
domain_to_slug() {
    echo "$1" | tr '.' '-' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g'
}

generate_password() {
    # Alphanumeric only: safe in MySQL URLs, PHP strings, and shell without quoting.
    # The range +-= in tr covers ASCII 43-61 (includes /  :  ;  <  etc.) — avoid ranges.
    # || true prevents SIGPIPE (exit 141) from aborting under set -o pipefail.
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true
}

# Escape een domeinnaam voor gebruik in PHP regex (trusted_host_patterns)
escape_domain_for_php() {
    echo "$1" | sed 's/\./\\./g'
}

# ── Template rendering ────────────────────────────────────────────────────────
# Vervangt {{UPPERCASE_VAR}} door de waarde van de gelijknamige variabele.
# Gebruikt perl zodat Nginx-variabelen zoals $uri onaangeroerd blijven.
render_template() {
    local template="$1"
    local output="$2"
    [[ -f "$template" ]] || die "Template niet gevonden: ${template}"
    perl -pe 's/\{\{([A-Z_]+)\}\}/$ENV{$1} \/\/ ""/ge' "$template" > "$output"
}

# ── Poortbeheer ───────────────────────────────────────────────────────────────
next_available_port() {
    local port=$PORT_START
    while [[ $port -le $PORT_END ]]; do
        # Niet in gebruik door bestaande Nginx config?
        if ! grep -qr "127.0.0.1:${port}" "${NGINX_CONF_DIR}/" 2>/dev/null; then
            # Niet actief bezet door een proces?
            if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
                echo "$port"
                return
            fi
        fi
        ((port++))
    done
    die "Geen beschikbare poort gevonden in range ${PORT_START}-${PORT_END}."
}

# ── State management ──────────────────────────────────────────────────────────
save_site_state() {
    mkdir -p "${STATE_DIR}/sites"
    cat > "${STATE_DIR}/sites/${SITE_SLUG}.conf" << EOF
# Drupal Manager state — gegenereerd op $(date)
SITE_SLUG="${SITE_SLUG}"
DOMAIN="${DOMAIN}"
SITE_DIR="${SITE_DIR}"
LOCAL_PORT="${LOCAL_PORT}"
PHP_VERSION="${PHP_VERSION}"
PHP_VERSION_SHORT="${PHP_VERSION_SHORT}"
PHP_FPM_SOCKET="${PHP_FPM_SOCKET}"
DB_NAME="${DB_NAME}"
DB_USER="${DB_USER}"
PROFILE="${PROFILE}"
AUTHENTIK_FORWARDAUTH="${AUTHENTIK_FORWARDAUTH}"
CREATED_AT="$(date -Iseconds)"
EOF
    log_success "State opgeslagen: ${STATE_DIR}/sites/${SITE_SLUG}.conf"
}

load_site_state() {
    local slug="$1"
    local state_file="${STATE_DIR}/sites/${slug}.conf"
    [[ -f "$state_file" ]] || die "Geen state gevonden voor site: ${slug}"
    # shellcheck source=/dev/null
    source "$state_file"
}

list_sites() {
    local state_dir="${STATE_DIR}/sites"
    if [[ ! -d "$state_dir" ]] || [[ -z "$(ls -A "$state_dir" 2>/dev/null)" ]]; then
        echo "  (geen sites aanwezig)"
        return
    fi
    printf "  %-25s %-38s %-6s %s\n" "SLUG" "DOMEIN" "POORT" "PHP"
    printf "  %-25s %-38s %-6s %s\n" "-------------------------" "--------------------------------------" "-----" "---"
    for f in "${state_dir}"/*.conf; do
        (
            # shellcheck source=/dev/null
            source "$f"
            printf "  %-25s %-38s %-6s %s\n" "$SITE_SLUG" "$DOMAIN" "$LOCAL_PORT" "$PHP_VERSION"
        )
    done
}
