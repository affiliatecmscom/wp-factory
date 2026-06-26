# Kiến trúc VPS học viên — LATVPS (reference design)

> Bản thiết kế chuẩn cho **1 VPS Ubuntu trắng của học viên** chạy nhiều WordPress site
> AffiliateCMS, cô lập để 1 site bị hack không lây sang site khác. Tài liệu để DUYỆT trước
> khi sửa config thật. Phần "Đề xuất bổ sung" là cái nên thêm so với bản đã build.
>
> **Cập nhật:** thao tác giờ qua **một lệnh `lat`** (menu TUI + subcommand) thay cho các script
> rời. Xem `README.md`. Kiến trúc hạ tầng/cô lập bên dưới vẫn nguyên; định danh site đổi sang **ID
> bất biến** (domain là thuộc tính, đổi domain không tạo lại container).

---

## 1. Mục tiêu & nguyên tắc

1. **1 lệnh là chạy** — học viên không cần kiến thức DevOps.
2. **Cô lập là mặc định** — mỗi site là 1 hộp kín; thủng 1 site không lan ra site khác.
3. **Bề mặt tấn công tối thiểu** — chỉ 3 cổng public (22/80/443), không lộ DB/WP ra ngoài.
4. **Nhân bản dễ** — cùng 1 bộ script chạy trên mọi VPS trắng, không cấu hình thủ công.
5. **Stateless tool, stateful data** — script (`/opt/latvps`) tách khỏi dữ liệu site
   (`/opt/sites`); xoá/cài lại tool không mất site.

---

## 2. Sơ đồ tổng thể (topology)

```
                            Internet
                               │
                     ┌─────────┴─────────┐
                     │   UFW firewall    │   chỉ mở 22 / 80 / 443
                     └─────────┬─────────┘
                               │ 80, 443
                    ┌──────────▼──────────┐
                    │   Caddy (1 cổng vào)│  HTTPS tự động (Let's Encrypt)
                    │   wpfactory_caddy   │  mỗi domain 1 block, cert riêng
                    └──────────┬──────────┘
                               │  network: wpfactory_proxy (chung)
          ┌────────────────────┼────────────────────┐
          │                    │                     │
   ┌──────▼──────┐      ┌──────▼──────┐       ┌──────▼──────┐
   │  site A wp  │      │  site B wp  │       │  site C wp  │   (chỉ WP join proxy)
   └──────┬──────┘      └──────┬──────┘       └──────┬──────┘
          │ net: A_internal    │ B_internal          │ C_internal   (RIÊNG mỗi site)
   ┌──────▼──────┐      ┌──────▼──────┐       ┌──────▼──────┐
   │  site A db  │      │  site B db  │       │  site C db  │   (DB KHÔNG ra proxy)
   └─────────────┘      └─────────────┘       └─────────────┘
   vol: A_db            vol: B_db             vol: C_db        (volume riêng)
   dir: /opt/sites/A    /opt/sites/B          /opt/sites/C     (wp-content riêng)
```

**Đường đi request:** Internet → UFW → Caddy (TLS) → `wpfactory_proxy` → WP container của
đúng domain → DB của chính site đó qua network nội bộ riêng. Không có mũi tên nào nối ngang
giữa các site.

---

## 3. Layout thư mục trên VPS

```
/opt/
├── latvps/                 # TOOL (track git, nhân bản sang VPS khác)
│   ├── install.sh              # bootstrap VPS trắng
│   ├── new-site.sh             # dựng 1 site
│   ├── remove-site.sh          # gỡ 1 site
│   ├── list-sites.sh           # liệt kê
│   ├── sync-payload.sh         # cập nhật plugin bundle
│   ├── backup.sh               # [ĐỀ XUẤT] backup toàn bộ site
│   ├── lib/common.sh           # helper chung
│   ├── templates/              # template compose/env/caddy
│   ├── caddy/                  # stack Caddy trung tâm + Caddyfile + sites/*.caddy
│   ├── payload/                # nguồn plugin/theme (không track git)
│   ├── bin/wp-cli.phar         # wp-cli (tải lúc install)
│   ├── .license                # license key (chmod 600, không commit)
│   └── docs/ARCHITECTURE.md    # tài liệu này
│
├── sites/                      # DATA (mỗi site 1 thư mục, KHÔNG track git)
│   ├── my-deals.com/
│   │   ├── docker-compose.yml
│   │   ├── .env                # DB_PASSWORD (chmod 600)
│   │   └── wp-content/         # plugin/theme/uploads của site
│   └── another-site.com/
│       └── ...
│
└── backups/                    # [ĐỀ XUẤT] dump DB + wp-content theo ngày
    └── my-deals.com/2026-06-26.tar.gz
```

**Nguyên tắc:** `latvps` = code (xoá được, cài lại từ git). `sites` + `backups` = dữ liệu
(phải giữ + backup). Phân tách rõ để học viên không xoá nhầm.

---

## 4. Mạng Docker (networks)

| Network | Loại | Ai join | Mục đích |
|---|---|---|---|
| `wpfactory_proxy` | external, tạo 1 lần | Caddy + **wp** của mọi site | Caddy → WP. Đây là mặt chung DUY NHẤT. |
| `site-<slug>_internal` | tạo theo từng site | **wp + db** của RIÊNG site đó | WP ↔ DB nội bộ. Tách biệt mỗi site. |

- DB **không bao giờ** join `wpfactory_proxy` → từ proxy net không có route tới bất kỳ DB nào.
- Mỗi `internal` do compose tự sinh theo project name → các site không thấy nhau ở tầng DB.
- **[ĐỀ XUẤT]** bật `enable_icc=false` cho `wpfactory_proxy` để các WP container không gọi
  ngang nhau qua HTTP (chỉ Caddy gọi vào được). Phòng trường hợp 1 WP bị chiếm dùng làm bàn
  đạp quét site khác trên cùng proxy net.

---

## 5. Mô hình cổng (ports) & firewall

| Cổng | Trạng thái | Ghi chú |
|---|---|---|
| 22/tcp | mở (UFW) | SSH. **[ĐỀ XUẤT]** tắt password auth, chỉ key. |
| 80/tcp | mở (UFW) | HTTP → Caddy (redirect 443 + ACME challenge). |
| 443/tcp | mở (UFW) | HTTPS → Caddy. |
| 3306 (DB) | **không publish** | DB chỉ trong network nội bộ. |
| WP:80 | **không publish** | Caddy vào qua proxy net, không bind host. |

**UFW**: `default deny incoming` + allow 22/80/443. Mọi container KHÔNG dùng `ports:` ra host
(trừ Caddy). Đây là khác biệt then chốt so với demo cũ (vốn bind `127.0.0.1:8110`): ở đây
container site hoàn toàn không có cổng host nào.

---

## 6. Ranh giới cô lập & threat model

**Tình huống:** site A bị chiếm (vd plugin lỗ hổng, RCE trong PHP của A).

| Tài nguyên | Kẻ tấn công làm được gì từ trong site A? | Vì sao bị chặn |
|---|---|---|
| DB của A | Có (đúng phạm vi A) | Chấp nhận — chỉ mất dữ liệu A |
| DB của B, C | **Không** | Khác network, không resolve/không route |
| File site B, C | **Không** | Bind-mount riêng, container A không thấy |
| Root của host | Rất khó | `no-new-privileges`, container không privileged |
| Làm sập site khác | Hạn chế | `mem_limit`/`cpus` chặn ngốn tài nguyên |
| Quét WP site khác | Hạn chế nếu bật ICC=false | Cùng proxy net mới gọi ngang được |

**Crown jewels** (DB + filesystem các site khác) được cô lập tuyệt đối bằng network + mount.
Bề mặt còn lại (proxy net chung) chỉ là HTTP, và siết thêm bằng ICC=false.

---

## 7. Thành phần & container inventory

| Thành phần | Image | Số lượng | Cổng host | Network |
|---|---|---|---|---|
| Caddy | `caddy:2` | 1 | 80, 443 | wpfactory_proxy |
| WP (mỗi site) | `wordpress:6-php8.3-apache` | N | không | proxy + internal |
| DB (mỗi site) | `mariadb:11` | N | không | internal |

Tổng container ≈ `1 + 2N` (N = số site).

---

## 8. Dữ liệu, volume & backup

**Trạng thái cần giữ:**
- DB mỗi site → named volume `site-<slug>_db`.
- `wp-content` mỗi site → bind-mount `/opt/sites/<domain>/wp-content` (gồm uploads, plugin, theme).
- Cert Let's Encrypt → volume `caddy_data` (tự xin lại được, nhưng giữ tránh rate-limit ACME).

**[ĐỀ XUẤT] `backup.sh <domain|all>`:**
1. `docker exec <slug>_db mariadb-dump` → `db.sql`.
2. `tar` thư mục `/opt/sites/<domain>` (gồm wp-content + compose + .env).
3. Gói `/opt/backups/<domain>/<date>.tar.gz`, xoay vòng giữ N bản (vd 14 ngày).
4. **[Tuỳ chọn]** đẩy lên S3/Backblaze để chống mất nguyên VPS.

**Restore:** giải nén thư mục về `/opt/sites/<domain>`, `import` lại db.sql vào container db,
`new-site.sh` ở chế độ "đã có dữ liệu" (bỏ qua core install).

---

## 9. Vòng đời site (lifecycle)

```
install.sh ──▶ host sẵn sàng (Docker, UFW, Caddy, license)
                   │
   new-site.sh ────┼──▶ tạo dir + compose + .env (DB pass random)
                   │    copy payload → wp-content
                   │    up -d → wait DB → WP-CLI install + plugin + theme
                   │    license activate domain
                   │    ghi caddy block + reload → cert tự cấp
                   ▼
              site LIVE (https://domain)
                   │
   backup.sh ──────┤  (định kỳ, cron)
                   │
   remove-site.sh ─┴──▶ deactivate license + down -v + xoá dir + xoá caddy block
```

---

## 10. Cập nhật & bảo trì

- **Plugin/theme**: phát hành qua license server (auto-update trong wp-admin từng site).
  `sync-payload.sh` chỉ ảnh hưởng site tạo MỚI về sau.
- **WordPress core / image**: `docker compose pull && up -d` từng site (hoặc vòng lặp all).
- **Caddy/Docker host**: `apt upgrade` + `docker compose pull` cho stack Caddy.
- **wp-cli** có sẵn (`bin/wp-cli.phar`) cho thao tác bảo trì: `wp ... ` qua `docker exec`.

---

## 11. Định cỡ tài nguyên (sizing)

Ước lượng RAM mỗi site ≈ WP (≈150-300MB) + MariaDB (≈150-250MB) ⇒ **~0.4-0.6GB/site**
(đã đặt `mem_limit: 512m`/container).

| RAM VPS | Số site khuyến nghị | Ghi chú |
|---|---|---|
| 2 GB | 2-3 | **[ĐỀ XUẤT]** thêm swap 2GB cho an toàn |
| 4 GB | 5-7 | |
| 8 GB | 12-15 | |

**[ĐỀ XUẤT]** `install.sh` tạo swapfile (vd 2GB) nếu VPS < 4GB RAM — MariaDB + PHP dễ OOM
trên VPS nhỏ.

---

## 12. Checklist hardening (mức host)

Đã có:
- [x] UFW chỉ 22/80/443, default deny.
- [x] Container không publish port (trừ Caddy).
- [x] `no-new-privileges` + `mem_limit` mỗi container.
- [x] Secret (DB pass, license) chmod 600, không commit.
- [x] HTTPS bắt buộc (Caddy tự redirect 80→443).

Đề xuất thêm trong `install.sh`:
- [ ] SSH: tắt `PasswordAuthentication`, chỉ key; (tuỳ chọn) đổi port 22.
- [ ] `fail2ban` cho SSH.
- [ ] `unattended-upgrades` (vá bảo mật OS tự động).
- [ ] Swapfile nếu RAM < 4GB.
- [ ] `enable_icc=false` cho `wpfactory_proxy`.
- [ ] (Tuỳ chọn) Caddy security headers mặc định (HSTS, X-Frame-Options) cho mọi site.

---

## 13. Khác biệt so với bản đã build (đề xuất tinh chỉnh)

Bản hiện tại đã đúng kiến trúc lõi (network/port/isolation). Để đạt chuẩn thiết kế này, đề
xuất bổ sung — sẽ làm sau khi bạn duyệt:

1. **`backup.sh`** + cron mẫu (mục 8) — hiện chưa có.
2. **Hardening trong `install.sh`** (mục 12): swap, SSH key-only, fail2ban,
   unattended-upgrades, `enable_icc=false`.
3. **`cpus:` limit** thêm cạnh `mem_limit` trong template (chặn 1 site ngốn CPU).
4. **Security headers** mặc định trong block Caddy (snippet import chung).
5. **`update-all.sh`** tiện ích `docker compose pull && up -d` vòng qua mọi site.

Các mục trên là "thêm cho đủ chuẩn", không phá vỡ bản đang chạy.
