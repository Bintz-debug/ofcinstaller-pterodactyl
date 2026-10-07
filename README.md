# installerptd.sh - Pterodactyl Panel + Wings Installer (1 Domain)

> Dibuat & dikelola oleh **BintzGE**

Script all-in-one untuk install, aktivasi, dan uninstall **Pterodactyl Panel** serta **Wings** di satu VPS, menggunakan **satu domain yang sama** untuk Panel dan FQDN Node, lengkap dengan SSL otomatis.

Mendukung **banyak distro Linux**, bukan cuma satu OS atau satu provider VPS tertentu.

---

## Distro & Provider yang Didukung

Script otomatis mendeteksi OS dan menyesuaikan cara install.

| Keluarga | Distro | Package Manager |
|---|---|---|
| **Debian** | Ubuntu, Debian, Linux Mint, Pop!_OS | `apt` |
| **RHEL** | Rocky Linux, AlmaLinux, CentOS Stream, RHEL, Fedora | `dnf` |

> Distro di luar daftar ini (Arch, Alpine, openSUSE, dll) belum didukung otomatis — script akan berhenti dengan pesan jelas, bukan error di tengah proses.

Berlaku di VPS provider mana pun: UpCloud, DigitalOcean, Vultr, Hetzner, Linode, Contabo, AWS, GCP, Biznet, IDCloudHost, dll — selama distro-nya termasuk yang didukung di atas.

---

## Persyaratan

- VPS dengan salah satu distro di atas, akses root
- Domain yang sudah diarahkan (A record) ke IP VPS
- Minimal 2GB RAM (disarankan)
- Port 80, 443, Daemon Wings (default 8443), 2022, dan port alokasi game terbuka di firewall

---

## Cara Menjalankan

Jalankan `installerptd.sh` ke VPS:

```bash
bash <(curl -s https://raw.githubusercontent.com/Bintz-debug/ofcinstaller-pterodactyl/main/installerptd.sh)
```

Saat dijalankan, script akan menampilkan OS yang terdeteksi lalu menu:

```
1) Install Panel
2) Install & Aktifkan Wings
3) Uninstall Panel
0) Keluar
```

---

## Menu 1: Install Panel

Input yang diminta:

| Input | Contoh |
|---|---|
| Domain Panel | `panel.contoh.com` |
| Email (untuk SSL & akun admin) | `admin@contoh.com` |
| Nama database | `panel` (default) |
| Nama user database | `pterodactyl` (default) |
| Password database | bebas, isi sendiri |
| Zona waktu | `Asia/Jakarta` |
| Konfirmasi DNS sudah terarah | `y` |

Proses otomatis (menyesuaikan distro):
- Install PHP 8.3, MariaDB, Nginx, Redis, Composer, Certbot
- Setup database & file Panel
- Request sertifikat SSL (Let's Encrypt)
- Konfigurasi Nginx, cron job, queue worker
- Membuat akun admin pertama

✅ Setelah selesai, Panel bisa diakses di `https://panel.contoh.com`.

**Langkah lanjutan (manual di dashboard Panel):**
1. **Admin → Locations** → buat location baru.
2. **Admin → Nodes → Create New**, isi:

   | Field | Nilai |
   |---|---|
   | FQDN | sama dengan domain Panel |
   | Behind Proxy | No |
   | Communicate Over SSL | **Yes** |
   | Daemon Port | **8443** |

3. Tambahkan **Allocation** (IP + port game) pada node.
4. Buka tab **Configuration** pada node untuk mengambil kode konfigurasi Wings.

**Buka firewall setelah instalasi** (script akan menampilkan command yang sesuai distro kamu):
```bash
# Debian/Ubuntu (ufw)
ufw allow 80/tcp && ufw allow 443/tcp

# RHEL family (firewalld)
firewall-cmd --permanent --add-port=80/tcp --add-port=443/tcp && firewall-cmd --reload
```

---

## Menu 2: Install & Aktifkan Wings

Jalankan setelah Node dibuat di Panel. Proses otomatis:
- Install Docker (jika belum ada, pakai installer resmi Docker — cocok untuk semua distro yang didukung)
- Download binary Wings

Kemudian script meminta kamu **paste satu baris perintah Configuration** dari Panel (Admin → Nodes → node kamu → tab **Configuration**). Copy **persis seperti yang ditampilkan Panel**, biasanya diawali `cd`, contoh formatnya:

```
cd /etc/pterodactyl && sudo wings configure --panel-url https://panel.contoh.com --token ptlc_xxxxx --node 1
```

Script menjalankan perintah tersebut apa adanya (termasuk bagian `cd`), mengambil konfigurasi node langsung dari Panel lewat metode resmi `wings configure`.

> ⚠️ Token pada perintah tersebut hanya berlaku sekitar **5 menit**. Jika expired, script memberi **3 kali kesempatan** untuk paste ulang — cukup buka lagi tab Configuration di Panel untuk mendapat kode baru.

Setelah konfigurasi berhasil, Wings otomatis:
- Dijadikan systemd service
- Dijalankan (`enable --now`)

✅ Jika berhasil, status Node di Panel berubah menjadi **online/hijau**. Jika belum, cek log:
```bash
journalctl -u wings -f
```

**Buka firewall untuk Wings:**
```bash
# Debian/Ubuntu (ufw)
ufw allow 8443/tcp && ufw allow 2022/tcp

# RHEL family (firewalld)
firewall-cmd --permanent --add-port=8443/tcp --add-port=2022/tcp && firewall-cmd --reload
```

---

## Menu 3: Uninstall Panel

Dasarnya menghapus Panel, tapi kamu bisa pilih seberapa dalam penghapusannya lewat beberapa pertanyaan terpisah — semuanya **default-nya "tidak dihapus"**, baru jalan kalau kamu jawab `y` secara eksplisit.

### Langkah 1 - Hapus Panel (wajib, otomatis)
- File Panel (`/var/www/pterodactyl`)
- Database & user Panel
- Konfigurasi Nginx untuk Panel (`sites-available`/`sites-enabled` atau `conf.d`, menyesuaikan distro)
- Cron job & systemd service `pteroq`
- (ditanya terpisah) sertifikat SSL domain Panel

### Langkah 2 - Hapus Wings? (opsional, ditanya terpisah)
Kalau dijawab `y`, akan ada **konfirmasi kedua** (ketik `HAPUS`) karena ini destruktif:
- Service & binary Wings
- **Semua container/server game di Docker** — data world, plugin, save game ikut hilang permanen
- Folder `/etc/pterodactyl`, `/var/lib/pterodactyl`, `/var/log/pterodactyl`

Kalau dijawab `n`, Wings tetap aktif dan tidak disentuh sama sekali.

### Langkah 3 - Hapus paket pendukung? (opsional)
Kalau dijawab `y`, PHP, MariaDB, Nginx, Redis, Composer ikut dihapus — dengan penanganan aman supaya tidak error:
1. Semua service (nginx, PHP-FPM, Redis, MariaDB) **di-stop & di-disable dulu**
2. Proses `mysqld`/`mariadbd` yang masih nyangkut **di-kill paksa**
3. Purge paket dilakukan **satu per satu**, jadi satu paket gagal tidak menghentikan proses lain
4. `dpkg --configure -a` dijalankan otomatis setelah purge untuk memperbaiki state dpkg yang mungkin rusak

> Ini perbaikan dari masalah sebelumnya di mana purge MariaDB bisa error karena service-nya masih jalan saat di-purge.

### Langkah 4 - Hapus Docker juga? (opsional, ditanya terpisah)
Pesannya otomatis menyesuaikan tergantung apakah Wings sudah kamu hapus di Langkah 2 atau belum, supaya kamu sadar risikonya sebelum menjawab.

---

## Troubleshooting

**OS terdeteksi "belum didukung otomatis":**
Script hanya mendukung keluarga Debian dan RHEL (lihat tabel di atas). Install ulang VPS dengan salah satu distro tersebut, atau lakukan instalasi manual.

**Node tidak online setelah install Wings:**
```bash
journalctl -u wings -f
```

**Cek status service:**
```bash
systemctl status nginx
systemctl status pteroq
systemctl status wings
```

**Token Wings expired saat menu 2:**
Buka ulang Admin → Nodes → node kamu → tab Configuration di Panel untuk mendapat kode baru, lalu paste lagi saat diminta (maksimal 3 percobaan per sesi jalan script).

**Sertifikat SSL gagal terbit saat menu 1:**
- Pastikan domain sudah benar-benar resolve ke IP VPS (`dig panel.contoh.com`)
- Pastikan port 80 tidak dipakai service lain

**Error permission di RHEL family (Rocky/Alma/CentOS/Fedora) terkait SELinux:**
```bash
setsebool -P httpd_can_network_connect 1
```

**Purge MariaDB masih error walau sudah pakai script ini:**
Cek proses yang masih memegang database:
```bash
ps aux | grep mysql
lsof /var/lib/mysql 2>/dev/null
```
Matikan manual lalu jalankan ulang Langkah 3 di menu 3.

---

## Catatan

- Wings (menu 2) membutuhkan sertifikat SSL yang dibuat oleh Panel (menu 1), jadi **Panel harus diinstal lebih dulu**.
- Daemon Port di Panel (saat buat Node) harus sama dengan yang tercantum dalam perintah `wings configure` yang kamu paste — otomatis selama kamu copy langsung dari tab Configuration.
- Saat sertifikat Let's Encrypt diperbarui otomatis, Nginx dan Wings akan ikut restart otomatis.
- Dukungan RHEL family (khususnya repo Remi untuk PHP 8.3) adalah best-effort — kalau menemui error spesifik di versi distro tertentu, silakan laporkan detail errornya untuk diperbaiki.
- **Tidak ada undo** untuk penghapusan Wings/container game atau paket pendukung. Pastikan backup dulu kalau ada data penting.

---

<p align="center">⚙️ Script & dokumentasi ini dirawat oleh <b>BintzGE</b> ⚙️</p>
