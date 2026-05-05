[{{SITE_SLUG}}]
user  = nginx
group = nginx

listen = {{PHP_FPM_SOCKET}}
listen.owner = nginx
listen.group = nginx
listen.mode  = 0660

pm                   = dynamic
pm.max_children      = 10
pm.start_servers     = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
pm.max_requests      = 500

; Begrens toegang tot de site map en /tmp
php_admin_value[open_basedir]         = {{SITE_DIR}}:/tmp
php_admin_value[error_log]            = /var/log/php-fpm/drupal-{{SITE_SLUG}}-error.log
php_admin_flag[log_errors]            = on
php_admin_value[memory_limit]         = 256M
php_admin_value[upload_max_filesize]  = 64M
php_admin_value[post_max_size]        = 64M
php_admin_value[max_execution_time]   = 300
php_admin_value[max_input_vars]       = 3000
