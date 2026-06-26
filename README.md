# LATVPS — `lat` CLI

Quản lý nhiều **WordPress** site trên một VPS Ubuntu, mỗi site **cô lập** (DB + Redis + network +
volume riêng) để một site bị hack không lây sang site khác. Một lệnh duy nhất: **`lat`**.

> Kiến trúc chuẩn production: **nginx-proxy** (front) + mỗi site **nginx + php-fpm + MariaDB + Redis**.

## Cài đặt (VPS Ubuntu trắng) — 1 lần

```bash
curl -fsSL https://raw.githubusercontent.com/affiliatecmscom/latvps/main/latvps.sh | sudo bash
```

Lệnh này: cài Docker + UFW (chỉ 22/80/443) + front proxy (nginx-proxy + acme-companion) + wp-cli,
tạo network, **cài lệnh `lat`**, hỏi license (bỏ qua được), rồi hỏi tạo site đầu tiên.

## Kiến trúc nhiều site

```
Internet → Cloudflare → nginx-proxy + acme-companion  (CHUNG, :80/:443, /opt/proxy/certs)
   ├─ site A: [nginx] → [wordpress:fpm] → [mariadb] + [redis]   (network nội bộ riêng)
   ├─ site B: [nginx] → [wordpress:fpm] → [mariadb] + [redis]
   └─ ...
```

nginx-proxy tự route domain theo `VIRTUAL_HOST` của container `_web` mỗi site → thêm/bớt site không
cần sửa config proxy. Chỉ `_web` chạm network chung; DB/Redis/file mỗi site cô lập.

## HTTPS — 2 chế độ (chọn lúc tạo site)

- **Auto Let's Encrypt**: domain trỏ thẳng về VPS (hoặc Cloudflare DNS-only). acme-companion tự cấp cert.
- **Cloudflare Origin Cert**: dán cert+key (Cloudflare > SSL/TLS > Origin Server) → lưu
  `/opt/proxy/certs`. Bật proxy (cam) + **SSL/TLS = Full (strict)**. Không cần token.

## Dùng hằng ngày

```bash
lat                     # menu TUI (mũi tên + Enter)
lat add my-deals.com --type affiliatecms --ssl auto --email you@email.com
lat add blog.com --type vanilla --ssl origin
lat ls
lat domain <id|domain> new-domain.com   # đổi domain, giữ nguyên dữ liệu
lat backup all
lat restore <id|domain> /opt/backups/<id>/<date>.tar.gz
lat logs <id|domain> [web|php|db|redis]
lat update              # cập nhật lệnh lat (git pull)
lat upgrade             # cập nhật hệ thống (image + OS)
lat rm <id|domain>
```

## Hai loại WordPress

- **affiliatecms**: cài sẵn plugin pro + ai + theme, tự activate license (lazy: hỏi khi cần).
- **vanilla**: WordPress sạch, không AffiliateCMS, không license.

Sau khi tạo, quyền wp-content được set đúng (`fix_perms`) → cài/sửa/xoá plugin & theme + upload media
từ wp-admin chạy ngay (không đòi FTP). Redis object cache bật sẵn (password riêng mỗi site).

## Nền tảng hỗ trợ

| Nền tảng | Trạng thái |
|---|---|
| WordPress / WooCommerce | **Sẵn sàng** |
| Laravel | Đang phát triển |
| Next.js / Node.js | Đang phát triển |
| Static Site | Đang phát triển |

## Cô lập bảo mật

Mỗi site = 1 docker-compose project (`site-<id>`), 4 container trên network nội bộ riêng:
- DB/Redis/php **không** ra network chung `latvps_proxy` → site khác không chạm tới.
- `no-new-privileges` + `mem_limit` mỗi container; chỉ proxy ra cổng 80/443.
- ID bất biến → đổi domain an toàn (search-replace DB, không tạo lại container).

## Khác

- **Payload** (plugin/theme AffiliateCMS): tải từ `app.lat.vn` gated license, không track git.
  Dev: `lat payload-sync --from /path/wp-content`.
- **Claude Code**: `lat install-claude` (trợ lý AI trên VPS) + auth OAuth token / API key.

## Cấu trúc

```
/opt/latvps/        # tool (git)
  bin/lat            latvps.sh
  lib/  templates/wordpress/  proxy/  assets/  payload/  VERSION
/opt/sites/<id>/    # data mỗi site: site.conf + compose + .env + nginx.conf + wp-content
/opt/proxy/certs/   # origin cert + cert Let's Encrypt
/opt/backups/<id>/  # backup
```
