#!/usr/bin/env bash
# actions/site_add.sh — thêm 1 WordPress site cô lập (nginx + php-fpm + mariadb + redis).
# SSL: auto (Let's Encrypt) hoặc origin (Cloudflare Origin Cert). Loại: affiliatecms | vanilla.
# Dùng: act_site_add [domain] [--type t] [--ssl auto|origin] [--email e] [--license k]

act_site_add() {
  require_root
  host_ready || { ui_msg "Host chưa sẵn sàng. Chạy: lat setup"; return 1; }

  local domain="" type="" ssl="" email="" license=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --type)    type="$2"; shift 2;;
      --ssl)     ssl="$2"; shift 2;;
      --email)   email="$2"; shift 2;;
      --license) license="$2"; shift 2;;
      -*)        shift;;
      *)         [ -z "$domain" ] && domain="$1"; shift;;
    esac
  done

  # --- Bước 1: domain ---
  while true; do
    [ -n "$domain" ] || domain="$(ui_input "Nhập domain (vd: my-deals.com):" "")" || return 1
    domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]' | sed 's/^www\.//; s#^https\?://##; s#/.*$##')"
    if ! valid_domain "$domain"; then ui_msg "Domain không hợp lệ: $domain"; domain=""; continue; fi
    if id_exist="$(site_id_by_domain "$domain")"; then
      ui_msg "Domain đã tồn tại (site ${id_exist}). Chọn domain khác."; domain=""; continue
    fi
    break
  done

  # --- Bước 2: loại site ---
  if [ -z "$type" ]; then
    type="$(ui_menu "Loại site cho ${domain}" \
      affiliatecms "WordPress + AffiliateCMS (khuyến nghị)" \
      vanilla      "WordPress thường (không AffiliateCMS)")" || return 1
  fi

  # --- Lazy license nếu affiliatecms ---
  if [ "$type" = "affiliatecms" ] && [ -z "$license" ]; then
    if ! license="$(resolve_license_for_site)"; then
      local pick
      pick="$(ui_menu "Chưa có license hợp lệ. Tiếp theo?" \
        vanilla "Tạo site WordPress thường (không cần license)" \
        later   "Vẫn tạo AffiliateCMS, activate license sau" \
        cancel  "Huỷ")" || return 1
      case "$pick" in
        vanilla) type="vanilla"; license="";;
        later)   license="";;
        *) return 1;;
      esac
    fi
  fi

  # --- Bước 3: SSL ---
  if [ -z "$ssl" ]; then
    ssl="$(ui_menu "Chứng chỉ HTTPS cho ${domain}" \
      auto   "Auto Let's Encrypt (domain trỏ thẳng / Cloudflare DNS-only)" \
      origin "Cloudflare Origin Cert (bật proxy cam + SSL Full strict)")" || return 1
  fi

  local cert="" key=""
  if [ "$ssl" = "origin" ]; then
    ui_msg "Tạo Cloudflare Origin Certificate:\nCloudflare > SSL/TLS > Origin Server > Create Certificate\n(phủ ${domain} và *.${domain}). Copy phần CERTIFICATE và PRIVATE KEY."
    cert="$(ui_input "Dán nội dung CERTIFICATE (-----BEGIN CERTIFICATE-----...):" "")" || return 1
    key="$(ui_input "Dán nội dung PRIVATE KEY (-----BEGIN PRIVATE KEY-----...):" "")" || return 1
    if ! printf '%s' "$cert" | grep -q 'BEGIN CERTIFICATE' || ! printf '%s' "$key" | grep -q 'BEGIN'; then
      ui_msg "Cert/key không hợp lệ. Huỷ."; return 1
    fi
  fi

  # --- Bước 4: email ---
  [ -n "$email" ] || email="$(ui_input "Email admin WordPress:" "admin@${domain}")" || return 1

  # --- Bước 5: xác nhận ---
  ui_yesno "Tạo site?\n\nDomain : ${domain}\nLoại   : ${type}\nSSL    : ${ssl}\nEmail  : ${email}" || { info "Đã huỷ."; return 1; }

  # --- Bước 6: tiến hành ---
  local id; id="$(new_site_id)"
  local dir; dir="$(site_dir "$id")"
  local db="${id}_db" php="${id}_php"
  mkdir -p "$dir/wp-content"

  _add_rollback() {
    warn "Lỗi khi tạo site — dọn dẹp..."
    docker compose -f "$dir/docker-compose.yml" --env-file "$dir/.env" down -v >/dev/null 2>&1 || true
    rm -rf "$dir"
    ssl_remove_origin "$domain"; ssl_remove_origin "www.${domain}"
  }

  # compose + nginx.conf + .env
  render_template "${WPF_ROOT}/templates/wordpress/compose.yml.tmpl" "DOMAIN=${domain}" "ID=${id}" > "$dir/docker-compose.yml" || { _add_rollback; return 1; }
  cp "${WPF_ROOT}/templates/wordpress/nginx.conf" "$dir/nginx.conf"

  local db_password redis_password le_host="" le_email=""
  db_password="$(rand_pass 24)"; redis_password="$(rand_pass 20)"
  if [ "$ssl" = "auto" ]; then le_host="${domain},www.${domain}"; le_email="$email"; fi
  {
    printf 'DB_PASSWORD=%s\n' "$db_password"
    printf 'REDIS_PASSWORD=%s\n' "$redis_password"
    printf 'VIRTUAL_HOST=%s\n' "${domain},www.${domain}"
    printf 'LE_HOST=%s\n' "$le_host"
    printf 'LE_EMAIL=%s\n' "$le_email"
  } > "$dir/.env"
  chmod 600 "$dir/.env"

  # origin cert -> /opt/proxy/certs (cho cả apex + www)
  if [ "$ssl" = "origin" ]; then
    ssl_save_origin "$domain" "$cert" "$key"
    ssl_save_origin "www.${domain}" "$cert" "$key"
  fi

  # site.conf
  site_set "$id" ID "$id"
  site_set "$id" DOMAIN "$domain"
  site_set "$id" STACK "wordpress"
  site_set "$id" TYPE "$type"
  site_set "$id" SSL "$ssl"
  site_set "$id" DB "mariadb"
  site_set "$id" REDIS "yes"
  site_set "$id" ADMIN_EMAIL "$email"
  [ "$type" = "affiliatecms" ] && site_set "$id" LICENSE_KEY "$license"

  # mu-plugin proxy-ssl (WP sau proxy nhận biết HTTPS)
  mkdir -p "$dir/wp-content/mu-plugins"
  cp "${WPF_ROOT}/assets/mu-plugins/proxy-ssl.php" "$dir/wp-content/mu-plugins/proxy-ssl.php" 2>/dev/null || true

  # plugin/theme cho affiliatecms
  if [ "$type" = "affiliatecms" ]; then
    if ! payload_present; then
      [ -n "$license" ] || { warn "Chưa có payload cache và chưa có license."; _add_rollback; return 1; }
      info "Tải payload từ app.lat.vn..."
      fetch_payload "$license" || { _add_rollback; return 1; }
    fi
    info "Copy plugin/theme AffiliateCMS..."
    mkdir -p "$dir/wp-content/plugins" "$dir/wp-content/themes"
    rsync -a "${WPF_ROOT}/payload/plugins/" "$dir/wp-content/plugins/" || { _add_rollback; return 1; }
    rsync -a "${WPF_ROOT}/payload/themes/"  "$dir/wp-content/themes/"  || { _add_rollback; return 1; }
  fi

  info "Khởi động container (nginx + php-fpm + mariadb + redis)..."
  docker compose -f "$dir/docker-compose.yml" --env-file "$dir/.env" up -d || { _add_rollback; return 1; }
  wait_for_db "$db" || { _add_rollback; return 1; }

  docker cp "${WPF_ROOT}/bin/wp-cli.phar" "${php}:/usr/local/bin/wp-cli.phar" >/dev/null 2>&1

  info "Chờ WordPress core..."
  local i
  for i in $(seq 1 30); do wp_run "$id" core version >/dev/null 2>&1 && break; sleep 2; done
  wp_run "$id" core version >/dev/null 2>&1 || { warn "WP core chưa sẵn sàng."; _add_rollback; return 1; }

  local admin_user="admin" admin_pass; admin_pass="$(rand_pass 10)"
  if ! wp_run "$id" core is-installed >/dev/null 2>&1; then
    info "Cài WordPress..."
    wp_run "$id" core install --url="https://${domain}" --title="${domain}" \
      --admin_user="$admin_user" --admin_password="$admin_pass" \
      --admin_email="$email" --skip-email || { _add_rollback; return 1; }
  fi
  wp_run "$id" rewrite structure '/%postname%/' >/dev/null 2>&1 || true

  if [ "$type" = "affiliatecms" ]; then
    info "Kích hoạt theme + plugin AffiliateCMS..."
    wp_run "$id" theme activate affiliateCMS-theme >/dev/null 2>&1 || warn "Chưa activate được theme."
    wp_run "$id" plugin activate affiliatecms-pro affiliatecms-ai >/dev/null 2>&1 || warn "Chưa activate được plugin."
    if [ -n "$license" ]; then
      wp_run "$id" option update acms_license_key "$license" >/dev/null 2>&1 || true
      license_activate "$license" "$domain" && ok "License đã activate." || warn "Activate license thất bại — xử lý sau trong wp-admin."
    else
      warn "Chưa có license — activate sau trong wp-admin."
    fi
  fi

  # quyền để cài/sửa/xoá plugin+theme + upload media từ wp-admin (không đòi FTP)
  fix_perms "$id"

  local ssl_note="Cert Let's Encrypt sẽ tự cấp khi domain trỏ về VPS."
  [ "$ssl" = "origin" ] && ssl_note="Đã dùng Cloudflare Origin Cert. Bật proxy (cam) + SSL/TLS = Full (strict)."

  ui_msg "Site đã sẵn sàng: https://${domain}\n\nWP Admin : https://${domain}/wp-admin\nUser     : ${admin_user}\nPassword : ${admin_pass}\nLoại     : ${type}\nSSL      : ${ssl}\nThư mục  : ${dir}\n\n>> Trỏ A record '${domain}' (và www) về IP VPS này.\n>> ${ssl_note}\n>> Lưu lại mật khẩu trên (sẽ không hiện lại)."
}
