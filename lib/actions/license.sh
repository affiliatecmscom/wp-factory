#!/usr/bin/env bash
# actions/license.sh - quản lý license key + helper ensure_license (validate qua app.lat.vn).

# Hỏi + validate + lưu license. Trả 0 nếu cuối cùng có license hợp lệ.
# Lặp tới khi hợp lệ hoặc user huỷ.
ensure_license() {
  local key
  while true; do
    key="$(ui_input "Nhập license key (ACMS-XXXX-XXXX-XXXX-XXXX):" "")" || return 1
    key="$(printf '%s' "$key" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
    [ -n "$key" ] || return 1
    info "Xác thực license với app.lat.vn..."
    if license_check "$key" >/dev/null 2>&1; then
      save_license "$key"
      ok "License hợp lệ, đã lưu."
      return 0
    fi
    ui_yesno "License không hợp lệ hoặc hết hạn. Thử lại?" || return 1
  done
}

# Trả về license hợp lệ để dùng cho 1 site AffiliateCMS (lazy check).
# In key ra stdout nếu OK; rỗng + return 1 nếu không có.
resolve_license_for_site() {
  local key; key="$(stored_license)"
  if [ -n "$key" ] && license_check "$key" >/dev/null 2>&1; then
    printf '%s' "$key"; return 0
  fi
  # Thiếu hoặc hết hạn -> hỏi nhập (ngoài luồng capture: dùng tty)
  if ensure_license; then
    printf '%s' "$(stored_license)"; return 0
  fi
  return 1
}

# Tóm tắt license (mask) -> stdout text.
license_summary() {
  local key; key="$(stored_license)"
  [ -n "$key" ] || { printf 'Chưa có license.'; return; }
  local json; json="$(license_check "$key" 2>/dev/null)" || { printf 'License: %s (không xác thực được hoặc hết hạn)' "$key"; return; }
  local used maxd
  used="$(printf '%s' "$json" | sed -n 's/.*"domains_used"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
  maxd="$(printf '%s' "$json" | sed -n 's/.*"max_domains"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
  printf 'License: %s\nĐang dùng: %s/%s domain' "$key" "${used:-?}" "${maxd:-?}"
}

act_license() {
  require_root
  while true; do
    local choice
    choice="$(ui_menu "License - $(license_summary | tr '\n' ' ')" \
      1 "Đổi / nhập license key" \
      2 "Xem chi tiết license" \
      0 "Quay lại")" || return 0
    case "$choice" in
      1) ensure_license || warn "Chưa cập nhật license." ;;
      2) ui_msg "$(license_summary)" ;;
      0|"") return 0 ;;
    esac
  done
}
