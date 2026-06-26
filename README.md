# LATVPS — `lat` CLI

Quản lý nhiều WordPress site (AffiliateCMS hoặc thường) trên một VPS Ubuntu, mỗi site **cô lập**
để một site bị hack không lây sang site khác. Một lệnh duy nhất: **`lat`**.

## Cài đặt (VPS Ubuntu trắng) — 1 lần

```bash
curl -fsSL https://raw.githubusercontent.com/affiliatecmscom/latvps/main/latvps.sh | sudo bash
```

Lệnh này: cài Docker + UFW (chỉ 22/80/443) + Caddy + wp-cli, tạo network, **cài lệnh `lat`**,
hỏi license (bỏ qua được — site vanilla không cần), rồi hỏi tạo site đầu tiên.

> Code lấy từ repo public `github.com/affiliatecmscom/latvps` (clone không cần token).
> Nếu đã có sẵn `/opt/latvps`, chạy thẳng: `sudo /opt/latvps/bin/lat setup`.

## Nguồn plugin/theme (payload)

Repo **không** chứa source plugin. Khi tạo site AffiliateCMS, plugin/theme được **tải từ
`app.lat.vn` gated theo license** (`fetch_payload`), cache vào `payload/`. mu-plugin `proxy-ssl`
(WP sau Caddy) ship sẵn trong `assets/`, copy cho mọi site.

## Cập nhật

| Cần update | Lệnh / cơ chế | Nguồn |
|---|---|---|
| Lệnh `lat` (code) | `lat update` (git pull, repo public) | GitHub |
| Plugin/theme site ĐÃ tạo | Tự update trong wp-admin | app.lat.vn |
| Plugin/theme site TẠO MỚI | tải mới nhất lúc `add`; `lat payload-sync` để refresh cache | app.lat.vn |
| Image WP/MariaDB/Caddy + OS | `lat upgrade` | Docker Hub / apt |

## Dùng hằng ngày: gõ `lat`

```bash
lat            # mở menu TUI (mũi tên + Enter; tự fallback menu số nếu thiếu whiptail)
```

Menu chính:
1. **Thêm site mới** (việc chính)
2. Quản lý site (chọn site → đổi domain / đổi www-nonwww / backup / bật-tắt / logs / xoá)
3. Backup tất cả
4. License
5. Trạng thái hệ thống
6. Bảo trì / nâng cao (cập nhật lệnh lat, cập nhật hệ thống, payload, Cloudflare, setup lại)

## Subcommand (power user / script / cron)

```bash
lat add my-deals.com --type affiliatecms --canonical non-www --email you@email.com
lat add blog.com --type vanilla            # WordPress thường, không AffiliateCMS
lat ls
lat domain <id|domain> new-domain.com      # đổi domain, giữ nguyên DB/container
lat canonical <id|domain> www|non-www|none
lat backup all
lat restore <id|domain> /opt/backups/<id>/<date>.tar.gz
lat upgrade        # nâng image WP/MariaDB/Caddy + vá OS
lat update         # cập nhật chính lệnh lat (code)
lat status
lat rm <id|domain>
```

## Cloudflare

**Bật proxy (đám mây cam) thoải mái — chỉ cần đặt SSL/TLS = Full** (tránh Flexible). Caddy vẫn tự
xin Let's Encrypt qua HTTP-01 (đi xuyên proxy được) và Cloudflare cấp SSL ở edge cho khách. Mặc
định chạy được, **không cần token**.

> Tránh chế độ **Flexible** (Caddy ép HTTP→HTTPS → vòng lặp redirect). Dùng **Full** hoặc Full strict.

### (Tùy chọn nâng cao) ACME DNS-01

Chỉ cần khi gặp trường hợp hiếm (port 80 bị chặn, cần wildcard, hoặc HTTP-01 không qua được). Menu
Bảo trì → **"Cloudflare DNS"** (hoặc `lat cloudflare`): nhập **Cloudflare API token**
(`Zone.Zone:Read` + `Zone.DNS:Edit`) → Caddy xin cert qua DNS-01 (TXT record qua Cloudflare API).
Caddy đã build kèm plugin `caddy-dns/cloudflare`. Token lưu `caddy/.env` (chmod 600). Khi bật,
mọi domain phải nằm trên Cloudflare dưới token đó.

> Cách không-token khác: dùng **Cloudflare Origin Certificate** (cấp trong dashboard, hạn 15 năm),
> nạp vào Caddy như couponapi. Hiện làm thủ công; chưa có trong menu.

## Claude Code (trợ lý AI trên VPS)

Menu chính có mục **"Cài Claude Code"** (hoặc `lat install-claude`): cài CLI Claude Code qua
native installer, **tự thêm PATH** (installer không tự làm trên root trắng), rồi hỏi auth:

- **OAuth token** (khuyến nghị nếu có gói Claude Pro/Max — không tốn API credits): chạy
  `claude setup-token` ở máy có trình duyệt để lấy token, dán vào.
- **API key** `sk-ant-...` (console.anthropic.com, tính theo token).
- Bỏ qua, auth sau.

Key/token lưu `chmod 600` ở `/root/.config/lat/claude-env`, nạp qua `.bashrc`. Dùng: mở SSH
mới rồi `cd <thư-mục>; claude`.

## Hai loại site

- **affiliatecms**: cài sẵn plugin `affiliatecms-pro` + `affiliatecms-ai` + theme, tự activate
  license cho domain (lazy: hỏi license khi cần nếu chưa có).
- **vanilla**: WordPress sạch, không liên quan AffiliateCMS, không dùng license.

## Cô lập bảo mật

Mỗi site = 1 docker-compose project riêng (`site-<id>`):
- DB nằm network nội bộ riêng, **không** ra `wpfactory_proxy` → site khác không chạm tới được.
- `wp-content` + volume DB riêng từng site.
- `no-new-privileges` + `mem_limit`; không publish cổng (chỉ Caddy ra 80/443).

Chi tiết kiến trúc: `docs/ARCHITECTURE.md`.

## Định danh site (vì sao đổi domain an toàn)

Mỗi site có **ID bất biến** (vd `s-a1b2c3`) dùng cho tên container/network/volume. Domain chỉ là
thuộc tính trong `/opt/sites/<id>/site.conf`. Đổi domain = search-replace DB + đổi license domain +
đổi Caddy block, **không** đụng container/volume → không mất dữ liệu.

## Cấu trúc

```
/opt/latvps/        # tool (track git)
  bin/lat            # dispatcher + symlink /usr/local/bin/lat
  latvps.sh             # bootstrap 1 lệnh
  lib/common.sh ui.sh menu.sh  actions/*.sh
  assets/mu-plugins/proxy-ssl.php   # ship kèm, copy cho mọi site
  templates/  caddy/  payload/  VERSION
/opt/sites/<id>/        # data mỗi site: site.conf + compose + .env + wp-content
/opt/backups/<id>/      # backup
```

## Lưu ý nhân bản
- Bộ này standalone (tự mang Caddy, bind 80/443) → để deploy sang VPS mới. Trên VPS đã chạy stack
  khác chiếm 80/443 sẽ xung đột cổng (đổi tạm port Caddy để test).
- `payload/` (plugin/theme) tải từ app.lat.vn gated license, không track git. Dev có thể nạp từ
  wp-content local: `lat payload-sync --from /path/to/wp-content`.
