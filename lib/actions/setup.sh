#!/usr/bin/env bash
# actions/setup.sh - bootstrap host (Docker + UFW + wp-cli + network + Caddy + symlink lat).
# License: hỏi nhưng KHÔNG bắt buộc (site vanilla không cần). Idempotent.

act_setup() {
  require_root
  info "LATVPS - cài đặt host"

  # 1. Gói cơ bản
  info "Cập nhật apt + cài tiện ích cơ bản..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg openssl ufw rsync whiptail unzip git cron >/dev/null
  systemctl enable --now cron >/dev/null 2>&1 || true

  # 1.5 Swap - RAM < ~2GB thì tạo swap 2GB để giảm OOM (VPS nhỏ chạy MariaDB/PHP/Docker).
  local mem_mb swap_mb
  mem_mb="$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')"
  swap_mb="$(free -m 2>/dev/null | awk '/^Swap:/{print $2}')"
  if [ "${mem_mb:-9999}" -lt 1900 ] && [ "${swap_mb:-0}" -lt 1024 ] && [ ! -f /swapfile ]; then
    info "RAM ${mem_mb}MB (<2GB) - tạo swap 2GB giảm OOM..."
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none 2>/dev/null
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null \
      && { grep -q '/swapfile' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab; ok "Đã bật swap 2GB."; } \
      || warn "Tạo swap không thành (bỏ qua)."
    sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
    grep -q '^vm.swappiness' /etc/sysctl.conf 2>/dev/null || echo 'vm.swappiness=10' >> /etc/sysctl.conf
  elif [ -f /swapfile ] || [ "${swap_mb:-0}" -ge 1024 ]; then
    ok "Đã có swap."
  fi

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

  # 3.5 Hardening: fail2ban (chống brute-force SSH) + unattended-upgrades (tự vá bảo mật OS)
  info "Cài fail2ban + unattended-upgrades..."
  apt-get install -y -qq fail2ban unattended-upgrades >/dev/null 2>&1 || warn "Cài fail2ban/unattended-upgrades lỗi."
  if [ -d /etc/fail2ban ]; then
    cat > /etc/fail2ban/jail.local <<'F2B'
[sshd]
enabled = true
maxretry = 5
findtime = 10m
bantime = 1h
F2B
    systemctl enable --now fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true
  fi
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'AUU'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
AUU
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  ok "fail2ban + tự vá bảo mật OS đã bật."

  # 3.6 SSH key-only (TUỲ CHỌN, chỉ khi đã có SSH key -> tránh tự khoá mình ra)
  if [ -s /root/.ssh/authorized_keys ]; then
    if ui_yesno "Phát hiện SSH key. Tắt đăng nhập bằng MẬT KHẨU (chỉ cho key, an toàn hơn)?\n\nChỉ chọn Yes nếu chắc chắn vào được bằng key, nếu không sẽ tự khoá mình ra."; then
      sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config 2>/dev/null
      grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config 2>/dev/null || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
      [ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ] && sed -i 's/^PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config.d/50-cloud-init.conf 2>/dev/null || true
      systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
      ok "Đã tắt đăng nhập mật khẩu SSH (chỉ key)."
    fi
  else
    info "Chưa thấy SSH key của root -> giữ đăng nhập mật khẩu. Nên thêm SSH key rồi tắt password sau."
  fi

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
    if ui_yesno "Nhập license AffiliateCMS bây giờ?\n(Khuyến nghị. Bỏ qua được - site vanilla không cần, site AffiliateCMS sẽ hỏi sau.)"; then
      ensure_license || warn "Chưa nhập được license - bỏ qua, nhập sau khi tạo site AffiliateCMS."
    else
      info "Bỏ qua license. Có thể nhập sau qua: lat license"
    fi
  fi

  # 7. ACME email + front proxy (nginx-proxy + acme-companion)
  mkdir -p /opt/proxy/certs; chmod 700 /opt/proxy/certs 2>/dev/null || true
  if [ ! -f "${WPF_ROOT}/proxy/.env" ]; then
    local acme_email; acme_email="$(ui_input "Email cho Let's Encrypt (cảnh báo cert hết hạn):" "")"
    printf 'ACME_EMAIL=%s\n' "$acme_email" > "${WPF_ROOT}/proxy/.env"
    chmod 600 "${WPF_ROOT}/proxy/.env"
  fi
  info "Khởi động front proxy (nginx-proxy + acme-companion)..."
  proxy_compose pull -q >/dev/null 2>&1 || true
  proxy_compose up -d
  ok "Proxy đang chạy (cổng 80/443)."

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
