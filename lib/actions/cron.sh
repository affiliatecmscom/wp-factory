#!/usr/bin/env bash
# actions/cron.sh - quản lý cronjob: tự cài cron AffiliateCMS cho 1 site, hoặc thêm cron tuỳ chọn.
# Cron gọi qua nginx-proxy local (--resolve 127.0.0.1) -> không phụ thuộc DNS/Cloudflare ngoài.

# Chọn 1 site -> in id ra stdout (rỗng nếu huỷ/không có).
_cron_pick_site() {
  local ids; ids="$(list_site_ids)"
  [ -n "$ids" ] || { ui_msg "Chưa có site nào."; return 1; }
  local args=() id dom
  for id in $ids; do dom="$(site_get "$id" DOMAIN)"; args+=("$id" "${dom}"); done
  ui_menu "Chọn site" "${args[@]}"
}

# Ghi/đè block cron của 1 site (đánh dấu để idempotent).
_cron_write_block() {
  local id="$1" block="$2" tmp; tmp="$(mktemp)"
  crontab -l 2>/dev/null | sed "/# >>> latvps ${id} >>>/,/# <<< latvps ${id} <<</d" > "$tmp"
  printf '%s\n' "$block" >> "$tmp"
  crontab "$tmp"; rm -f "$tmp"
}

# Tự cài 6 cron AffiliateCMS cho 1 site.
_cron_install_site() {
  local id; id="$(_cron_pick_site)" || return 0
  [ -n "$id" ] || return 0
  local domain type; domain="$(site_get "$id" DOMAIN)"; type="$(site_get "$id" TYPE)"
  if [ "$type" != "affiliatecms" ]; then
    ui_yesno "Site ${domain} không phải AffiliateCMS - cron này chỉ hợp cho AffiliateCMS. Vẫn cài?" || return 0
  fi

  info "Lấy token cron của site..."
  local token key
  token="$(wp_run "$id" option get acms_api_token 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$token" ]; then
    token="$(wp_run "$id" eval 'echo wp_generate_password(32,false);' 2>/dev/null | tr -d '[:space:]')"
    wp_run "$id" option update acms_api_token "$token" >/dev/null 2>&1 || true
  fi
  key="$(wp_run "$id" option get acms_ai_cron_key 2>/dev/null | tr -d '[:space:]')"

  local c="curl -sk -X POST --resolve ${domain}:443:127.0.0.1"
  local base="https://${domain}/wp-json"
  local block
  block="$(cat <<EOF
# >>> latvps ${id} >>>  (AffiliateCMS cron - ${domain})
*/5 * * * * ${c} "${base}/acms/v1/automation/scrape" -H "X-ACMS-Token: ${token}" >/dev/null 2>&1
*/5 * * * * ${c} "${base}/acms/v1/automation/process-scheduled" -H "X-ACMS-Token: ${token}" >/dev/null 2>&1
*/5 * * * * ${c} "${base}/acms/v1/automation/process-queue?limit=10" -H "X-ACMS-Token: ${token}" >/dev/null 2>&1
*/5 * * * * ${c} "${base}/acms-ai/v1/cron/scan?cron_key=${key}" >/dev/null 2>&1
*/2 * * * * ${c} "${base}/acms-ai/v1/cron/work?cron_key=${key}" >/dev/null 2>&1
*/5 * * * * ${c} "${base}/acms-ai/v1/cron/process?cron_key=${key}" >/dev/null 2>&1
# <<< latvps ${id} <<<
EOF
)"
  _cron_write_block "$id" "$block"
  ok "Đã cài 6 cronjob AffiliateCMS cho ${domain}."
  ui_msg "Đã cài cron tự động cho ${domain}:\n- PRO: scrape / process-scheduled / process-queue (5 phút)\n- AI: scan (5p) / work (2p) / process (5p)\n\nXem: lat cron -> Xem crontab. Gỡ: lat cron -> Xoá cron của site."
}

# Thêm 1 dòng cron tuỳ chọn (dán + enter).
_cron_add_custom() {
  local line; line="$(ui_input "Dán 1 dòng crontab (vd: */10 * * * * lệnh):" "")" || return 0
  line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$line" ] || { warn "Bỏ trống."; return 0; }
  # kiểm thô: tối thiểu 5 trường lịch + lệnh
  if [ "$(printf '%s' "$line" | awk '{print NF}')" -lt 6 ] && ! printf '%s' "$line" | grep -q '@'; then
    ui_msg "Dòng cron không hợp lệ (cần 5 trường thời gian + lệnh)."; return 0
  fi
  ( crontab -l 2>/dev/null; printf '# latvps custom\n%s\n' "$line" ) | crontab -
  ok "Đã thêm cronjob tuỳ chọn."
}

# Xoá block cron của 1 site.
_cron_remove_site() {
  local id; id="$(_cron_pick_site)" || return 0
  [ -n "$id" ] || return 0
  local tmp; tmp="$(mktemp)"
  crontab -l 2>/dev/null | sed "/# >>> latvps ${id} >>>/,/# <<< latvps ${id} <<</d" > "$tmp"
  crontab "$tmp"; rm -f "$tmp"
  ok "Đã xoá cron của site ${id}."
}

act_cron() {
  require_root
  need_cmd crontab || { ui_msg "Thiếu 'cron'. Chạy: apt-get install -y cron"; return 1; }
  while true; do
    local c
    c="$(ui_menu "Cronjob" \
      auto "Cài cron AffiliateCMS cho 1 site (tự động)" \
      add  "Thêm cronjob tuỳ chọn (dán dòng crontab)" \
      list "Xem crontab hiện tại" \
      del  "Xoá cron của 1 site" \
      0    "Quay lại")" || return 0
    case "$c" in
      auto) _cron_install_site ;;
      add)  _cron_add_custom ;;
      list) ui_msg "$(crontab -l 2>/dev/null || echo '(crontab trống)')" ;;
      del)  _cron_remove_site ;;
      0|"") return 0 ;;
    esac
  done
}
