#!/usr/bin/env bash
# actions/site_add.sh - thêm 1 WordPress site cô lập (nginx + php-fpm + mariadb + redis).
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
      cloudflare "Cloudflare proxy CAM - tự tạo cert (đặt SSL/TLS = Full) [dễ nhất]" \
      auto       "Let's Encrypt (domain trỏ thẳng / Cloudflare DNS-only màu xám)" \
      origin     "Cloudflare Origin Cert (dán cert, SSL/TLS = Full strict)")" || return 1
  fi

  local cert="" key=""
  if [ "$ssl" = "origin" ]; then
    ui_msg "Tạo Cloudflare Origin Certificate:\nCloudflare > SSL/TLS > Origin Server > Create Certificate\n(phủ ${domain} và *.${domain}). Copy phần CERTIFICATE và PRIVATE KEY.\n\nỞ 2 bước sau, dán NGUYÊN khối nhiều dòng (gồm cả dòng BEGIN/END)."
    cert="$(ui_paste_block "Dán CERTIFICATE (cả -----BEGIN CERTIFICATE----- ... -----END CERTIFICATE-----):" 'END CERTIFICATE')"
    key="$(ui_paste_block "Dán PRIVATE KEY (cả -----BEGIN ... PRIVATE KEY----- ... -----END ... PRIVATE KEY-----):" 'END.*PRIVATE KEY')"
    if ! printf '%s' "$cert" | grep -q 'BEGIN CERTIFICATE' || ! printf '%s' "$key" | grep -q 'BEGIN.*PRIVATE KEY'; then
      ui_msg "Cert/key không hợp lệ (thiếu dòng BEGIN). Huỷ."; return 1
    fi
  fi

  # --- Bước 4: domain chính (www / non-www). Bên còn lại tự 301 về (WP redirect_canonical). ---
  local canon canon_host
  canon="$(ui_menu "Domain chính (chuẩn SEO; bên kia tự chuyển 301 về đây)" \
    non-www "${domain} (không www) [khuyến nghị]" \
    www     "www.${domain}")" || return 1
  [ "$canon" = "www" ] && canon_host="www.${domain}" || canon_host="${domain}"

  # --- Bước 5: email ---
  [ -n "$email" ] || email="$(ui_input "Email admin WordPress:" "admin@${domain}")" || return 1

  # --- Bước 6: xác nhận ---
  ui_yesno "Tạo site?\n\nDomain chính : https://${canon_host}\nLoại         : ${type}\nSSL          : ${ssl}\nEmail        : ${email}" || { info "Đã huỷ."; return 1; }

  # --- Bước 6: tiến hành ---
  local id; id="$(new_site_id)"
  local dir; dir="$(site_dir "$id")"
  local db="${id}_db" php="${id}_php"
  mkdir -p "$dir/wp-content"

  _add_rollback() {
    warn "Lỗi khi tạo site - dọn dẹp..."
    docker compose -f "$dir/docker-compose.yml" --env-file "$dir/.env" down -v >/dev/null 2>&1 || true
    rm -rf "$dir"
    site_link_remove "$domain"
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

  # cert -> /opt/proxy/certs (cho cả apex + www)
  if [ "$ssl" = "origin" ]; then
    ssl_save_origin "$domain" "$cert" "$key"
    ssl_save_origin "www.${domain}" "$cert" "$key"
  elif [ "$ssl" = "cloudflare" ]; then
    ssl_make_selfsigned "$domain" || { warn "Tạo cert tự ký lỗi (thiếu openssl?)."; _add_rollback; return 1; }
  fi

  # site.conf
  site_set "$id" ID "$id"
  site_set "$id" DOMAIN "$domain"
  site_set "$id" STACK "wordpress"
  site_set "$id" TYPE "$type"
  site_set "$id" SSL "$ssl"
  site_set "$id" CANONICAL "$canon"
  site_set "$id" DB "mariadb"
  site_set "$id" REDIS "yes"
  site_set "$id" ADMIN_EMAIL "$email"
  [ "$type" = "affiliatecms" ] && site_set "$id" LICENSE_KEY "$license"
  site_link_set "$id" "$domain"   # /opt/sites/<domain> -> /opt/sites/<id>

  # mu-plugin proxy-ssl (WP sau proxy nhận biết HTTPS)
  mkdir -p "$dir/wp-content/mu-plugins"
  cp "${WPF_ROOT}/assets/mu-plugins/proxy-ssl.php" "$dir/wp-content/mu-plugins/proxy-ssl.php" 2>/dev/null || true
  cp "${WPF_ROOT}/assets/mu-plugins/latvps-hardening.php" "$dir/wp-content/mu-plugins/latvps-hardening.php" 2>/dev/null || true

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
    # Child theme (giống demo) - ship kèm repo trong assets/, không gated.
    cp -a "${WPF_ROOT}/assets/themes/affiliateCMS-Child" "$dir/wp-content/themes/" 2>/dev/null \
      || warn "Không copy được child theme (assets/themes/affiliateCMS-Child)."
  fi

  info "Khởi động container (nginx + php-fpm + mariadb + redis)..."
  docker compose -f "$dir/docker-compose.yml" --env-file "$dir/.env" up -d || { _add_rollback; return 1; }
  wait_for_db "$db" "$db_password" || { _add_rollback; return 1; }

  docker cp "${WPF_ROOT}/bin/wp-cli.phar" "${php}:/usr/local/bin/wp-cli.phar" >/dev/null 2>&1

  info "Chờ WordPress core..."
  local i
  for i in $(seq 1 30); do wp_run "$id" core version >/dev/null 2>&1 && break; sleep 2; done
  wp_run "$id" core version >/dev/null 2>&1 || { warn "WP core chưa sẵn sàng."; _add_rollback; return 1; }

  local admin_user="admin" admin_pass; admin_pass="$(rand_pass 10)"
  if ! wp_run "$id" core is-installed >/dev/null 2>&1; then
    info "Cài WordPress..."
    wp_run "$id" core install --url="https://${canon_host}" --title="${domain}" \
      --admin_user="$admin_user" --admin_password="$admin_pass" \
      --admin_email="$email" --skip-email || { _add_rollback; return 1; }
  fi
  wp_run "$id" rewrite structure '/%postname%/' >/dev/null 2>&1 || true
  # Mặc định CHẶN search engine index -> tránh trùng lặp nội dung giữa các site học viên
  # (nội dung/cấu hình giống demo). Khi site chạy thật: Settings > Reading, bỏ tick Discourage.
  wp_run "$id" option update blog_public 0 >/dev/null 2>&1 || true

  if [ "$type" = "affiliatecms" ]; then
    # Plugin PHỤ THUỘC (giống demo iflmmo): Rank Math (AffiliateCMS tích hợp SEO/schema sâu) +
    # Classic Editor. Tải từ wordpress.org qua wp-cli - KHÔNG có sẽ thiếu SEO/schema.
    info "Cài plugin phụ thuộc (Rank Math SEO + Classic Editor)..."
    wp_run "$id" plugin install seo-by-rank-math classic-editor --activate >/dev/null 2>&1 \
      || warn "Cài Rank Math/Classic Editor lỗi (kiểm mạng) - vào wp-admin cài tay: seo-by-rank-math, classic-editor."
    info "Kích hoạt theme CON (giống demo) + plugin AffiliateCMS..."
    wp_run "$id" theme activate affiliateCMS-Child >/dev/null 2>&1 \
      || wp_run "$id" theme activate affiliateCMS-theme >/dev/null 2>&1 \
      || warn "Chưa activate được theme."
    # Xoá theme mặc định của WordPress core. Giữ lại cha affiliateCMS-theme (child cần kế thừa).
    local _t
    for _t in $(wp_run "$id" theme list --status=inactive --field=name 2>/dev/null); do
      [ "$_t" = "affiliateCMS-theme" ] && continue
      wp_run "$id" theme delete "$_t" >/dev/null 2>&1 || true
    done
    wp_run "$id" plugin activate affiliatecms-pro affiliatecms-ai >/dev/null 2>&1 || warn "Chưa activate được plugin."
    # Import config giống demo (Rank Math + settings + templates), đã strip license/API/affiliate_tag.
    info "Import cấu hình giống demo..."
    acms_import_config "$id"
    if [ -n "$license" ]; then
      wp_run "$id" option update acms_license_key "$license" >/dev/null 2>&1 || true
      license_activate "$license" "$domain" && ok "License đã activate." || warn "Activate license thất bại - xử lý sau trong wp-admin."
    else
      warn "Chưa có license - activate sau trong wp-admin."
    fi
    # Nội dung mẫu giống demo (mặc định Có). Cần internet để tải ảnh từ demo.
    if ui_yesno "Import nội dung mẫu giống demo (22 bài, 6 trang, menu, ảnh)?" yes; then
      acms_import_demo_content "$id" "$canon_host"
    else
      info "Bỏ qua nội dung demo - site bắt đầu trống."
    fi
  fi

  # quyền để cài/sửa/xoá plugin+theme + upload media từ wp-admin (không đòi FTP)
  fix_perms "$id"

  local ssl_note="Cert Let's Encrypt sẽ tự cấp khi domain trỏ về VPS."
  [ "$ssl" = "origin" ] && ssl_note="Đã dùng Cloudflare Origin Cert. Bật proxy (cam) + SSL/TLS = Full (strict)."
  [ "$ssl" = "cloudflare" ] && ssl_note="Đã tạo cert tự ký. Bật Cloudflare proxy (CAM) + đặt SSL/TLS = Full (KHÔNG phải strict)."

  local other_host="www.${domain}"; [ "$canon" = "www" ] && other_host="${domain}"
  ui_msg "Site đã sẵn sàng: https://${canon_host}\n\nWP Admin : https://${canon_host}/wp-admin\nUser     : ${admin_user}\nPassword : ${admin_pass}\nLoại     : ${type}\nSSL      : ${ssl}\nThư mục  : ${SITES_ROOT}/${domain}  (-> ${dir})\n\n>> Trỏ A record '${domain}' (và www) về IP VPS này.\n>> ${ssl_note}\n>> Domain chính: ${canon_host} (https://${other_host} tự 301 về domain chính).\n>> Search engine: ĐANG CHẶN index (chống trùng lặp). Khi chạy thật: Settings > Reading, bỏ tick 'Discourage search engines'.\n>> Lưu lại mật khẩu trên (sẽ không hiện lại)."
}
