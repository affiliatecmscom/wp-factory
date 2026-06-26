#!/usr/bin/env bash
# actions/setup.sh — bootstrap host (Docker + UFW + wp-cli + network + Caddy + symlink lat).
# License: hỏi nhưng KHÔNG bắt buộc (site vanilla không cần). Idempotent.

act_setup() {
  require_root
  info "LATVPS — cài đặt host"

  # 1. Gói cơ bản
  info "Cập nhật apt + cài tiện ích cơ bản..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg openssl ufw rsync whiptail unzip git >/dev/null

  # 2. Docker CE + compose
  if need_cmd docker && docker compose version >/dev/null 2>&1; then
    ok "Docker đã có sẵn."
  else
    info "Cài Docker CE + compose plugin..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    local codename; codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
    systemctl enable --now docker >/dev/null 2>&1 || true
    ok "Docker đã cài."
  fi

  # 3. wp-cli.phar
  mkdir -p "${WPF_ROOT}/bin"
  if [ -f "${WPF_ROOT}/bin/wp-cli.phar" ]; then
    ok "wp-cli.phar đã có."
  else
    info "Tải wp-cli.phar..."
    curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
      -o "${WPF_ROOT}/bin/wp-cli.phar"
    chmod 0755 "${WPF_ROOT}/bin/wp-cli.phar"
    ok "wp-cli.phar đã tải."
  fi

  # 4. UFW
  info "Cấu hình UFW (22/80/443)..."
  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp  >/dev/null
  ufw allow 80/tcp  >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw --force enable >/dev/null
  ok "UFW bật: chỉ mở 22, 80, 443."

  # 5. Network chung
  if docker network inspect "$PROXY_NET" >/dev/null 2>&1; then
    ok "Network ${PROXY_NET} đã có."
  else
    docker network create "$PROXY_NET" >/dev/null
    ok "Đã tạo network ${PROXY_NET}."
  fi

  # 6. License (optional)
  if [ -n "$(stored_license)" ]; then
    ok "Đã có license lưu sẵn."
  else
    if ui_yesno "Nhập license AffiliateCMS bây giờ?\n(Khuyến nghị. Bỏ qua được — site vanilla không cần, site AffiliateCMS sẽ hỏi sau.)"; then
      ensure_license || warn "Chưa nhập được license — bỏ qua, nhập sau khi tạo site AffiliateCMS."
    else
      info "Bỏ qua license. Có thể nhập sau qua: lat license"
    fi
  fi

  # 7. ACME email + Caddy
  if [ ! -f "${WPF_ROOT}/caddy/.env" ]; then
    local acme_email; acme_email="$(ui_input "Email cho Let's Encrypt (cảnh báo cert hết hạn):" "")"
    printf 'ACME_EMAIL=%s\n' "$acme_email" > "${WPF_ROOT}/caddy/.env"
    chmod 600 "${WPF_ROOT}/caddy/.env"
  fi
  write_caddyfile
  info "Build Caddy (kèm plugin Cloudflare DNS; lần đầu ~2-3 phút)..."
  caddy_compose build >/dev/null 2>&1 || warn "Build Caddy gặp lỗi — kiểm mạng/docker."
  info "Khởi động Caddy trung tâm..."
  caddy_compose up -d
  ok "Caddy đang chạy (cổng 80/443)."

  # 8. Symlink lat
  ln -sf "${WPF_ROOT}/bin/lat" /usr/local/bin/lat
  chmod +x "${WPF_ROOT}/bin/lat"
  ok "Lệnh 'lat' đã sẵn sàng."

  ui_msg "Host đã sẵn sàng.\n\nGõ:  lat   để mở menu quản lý.\nTạo site nhanh:  lat add <domain>\n\nNhớ trỏ A record của domain về IP VPS này trước khi tạo site."

  # 9. Gợi ý tạo site đầu tiên
  if ui_yesno "Thêm site đầu tiên ngay?"; then
    act_site_add
  fi
}
