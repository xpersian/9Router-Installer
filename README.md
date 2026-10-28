# 9Router Installer

**One-line installer & auto-updater for [9Router](https://github.com/decolua/9router) on any Ubuntu/Debian VPS.**

## ⚡ One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/xpersian/9Router-Installer/main/9router-npm-script.sh -o install.sh
sudo bash 9router-npm-script.sh
```

The first run asks for your admin password, port (default `20128`) and public URL, then installs everything. **Run the same command again later and it silently updates** — reusing your saved config, no prompts.

## ✨ What it does

- Installs/updates the latest **Node.js 22.x** (resolves NodeSource/apt conflicts, fixes broken npm installs)
- Clones and builds 9Router from source into `/opt/9router` (data: `/var/lib/9router`)
- Auto-generates secure secrets (`JWT_SECRET`, `API_KEY_SECRET`, `MACHINE_ID_SALT`)
- Runs it with **PM2** (auto-start on reboot), binds `0.0.0.0`, opens the port in **ufw**
- Detects the server's public IP and sets `NEXT_PUBLIC_BASE_URL`
- **Daily auto-update cron** (04:45) — enabled automatically; log: `/var/log/9router-update.log`
- Creates a 2–4 GB temporary swap on low-RAM VPSes so the build never OOMs
- Works around 9Router's hardcoded `--port 20127` by launching `custom-server.js` directly with your chosen port

## 🧰 After install

```bash
sudo 9router                  # menu: Install/Update | Uninstall
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

- **اجرا اول:** پسورد ادمین، پورت (پیش‌فرض `20128`) و آدرس عمومی را می‌پرسد و همه‌چیز را نصب می‌کند (Node.js، بیلد، PM2، فایروال، آپدیت خودکار روزانه)
- **اجرا دوم به بعد:** بدون هیچ سوالی، فقط آپدیت بی‌صدا با همان تنظیمات ذخیره‌شده

## ✨ امکانات

- نصب/ارتقای خودکار آخرین نسخه Node.js 22.x و حل تعارض‌های npm در اوبونتو
- بیلد از سورس در `/opt/9router` و دیتا در `/var/lib/9router`
- تولید خودکار secretهای امن (`JWT_SECRET`, `API_KEY_SECRET`, `MACHINE_ID_SALT`)
- اجرا با PM2 (استارت خودکار بعد از ریبوت)، اتصال به `0.0.0.0` و باز کردن پورت در ufw
- تشخیص خودکار IP عمومی سرور و تنظیم `NEXT_PUBLIC_BASE_URL`
- **آپدیت خودکار روزانه** (ساعت 4:45) — خودکار فعال می‌شود؛ لاگ: `/var/log/9router-update.log`
- ساخت swap موقت روی سرورهای کم‌رم برای جلوگیری از خطای Out of Memory هنگام بیلد
- رفع مشکل پورت هاردکد 20127 خود پروژه (اجرای مستقیم `custom-server.js` با پورت انتخابی شما)

## 🧰 دستورات بعد از نصب

```bash
sudo 9router                  # منو: نصب/آپدیت | حذف
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
