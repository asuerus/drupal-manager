#!/usr/bin/env bash
# Traefik dynamic config beheer
# Voegt router+service toe aan / verwijdert ze uit het enkelvoudige traefik-dynamic.yaml

_traefik_yaml_check() {
    [[ -f "$TRAEFIK_DYNAMIC_FILE" ]] \
        || die "Traefik dynamic config niet gevonden: ${TRAEFIK_DYNAMIC_FILE}\nControleer TRAEFIK_DYNAMIC_FILE in global.conf."
    command -v python3 &>/dev/null \
        || die "python3 niet gevonden — installeer het met: dnf install -y python3"
    python3 -c "import yaml" 2>/dev/null \
        || die "Python yaml module niet beschikbaar — installeer met: dnf install -y python3-pyyaml"
}

create_traefik_config() {
    local slug="$1"
    local domain="$2"
    local port="$3"
    local use_auth="${4:-false}"

    log_step "Traefik router toevoegen voor ${domain}..."
    _traefik_yaml_check

    SITE_SLUG="$slug" \
    DOMAIN="$domain" \
    LOCAL_PORT="$port" \
    USE_AUTH="$use_auth" \
    TRAEFIK_BACKEND_HOST="$TRAEFIK_BACKEND_HOST" \
    CERT_RESOLVER="$CERT_RESOLVER" \
    TRAEFIK_ENTRYPOINT_HTTPS="$TRAEFIK_ENTRYPOINT_HTTPS" \
    AUTHENTIK_MIDDLEWARE_NAME="$AUTHENTIK_MIDDLEWARE_NAME" \
    TRAEFIK_DYNAMIC_FILE="$TRAEFIK_DYNAMIC_FILE" \
    python3 - << 'PYEOF'
import yaml, os

f    = os.environ['TRAEFIK_DYNAMIC_FILE']
slug = os.environ['SITE_SLUG']
dom  = os.environ['DOMAIN']
port = os.environ['LOCAL_PORT']
host = os.environ['TRAEFIK_BACKEND_HOST']
cert = os.environ['CERT_RESOLVER']
ep   = os.environ['TRAEFIK_ENTRYPOINT_HTTPS']
auth = os.environ['USE_AUTH'] == 'true'
amw  = os.environ['AUTHENTIK_MIDDLEWARE_NAME']

with open(f) as fh:
    cfg = yaml.safe_load(fh) or {}

http = cfg.setdefault('http', {})

middlewares = ['drupal-headers']
if auth:
    middlewares.append(amw)

http.setdefault('routers', {})[slug] = {
    'rule':        f'Host(`{dom}`)',
    'entryPoints': [ep],
    'service':     slug,
    'tls':         {'certResolver': cert},
    'middlewares': middlewares,
}
http.setdefault('services', {})[slug] = {
    'loadBalancer': {'servers': [{'url': f'http://{host}:{port}'}]}
}

with open(f, 'w') as fh:
    yaml.dump(cfg, fh, default_flow_style=False, allow_unicode=True, sort_keys=False)
PYEOF

    log_success "Traefik router toegevoegd voor ${domain}."
    log_info  "Traefik herlaadt de config automatisch (file watch)."
}

remove_traefik_config() {
    local slug="$1"

    log_step "Traefik router verwijderen voor '${slug}'..."
    _traefik_yaml_check

    SITE_SLUG="$slug" \
    TRAEFIK_DYNAMIC_FILE="$TRAEFIK_DYNAMIC_FILE" \
    python3 - << 'PYEOF'
import yaml, os

f    = os.environ['TRAEFIK_DYNAMIC_FILE']
slug = os.environ['SITE_SLUG']

with open(f) as fh:
    cfg = yaml.safe_load(fh) or {}

http = cfg.get('http', {})
http.get('routers',  {}).pop(slug, None)
http.get('services', {}).pop(slug, None)

with open(f, 'w') as fh:
    yaml.dump(cfg, fh, default_flow_style=False, allow_unicode=True, sort_keys=False)
PYEOF

    log_success "Traefik router verwijderd voor '${slug}'."
}
