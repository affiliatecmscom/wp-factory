#!/usr/bin/env bash
# actions/site_list.sh — liệt kê site dạng bảng (cho `lat ls`).

act_site_list_print() {
  local ids; ids="$(list_site_ids)"
  if [ -z "$ids" ]; then info "Chưa có site nào."; return 0; fi
  printf "%-10s %-30s %-12s %-7s %-8s\n" "ID" "DOMAIN" "LOẠI" "SSL" "WEB"
  printf "%-10s %-30s %-12s %-7s %-8s\n" "----------" "------------------------------" "------------" "-------" "--------"
  local id dom typ ssl st
  for id in $ids; do
    dom="$(site_get "$id" DOMAIN)"; typ="$(site_get "$id" TYPE)"; ssl="$(site_get "$id" SSL)"
    st="$(docker inspect -f '{{.State.Status}}' "${id}_web" 2>/dev/null || echo down)"
    printf "%-10s %-30s %-12s %-7s %-8s\n" "$id" "$dom" "$typ" "${ssl:-?}" "$st"
  done
}

# Hiện thông tin chi tiết 1 site -> text (dùng cho submenu).
site_info_text() {
  local id="$1"
  local dom typ ssl email st_web st_db st_redis du
  dom="$(site_get "$id" DOMAIN)"; typ="$(site_get "$id" TYPE)"
  ssl="$(site_get "$id" SSL)"; email="$(site_get "$id" ADMIN_EMAIL)"
  st_web="$(docker inspect -f '{{.State.Status}}' "${id}_web" 2>/dev/null || echo down)"
  st_db="$(docker inspect -f '{{.State.Status}}' "${id}_db" 2>/dev/null || echo down)"
  st_redis="$(docker inspect -f '{{.State.Status}}' "${id}_redis" 2>/dev/null || echo down)"
  du="$(du -sh "$(site_dir "$id")" 2>/dev/null | cut -f1)"
  printf 'ID         : %s\nDomain     : %s\nURL        : https://%s\nStack/Loại : wordpress / %s\nSSL        : %s\nEmail      : %s\nweb/db/redis: %s / %s / %s\nDung lượng : %s\nThư mục    : %s' \
    "$id" "$dom" "$dom" "$typ" "${ssl:-?}" "$email" "$st_web" "$st_db" "$st_redis" "${du:-?}" "$(site_dir "$id")"
}
