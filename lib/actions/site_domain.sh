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

  # 1. WP: search-replace + update url (giữ canonical www/non-www đã chọn lúc tạo)
  local canon; canon="$(site_get "$id" CANONICAL 2>/dev/null)"
  local new_canon="$new"; [ "$canon" = "www" ] && new_canon="www.${new}"
  info "Cập nhật URL trong WordPress (search-replace)..."
  wp_run "$id" search-replace "$old" "$new" --all-tables --skip-columns=guid >/dev/null 2>&1 || warn "search-replace gặp lỗi (kiểm tra DB)."
  wp_run "$id" option update home "https://${new_canon}" >/dev/null 2>&1 || true
  wp_run "$id" option update siteurl "https://${new_canon}" >/dev/null 2>&1 || true

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
  case "$ssl" in
    auto)
      le_host="${new},www.${new}"
      ;;
    cloudflare)
      ssl_make_selfsigned "$new" && ok "Đã tạo cert tự ký cho ${new}." || warn "Tạo cert tự ký lỗi."
      ;;
    origin)
      ui_msg "SSL origin: cần Cloudflare Origin Cert MỚI cho ${new}.\nDán nguyên khối (tự dừng ở dòng END)."
      local cert key
      cert="$(ui_paste_block "Dán CERTIFICATE cho ${new}:" 'END CERTIFICATE')"
      key="$(ui_paste_block "Dán PRIVATE KEY cho ${new}:" 'END.*PRIVATE KEY')"
      if printf '%s' "$cert" | grep -q 'BEGIN CERTIFICATE'; then
        ssl_save_origin "$new" "$cert" "$key"; ssl_save_origin "www.${new}" "$cert" "$key"
      else
        warn "Bỏ qua cert - thả cert vào /opt/proxy/certs/${new}.crt|.key sau."
      fi
      ;;
  esac
  sed -i "s|^VIRTUAL_HOST=.*|VIRTUAL_HOST=${new},www.${new}|" "$dir/.env"
  sed -i "s|^LE_HOST=.*|LE_HOST=${le_host}|" "$dir/.env"
  docker compose -f "$dir/docker-compose.yml" --env-file "$dir/.env" up -d --force-recreate web >/dev/null 2>&1 \
    || warn "Recreate web lỗi - kiểm 'lat logs ${id} web'."

  # 4. site.conf + symlink domain (/opt/sites/<domain>)
  site_set "$id" DOMAIN "$new"
  site_link_remove "$old"
  site_link_set "$id" "$new"

  ui_msg "Đã đổi domain: ${old} -> ${new}\n\nThư mục: ${SITES_ROOT}/${new}  (-> $(site_dir "$id"))\n>> Nhớ trỏ A record '${new}' (và www) về IP VPS này.\n>> SSL ${ssl}: cert sẽ được cấp/áp khi domain trỏ đúng."
}
