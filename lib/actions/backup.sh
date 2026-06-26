#!/usr/bin/env bash
# actions/backup.sh — backup/restore site (db.sql + wp-content + config).

BACKUP_KEEP="${BACKUP_KEEP:-14}"

# backup 1 site theo id. In đường dẫn file ra stdout.
_backup_one() {
  local id="$1"
  local dir; dir="$(site_dir "$id")"
  local domain; domain="$(site_get "$id" DOMAIN)"
  local out="${BACKUPS_ROOT}/${id}"
  mkdir -p "$out"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local tmp="${dir}/db.sql"

  info "Backup ${domain} (${id})..."
  docker exec "${id}_db" sh -c 'exec mariadb-dump --no-tablespaces -uwordpress -p"$MARIADB_PASSWORD" wordpress' > "$tmp" 2>/dev/null \
    || { warn "Dump DB lỗi cho ${id}."; rm -f "$tmp"; return 1; }

  local file="${out}/${stamp}.tar.gz"
  tar -C "$SITES_ROOT" -czf "$file" "$id" 2>/dev/null
  rm -f "$tmp"

  # xoay vòng
  ls -1t "${out}"/*.tar.gz 2>/dev/null | tail -n +"$((BACKUP_KEEP+1))" | xargs -r rm -f
  ok "Đã backup: ${file}"
  printf '%s' "$file"
}

# act_backup [id|domain|all]
act_backup() {
  require_root
  local arg="${1:-all}"
  if [ "$arg" = "all" ]; then
    local id any=0
    for id in $(list_site_ids); do _backup_one "$id" >/dev/null && any=1; done
    [ "$any" = 1 ] && ok "Backup tất cả xong." || info "Không có site để backup."
    return 0
  fi
  local id; id="$(resolve_site "$arg")" || { warn "Không tìm thấy site: $arg"; return 1; }
  _backup_one "$id" >/dev/null
}

# act_restore <id|domain> <file.tar.gz>
act_restore() {
  require_root
  local arg="${1:-}" file="${2:-}"
  [ -n "$arg" ] && [ -n "$file" ] || { warn "Dùng: lat restore <id|domain> <file.tar.gz>"; return 1; }
  [ -f "$file" ] || { warn "Không thấy file: $file"; return 1; }
  local id; id="$(resolve_site "$arg")" || { warn "Không tìm thấy site: $arg"; return 1; }
  local dir; dir="$(site_dir "$id")"

  ui_yesno "Phục hồi site ${id} từ ${file}? Dữ liệu hiện tại sẽ bị ghi đè." || return 1

  info "Giải nén wp-content + config..."
  tar -C "$SITES_ROOT" -xzf "$file" 2>/dev/null || { warn "Giải nén lỗi."; return 1; }
  docker compose -f "$dir/docker-compose.yml" --env-file "$dir/.env" up -d
  wait_for_db "${id}_db"
  if [ -f "${dir}/db.sql" ]; then
    info "Import database..."
    docker exec -i "${id}_db" sh -c 'exec mariadb -uwordpress -p"$MARIADB_PASSWORD" wordpress' < "${dir}/db.sql" \
      && ok "Đã import DB." || warn "Import DB lỗi."
    rm -f "${dir}/db.sql"
  fi
  ok "Phục hồi xong site ${id}."
}
