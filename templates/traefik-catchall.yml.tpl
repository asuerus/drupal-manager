http:
  routers:
    drupal-catchall:
      # Vangt alle *.{{BASE_DOMAIN}} op die geen eigen router hebben (prioriteit 1 = laagste)
      rule: "HostRegexp(`^[a-z0-9-]+\\.{{BASE_DOMAIN_ESCAPED}}$`)"
      priority: 1
      entryPoints:
        - {{TRAEFIK_ENTRYPOINT_HTTPS}}
      service: drupal-catchall
      tls:
        certResolver: {{CERT_RESOLVER}}

  services:
    drupal-catchall:
      loadBalancer:
        servers:
          - url: "http://{{TRAEFIK_BACKEND_HOST}}:{{CATCHALL_PORT}}"
