#!/usr/bin/env bash
# actions/site_canonical.sh — đổi canonical www/non-www/none của site. Chỉ render lại Caddy block.

act_site_canonical() {
  require_root
  local arg="${1:-}" canonical="${2:-}"
  [ -n "$arg" ] || { warn "Dùng: lat canonical <id|domain> <www|non-www|none>"; return 1; }
  local id; id="$(resolve_site "$arg")" || { warn "Không tìm thấy site: $arg"; return 1; }
  local domain; domain="$(site_get "$id" DOMAIN)"

  if [ -z "$canonical" ]; then
    canonical="$(ui_menu "Canonical cho ${domain} (hiện: $(site_get "$id" CANONICAL))" \
      non-www "non-www: ${domain}" \
      www     "www: www.${domain}" \
      none    "phục vụ cả hai, không redirect")" || return 1
  fi
  case "$canonical" in www|non-www|none) ;; *) warn "Giá trị không hợp lệ: $canonical"; return 1;; esac

  write_caddy_block "$id" "$domain" "$canonical"
  caddy_reload || warn "Caddy reload lỗi."
  site_set "$id" CANONICAL "$canonical"
  [ "$canonical" = "non-www" ] || ui_note "Nhớ A record cho www.${domain}"
  ok "Đã đổi canonical sang ${canonical} cho ${domain}."
}
