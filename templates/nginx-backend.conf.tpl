server {
    # Localhost for direct testing; Traefik (Docker) reaches the host via TRAEFIK_BACKEND_HOST
    listen 127.0.0.1:{{LOCAL_PORT}};
    listen {{TRAEFIK_BACKEND_HOST}}:{{LOCAL_PORT}};
    server_name _;

    root {{SITE_DIR}}/web;
    index index.php;

    access_log /var/log/nginx/drupal-{{SITE_SLUG}}-access.log;
    error_log  /var/log/nginx/drupal-{{SITE_SLUG}}-error.log;

    # Trust forwarded IP from Traefik (Docker gateway) and localhost
    real_ip_header X-Forwarded-For;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from {{TRAEFIK_BACKEND_HOST}};

    location / {
        try_files $uri /index.php?$query_string;
    }

    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt  { allow all; log_not_found off; access_log off; }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+?\.php)(|/.*)$;
        fastcgi_pass unix:{{PHP_FPM_SOCKET}};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param SCRIPT_NAME     $fastcgi_script_name;
        fastcgi_param PATH_INFO       $fastcgi_path_info;
        fastcgi_param HTTP_PROXY      "";
        include fastcgi_params;
        fastcgi_intercept_errors on;
        fastcgi_read_timeout 300;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 256 16k;
    }

    # ── Drupal beveiliging ────────────────────────────────────────────────────
    location ~ (^|/)\. {
        return 403;
    }
    location ~ ^/sites/.*/private/ {
        return 403;
    }
    location ~ ^/sites/[^/]+/files/.*\.php$ {
        return 403;
    }
    location ~* \.(engine|inc|install|make|module|profile|po|sh|sql|theme|twig|tpl\.php|xtmpl|yml)(~|\.sw[op]|\.bak|\.orig|\.save)?$ {
        return 403;
    }
    location ~ ^/update\.php {
        return 403;
    }
}
