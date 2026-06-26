#!/usr/bin/env bash
# lib/common.sh — helper dùng chung cho mọi script của LATVPS.
# Source file này ở đầu mỗi script:  source "$(dirname "$0")/lib/common.sh"

# Đường dẫn gốc của factory (thư mục chứa lib/).
WPF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITES_ROOT="/opt/sites"
PROXY_NET="wpfactory_proxy"
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
  local db_container="$1" tries="${2:-60}"
  info "Chờ database '${db_container}' sẵn sàng..."
  for i in $(seq 1 "$tries"); do
    if docker exec "$db_container" mariadb-admin ping -uroot --silent >/dev/null 2>&1 \
       || docker exec "$db_container" sh -c 'mariadb-admin ping --silent' >/dev/null 2>&1; then
      ok "Database sẵn sàng."
      return 0
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
# Site registry — mỗi site 1 thư mục /opt/sites/<id> + site.conf.
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

# Liệt kê mọi site id (thư mục có site.conf).
list_site_ids() {
  [ -d "$SITES_ROOT" ] || return 0
  local d
  for d in "$SITES_ROOT"/*/; do
    [ -f "${d}site.conf" ] && basename "$d"
  done
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

# wp-cli trong container wp của site: wp_run <id> <args...>
wp_run() {
  local id="$1"; shift
  docker exec "${id}_wp" php /usr/local/bin/wp-cli.phar --allow-root --path=/var/www/html "$@"
}

# ============================================================
# Caddy — sinh block theo canonical + reload.
# ============================================================

# caddy_block <domain> <wp_container> <canonical:www|non-www|none> -> stdout
caddy_block() {
  local domain="$1" wp="$2" canonical="$3"
  printf '# %s (sinh bởi lat)\n' "$domain"
  case "$canonical" in
    www)
      cat <<EOF
${domain}, www.${domain} {
	encode zstd gzip
	@nowww host ${domain}
	redir @nowww https://www.${domain}{uri} permanent
	reverse_proxy ${wp}:80
}
EOF
      ;;
    none)
      cat <<EOF
${domain}, www.${domain} {
	encode zstd gzip
	reverse_proxy ${wp}:80
}
EOF
      ;;
    *)  # non-www (mặc định)
      cat <<EOF
${domain}, www.${domain} {
	encode zstd gzip
	@www host www.${domain}
	redir @www https://${domain}{uri} permanent
	reverse_proxy ${wp}:80
}
EOF
      ;;
  esac
}

# Ghi block ra caddy/sites/<domain>.caddy
write_caddy_block() {
  local id="$1" domain="$2" canonical="$3"
  mkdir -p "${WPF_ROOT}/caddy/sites"
  caddy_block "$domain" "${id}_wp" "$canonical" > "${WPF_ROOT}/caddy/sites/${domain}.caddy"
}

# docker compose cho stack Caddy, LUÔN nạp caddy/.env (ACME_EMAIL, CF_API_TOKEN).
caddy_compose() {
  [ -f "${WPF_ROOT}/caddy/.env" ] || touch "${WPF_ROOT}/caddy/.env"
  docker compose -f "${WPF_ROOT}/caddy/docker-compose.yml" --env-file "${WPF_ROOT}/caddy/.env" "$@"
}

caddy_reload() {
  caddy_compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1
}

# Đọc 1 biến từ caddy/.env (vd ACME_EMAIL, CF_API_TOKEN).
caddy_env_get() {
  local key="$1" f="${WPF_ROOT}/caddy/.env"
  [ -f "$f" ] || return 1
  sed -n "s/^${key}=//p" "$f" | head -n1
}

# Sinh caddy/Caddyfile. Nếu caddy/.env có CF_API_TOKEN -> thêm acme_dns cloudflare (ACME DNS-01).
# Dùng nháy đơn để giữ NGUYÊN {$ACME_EMAIL}, {env.CF_API_TOKEN} (placeholder của Caddy, không phải bash).
write_caddyfile() {
  local cf; cf="$(caddy_env_get CF_API_TOKEN 2>/dev/null || true)"
  {
    printf '# Caddyfile trung tâm LATVPS (sinh bởi lat). KHONG sua tay.\n'
    printf '{\n'
    printf '\temail {$ACME_EMAIL}\n'
    [ -n "$cf" ] && printf '\tacme_dns cloudflare {env.CF_API_TOKEN}\n'
    printf '}\n\n'
    printf 'import /etc/caddy/sites/*.caddy\n'
  } > "${WPF_ROOT}/caddy/Caddyfile"
}

# Host đã bootstrap chưa? (docker + network + wp-cli).
host_ready() {
  need_cmd docker && docker network inspect "$PROXY_NET" >/dev/null 2>&1 \
    && [ -f "${WPF_ROOT}/bin/wp-cli.phar" ]
}

# ============================================================
# Payload — tải plugin/theme AffiliateCMS từ license server (app.lat.vn),
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
  ensure_unzip || { warn "Thiếu unzip — không giải nén được payload."; return 1; }
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
