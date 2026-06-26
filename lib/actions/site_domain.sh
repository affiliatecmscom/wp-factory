#!/usr/bin/env bash
# actions/site_domain.sh — đổi domain của site. Container/DB GIỮ NGUYÊN (định danh theo ID).
# Chỉ đổi: DB search-replace, license, Caddy block, site.conf.

act_site_domain() {
  require_root
  local arg="${1:-}" new="${2:-}"
  [ -n "$arg" ] || { warn "Dùng: lat domain <id|domain> <new-domain>"; return 1; }
  local id; id="$(resolve_site "$arg")" || { warn "Không tìm thấy site: $arg"; return 1; }

  local old; old="$(site_get "$id" DOMAIN)"
  local type; type="$(site_get "$id" TYPE)"
  local canonical; canonical="$(site_get "$id" CANONICAL)"

  # Nhập domain mới nếu thiếu
  while true; do
    [ -n "$new" ] || new="$(ui_input "Domain hiện tại: ${old}\nNhập domain MỚI:" "")" || return 1
    new="$(printf '%s' "$new" | tr '[:upper:]' '[:lower:]' | sed 's/^www\.//; s#^https\?://##; s#/.*$##')"
    if ! valid_domain "$new"; then ui_msg "Domain không hợp lệ."; new=""; continue; fi
    if [ "$new" = "$old" ]; then ui_msg "Trùng domain cũ."; new=""; continue; fi
    if site_id_by_domain "$new" >/dev/null 2>&1; then ui_msg "Domain đã dùng cho site khác."; new=""; continue; fi
    break
  done

  ui_yesno "Đổi domain site ${id}:\n${old}  ->  ${new}\n\nDữ liệu (bài viết, DB) giữ nguyên. Tiếp tục?" || { info "Đã huỷ."; return 1; }

  # 1. WP: search-replace + update url
  info "Cập nhật URL trong WordPress (search-replace)..."
  wp_run "$id" search-replace "$old" "$new" --all-tables --skip-columns=guid >/dev/null 2>&1 || warn "search-replace gặp lỗi (kiểm tra DB)."
  wp_run "$id" option update home "https://${new}" >/dev/null 2>&1 || true
  wp_run "$id" option update siteurl "https://${new}" >/dev/null 2>&1 || true

  # 2. License: chuyển domain
  if [ "$type" = "affiliatecms" ]; then
    local key; key="$(site_get "$id" LICENSE_KEY 2>/dev/null || stored_license)"
    if [ -n "$key" ]; then
      info "Chuyển license sang domain mới..."
      license_deactivate "$key" "$old" || true
      license_activate "$key" "$new" && ok "License activate cho ${new}." || warn "Activate domain mới thất bại — xử lý sau."
    fi
  fi

  # 3. Caddy: thay block
  info "Cập nhật Caddy..."
  rm -f "${WPF_ROOT}/caddy/sites/${old}.caddy"
  write_caddy_block "$id" "$new" "$canonical"
  caddy_reload || warn "Caddy reload lỗi."

  # 4. site.conf
  site_set "$id" DOMAIN "$new"

  ui_msg "Đã đổi domain: ${old} -> ${new}\n\n>> Nhớ trỏ A record '${new}' (và www nếu dùng) về IP VPS này.\n>> Cert mới sẽ được cấp khi domain trỏ đúng."
}
