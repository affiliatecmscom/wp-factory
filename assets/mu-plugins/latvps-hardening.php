<?php
// LATVPS hardening (defense-in-depth). Copy vào wp-content/mu-plugins/ mọi site.
// XML-RPC đã chặn ở nginx; tắt thêm trong WP cho chắc (chống brute-force/pingback DDoS).
add_filter('xmlrpc_enabled', '__return_false');
add_filter('xmlrpc_methods', function ($methods) {
    unset($methods['pingback.ping'], $methods['pingback.extensions.getPingbacks']);
    return $methods;
});
// Bỏ header X-Pingback (không quảng cáo pingback).
add_filter('wp_headers', function ($headers) {
    unset($headers['X-Pingback']);
    return $headers;
});
