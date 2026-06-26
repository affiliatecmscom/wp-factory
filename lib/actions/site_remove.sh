#!/usr/bin/env bash
# actions/site_remove.sh - gỡ sạch 1 site (container + volume + dir + origin cert + license slot).

act_site_remove() {
  require_root
  local arg="${1:-}" assume_yes=0
  [ "${2:-}" = "--yes" ] && assume_yes=1
  [ -n "$arg" ] || { warn "Dùng: lat rm <id|domain>"; return 1; }

  local id; id="$(resolve_site "$arg")" || { warn "Không tìm thấy site: $arg"; return 1; }
  local dir; dir="$(site_dir "$id")"
  local domain; domain="$(site_get "$id" DOMAIN)"

  if [ "$assume_yes" -ne 1 ]; then
    local confirm
    confirm="$(ui_input "XOÁ VĨNH VIỄN site ${domain} (container + database + file).\nGõ lại domain để xác nhận:" "")" || return 1
    [ "$confirm" = "$domain" ] || { ui_msg "Xác nhận không khớp. Đã huỷ."; return 1; }
  fi

  # Giải phóng license slot
  local key; key="$(site_get "$id" LICENSE_KEY 2>/dev/null || true)"
  [ -n "$key" ] && { info "Giải phóng license slot..."; license_deactivate "$key" "$domain" && ok "Đã deactivate." || warn "Không deactivate được (bỏ qua)."; }

  info "Tắt + xoá container/volume..."
  docker compose -f "$dir/docker-compose.yml" --env-file "$dir/.env" down -v >/dev/null 2>&1 || warn "compose down lỗi."

  # Xoá origin cert (nếu có); nginx-proxy tự bỏ route khi container _web mất.
  ssl_remove_origin "$domain"; ssl_remove_origin "www.${domain}"

  rm -rf "$dir"
  ok "Đã gỡ site ${domain}."
}
