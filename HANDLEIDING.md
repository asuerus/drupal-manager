# Drupal Manager — Handleiding

Drupal Manager is een Bash-script dat het installeren, configureren en verwijderen van meerdere Drupal-instanties op één server automatiseert. Elke instantie krijgt een eigen database, PHP-FPM pool, Nginx backend en Traefik router. Optioneel wordt Authentik ForwardAuth per site ingeschakeld.

---

## Inhoudsopgave

1. [Architectuuroverzicht](#1-architectuuroverzicht)
2. [Componentenkaart — bestanden en mappen](#2-componentenkaart)
3. [Configuratie](#3-configuratie)
4. [Profielen](#4-profielen)
5. [Commando's en gebruik](#5-commandos-en-gebruik)
6. [Installatiestappen (wat doet `new`?)](#6-installatiestappen)
7. [State-beheer](#7-state-beheer)
8. [Infrastructuur eenmalig opzetten](#8-infrastructuur-eenmalig-opzetten)
9. [Git-workflow (Mac → GitHub → VPS)](#9-git-workflow)
10. [Authentik API-token aanmaken](#10-authentik-api-token-aanmaken)
11. [Veelgestelde vragen en bekende aandachtspunten](#11-veelgestelde-vragen)

---

## 1. Architectuuroverzicht

```
Internet
    │  HTTPS (443)
    ▼
┌─────────────────────────────────┐
│  Traefik  (Docker)              │  reverse proxy + TLS (Let's Encrypt)
│  traefik-dynamic.yaml           │  één YAML-bestand, per site een router + service
└────────────┬────────────────────┘
             │  HTTP → 172.31.0.1:<poort>
             ▼
┌─────────────────────────────────┐
│  Nginx  (native, Rocky Linux)   │  één vhost-config per site
│  /etc/nginx/conf.d/             │  luistert op 127.0.0.1 én 172.31.0.1
└────────────┬────────────────────┘
             │  FastCGI → Unix socket
             ▼
┌─────────────────────────────────┐
│  PHP-FPM  (REMI, per versie)    │  één pool per site
│  /etc/opt/remi/php83/php-fpm.d/ │
└────────────┬────────────────────┘
             │
             ▼
┌─────────────────────────────────┐
│  Drupal  (Composer)             │  bestanden in /var/www/drupal/<slug>/
│  MariaDB                        │  database drupal_<slug>
└─────────────────────────────────┘

Optioneel:
┌─────────────────────────────────┐
│  Authentik  (Docker)            │  ForwardAuth per site
│  proxy outpost                  │  Traefik middleware
└─────────────────────────────────┘
```

**Traefik draait in Docker** en bereikt de native Nginx-backends via het gateway-IP van het `traefik-net` netwerk (standaard `172.31.0.1`). Nginx luistert daarom op zowel `127.0.0.1` als dat gateway-IP.

---

## 2. Componentenkaart

### Op de Mac (ontwikkeling)

| Pad | Beschrijving |
|-----|-------------|
| `~/drupal-manager/` | Lokale git-werkkopie |
| `~/drupal-manager/drupal-manager.sh` | Hoofdscript |
| `~/drupal-manager/setup-infra.sh` | Eenmalige infrastructuur-setup |
| `~/drupal-manager/config/global.conf` | Actieve configuratie (gitignored) |
| `~/drupal-manager/config/global.conf.example` | Sjabloon (in git) |
| `~/drupal-manager/lib/*.sh` | Functie-bibliotheken |
| `~/drupal-manager/profiles/*.conf` | Installatieprofielen |
| `~/drupal-manager/templates/*.tpl` | Configuratiesjablonen |

### Op de VPS (Rocky Linux 10)

| Pad | Beschrijving |
|-----|-------------|
| `/opt/drupal-manager/` | Script-installatie (git clone) |
| `/usr/local/bin/drupal-manager` | Symlink naar het script (werkt overal) |
| `/var/www/drupal/<slug>/` | Bestanden per Drupal-site |
| `/var/lib/drupal-manager/sites/<slug>.conf` | State per site |
| `/etc/nginx/conf.d/drupal-<slug>.conf` | Nginx vhost per site |
| `/etc/opt/remi/php83/php-fpm.d/<slug>.conf` | PHP-FPM pool per site |
| `/var/opt/remi/php83/run/php-fpm/<slug>.sock` | PHP-FPM Unix socket per site |
| `/var/log/nginx/drupal-<slug>-*.log` | Nginx logs per site |
| `/var/log/php-fpm/drupal-<slug>-error.log` | PHP-FPM logs per site |
| `/root/.drupal-manager-dbroot` | MariaDB root-wachtwoord (600) |
| `/home/asuerus/docker/traefik/traefik-dynamic.yaml` | Traefik dynamic config (gedeeld) |

---

## 3. Configuratie

### `config/global.conf`

Het hoofdconfiguratiebestand. Dit bestand staat **niet in git** (gitignored) omdat het productiewaarden bevat. Gebruik `global.conf.example` als sjabloon.

| Variabele | Standaard | Beschrijving |
|-----------|-----------|-------------|
| `SITES_DIR` | `/var/www/drupal` | Basismap voor alle Drupal-installaties |
| `NGINX_CONF_DIR` | `/etc/nginx/conf.d` | Map voor Nginx vhost-configs |
| `STATE_DIR` | `/var/lib/drupal-manager` | State-bestanden per site |
| `TRAEFIK_DYNAMIC_DIR` | `/etc/traefik/dynamic` | (Ongebruikt — zie `TRAEFIK_DYNAMIC_FILE`) |
| `PORT_START` | `8100` | Begin van poortbereik voor Nginx backends |
| `PORT_END` | `8999` | Einde van poortbereik |
| `BASE_DOMAIN` | `v-tuijl.nl` | Basisdomein — sites worden `<naam>.v-tuijl.nl` |
| `CERT_RESOLVER` | `letsencrypt` | Traefik TLS-certificaat resolver |
| `TRAEFIK_ENTRYPOINT_HTTP` | `web` | Traefik HTTP entrypoint naam |
| `TRAEFIK_ENTRYPOINT_HTTPS` | `websecure` | Traefik HTTPS entrypoint naam |
| `CATCHALL_PORT` | `8099` | Nginx poort voor "site niet gevonden" pagina |
| `TRAEFIK_DYNAMIC_FILE` | `/home/asuerus/docker/traefik/traefik-dynamic.yaml` | Volledig pad naar Traefik YAML |
| `TRAEFIK_BACKEND_HOST` | `172.31.0.1` | Gateway-IP van het traefik-net Docker-netwerk |
| `DB_HOST` | `localhost` | MariaDB host |
| `DB_ROOT_PASSWORD_FILE` | `/root/.drupal-manager-dbroot` | Bestand met MariaDB root-wachtwoord |
| `COMPOSER_BIN` | `/usr/local/bin/composer` | Pad naar Composer executable |
| `AUTHENTIK_ENABLED` | `true` / `false` | Authentik ForwardAuth beschikbaar stellen als optie |
| `AUTHENTIK_URL` | `https://authentik.v-tuijl.nl` | Publieke URL van Authentik |
| `AUTHENTIK_OUTPOST_URL` | `http://authentik-proxy:9000` | Interne URL van de proxy outpost |
| `AUTHENTIK_MIDDLEWARE_NAME` | `authentik` | Naam van de Traefik middleware voor Authentik |
| `AUTHENTIK_TOKEN` | *(leeg)* | API-token voor de Authentik REST API |

> **Tip:** Haal `TRAEFIK_BACKEND_HOST` op met:
> ```bash
> docker network inspect traefik-net --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'
> ```

### Templates

Templates gebruiken `{{UPPERCASE_VAR}}` als plaatshouders. Ze worden ingevuld via `render_template()` in `lib/utils.sh` (gebruikt Perl zodat Nginx-variabelen zoals `$uri` onaangeroerd blijven).

| Template | Waarvoor |
|----------|----------|
| `templates/nginx-backend.conf.tpl` | Nginx vhost per site |
| `templates/php-fpm-pool.conf.tpl` | PHP-FPM pool per site |
| `templates/traefik-site.yml.tpl` | *(aanwezig, niet actief gebruikt — logica zit in lib/traefik.sh)* |
| `templates/traefik-site-auth.yml.tpl` | *(idem)* |
| `templates/traefik-catchall.yml.tpl` | *(idem)* |

---

## 4. Profielen

Profielen staan in `profiles/*.conf` en bepalen welke Drupal-versie en welk installatieprofiel wordt gebruikt. Elk profiel definieert:

| Variabele | Beschrijving |
|-----------|-------------|
| `PROFILE_NAME` | Weergavenaam in het menu |
| `DRUPAL_PROJECT` | Composer package-naam |
| `DRUPAL_VERSION` | Versie-constraint (bijv. `^11`) |
| `INSTALL_PROFILE` | Drush installatieprofiel |
| `PHP_VERSION` | Standaard PHP-versie voor dit profiel |
| `ADMIN_USERNAME` | Gebruikersnaam van de Drupal-beheerder |

### Beschikbare profielen

| Bestand | Naam | Project | Versie |
|---------|------|---------|--------|
| `drupal-cms.conf` | Drupal CMS (nieuwste) | `drupal/cms` | `^1` |
| `drupal-standard.conf` | Drupal 11 (standaard) | `drupal/recommended-project` | `^11` |

**Nieuw profiel toevoegen:** maak een `.conf`-bestand aan in `profiles/` met bovenstaande variabelen. Het script toont het automatisch in het keuzelijstje.

---

## 5. Commando's en gebruik

Het script vereist `sudo` (root-rechten). Gebruiker `asuerus` heeft NOPASSWD-toegang via sudoers.

```bash
# Interactief menu (standaard)
sudo drupal-manager

# Nieuwe Drupal-instantie aanmaken
sudo drupal-manager new

# Overzicht van alle instanties
sudo drupal-manager list

# Instantie verwijderen (vraagt om bevestiging)
sudo drupal-manager remove
sudo drupal-manager remove <slug>   # direct met slug

# Help
sudo drupal-manager help
```

### Uitvoer van `list`

```
SLUG                      DOMEIN                                 POORT  PHP
-------------------------  --------------------------------------  -----  ---
test                      test.v-tuijl.nl                        8100   8.3
test2                     test2.v-tuijl.nl                       8101   8.3
```

### Interactieve vragen bij `new`

1. **Profiel kiezen** — welke Drupal-versie
2. **Hostnaam** — bijv. `mijnsite` → wordt `mijnsite.v-tuijl.nl`
3. **Sitenaam** — weergavenaam in Drupal (standaard: het domein)
4. **PHP-versie** — standaard uit het profiel, aanpasbaar
5. **Admin-wachtwoord** — leeg laten = automatisch gegenereerd (24 tekens, alfanumeriek)
6. **Authentik ForwardAuth** — alleen zichtbaar als `AUTHENTIK_ENABLED=true`
7. **Bevestiging** — typ `ja` om te starten

---

## 6. Installatiestappen

Bij `sudo drupal-manager new` worden de volgende stappen uitgevoerd:

| Stap | Wat gebeurt er |
|------|---------------|
| 1 | PHP-versie beschikbaar maken via REMI (installeren als nodig) |
| 2 | MariaDB database + gebruiker aanmaken (`drupal_<slug>`) |
| 3 | `composer create-project` — Drupal downloaden naar `/var/www/drupal/<slug>/` |
| 4 | PHP-FPM pool aanmaken in `/etc/opt/remi/php<ver>/php-fpm.d/<slug>.conf` |
| 5 | Nginx vhost aanmaken in `/etc/nginx/conf.d/drupal-<slug>.conf` |
| 6 | `drush site:install` — Drupal installeren en database inrichten |
| 7 | `settings.php` aanpassen (trusted_host_patterns, reverse proxy headers) |
| 8 | Bestandspermissies instellen (eigenaar: nginx) |
| 9 | *(optioneel)* Authentik Provider + Application aanmaken via REST API |
| 10 | Traefik router + service toevoegen aan `traefik-dynamic.yaml` |
| 11 | State opslaan in `/var/lib/drupal-manager/sites/<slug>.conf` |

Bij `remove` worden alle stappen in omgekeerde volgorde ongedaan gemaakt: Traefik-router weg, Authentik-app weg, Nginx-config weg, PHP-FPM pool weg, database weg, bestanden weg, state weg.

---

## 7. State-beheer

Per site wordt een state-bestand opgeslagen in `/var/lib/drupal-manager/sites/<slug>.conf`. Dit bevat alle gegevens die nodig zijn om de site te beheren en te verwijderen:

```bash
SITE_SLUG="test2"
DOMAIN="test2.v-tuijl.nl"
SITE_DIR="/var/www/drupal/test2"
LOCAL_PORT="8101"
PHP_VERSION="8.3"
PHP_VERSION_SHORT="83"
PHP_FPM_SOCKET="/var/opt/remi/php83/run/php-fpm/test2.sock"
DB_NAME="drupal_test2"
DB_USER="drupal_test2"
PROFILE="/opt/drupal-manager/profiles/drupal-cms.conf"
AUTHENTIK_FORWARDAUTH="true"
CREATED_AT="2026-05-05T18:00:00+02:00"
```

> **Let op:** het database-wachtwoord staat **niet** in de state — dat staat uitsluitend in de `settings.php` van Drupal zelf.

---

## 8. Infrastructuur eenmalig opzetten

Vóór het eerste gebruik moet `setup-infra.sh` eenmalig worden gedraaid. Dit installeert en configureert:

- EPEL + REMI repositories
- Nginx (met wildcard include en uitgeschakelde default-vhost)
- MariaDB (beveiligd, root-wachtwoord opgeslagen in `/root/.drupal-manager-dbroot`)
- PHP 8.3 via REMI + PHP-FPM
- Composer (`/usr/local/bin/composer`)
- Python3 + PyYAML (voor Traefik YAML-beheer)
- Catch-all Nginx-pagina op poort 8099 ("site niet gevonden")
- Catch-all Traefik-router voor `*.v-tuijl.nl` (laagste prioriteit)

```bash
cd /opt/drupal-manager
sudo ./setup-infra.sh
```

**Eenmalige DNS-instelling** (buiten het script):

| Type | Naam | Waarde |
|------|------|--------|
| A | `*.v-tuijl.nl` | VPS IP-adres |

Met een wildcard DNS-record zijn geen DNS-wijzigingen nodig voor nieuwe sites.

---

## 9. Git-workflow

Het script wordt beheerd via GitHub. Aanpassingen op de Mac worden gepusht naar GitHub en op de VPS gepulld.

```
Mac                    GitHub                    VPS
 │                       │                        │
 │  git add / commit      │                        │
 │  git push             ──▶  github.com/asuerus   │
 │                             /drupal-manager     │
 │                                                 │
 │                       │   sudo git pull        ◀──
```

### Workflow

**Mac:**
```bash
cd ~/drupal-manager
git add -p                        # selectief bestanden stagen
git commit -m "omschrijving"
git push
```

**VPS:**
```bash
cd /opt/drupal-manager
sudo git pull
```

### Wat staat wél/niet in git?

| In git ✅ | Niet in git ❌ |
|-----------|--------------|
| `drupal-manager.sh` | `config/global.conf` (productiewaarden) |
| `setup-infra.sh` | |
| `lib/*.sh` | |
| `profiles/*.conf` | |
| `templates/*.tpl` | |
| `config/global.conf.example` | |

---

## 10. Authentik API-token aanmaken

De Authentik-integratie vereist een permanent API-token. Tokens aangemaakt via de Authentik UI hebben in versie 2026.2.x een bug waarbij `expiring=False` genegeerd wordt. Gebruik de Django-shell:

```bash
docker exec -it authentik-server ak shell -c "
from authentik.core.models import Token, TokenIntents, User
user = User.objects.get(username='akadmin')
t = Token.objects.create(
    identifier='drupal-manager-permanent',
    user=user,
    intent=TokenIntents.INTENT_API,
    expiring=False,
)
print('Token key:', t.key)
"
```

Sla de sleutel op in de VPS-configuratie:

```bash
sudo nano /opt/drupal-manager/config/global.conf
# Zet: AUTHENTIK_TOKEN="<token key>"
```

> Dit bestand staat niet in git — de token blijft veilig op de server.

---

## 11. Veelgestelde vragen

**Kan ik een andere PHP-versie gebruiken per site?**
Ja. Tijdens `new` vraagt het script om de PHP-versie. Als die versie nog niet aanwezig is, installeert het script hem automatisch via REMI.

**Hoe voeg ik een nieuw installatieprofiel toe?**
Maak een `.conf`-bestand aan in `profiles/` met de vereiste variabelen (zie §4). Het verschijnt automatisch in het keuzelijstje.

**Hoe verwijder ik een site volledig?**
```bash
sudo drupal-manager remove <slug>
```
Dit verwijdert: Traefik-router, Authentik-app (indien actief), Nginx-config, PHP-FPM pool, database, bestanden en state.

**Hoe controleer ik welke sites er zijn?**
```bash
sudo drupal-manager list
```

**Waar vind ik de logs?**
```
Nginx access log:   /var/log/nginx/drupal-<slug>-access.log
Nginx error log:    /var/log/nginx/drupal-<slug>-error.log
PHP-FPM error log:  /var/log/php-fpm/drupal-<slug>-error.log
```

**Het script geeft een fout over een ontbrekende PHP binary.**
Controleer of de gevraagde PHP-versie beschikbaar is via REMI:
```bash
rpm -q php83-php-fpm
```
Bij een andere versie dan 8.3: vervang `83` door de gewenste versie (bijv. `82` voor 8.2).

**Traefik laadt de nieuwe site niet.**
Traefik herlaadt `traefik-dynamic.yaml` automatisch via file-watching. Wacht ~5 seconden. Controleer anders:
```bash
docker logs traefik --tail 20
```

**Hoe update ik het script zelf?**
```bash
cd /opt/drupal-manager
sudo git pull
```

**Wat is de slug?**
De slug is de machine-leesbare naam van een site: punten worden koppeltekens, alles kleine letters. `mijnsite.v-tuijl.nl` → slug `mijnsite`. De slug wordt gebruikt voor bestandsnamen, databasenamen en state.
