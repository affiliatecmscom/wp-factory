#!/usr/bin/env bash
# lib/common.sh - helper dùng chung cho mọi script của LATVPS.
# Source file này ở đầu mỗi script:  source "$(dirname "$0")/lib/common.sh"

# Đường dẫn gốc của factory (thư mục chứa lib/).
WPF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITES_ROOT="/opt/sites"
PROXY_NET="latvps_proxy"
LICENSE_FILE="${WPF_ROOT}/.license"
LICENSE_SERVER="https://app.lat.vn/wp-json/acms-license/v1"

# ----- output có màu -----
c_red='\033[0;31m'; c_grn='\033[0;32m'; c_ylw='\033[0;33m'; c_blu='\033[0;34m'; c_rst='\033[0m'
# info/ok/warn/die -> stderr (log), để stdout dành cho giá trị trả về mà $() bắt.
info()  { printf "${c_blu}[*]${c_rst} %s\n" "$*" >&2; }
ok()    { printf "${c_grn}[OK]${c_rst} %s\n" "$*" >&2; }
warn()  { printf "${c_ylw}[!]${c_rst} %s\n" "$*" >&2; }
die()   { printf "${c_red}[X] %s${c_rst}\n" "$*" >&2; exit 1; }

# Bắt buộc chạy quyền root (cần cho docker, ufw, /opt).
require_root() {
  [ "$(id -u)" -eq 0 ] || die "Vui lòng chạy bằng quyền root (sudo)."
}

# Kiểm tra một lệnh có tồn tại không.
need_cmd() { command -v "$1" >/dev/null 2>&1; }

# Chuẩn hoá domain -> slug an toàn cho tên container/network/volume.
# vd: best-deals.example.com -> best-deals-example-com
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

# Validate domain cơ bản (có dấu chấm, ký tự hợp lệ, không phải localhost/IP rỗng).
valid_domain() {
  printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
}

# Sinh mật khẩu ngẫu nhiên (mặc định 32 hex = 16 byte).
rand_pass() { openssl rand -hex "${1:-24}"; }

# Render template: thay token dạng __KEY__ bằng giá trị truyền vào.
# Dùng:  render_template templates/x.tmpl SLUG=foo MEM=512m > out
# Dùng __KEY__ (KHÔNG dùng ${VAR}) để token render-time không đụng ${DB_PASSWORD}
# vốn để nguyên cho docker compose đọc từ .env lúc chạy.
render_template() {
  local tmpl="$1"; shift
  [ -f "$tmpl" ] || die "Không tìm thấy template: $tmpl"
  local content; content="$(cat "$tmpl")"
  local pair key val
  for pair in "$@"; do
    key="${pair%%=*}"; val="${pair#*=}"
    # Escape ký tự đặc biệt của sed trong giá trị thay thế.
    val="$(printf '%s' "$val" | sed -e 's/[\/&|]/\\&/g')"
    content="$(printf '%s' "$content" | sed "s|__${key}__|${val}|g")"
  done
  printf '%s\n' "$content"
}

# Chờ MariaDB của 1 site sẵn sàng (truyền tên container db).
wait_for_db() {
  local db_container="$1" db_pass="$2" tries="${3:-60}"
  info "Chờ database '${db_container}' sẵn sàng..."
  for i in $(seq 1 "$tries"); do
    # Ép TCP (-h127.0.0.1) + user 'wordpress': chỉ thành công khi server THẬT đã mở mạng
    # và user/DB đã tạo xong. Tránh false-positive của server tạm (socket-only) lúc init.
    if [ -n "$db_pass" ]; then
      if docker exec -e MYSQL_PWD="$db_pass" "$db_container" \
           mariadb -h127.0.0.1 -uwordpress wordpress -e 'SELECT 1' >/dev/null 2>&1; then
        ok "Database sẵn sàng."
        return 0
      fi
    else
      # vanilla/không pass: vẫn ép TCP để chắc server thật đã lên.
      if docker exec "$db_container" sh -c 'mariadb-admin ping -h127.0.0.1 --silent' >/dev/null 2>&1; then
        ok "Database sẵn sàng."
        return 0
      fi
    fi
    sleep 2
  done
  die "Database '${db_container}' không phản hồi sau $((tries*2))s."
}

# Gọi license server kiểm tra key. Trả 0 + in JSON nếu key hợp lệ và status=active.
# API dùng application/x-www-form-urlencoded (KHÔNG phải JSON).
# /license-info trả {"success":true,"license":{"status":"active",...}}
license_check() {
  local key="$1"
  [ -n "$key" ] || return 1
  local resp
  resp="$(curl -fsS --max-time 15 \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "license_key=${key}" \
    "${LICENSE_SERVER}/license-info" 2>/dev/null)" || return 1
  printf '%s' "$resp" | grep -q '"success"[[:space:]]*:[[:space:]]*false' && return 1
  printf '%s' "$resp" | grep -q '"error"' && return 1
  printf '%s' "$resp" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"active"' || return 1
  printf '%s\n' "$resp"
  return 0
}

# Activate 1 domain dưới license. Trả 0 nếu thành công.
# In message lỗi (vd hết slot domain) nếu fail.
license_activate() {
  local key="$1" domain="$2"
  [ -n "$key" ] && [ -n "$domain" ] || return 1
  local resp
  resp="$(curl -fsS --max-time 15 \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "license_key=${key}" \
    --data-urlencode "domain=${domain}" \
    --data-urlencode "code_hash=" \
    "${LICENSE_SERVER}/activate" 2>/dev/null)" || { warn "Không gọi được license server."; return 1; }
  if printf '%s' "$resp" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
    return 0
  fi
  warn "Activate thất bại: $(printf '%s' "$resp" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  return 1
}

# Đọc license key đã lưu lúc install (nếu có).
stored_license() {
  [ -f "$LICENSE_FILE" ] && tr -d '[:space:]' < "$LICENSE_FILE" || true
}

# Lưu license key (validate xong mới gọi).
save_license() {
  umask 077
  printf '%s\n' "$1" > "$LICENSE_FILE"
  chmod 600 "$LICENSE_FILE"
}

# Deactivate domain khỏi license (giải phóng slot). Best-effort.
license_deactivate() {
  local key="$1" domain="$2"
  [ -n "$key" ] && [ -n "$domain" ] || return 0
  curl -fsS --max-time 15 -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "license_key=${key}" --data-urlencode "domain=${domain}" \
    "${LICENSE_SERVER}/deactivate" >/dev/null 2>&1
}

# ============================================================
# Site registry - mỗi site 1 thư mục /opt/sites/<id> + site.conf.
# ID bất biến (sinh lúc tạo); domain là thuộc tính đổi được.
# ============================================================
BACKUPS_ROOT="/opt/backups"

# Sinh ID site bất biến, vd s-a1b2c3.
new_site_id() { printf 's-%s' "$(openssl rand -hex 3)"; }

site_dir()  { printf '%s/%s' "$SITES_ROOT" "$1"; }
site_conf() { printf '%s/%s/site.conf' "$SITES_ROOT" "$1"; }

# site_get <id> KEY -> giá trị field trong site.conf.
site_get() {
  local f; f="$(site_conf "$1")"
  [ -f "$f" ] || return 1
  sed -n "s/^$2=//p" "$f" | head -n1
}

# site_set <id> KEY VALUE -> thêm/ghi đè field.
site_set() {
  local id="$1" key="$2" val="$3" f esc; f="$(site_conf "$id")"
  touch "$f"; chmod 600 "$f"
  esc="$(printf '%s' "$val" | sed -e 's/[\/&|]/\\&/g')"
  if grep -q "^${key}=" "$f" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${esc}|" "$f"
  else
    printf '%s=%s\n' "$key" "$val" >> "$f"
  fi
}

# Liệt kê mọi site id (thư mục THẬT có site.conf). Bỏ qua symlink domain (tránh đếm trùng).
list_site_ids() {
  [ -d "$SITES_ROOT" ] || return 0
  local d
  for d in "$SITES_ROOT"/*/; do
    [ -L "${d%/}" ] && continue
    [ -f "${d}site.conf" ] && basename "$d"
  done
}

# Symlink thân thiện /opt/sites/<domain> -> /opt/sites/<id> (để cd theo tên domain).
# Thư mục THẬT vẫn là <id> (bất biến) -> đổi domain chỉ đổi symlink, container giữ nguyên.
site_link_set() {
  local id="$1" domain="$2"
  [ -n "$domain" ] || return 0
  ln -sfn "$(site_dir "$id")" "${SITES_ROOT}/${domain}" 2>/dev/null || true
}
site_link_remove() {
  local domain="$1"
  [ -n "$domain" ] && [ -L "${SITES_ROOT}/${domain}" ] && rm -f "${SITES_ROOT}/${domain}" || true
}

# Tìm id theo domain.
site_id_by_domain() {
  local domain="$1" id
  for id in $(list_site_ids); do
    [ "$(site_get "$id" DOMAIN)" = "$domain" ] && { printf '%s' "$id"; return 0; }
  done
  return 1
}

# Nhận id HOẶC domain -> trả về id.
resolve_site() {
  local arg="$1"
  [ -n "$arg" ] || return 1
  [ -f "$(site_conf "$arg")" ] && { printf '%s' "$arg"; return 0; }
  site_id_by_domain "$arg"
}

# wp-cli trong container php của site: wp_run <id> <args...>
wp_run() {
  local id="$1"; shift
  docker exec "${id}_php" php /usr/local/bin/wp-cli.phar --allow-root --path=/var/www/html "$@"
}

# ============================================================
# Front proxy (nginx-proxy + acme-companion). Routing qua env VIRTUAL_HOST của container _web
# -> KHÔNG cần file block per-domain. acme-companion tự cấp Let's Encrypt khi có LETSENCRYPT_HOST.
# ============================================================
PROXY_DIR="/opt/proxy"
PROXY_CERTS="${PROXY_DIR}/certs"

# docker compose cho stack proxy (LUÔN nạp proxy/.env: ACME_EMAIL).
proxy_compose() {
  [ -f "${WPF_ROOT}/proxy/.env" ] || touch "${WPF_ROOT}/proxy/.env"
  docker compose -f "${WPF_ROOT}/proxy/docker-compose.yml" --env-file "${WPF_ROOT}/proxy/.env" "$@"
}

# Lưu Cloudflare Origin Certificate cho 1 domain (nginx-proxy dùng thay vì Let's Encrypt).
ssl_save_origin() {
  local domain="$1" cert="$2" key="$3"
  mkdir -p "$PROXY_CERTS"; chmod 700 "$PROXY_CERTS" 2>/dev/null || true
  printf '%s\n' "$cert" > "${PROXY_CERTS}/${domain}.crt"
  printf '%s\n' "$key"  > "${PROXY_CERTS}/${domain}.key"
  chmod 600 "${PROXY_CERTS}/${domain}.crt" "${PROXY_CERTS}/${domain}.key"
}

ssl_remove_origin() {
  local domain="$1"
  rm -f "${PROXY_CERTS}/${domain}.crt" "${PROXY_CERTS}/${domain}.key"
}

# Tạo cert TỰ KÝ cho domain + www (dùng khi giữ Cloudflare proxy cam, đặt SSL/TLS = Full).
# Cloudflare "Full" chấp nhận cert tự ký -> không cần Origin Cert, không cần dán gì.
# Origin vẫn phục vụ 443 (proto đúng, tránh redirect loop của chế độ Flexible/HTTP).
ssl_make_selfsigned() {
  local domain="$1"
  mkdir -p "$PROXY_CERTS"; chmod 700 "$PROXY_CERTS" 2>/dev/null || true
  local crt="${PROXY_CERTS}/${domain}.crt" key="${PROXY_CERTS}/${domain}.key"
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "$key" -out "$crt" \
    -subj "/CN=${domain}" \
    -addext "subjectAltName=DNS:${domain},DNS:www.${domain}" >/dev/null 2>&1 || return 1
  chmod 600 "$crt" "$key"
  # nginx-proxy khớp cert theo tên host -> tạo bản cho www trỏ cùng cert/key.
  cp -f "$crt" "${PROXY_CERTS}/www.${domain}.crt"
  cp -f "$key" "${PROXY_CERTS}/www.${domain}.key"
  chmod 600 "${PROXY_CERTS}/www.${domain}.crt" "${PROXY_CERTS}/www.${domain}.key"
}

# Sửa quyền wp-content để WordPress cài/sửa/xoá plugin+theme + upload media (không đòi FTP).
# Chạy chown TRONG container php (đúng uid www-data của image).
fix_perms() {
  local id="$1"
  docker exec "${id}_php" chown -R www-data:www-data /var/www/html/wp-content 2>/dev/null || true
}

# Import config AffiliateCMS + Rank Math (giống demo) vào site. Bundle đã strip license/API/secret.
# Dùng wp eval + update_option (serialize đúng). Chỉ áp cho site affiliatecms.
acms_import_config() {
  local id="$1" f="${WPF_ROOT}/assets/acms-config/options.json"
  [ -f "$f" ] || { info "Không có config bundle - bỏ qua import (dùng default plugin)."; return 0; }
  docker cp "$f" "${id}_php:/tmp/acms-config.json" >/dev/null 2>&1 || { warn "Copy config vào container lỗi."; return 1; }
  wp_run "$id" eval 'foreach((array)json_decode(file_get_contents("/tmp/acms-config.json"),true) as $k=>$v){ update_option($k,$v); }' >/dev/null 2>&1 \
    && ok "Đã import config (giống demo, không gồm license/API)." || warn "Import config gặp lỗi."
  # Rank Math: bỏ qua setup wizard
  wp_run "$id" eval 'update_option("rank_math_is_configured",1); update_option("rank_math_registration_skip",1);' >/dev/null 2>&1 || true
  docker exec "${id}_php" rm -f /tmp/acms-config.json >/dev/null 2>&1 || true
}

# Tải BUNDLE nội dung demo (DB+uploads đã sanitize) từ app.lat.vn, gated theo license.
# Trả về đường dẫn thư mục đã giải nén (chứa database.sql + uploads/ + bundle.info) qua stdout.
fetch_demo_bundle() {
  local key="$1" outdir="$2"
  [ -n "$key" ] || { warn "Cần license để tải bundle demo."; return 1; }
  ensure_unzip >/dev/null 2>&1 || true
  local tmp; tmp="$(mktemp -d)"
  if ! curl -fsS --max-time 300 -o "${tmp}/demo-bundle.tar.gz" \
      "${LICENSE_SERVER}/update/demo/download?license_key=${key}"; then
    warn "Tải bundle demo thất bại (license còn hạn? server có bundle chưa?)."; rm -rf "$tmp"; return 1
  fi
  mkdir -p "$outdir"
  tar -xzf "${tmp}/demo-bundle.tar.gz" -C "$outdir" 2>/dev/null || { warn "Giải nén bundle demo lỗi."; rm -rf "$tmp" "$outdir"; return 1; }
  rm -rf "$tmp"
  [ -f "${outdir}/database.sql" ] || { warn "Bundle thiếu database.sql."; return 1; }
  return 0
}

# Import NỘI DUNG + CẤU HÌNH demo bằng FULL CLONE (DB + uploads) -> giống hệt demo:
# sản phẩm/từ khóa (bảng acms), logo/sidebar/widget (theme_mods), bài/trang/menu/ảnh.
# Nạp database.sql (đã sanitize secret) đè DB site, copy uploads, tạo lại admin (dump bỏ users),
# đổi URL demo -> canon_host. Cần license (gated tải bundle).
acms_import_demo_content() {
  local id="$1" canon_host="$2" admin_user="$3" admin_pass="$4" admin_email="$5" license="$6"
  [ -n "$license" ] || { warn "Chưa có license - bỏ qua nội dung demo (gated)."; return 1; }
  local dir; dir="$(site_dir "$id")"
  local db_pass; db_pass="$(grep -E '^DB_PASSWORD=' "${dir}/.env" | head -1 | cut -d= -f2-)"
  [ -n "$db_pass" ] || { warn "Không đọc được DB_PASSWORD site."; return 1; }

  local ex; ex="$(mktemp -d)"
  info "Tải bundle nội dung demo từ app.lat.vn..."
  fetch_demo_bundle "$license" "$ex" || { rm -rf "$ex"; return 1; }

  info "Nạp database demo (đè) ..."
  if ! docker exec -i "${id}_db" mariadb -uwordpress -p"$db_pass" wordpress < "${ex}/database.sql"; then
    warn "Nạp database demo lỗi."; rm -rf "$ex"; return 1
  fi
  if [ -d "${ex}/uploads" ]; then
    info "Copy uploads demo..."
    mkdir -p "${dir}/wp-content/uploads"
    rsync -a "${ex}/uploads/" "${dir}/wp-content/uploads/" 2>/dev/null || cp -a "${ex}/uploads/." "${dir}/wp-content/uploads/" 2>/dev/null || true
  fi
  local demo_host; demo_host="$(grep -E '^demo_host=' "${ex}/bundle.info" 2>/dev/null | cut -d= -f2-)"
  [ -n "$demo_host" ] || demo_host="iflmmo.affiliatecms.com"
  rm -rf "$ex"

  # Dump bỏ data wp_users NHƯNG structure giữ AUTO_INCREMENT cũ (=4) -> admin mới sẽ là ID 4,
  # trong khi MỌI bài demo author = ID 1 -> mất tác giả. Fix CHẮC CHẮN: reset AUTO_INCREMENT=1
  # để admin mới = ID 1 (đúng author demo). Vẫn reassign như lưới phụ.
  info "Tạo tài khoản admin..."
  # Reset AUTO_INCREMENT=1 -> admin mới = ID 1 = đúng author của mọi bài demo (giữ tác giả).
  docker exec "${id}_db" mariadb -uwordpress -p"$db_pass" wordpress \
    -e "ALTER TABLE wp_users AUTO_INCREMENT=1;" >/dev/null 2>&1 || true
  local admin_id
  admin_id="$(wp_run "$id" user create "$admin_user" "$admin_email" --role=administrator --user_pass="$admin_pass" --porcelain 2>/dev/null | tr -d '[:space:]')"
  printf '%s' "$admin_id" | grep -qE '^[0-9]+$' \
    || admin_id="$(wp_run "$id" user list --role=administrator --field=ID 2>/dev/null | head -1 | tr -d '[:space:]')"
  if printf '%s' "$admin_id" | grep -qE '^[0-9]+$'; then
    # Lưới phụ (phòng admin_id != 1): gán lại tác giả mọi bài/trang về admin bằng SQL trực tiếp.
    docker exec "${id}_db" mariadb -uwordpress -p"$db_pass" wordpress \
      -e "UPDATE wp_posts SET post_author=${admin_id} WHERE post_author>0;" >/dev/null 2>&1 || true
    ok "Admin (ID ${admin_id}) + tác giả bài viết đã gán."
  else
    warn "Không tạo được admin sau clone - kiểm tra wp-admin."
  fi

  info "Đổi URL demo -> ${canon_host} ..."
  wp_run "$id" search-replace "$demo_host" "$canon_host" --all-tables --skip-columns=guid >/dev/null 2>&1 || true
  wp_run "$id" option update home "https://${canon_host}" >/dev/null 2>&1 || true
  wp_run "$id" option update siteurl "https://${canon_host}" >/dev/null 2>&1 || true
  wp_run "$id" option update blog_public 0 >/dev/null 2>&1 || true
  wp_run "$id" cache flush >/dev/null 2>&1 || true
  ok "Đã clone nội dung + cấu hình demo (sản phẩm, từ khóa, logo, sidebar, bài, ảnh)."
}

# Host đã bootstrap chưa? (docker + network + wp-cli).
host_ready() {
  need_cmd docker && docker network inspect "$PROXY_NET" >/dev/null 2>&1 \
    && [ -f "${WPF_ROOT}/bin/wp-cli.phar" ]
}

# ============================================================
# Payload - tải plugin/theme AffiliateCMS từ license server (app.lat.vn),
# gated theo license. Repo KHÔNG chứa source plugin (payload/ gitignore).
# ============================================================

ensure_unzip() {
  need_cmd unzip && return 0
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq unzip >/dev/null 2>&1
  need_cmd unzip
}

# Payload đã có đủ plugin/theme chính chưa?
payload_present() {
  [ -d "${WPF_ROOT}/payload/plugins/affiliatecms-pro" ] \
    && [ -d "${WPF_ROOT}/payload/plugins/affiliatecms-ai" ] \
    && [ -d "${WPF_ROOT}/payload/themes/affiliateCMS-theme" ]
}

# Tải payload mới nhất từ license server. Cần license active. Trả 0 nếu đủ.
# Plugin: gated (plugin= + license_key=). Theme: chỉ slug=. Mỗi zip có 1 thư mục gốc đúng tên.
fetch_payload() {
  local key="$1"
  [ -n "$key" ] || { warn "Cần license để tải payload."; return 1; }
  ensure_unzip || { warn "Thiếu unzip - không giải nén được payload."; return 1; }
  local payload="${WPF_ROOT}/payload" tmp; tmp="$(mktemp -d)"
  mkdir -p "${payload}/plugins" "${payload}/themes"
  local rc=0 p

  for p in affiliatecms-pro affiliatecms-ai; do
    info "Tải plugin ${p} từ app.lat.vn..."
    if curl -fsS --max-time 120 -o "${tmp}/${p}.zip" \
        "${LICENSE_SERVER}/update/download?plugin=${p}&license_key=${key}&domain=factory"; then
      rm -rf "${payload}/plugins/${p}"
      unzip -q -o "${tmp}/${p}.zip" -d "${payload}/plugins/" || { warn "Giải nén ${p} lỗi."; rc=1; }
    else
      warn "Tải ${p} thất bại (license còn hạn?)."; rc=1
    fi
  done

  info "Tải theme affiliateCMS-theme..."
  if curl -fsS --max-time 120 -o "${tmp}/theme.zip" \
      "${LICENSE_SERVER}/update/theme/download?slug=affiliateCMS-theme"; then
    rm -rf "${payload}/themes/affiliateCMS-theme"
    unzip -q -o "${tmp}/theme.zip" -d "${payload}/themes/" || { warn "Giải nén theme lỗi."; rc=1; }
  else
    warn "Tải theme thất bại."; rc=1
  fi

  rm -rf "$tmp"
  [ "$rc" = 0 ] && ok "Payload đã cập nhật từ app.lat.vn." || warn "Payload tải chưa đầy đủ."
  return "$rc"
}
