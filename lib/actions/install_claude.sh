#!/usr/bin/env bash
# actions/install_claude.sh - cài Claude Code (CLI Anthropic) cho học viên trên VPS.
# Native installer (không cần Node). Tự thêm PATH + symlink /usr/local/bin.
# ĐĂNG NHẬP: dùng TÀI KHOẢN Pro/Max - học viên thoát lat rồi gõ 'claude' lần đầu,
#   claude hiện link đăng nhập, login xong lưu ở ~/.claude -> dùng mọi shell, vĩnh viễn.
#   (KHÔNG dùng setup-token/biến môi trường cho tài khoản - đó là kho login riêng của claude.)
# Tuỳ chọn khác: ANTHROPIC_API_KEY (tính theo token) lưu vào env file.

CLAUDE_BIN="/root/.local/bin/claude"
CLAUDE_ENV_DIR="/root/.config/lat"
CLAUDE_ENV_FILE="${CLAUDE_ENV_DIR}/claude-env"
CLAUDE_BASHRC="/root/.bashrc"

# Đảm bảo ~/.local/bin trong PATH (.bashrc) + process hiện tại + symlink toàn cục.
_claude_ensure_path() {
  grep -q '.local/bin' "$CLAUDE_BASHRC" 2>/dev/null \
    || printf '\n# Claude Code\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$CLAUDE_BASHRC"
  case ":$PATH:" in *":/root/.local/bin:"*) ;; *) export PATH="/root/.local/bin:$PATH";; esac
  # symlink vào /usr/local/bin (luôn trong PATH mọi shell/root) -> 'claude' chạy ngay.
  [ -x "$CLAUDE_BIN" ] && ln -sf "$CLAUDE_BIN" /usr/local/bin/claude 2>/dev/null || true
}

# Lưu biến auth (API key) vào file chmod 600 + nạp từ .bashrc.
_claude_save_env() {
  local var="$1" val="$2"
  mkdir -p "$CLAUDE_ENV_DIR"; chmod 700 "$CLAUDE_ENV_DIR"
  touch "$CLAUDE_ENV_FILE"
  sed -i "/^export ${var}=/d" "$CLAUDE_ENV_FILE" 2>/dev/null || true
  printf 'export %s=%q\n' "$var" "$val" >> "$CLAUDE_ENV_FILE"
  chmod 600 "$CLAUDE_ENV_FILE"
  local srcline='[ -f ~/.config/lat/claude-env ] && . ~/.config/lat/claude-env'
  grep -qF "$srcline" "$CLAUDE_BASHRC" 2>/dev/null \
    || printf '\n# Claude Code auth (lat)\n%s\n' "$srcline" >> "$CLAUDE_BASHRC"
  export "${var}=${val}"
}

# Hướng dẫn đăng nhập bằng TÀI KHOẢN (cách khuyến nghị). Không lưu token - claude tự lưu.
_claude_login_help() {
  # Bỏ token cũ (nếu phiên trước lỡ lưu) để không che mất kho đăng nhập của claude.
  [ -f "$CLAUDE_ENV_FILE" ] && sed -i '/^export CLAUDE_CODE_OAUTH_TOKEN=/d' "$CLAUDE_ENV_FILE" 2>/dev/null || true
  ui_msg "ĐĂNG NHẬP CLAUDE CODE (tài khoản Claude Pro/Max):\n\n 1) Thoát lat: gõ 0 (hoặc Ctrl+C) để về dấu nhắc shell.\n 2) Gõ:  claude\n 3) Lần đầu, claude hiện MỘT ĐƯỜNG LINK. Copy, mở bằng trình duyệt ĐANG ĐĂNG NHẬP Claude > Authorize > dán code lại nếu được hỏi.\n 4) Xong. Claude lưu đăng nhập (~/.claude) - mọi shell, mọi lần sau đều dùng được, KHÔNG cần vào lại lat.\n\nHết hạn sau này: cứ gõ 'claude' và đăng nhập lại bước trên (đăng nhập tự gia hạn khi còn dùng nên hiếm khi phải làm lại)."
}

# Tuỳ chọn: đặt API key (tính theo token, dùng thay tài khoản).
_claude_apikey() {
  local k; k="$(ui_input "Dán ANTHROPIC_API_KEY (sk-ant-...):" "")" || return 0
  k="$(printf '%s' "$k" | tr -d '[:space:]')"
  if [ -n "$k" ]; then
    _claude_save_env ANTHROPIC_API_KEY "$k"
    ui_msg "Đã lưu API key. Áp dụng ở SSH MỚI (hoặc chạy: source ~/.bashrc) rồi gõ 'claude'."
  else
    warn "Bỏ trống - bỏ qua."
  fi
}

# Gỡ Claude Code: binary + đăng nhập. Giữ dòng PATH .local/bin (tool khác có thể dùng).
_claude_uninstall() {
  require_root
  ui_yesno "Gỡ Claude Code khỏi VPS này?\n(Xoá binary + phần đăng nhập)" || return 0
  _claude_ensure_path
  "$CLAUDE_BIN" uninstall >/dev/null 2>&1 && info "Đã chạy 'claude uninstall'." || true
  rm -f "$CLAUDE_BIN"
  rm -rf /root/.local/share/claude 2>/dev/null || true
  rm -f "$CLAUDE_ENV_FILE"
  rm -f /usr/local/bin/claude 2>/dev/null || true
  sed -i '/# Claude Code auth (lat)/d' "$CLAUDE_BASHRC" 2>/dev/null || true
  sed -i '\#claude-env#d' "$CLAUDE_BASHRC" 2>/dev/null || true
  if ui_yesno "Xoá luôn đăng nhập + cấu hình của Claude (~/.claude, ~/.config/claude)?"; then
    rm -rf /root/.claude /root/.config/claude 2>/dev/null || true
    ok "Đã xoá cả đăng nhập/cấu hình."
  fi
  ui_msg "Đã gỡ Claude Code."
}

act_install_claude() {
  require_root

  # Đã cài -> menu thao tác.
  if command -v claude >/dev/null 2>&1 || [ -x "$CLAUDE_BIN" ]; then
    _claude_ensure_path
    local ver; ver="$("$CLAUDE_BIN" --version 2>/dev/null || claude --version 2>/dev/null)"
    local c
    c="$(ui_menu "Claude Code đã cài (${ver:-?}). Làm gì?" \
      login     "Hướng dẫn đăng nhập tài khoản (gõ claude)" \
      apikey    "Dùng API key sk-ant-... thay tài khoản (tuỳ chọn)" \
      update    "Cập nhật (claude update)" \
      reinstall "Cài lại" \
      uninstall "Gỡ cài đặt Claude Code" \
      back      "Quay lại")" || return 0
    case "$c" in
      login)     _claude_login_help; return 0;;
      apikey)    _claude_apikey; return 0;;
      update)    "$CLAUDE_BIN" update 2>&1 | tail -5 || true; ui_msg "Đã chạy cập nhật Claude Code."; return 0;;
      reinstall) ;;  # rơi xuống phần cài
      uninstall) _claude_uninstall; return 0;;
      *)         return 0;;
    esac
  fi

  need_cmd curl || { ui_msg "Thiếu curl. Chạy: apt-get install -y curl"; return 1; }
  info "Cài Claude Code (native installer)..."
  curl -fsSL https://claude.ai/install.sh | bash || { ui_msg "Cài thất bại - kiểm mạng/quyền."; return 1; }

  _claude_ensure_path
  local ver; ver="$("$CLAUDE_BIN" --version 2>/dev/null)"
  [ -n "$ver" ] && ok "Đã cài Claude Code: ${ver}" || warn "Cài xong nhưng chưa verify được version."

  # Cài xong KHÔNG hỏi đăng nhập - chỉ hướng dẫn gõ 'claude' để login (lưu vĩnh viễn).
  _claude_login_help
}
