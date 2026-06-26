#!/usr/bin/env bash
# lib/ui.sh — lớp giao diện trung lập. Có whiptail thì dùng TUI; không thì fallback menu số.
# Mọi hàm trả KẾT QUẢ qua stdout (để $() bắt được), vẽ UI ra stderr/terminal.

HAS_WHIPTAIL=0
command -v whiptail >/dev/null 2>&1 && HAS_WHIPTAIL=1

# ui_menu "TITLE"  tag1 "label1"  tag2 "label2" ...  -> in tag được chọn. Return !=0 nếu Huỷ.
ui_menu() {
  local title="$1"; shift
  if [ "$HAS_WHIPTAIL" = 1 ]; then
    local n=$(( $# / 2 ))
    [ "$n" -gt 12 ] && n=12
    whiptail --title "lat" --notags --menu "$title" 20 74 "$n" "$@" 3>&1 1>&2 2>&3
    return $?
  fi
  # Fallback: in danh sách ra stderr, đọc tag từ tty.
  printf '\n== %s ==\n' "$title" >&2
  local items=("$@") i
  for ((i=0; i<${#items[@]}; i+=2)); do
    printf '  %s) %s\n' "${items[i]}" "${items[i+1]}" >&2
  done
  printf 'Chọn: ' >&2
  local choice; read -r choice </dev/tty || return 1
  [ -n "$choice" ] || return 1
  printf '%s' "$choice"
}

# ui_input "PROMPT" "DEFAULT" -> in giá trị nhập (hoặc default). Return !=0 nếu Huỷ (whiptail).
ui_input() {
  local prompt="$1" def="${2:-}"
  if [ "$HAS_WHIPTAIL" = 1 ]; then
    whiptail --title "lat" --inputbox "$prompt" 11 74 "$def" 3>&1 1>&2 2>&3
    return $?
  fi
  printf '%s [%s]: ' "$prompt" "$def" >&2
  local v; read -r v </dev/tty || return 1
  printf '%s' "${v:-$def}"
}

# ui_yesno "MSG" -> return 0 nếu Yes, 1 nếu No.
ui_yesno() {
  local msg="$1"
  if [ "$HAS_WHIPTAIL" = 1 ]; then
    whiptail --title "lat" --yesno "$msg" 12 74
    return $?
  fi
  printf '%s [y/N]: ' "$msg" >&2
  local a; read -r a </dev/tty || return 1
  case "$a" in [Yy]*) return 0;; *) return 1;; esac
}

# ui_msg "TEXT" -> hiện thông báo.
ui_msg() {
  if [ "$HAS_WHIPTAIL" = 1 ]; then
    whiptail --title "lat" --scrolltext --msgbox "$1" 20 74
  else
    printf '\n%s\n' "$1" >&2
    printf '[Enter để tiếp tục] ' >&2; read -r _ </dev/tty || true
  fi
}

# ui_gauge_msg "TEXT" — thông báo tiến trình ngắn (không chặn). Dùng info() là đủ; alias cho rõ nghĩa.
ui_note() { info "$@"; }
