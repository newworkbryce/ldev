# Local Projects Dashboard

A React app that lists your local dev projects (name, URL, port, platform) and lets you add or remove them.

- **App location:** `~/Sites/local-projects-dashboard/`
- **Config storage:** By default the config (projects list + app settings) is stored at **`~/Sites/local-projects-dashboard.json`**. You can change the Sites directory and local TLD (default `.ldev`) in **Settings** (gear icon). The app keeps a small bootstrap file in its own `data/config-path.json` so it knows where to find the main config after a rebuild.

## Development (React + Vite)

```bash
npm install
# In one terminal, run PHP so the API is available:
php -S 127.0.0.1:8080
# In another terminal, run the dev server (proxies api.php to port 8080):
npm run dev
```

Open the URL Vite prints (e.g. http://localhost:5173). To build for production:

```bash
npm run build
```

Output is in **`dist/`**. To serve the **built** app on **port 80** (Apache), run (in your terminal so you can enter your password when prompted):

```bash
./serve-built-on-port80.sh
```

This builds the app, copies `api.php`, `data/`, and `.htaccess` into `dist/`, updates the Apache port-80 vhost to use `dist/` as DocumentRoot, and restarts Apache. After that, http://localhost/ and http://seasonal-drops.ldev/ serve the built React app.

**If the built app shows "Failed to load projects"**: the front end is calling `/api.php` on the same origin. Ensure (1) the port-80 vhost has PHP enabled for the dashboard DocumentRoot (e.g. `proxy:fcgi://127.0.0.1:9000` or `mod_php` for that directory), and (2) no rewrite rule is sending `/api.php` to `index.html`. The copied `dist/.htaccess` tells Apache not to rewrite `api.php`. If you use a catch-all SPA rule elsewhere, exclude `api.php` from it.

---

## One-time setup (Apache on port 80, 8080, 8443)

To serve this dashboard on **port 80** and have **Homebrew Apache** be the only web server (port 80 = dashboard, 8080/8443 = your projects):

```bash
cd ~/Sites/local-projects-dashboard
./setup-homebrew-apache-port80.sh
```

The script will ask for your password. It:

1. **Disables macOS system Apache** so it no longer uses port 80.
2. **Fixes** `/opt/homebrew/etc/httpd/httpd.conf` (enables `Listen 80`, keeps main DocumentRoot as `/opt/homebrew/var/www`).
3. **Adds** `ServerAlias *.ldev` to the port 80 vhost if missing.
4. **Installs and starts** Homebrew Apache as a LaunchDaemon (runs as root so it can bind to port 80).

After that:

- **http://localhost/** and **http://seasonal-drops.ldev/** (port 80) → this dashboard  
- **http://seasonal-drops.ldev:8080/** → your WordPress site (HTTP)  
- **https://seasonal-drops.ldev:8443/** → your WordPress site (HTTPS)

Do **not** use `brew services start httpd`; the LaunchDaemon runs Apache.

---

## Restart Apache

After editing Apache config (e.g. vhosts or `httpd.conf`):

```bash
cd ~/Sites/local-projects-dashboard
./restart-homebrew-apache.sh
```

---

## Requirements

- **Homebrew Apache** (`brew install httpd`) and **PHP** (e.g. PHP-FPM on 127.0.0.1:9000).
- The dashboard vhosts use `proxy:fcgi://127.0.0.1:9000` for PHP.
- **data/** must be writable so `data/projects.json` can be created and updated.

---

## Troubleshooting

- **Port 80 shows "It works!"** — macOS system Apache is still running. Run `./setup-homebrew-apache-port80.sh` again (it disables system Apache).
- **Port 80 connection refused** — LaunchDaemon may not be running. Run `./restart-homebrew-apache.sh`. Check: `sudo lsof -i :80 -P -n` (you should see `/opt/homebrew/opt/httpd/bin/httpd`).
- **LaunchDaemon won’t start** — Check: `sudo cat /opt/homebrew/var/log/httpd/launchd_stderr.log`. Run `/opt/homebrew/opt/httpd/bin/httpd -t` to test Apache config.
- **Stop Apache:** `sudo launchctl bootout system/org.apache.httpd.homebrew`  
- **Start Apache:** `sudo launchctl bootstrap system /Library/LaunchDaemons/org.apache.httpd.homebrew.plist`
