#!/usr/bin/env bash
# Xuất CONFIG AffiliateCMS + Rank Math từ 1 site demo -> assets/acms-config/options.json
# CHỈ whitelist config (KHÔNG license/API key/secret/per-install/per-domain). Strip affiliate_tag.
# Chạy trên máy có container WP demo:  bash tools/export-acms-config.sh [wp_container]
set -euo pipefail
WPC="${1:-iflmmo_wp}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/assets/acms-config/options.json"
mkdir -p "$(dirname "$OUT")"

export WPC OUT
python3 - <<'PY'
import os, json, subprocess

WPC=os.environ['WPC']; OUT=os.environ['OUT']

# Whitelist: config an toàn để ship (đã loại mọi option chứa license/API key/secret/install/proof/domain).
KEYS=[
  "acms_general_settings","acms_post_types","acms_content_templates","acms_automation",
  "acms_ai_templates","acms_default_template_id",
  "acms_ai_default_template_enhance_asin","acms_ai_default_template_generate_review",
  "acms_ai_provider","acms_ai_default_model","acms_ai_model","acms_ai_selected_models",
  "acms_ai_enabled_providers","acms_ai_enabled",
  "acms_reviews_category_children","acms_reviews_brand_children","acms_admin_theme",
  "rank-math-options-general","rank-math-options-titles","rank-math-options-sitemap","rank_math_modules",
]
# Field secret cần strip trong general_settings (per-user, không ship).
STRIP_FIELDS={"affiliate_tag","custom_url_params"}

def wp(*a):
    return subprocess.run(
        ["docker","exec",WPC,"php","/var/www/html/wp-cli.phar","--allow-root","--path=/var/www/html",*a],
        capture_output=True,text=True)

out={}
for k in KEYS:
    r=wp("option","get",k,"--format=json")
    if r.returncode!=0 or not r.stdout.strip():
        print(f"  bỏ qua (không có): {k}"); continue
    try: val=json.loads(r.stdout)
    except Exception:
        print(f"  bỏ qua (không phải json): {k}"); continue
    if k=="acms_general_settings" and isinstance(val,dict):
        for f in STRIP_FIELDS:
            if f in val: val[f]=""
    out[k]=val
    print(f"  + {k}")

# An toàn: quét secret pattern trong toàn bộ giá trị.
blob=json.dumps(out)
import re
bad=re.findall(r'sk-[A-Za-z0-9]{6,}|AIza[0-9A-Za-z_\-]{10,}|-----BEGIN|ACMS-[0-9A-F]{4}-', blob)
if bad:
    raise SystemExit(f"!! PHÁT HIỆN SECRET trong export: {set(bad)} — DỪNG, không ghi file.")

with open(OUT,"w") as f: json.dump(out,f,ensure_ascii=False,indent=1)
print(f"\nĐã ghi {OUT}  ({len(out)} option, {len(blob)} bytes)")
PY
