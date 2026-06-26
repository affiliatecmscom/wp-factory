#!/usr/bin/env bash
# actions/self_update.sh - tự cập nhật bộ lệnh lat.
# Ưu tiên git pull (nếu /opt/latvps là git repo); fallback tải tarball.
# GIỮ nguyên: .license, proxy/.env, payload/, /opt/sites (đều ngoài git / gitignore).

# Nguồn tarball khi KHÔNG phải git (đặt URL thật khi phát hành):
LATVPS_TARBALL_URL="${LATVPS_TARBALL_URL:-https://cdn.lat.vn/latvps.tar.gz}"

_current_version() { cat "${WPF_ROOT}/VERSION" 2>/dev/null || echo "0.0.0"; }

# Kiểm tra cú pháp mọi script bash trong cây cho trước. Trả 0 nếu sạch.
_syntax_ok() {
  local root="$1" f
  while IFS= read -r f; do
    bash -n "$f" 2>/dev/null || { warn "Lỗi cú pháp: $f"; return 1; }
  done < <(find "$root" \( -name '*.sh' -o -path '*/bin/lat' \) -type f)
  return 0
}

act_self_update() {
  require_root
  info "Phiên bản hiện tại: $(_current_version)"

  if [ -d "${WPF_ROOT}/.git" ] && need_cmd git; then
    info "Cập nhật qua git..."
    if git -C "$WPF_ROOT" pull --ff-only >/dev/null 2>&1; then
      _syntax_ok "$WPF_ROOT" || { warn "Bản mới có lỗi cú pháp - cân nhắc rollback bằng git."; return 1; }
      chmod +x "${WPF_ROOT}/bin/lat" 2>/dev/null || true
      ln -sf "${WPF_ROOT}/bin/lat" /usr/local/bin/lat
      ui_msg "Đã cập nhật lat qua git.\nPhiên bản: $(_current_version)\nChạy lại 'lat' để dùng bản mới."
      return 0
    fi
    warn "git pull thất bại."; return 1
  fi

  # Fallback tarball
  info "Tải bản mới từ ${LATVPS_TARBALL_URL}..."
  local tmp; tmp="$(mktemp -d)"
  if ! curl -fsSL "$LATVPS_TARBALL_URL" -o "${tmp}/latvps.tar.gz"; then
    warn "Tải tarball thất bại."; rm -rf "$tmp"; return 1
  fi
  tar -C "$tmp" -xzf "${tmp}/latvps.tar.gz" || { warn "Giải nén lỗi."; rm -rf "$tmp"; return 1; }
  # tarball giả định giải nén ra thư mục latvps/
  local newroot; newroot="$(find "$tmp" -maxdepth 2 -name VERSION -printf '%h\n' | head -1)"
  [ -n "$newroot" ] || newroot="${tmp}/latvps"
  _syntax_ok "$newroot" || { warn "Bản mới lỗi cú pháp - huỷ."; rm -rf "$tmp"; return 1; }

  info "Áp bản mới (giữ license/sites/payload)..."
  rsync -a --delete \
    --exclude '.license' --exclude 'proxy/.env' \
    --exclude 'payload/' --exclude 'bin/wp-cli.phar' \
    "${newroot}/" "${WPF_ROOT}/"
  chmod +x "${WPF_ROOT}/bin/lat" 2>/dev/null || true
  ln -sf "${WPF_ROOT}/bin/lat" /usr/local/bin/lat
  rm -rf "$tmp"
  ui_msg "Đã cập nhật lat.\nPhiên bản: $(_current_version)\nChạy lại 'lat'."
}
