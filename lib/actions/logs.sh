#!/usr/bin/env bash
# actions/logs.sh — xem log container của 1 site.

act_logs() {
  require_root
  local arg="${1:-}" which="${2:-wp}"
  [ -n "$arg" ] || { warn "Dùng: lat logs <id|domain> [wp|db]"; return 1; }
  local id; id="$(resolve_site "$arg")" || { warn "Không tìm thấy site: $arg"; return 1; }
  case "$which" in wp|db) ;; *) which="wp";; esac
  docker logs --tail 200 "${id}_${which}" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
}
