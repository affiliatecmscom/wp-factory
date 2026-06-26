#!/usr/bin/env bash
# actions/payload_sync.sh - cập nhật plugin/theme bundle (payload/).
# Mặc định: tải mới nhất từ license server (app.lat.vn) gated theo license.
# Dev: `lat payload-sync --from /path/to/wp-content` rsync từ nguồn local.
# Chỉ ảnh hưởng site affiliatecms tạo SAU. Site đã tạo update qua wp-admin.

act_payload_sync() {
  require_root

  # --- chế độ dev: rsync từ wp-content local ---
  if [ "${1:-}" = "--from" ]; then
    local src="${2:-}"
    [ -d "$src" ] || { warn "Không thấy nguồn: $src"; return 1; }
    local payload="${WPF_ROOT}/payload"
    mkdir -p "${payload}/plugins" "${payload}/themes"
    local p
    for p in affiliatecms-pro affiliatecms-ai; do
      [ -d "${src}/plugins/${p}" ] && { info "Sync ${p}..."; rsync -a --delete "${src}/plugins/${p}/" "${payload}/plugins/${p}/"; }
    done
    [ -d "${src}/themes/affiliateCMS-theme" ] && { info "Sync theme..."; rsync -a --delete "${src}/themes/affiliateCMS-theme/" "${payload}/themes/affiliateCMS-theme/"; }
    ok "Payload đã cập nhật (dev, từ ${src})."
    return 0
  fi

  # --- mặc định: tải từ license server ---
  local key; key="$(stored_license)"
  if [ -z "$key" ]; then
    ensure_license && key="$(stored_license)"
  fi
  [ -n "$key" ] || { warn "Cần license để tải payload."; return 1; }
  fetch_payload "$key"
}
