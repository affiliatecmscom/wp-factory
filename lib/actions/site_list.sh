#!/usr/bin/env bash
# actions/site_list.sh — liệt kê site dạng bảng (cho `lat ls`).

act_site_list_print() {
  local ids; ids="$(list_site_ids)"
  if [ -z "$ids" ]; then info "Chưa có site nào."; return 0; fi
  printf "%-10s %-32s %-13s %-8s\n" "ID" "DOMAIN" "LOẠI" "WP"
  printf "%-10s %-32s %-13s %-8s\n" "----------" "--------------------------------" "-------------" "--------"
  local id dom typ st
  for id in $ids; do
    dom="$(site_get "$id" DOMAIN)"; typ="$(site_get "$id" TYPE)"
    st="$(docker inspect -f '{{.State.Status}}' "${id}_wp" 2>/dev/null || echo down)"
    printf "%-10s %-32s %-13s %-8s\n" "$id" "$dom" "$typ" "$st"
  done
}

# Hiện thông tin chi tiết 1 site -> text (dùng cho submenu).
site_info_text() {
  local id="$1"
  local dom typ can email st_wp st_db du
  dom="$(site_get "$id" DOMAIN)"; typ="$(site_get "$id" TYPE)"
  can="$(site_get "$id" CANONICAL)"; email="$(site_get "$id" ADMIN_EMAIL)"
  st_wp="$(docker inspect -f '{{.State.Status}}' "${id}_wp" 2>/dev/null || echo down)"
  st_db="$(docker inspect -f '{{.State.Status}}' "${id}_db" 2>/dev/null || echo down)"
  du="$(du -sh "$(site_dir "$id")" 2>/dev/null | cut -f1)"
  printf 'ID        : %s\nDomain    : %s\nURL       : https://%s\nLoại      : %s\nCanonical : %s\nEmail     : %s\nWP/DB     : %s / %s\nDung lượng: %s\nThư mục   : %s' \
    "$id" "$dom" "$dom" "$typ" "$can" "$email" "$st_wp" "$st_db" "${du:-?}" "$(site_dir "$id")"
}
