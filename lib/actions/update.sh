#!/usr/bin/env bash
# actions/update.sh — cập nhật HỆ THỐNG: image Caddy + WP/MariaDB từng site, vá OS (tuỳ chọn).
# Plugin/theme AffiliateCMS KHÔNG ở đây (update qua license server / payload-sync).

act_update() {
  require_root
  ui_yesno "Cập nhật hệ thống sẽ pull image mới (WordPress/MariaDB/nginx/redis) và khởi động lại từng site.\nNên backup trước. Backup tất cả ngay bây giờ?" && act_backup all

  info "Cập nhật front proxy..."
  proxy_compose pull -q >/dev/null 2>&1 || true
  proxy_compose up -d >/dev/null 2>&1 || warn "Proxy up lỗi."

  local id dir dom done=0 fail=0
  for id in $(list_site_ids); do
    dir="$(site_dir "$id")"; dom="$(site_get "$id" DOMAIN)"
    info "Nâng site ${dom} (${id})..."
    if docker compose -f "$dir/docker-compose.yml" --env-file "$dir/.env" pull -q >/dev/null 2>&1 \
       && docker compose -f "$dir/docker-compose.yml" --env-file "$dir/.env" up -d >/dev/null 2>&1; then
      done=$((done+1))
    else
      warn "Nâng ${dom} lỗi."; fail=$((fail+1))
    fi
  done

  if ui_yesno "Vá hệ điều hành (apt upgrade) + dọn image cũ?"; then
    info "apt upgrade..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get upgrade -y -qq >/dev/null 2>&1 || warn "apt upgrade gặp lỗi."
    docker image prune -f >/dev/null 2>&1 || true
  fi

  ui_msg "Cập nhật hệ thống xong.\nSite nâng OK: ${done}, lỗi: ${fail}."
}
