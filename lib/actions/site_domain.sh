#!/usr/bin/env bash
# actions/site_domain.sh - đổi domain của site. Container/DB GIỮ NGUYÊN (định danh theo ID).
# Chỉ đổi: DB search-replace, license, Caddy block, site.conf.

act_site_domain() {
  require_root
  local arg="${1:-}" new="${2:-}"
  [ -n "$arg" ] || { warn "Dùng: lat domain <id|domain> <new-domain>"; return 1; }
  local id; id="$(resolve_site "$arg")" || { warn "Không tìm thấy site: $arg"; return 1; }

  local old; old="$(site_get "$id" DOMAIN)"
  local type; type="$(site_get "$id" TYPE)"
  local ssl; ssl="$(site_get "$id" SSL)"
  local dir; dir="$(site_dir "$id")"

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
      license_activate "$key" "$new" && ok "License activate cho ${new}." || warn "Activate domain mới thất bại - xử lý sau."
    fi
  fi

  # 3. Routing + SSL: đổi VIRTUAL_HOST/LE_HOST trong .env rồi recreate container _web
  info "Cập nhật proxy + SSL..."
  ssl_remove_origin "$old"; ssl_remove_origin "www.${old}"
  local le_host=""
  if [ "$ssl" = "auto" ]; then
    le_host="${new},www.${new}"
  else
    ui_msg "SSL origin: cần Cloudflare Origin Cert MỚI cho ${new}."
    local cert key
    cert="$(ui_input "Dán CERTIFICATE cho ${new}:" "")" || true
    key="$(ui_input "Dán PRIVATE KEY:" "")" || true
    if printf '%s' "$cert" | grep -q 'BEGIN CERTIFICATE'; then
      ssl_save_origin "$new" "$cert" "$key"; ssl_save_origin "www.${new}" "$cert" "$key"
    else
      warn "Bỏ qua cert - thả cert vào /opt/proxy/certs/${new}.crt|.key sau."
    fi
  fi
  sed -i "s|^VIRTUAL_HOST=.*|VIRTUAL_HOST=${new},www.${new}|" "$dir/.env"
  sed -i "s|^LE_HOST=.*|LE_HOST=${le_host}|" "$dir/.env"
  docker compose -f "$dir/docker-compose.yml" --env-file "$dir/.env" up -d --force-recreate web >/dev/null 2>&1 \
    || warn "Recreate web lỗi - kiểm 'lat logs ${id} web'."

  # 4. site.conf
  site_set "$id" DOMAIN "$new"

  ui_msg "Đã đổi domain: ${old} -> ${new}\n\n>> Nhớ trỏ A record '${new}' (và www) về IP VPS này.\n>> SSL ${ssl}: cert sẽ được cấp/áp khi domain trỏ đúng."
}
