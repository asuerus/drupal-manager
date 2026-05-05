#!/usr/bin/env bash
# Authentik Provider + Application beheer via REST API

_authentik_check() {
    [[ "${AUTHENTIK_ENABLED}" == "true" ]] \
        || die "AUTHENTIK_ENABLED is niet 'true' in global.conf."
    [[ -n "${AUTHENTIK_TOKEN:-}" ]] \
        || die "AUTHENTIK_TOKEN is niet ingesteld in global.conf.\nAanmaken via Authentik → Admin → Directory → Tokens (intent: API)."
}

create_authentik_app() {
    local slug="$1"
    local domain="$2"

    if [[ "${AUTHENTIK_ENABLED}" != "true" ]] || [[ -z "${AUTHENTIK_TOKEN:-}" ]]; then
        log_warning "Authentik overgeslagen (AUTHENTIK_ENABLED of AUTHENTIK_TOKEN niet ingesteld)."
        return 0
    fi

    log_step "Authentik Provider + Application aanmaken voor ${domain}..."

    AUTHENTIK_URL="$AUTHENTIK_URL" \
    AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN" \
    SITE_SLUG="$slug" \
    SITE_DOMAIN="$domain" \
    BASE_DOMAIN="$BASE_DOMAIN" \
    python3 - << 'PYEOF' \
        || die "Authentik configuratie mislukt voor ${domain}."
import sys, os, json
from urllib.request import Request, urlopen
from urllib.error import HTTPError

base   = os.environ['AUTHENTIK_URL'].rstrip('/')
token  = os.environ['AUTHENTIK_TOKEN']
slug   = os.environ['SITE_SLUG']
domain = os.environ['SITE_DOMAIN']
base_domain = os.environ['BASE_DOMAIN']

def api(method, endpoint, data=None):
    req = Request(
        f"{base}/api/v3/{endpoint}",
        data=json.dumps(data).encode() if data is not None else None,
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'},
        method=method,
    )
    try:
        with urlopen(req) as r:
            body = r.read()
            return json.loads(body) if body else {}
    except HTTPError as e:
        print(f"Authentik API {method} {endpoint} → {e.code}: {e.read().decode()}", file=sys.stderr)
        sys.exit(1)

# Default authorization flow
flows = api('GET', 'flows/instances/?designation=authorization&ordering=slug')
if not flows.get('results'):
    print("Geen authorization flow gevonden in Authentik.", file=sys.stderr)
    sys.exit(1)
auth_flow = flows['results'][0]['pk']

# Default invalidation flow (required in newer Authentik versions)
inv_flows = api('GET', 'flows/instances/?designation=invalidation&ordering=slug')
if not inv_flows.get('results'):
    print("Geen invalidation flow gevonden in Authentik.", file=sys.stderr)
    sys.exit(1)
inv_flow = inv_flows['results'][0]['pk']

# Proxy Provider (forward_auth_single = hele site achter Authentik)
provider = api('POST', 'providers/proxy/', {
    'name':               f'Drupal - {slug}',
    'authorization_flow': auth_flow,
    'invalidation_flow':  inv_flow,
    'external_host':      f'https://{domain}',
    'mode':               'forward_single',
    'cookie_domain':      base_domain,
})
provider_pk = provider['pk']

# Application
api('POST', 'core/applications/', {
    'name':     domain,
    'slug':     f'drupal-{slug}',
    'provider': provider_pk,
})

# Voeg provider toe aan bestaande proxy outpost
outposts = api('GET', 'outposts/instances/?type=proxy')
proxy_outpost = next((o for o in outposts.get('results', []) if o['type'] == 'proxy'), None)
if not proxy_outpost:
    print("Geen proxy outpost gevonden in Authentik.", file=sys.stderr)
    sys.exit(1)

providers = proxy_outpost['providers']
if provider_pk not in providers:
    providers.append(provider_pk)
    api('PATCH', f"outposts/instances/{proxy_outpost['pk']}/", {'providers': providers})

print(f"OK provider_pk={provider_pk}")
PYEOF

    log_success "Authentik geconfigureerd voor ${domain}."
}

remove_authentik_app() {
    local slug="$1"

    if [[ "${AUTHENTIK_ENABLED}" != "true" ]] || [[ -z "${AUTHENTIK_TOKEN:-}" ]]; then
        return 0
    fi

    log_step "Authentik Provider + Application verwijderen voor '${slug}'..."

    AUTHENTIK_URL="$AUTHENTIK_URL" \
    AUTHENTIK_TOKEN="$AUTHENTIK_TOKEN" \
    SITE_SLUG="$slug" \
    python3 - << 'PYEOF' \
        || die "Authentik verwijderen mislukt voor '${slug}'."
import sys, os, json
from urllib.request import Request, urlopen
from urllib.error import HTTPError

base  = os.environ['AUTHENTIK_URL'].rstrip('/')
token = os.environ['AUTHENTIK_TOKEN']
slug  = os.environ['SITE_SLUG']
app_slug = f'drupal-{slug}'

def api(method, endpoint, data=None):
    req = Request(
        f"{base}/api/v3/{endpoint}",
        data=json.dumps(data).encode() if data is not None else None,
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'},
        method=method,
    )
    try:
        with urlopen(req) as r:
            body = r.read()
            return json.loads(body) if body else {}
    except HTTPError as e:
        if e.code == 404:
            return None
        print(f"Authentik API {method} {endpoint} → {e.code}: {e.read().decode()}", file=sys.stderr)
        sys.exit(1)

# Zoek application op slug
apps = api('GET', f'core/applications/?slug={app_slug}')
app = next((a for a in apps.get('results', []) if a['slug'] == app_slug), None)
if not app:
    print(f"Authentik application '{app_slug}' niet gevonden, overgeslagen.")
    sys.exit(0)

provider_pk = app.get('provider')

# Verwijder provider uit outpost
outposts = api('GET', 'outposts/instances/?type=proxy')
proxy_outpost = next((o for o in outposts.get('results', []) if o['type'] == 'proxy'), None)
if proxy_outpost and provider_pk in proxy_outpost['providers']:
    providers = [p for p in proxy_outpost['providers'] if p != provider_pk]
    api('PATCH', f"outposts/instances/{proxy_outpost['pk']}/", {'providers': providers})

# Verwijder application
api('DELETE', f"core/applications/{app['slug']}/")

# Verwijder provider
if provider_pk:
    api('DELETE', f"providers/proxy/{provider_pk}/")

print(f"OK verwijderd: {app_slug}")
PYEOF

    log_success "Authentik verwijderd voor '${slug}'."
}
