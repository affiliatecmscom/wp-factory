#!/usr/bin/env bash
# latvps.sh - BOOTSTRAP 1 lệnh cho VPS Ubuntu trắng.
# Dùng:  curl -fsSL https://cdn.lat.vn/latvps.sh | sudo bash
# Kéo bộ latvps về /opt/latvps rồi chạy setup (Docker/UFW/Caddy/license/symlink lat).
set -euo pipefail

# Nguồn code (đặt repo thật khi phát hành; có thể override bằng biến môi trường).
LATVPS_REPO="${LATVPS_REPO:-https://github.com/affiliatecmscom/latvps.git}"
DEST="/opt/latvps"

[ "$(id -u)" -eq 0 ] || { echo "Vui lòng chạy bằng root (sudo)."; exit 1; }

echo "[*] LATVPS bootstrap"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl ca-certificates >/dev/null

if [ -x "${DEST}/bin/lat" ]; then
  echo "[OK] Đã có ${DEST} - dùng bản hiện tại."
elif [ -d "${DEST}/.git" ]; then
  echo "[*] Cập nhật ${DEST}..."
  git -C "$DEST" pull --ff-only || true
else
  echo "[*] Tải code về ${DEST}..."
  git clone --depth 1 "$LATVPS_REPO" "$DEST"
fi

chmod +x "${DEST}/bin/lat"
echo "[*] Chạy setup host..."
exec "${DEST}/bin/lat" setup
