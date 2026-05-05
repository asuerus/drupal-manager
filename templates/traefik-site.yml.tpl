http:
  routers:
    {{SITE_SLUG}}:
      rule: "Host(`{{DOMAIN}}`)"
      entryPoints:
        - {{TRAEFIK_ENTRYPOINT_HTTPS}}
      service: {{SITE_SLUG}}
      tls:
        certResolver: {{CERT_RESOLVER}}

  services:
    {{SITE_SLUG}}:
      loadBalancer:
        servers:
          - url: "http://{{TRAEFIK_BACKEND_HOST}}:{{LOCAL_PORT}}"
