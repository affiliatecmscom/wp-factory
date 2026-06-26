<?php
// proxy-ssl - WordPress đứng sau reverse proxy (Caddy) cần nhận biết HTTPS qua X-Forwarded-Proto.
// Copy vào wp-content/mu-plugins/ của MỌI site. Generic, không phụ thuộc AffiliateCMS.
if (!empty($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    $_SERVER['HTTPS'] = 'on';
}
