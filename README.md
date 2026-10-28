# 9Router Installer

**One-line installer & auto-updater for [9Router](https://github.com/decolua/9router) on any Ubuntu/Debian VPS.**

## ⚡ One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/xpersian/9Router-Installer/main/install.sh | sudo bash
```

The first run asks for your admin password (input hidden), port (default `20128`) and public URL, then installs everything. **Run the same command again later and it silently updates** — reusing your saved config, no prompts, and skipping `npm install`/build entirely when the source has not changed.

Prompts are read from the terminal (`/dev/tty`), never from stdin, so the piped one-liner works out of the box.

## ✨ What it does

- Installs/updates the latest **Node.js 22.x** (resolves NodeSource/apt conflicts, fixes broken npm installs)
- Clones and builds 9Router from source into `/opt/9router` (data: `/var/lib/9router`)
- Auto-generates secure secrets (`JWT_SECRET`, `API_KEY_SECRET`, `MACHINE_ID_SALT`) and saves everything to `/opt/9router/.env` — later runs reuse that file, so your config, secrets and admin password survive updates
- Runs it with **PM2** (auto-start on reboot), binds `0.0.0.0`, opens the port in **ufw**
- Detects the server's public IP and sets `NEXT_PUBLIC_BASE_URL`
- **Daily auto-update cron** (04:45) — enabled automatically; log: `/var/log/9router-update.log`; updates are fast when nothing changed
- Creates a 2–4 GB temporary swap on low-RAM VPSes so the build never OOMs
- Works around 9Router's hardcoded `--port 20127` by launching `custom-server.js` directly with your chosen port
- Installs the `sudo 9router` management helper (menu: update / uninstall)

## 🔧 Non-interactive install (optional)

Prefer no prompts (automation, CI, scripts)? Provide the values as environment variables:

```bash
curl -fsSL https://raw.githubusercontent.com/xpersian/9Router-Installer/main/install.sh -o install.sh
sudo INITIAL_PASSWORD='your-admin-password' PORT=20128 bash install.sh
```

`BASE_URL` can be provided the same way; anything omitted falls back to the default (auto-detected public IP).

## 🧰 After install

```bash
sudo 9router                  # menu: Update | Uninstall
sudo 9router update           # silent update
sudo 9router --no-auto-update # disable the daily auto-update
```

```bash
pm2 status        # status
pm2 logs 9router  # logs
pm2 restart 9router
```

## 🗑 Uninstall

```bash
sudo 9router uninstall
```

Stops the app and removes `/opt/9router`, the cron job and (after confirmation) the data directory.

## Requirements

- An Ubuntu/Debian VPS with root/sudo access
- If your VPS sits behind a cloud firewall (Hetzner/AWS/GCP/Oracle), open your chosen TCP port there too

---

# 🇮🇷 فارسی

**نصب و آپدیت خودکار 9Router با یک خط، روی هر VPS اوبونتو/دبیان.**

## ⚡ نصب با یک خط

```bash
curl -fsSL https://raw.githubusercontent.com/xpersian/9Router-Installer/main/install.sh | sudo bash
```

- **اجرا اول:** پسورد ادمین (پنهان)، پورت (پیش‌فرض `20128`) و آدرس عمومی را می‌پرسد و همه‌چیز را نصب می‌کند (Node.js، بیلد، PM2، فایروال، آپدیت خودکار روزانه)
- **اجرا دوم به بعد:** بدون هیچ سوالی، فقط آپدیت بی‌صدا با همان تنظیمات ذخیره‌شده؛ اگر سورس تغییری نکرده باشد، بیلد هم به‌کل رد می‌شود

سؤال‌ها از ترمینال (`/dev/tty`) خوانده می‌شوند نه از stdin، بنابراین همان دستور تک‌خطی pipe‌شده بدون مشکل کار می‌کند.

## ✨ امکانات

- نصب/ارتقای خودکار آخرین نسخه Node.js 22.x و حل تعارض‌های npm در اوبونتو
- بیلد از سورس در `/opt/9router` و دیتا در `/var/lib/9router`
- تولید خودکار secretهای امن (`JWT_SECRET`, `API_KEY_SECRET`, `MACHINE_ID_SALT`) و ذخیره‌ی همه‌چیز در `/opt/9router/.env` — اجراهای بعدی همین فایل را استفاده می‌کنند؛ پس تنظیمات، secretها و پسورد ادمین بعد از آپدیت هم باقی می‌مانند
- اجرا با PM2 (استارت خودکار بعد از ریبوت)، اتصال به `0.0.0.0` و باز کردن پورت در ufw
- تشخیص خودکار IP عمومی سرور و تنظیم `NEXT_PUBLIC_BASE_URL`
- **آپدیت خودکار روزانه** (ساعت 4:45) — خودکار فعال می‌شود؛ لاگ: `/var/log/9router-update.log`؛ اگر تغییری نباشد خیلی سریع تمام می‌شود
- ساخت swap موقت روی سرورهای کم‌رم برای جلوگیری از خطای Out of Memory هنگام بیلد
- رفع مشکل پورت هاردکد 20127 خود پروژه (اجرای مستقیم `custom-server.js` با پورت انتخابی شما)
- نصب دستور مدیریت `sudo 9router` (منو: آپدیت / حذف)

## 🔧 نصب بدون سؤال (اختیاری)

برای اتوماسیون می‌توانید مقادیر را با متغیر محیطی بدهید و هیچ سؤالی پرسیده نشود:

```bash
curl -fsSL https://raw.githubusercontent.com/xpersian/9Router-Installer/main/install.sh -o install.sh
sudo INITIAL_PASSWORD='your-admin-password' PORT=20128 bash install.sh
```

`BASE_URL` هم همین‌طور قابل تنظیم است؛ هر چیزی که ندهید با پیش‌فرض (IP عمومی سرور) پر می‌شود.

## 🧰 دستورات بعد از نصب

```bash
sudo 9router                  # منو: آپدیت | حذف
sudo 9router update           # آپدیت بی‌سوال
sudo 9router --no-auto-update # خاموش کردن آپدیت خودکار
```

```bash
pm2 status        # وضعیت
pm2 logs 9router  # لاگ‌ها
pm2 restart 9router
```

## 🗑 حذف

```bash
sudo 9router uninstall
```

اپ را متوقف می‌کند و پوشه برنامه، cron آپدیت خودکار و (در صورت تأیید) دیتای `/var/lib/9router` را پاک می‌کند.

## پیش‌نیازها

- سرور Ubuntu/Debian با دسترسی root/sudo
- اگر سرورتان پشت فایروال کلود است (Hetzner/AWS/GCP/Oracle)، پورت TCP انتخابی را آنجا هم باز کنید

---

Made for the [9Router](https://github.com/decolua/9router) community
