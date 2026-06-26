#!/usr/bin/env bash
# lib/menu.sh - các menu TUI tương tác. Gọi vào act_* trong lib/actions/.

main_menu() {
  host_ready || { ui_msg "Host chưa sẵn sàng (thiếu Docker/proxy).\n\nChạy lệnh cài đặt 1 lần trước:\n  curl -fsSL https://raw.githubusercontent.com/affiliatecmscom/latvps/main/latvps.sh | sudo bash"; exit 1; }
  while true; do
    local c
    c="$(ui_menu "LATVPS - quản lý site" \
      1 "Thêm site mới" \
      2 "Quản lý site" \
      3 "Backup tất cả" \
      4 "License" \
      5 "Trạng thái hệ thống" \
      6 "Cài Claude Code" \
      7 "Bảo trì / nâng cao" \
      0 "Thoát")" || break
    case "$c" in
      1) act_site_add ;;
      2) manage_menu ;;
      3) act_backup all; ui_msg "Backup tất cả xong (xem /opt/backups)." ;;
      4) act_license ;;
      5) act_status ;;
      6) act_install_claude ;;
      7) maintenance_menu ;;
      0|"") break ;;
    esac
  done
  clear 2>/dev/null || true
}

manage_menu() {
  local ids; ids="$(list_site_ids)"
  if [ -z "$ids" ]; then
    ui_yesno "Chưa có site nào. Thêm site mới?" && act_site_add
    return
  fi
  local args=() id dom typ st
  for id in $ids; do
    dom="$(site_get "$id" DOMAIN)"; typ="$(site_get "$id" TYPE)"
    st="$(docker inspect -f '{{.State.Status}}' "${id}_web" 2>/dev/null || echo down)"
    args+=("$id" "${dom}  [${typ}]  ${st}")
  done
  local sel; sel="$(ui_menu "Chọn site để quản lý" "${args[@]}")" || return
  [ -n "$sel" ] && site_submenu "$sel"
}

site_submenu() {
  local id="$1"
  while true; do
    local dom; dom="$(site_get "$id" DOMAIN)"
    [ -n "$dom" ] || return   # đã bị xoá
    local c
    c="$(ui_menu "Site: ${dom} (${id})" \
      1 "Xem thông tin" \
      2 "Đổi domain" \
      3 "Backup site này" \
      4 "Bật / Tắt site" \
      5 "Xem logs" \
      6 "Xoá site" \
      0 "Quay lại")" || return
    case "$c" in
      1) ui_msg "$(site_info_text "$id")" ;;
      2) act_site_domain "$id" ;;
      3) act_backup "$id"; ui_msg "Đã backup (xem /opt/backups/${id})." ;;
      4) toggle_site "$id" ;;
      5) ui_msg "$(act_logs "$id" php | tail -40)" ;;
      6) act_site_remove "$id"; return ;;
      0|"") return ;;
    esac
  done
}

toggle_site() {
  local id="$1" dir; dir="$(site_dir "$id")"
  local st; st="$(docker inspect -f '{{.State.Status}}' "${id}_web" 2>/dev/null || echo down)"
  if [ "$st" = "running" ]; then
    docker compose -f "$dir/docker-compose.yml" --env-file "$dir/.env" stop >/dev/null 2>&1
    ui_msg "Đã TẮT site (dữ liệu giữ nguyên)."
  else
    docker compose -f "$dir/docker-compose.yml" --env-file "$dir/.env" start >/dev/null 2>&1
    ui_msg "Đã BẬT site."
  fi
}

maintenance_menu() {
  while true; do
    local c
    c="$(ui_menu "Bảo trì / nâng cao" \
      1 "Cập nhật hệ thống (image WP/MariaDB/nginx + OS) [lat upgrade]" \
      2 "Cập nhật lệnh lat (code) [lat update]" \
      3 "Cập nhật plugin payload (cho site tạo sau)" \
      4 "Cronjob (cài cron AffiliateCMS / thêm cron)" \
      5 "Chạy lại setup host (idempotent)" \
      0 "Quay lại")" || return
    case "$c" in
      1) act_update ;;
      2) act_self_update ;;
      3) act_payload_sync; ui_msg "Payload đã cập nhật." ;;
      4) act_cron ;;
      5) act_setup ;;
      0|"") return ;;
    esac
  done
}
