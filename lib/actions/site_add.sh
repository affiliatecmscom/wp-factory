#!/usr/bin/env bash
# actions/site_add.sh — thêm 1 WP site cô lập. Loại: affiliatecms | vanilla.
# Dùng: act_site_add [domain] [--type t] [--canonical c] [--email e] [--license k]

act_site_add() {
  require_root
  host_ready || { ui_msg "Host chưa sẵn sàng. Chạy: lat setup"; return 1; }

  local domain="" type="" canonical="" email="" license=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --type)      type="$2"; shift 2;;
      --canonical) canonical="$2"; shift 2;;
      --email)     email="$2"; shift 2;;
      --license)   license="$2"; shift 2;;
      -*)          shift;;
      *)           [ -z "$domain" ] && domain="$1"; shift;;
    esac
  done

  # --- Bước 1: domain ---
  while true; do
    [ -n "$domain" ] || domain="$(ui_input "Nhập domain (vd: my-deals.com):" "")" || return 1
    domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]' | sed 's/^www\.//; s#^https\?://##; s#/.*$##')"
    if ! valid_domain "$domain"; then
      ui_msg "Domain không hợp lệ: $domain"; domain=""; continue
    fi
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

  # --- Bước 3: canonical ---
  if [ -z "$canonical" ]; then
    canonical="$(ui_menu "HTTPS canonical (HTTPS luôn bật)" \
      non-www "non-www: ${domain} (www đẩy về non-www)" \
      www     "www: www.${domain} (non-www đẩy về www)" \
      none    "phục vụ cả hai, không redirect")" || return 1
    [ "$canonical" = "non-www" ] || ui_note "Nhớ tạo A record cho cả www.${domain}"
  fi

  # --- Bước 4: email ---
  [ -n "$email" ] || email="$(ui_input "Email admin WordPress:" "admin@${domain}")" || return 1

  # --- Bước 5: xác nhận ---
  ui_yesno "Tạo site?\n\nDomain : ${domain}\nLoại   : ${type}\nHTTPS  : ${canonical}\nEmail  : ${email}" || { info "Đã huỷ."; return 1; }

  # --- Bước 6: tiến hành ---
  local id; id="$(new_site_id)"
  local dir; dir="$(site_dir "$id")"
  local wp="${id}_wp" db="${id}_db"
  mkdir -p "$dir/wp-content"

  # rollback nếu lỗi
  _add_rollback() {
    warn "Lỗi khi tạo site — dọn dẹp..."
    docker compose -f "$dir/docker-compose.yml" --env-file "$dir/.env" down -v >/dev/null 2>&1 || true
    rm -rf "$dir"
    rm -f "${WPF_ROOT}/caddy/sites/${domain}.caddy"
  }

  local db_password; db_password="$(rand_pass 24)"
  render_template "${WPF_ROOT}/templates/site.compose.yml.tmpl" "DOMAIN=${domain}" "SLUG=${id}" > "$dir/docker-compose.yml" || { _add_rollback; return 1; }
  render_template "${WPF_ROOT}/templates/site.env.tmpl" "DOMAIN=${domain}" "DB_PASSWORD=${db_password}" > "$dir/.env"
  chmod 600 "$dir/.env"

  # site.conf
  site_set "$id" ID "$id"
  site_set "$id" DOMAIN "$domain"
  site_set "$id" TYPE "$type"
  site_set "$id" CANONICAL "$canonical"
  site_set "$id" ADMIN_EMAIL "$email"
  [ "$type" = "affiliatecms" ] && site_set "$id" LICENSE_KEY "$license"

  # mu-plugin proxy-ssl cho MỌI site (WP sau Caddy cần nhận HTTPS)
  mkdir -p "$dir/wp-content/mu-plugins"
  cp "${WPF_ROOT}/assets/mu-plugins/proxy-ssl.php" "$dir/wp-content/mu-plugins/proxy-ssl.php" 2>/dev/null || true

  # plugin/theme chỉ cho affiliatecms — tải từ app.lat.vn nếu payload chưa có
  if [ "$type" = "affiliatecms" ]; then
    if ! payload_present; then
      if [ -z "$license" ]; then
        warn "Chưa có payload cache và chưa có license — cần license để tải plugin lần đầu."
        _add_rollback; return 1
      fi
      info "Payload chưa có — tải từ app.lat.vn (gated theo license)..."
      fetch_payload "$license" || { warn "Không tải được payload."; _add_rollback; return 1; }
    fi
    info "Copy plugin/theme AffiliateCMS..."
    mkdir -p "$dir/wp-content/plugins" "$dir/wp-content/themes"
    rsync -a "${WPF_ROOT}/payload/plugins/" "$dir/wp-content/plugins/" || { _add_rollback; return 1; }
    rsync -a "${WPF_ROOT}/payload/themes/"  "$dir/wp-content/themes/"  || { _add_rollback; return 1; }
  fi

  info "Khởi động container..."
  docker compose -f "$dir/docker-compose.yml" --env-file "$dir/.env" up -d || { _add_rollback; return 1; }
  wait_for_db "$db" || { _add_rollback; return 1; }

  docker cp "${WPF_ROOT}/bin/wp-cli.phar" "${wp}:/usr/local/bin/wp-cli.phar" >/dev/null 2>&1

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
      if license_activate "$license" "$domain"; then
        ok "License đã activate cho ${domain}."
      else
        warn "Activate license thất bại (vd hết slot) — site vẫn chạy, xử lý sau trong wp-admin."
      fi
    else
      warn "Chưa có license — activate sau trong wp-admin."
    fi
  fi

  info "Cấu hình Caddy + reload..."
  write_caddy_block "$id" "$domain" "$canonical"
  caddy_reload || warn "Caddy reload lỗi — kiểm: docker logs wpfactory_caddy"

  ui_msg "Site đã sẵn sàng: https://${domain}\n\nWP Admin : https://${domain}/wp-admin\nUser     : ${admin_user}\nPassword : ${admin_pass}\nLoại     : ${type}\nThư mục  : ${dir}\n\n>> Trỏ A record '${domain}' về IP VPS này để cấp cert.\n>> Lưu lại mật khẩu trên (sẽ không hiện lại)."
}
