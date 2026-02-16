# MTProxy Installer (Ubuntu / Debian)

Production-ready installer for private Telegram MTProto Proxy on
Ubuntu/Debian VPS.

Upstream: https://github.com/TelegramMessenger/MTProxy

Repository: https://github.com/someonelikedani/MTProxy-installer

------------------------------------------------------------------------

## 📌 About

This project provides a private MTProxy installer for Ubuntu/Debian VPS.

The script:

-   builds MTProxy from source
-   creates a systemd unit
-   enables auto-start
-   securely stores installation state
-   optionally enables minimal anti-abuse protection
-   prints ready-to-use Telegram proxy links

Designed for private MTProxy usage on VPS with minimal system intrusion.

------------------------------------------------------------------------

## 🧩 Design goals

-   Minimal system changes
-   No hidden firewall modifications
-   Deterministic builds (pin by tag/commit)
-   Explicit and transparent security model
-   No changes to global git configuration
-   Uses safe local override `git -c safe.directory=...`

------------------------------------------------------------------------

## 🚀 Quick install

``` bash
git clone https://github.com/someonelikedani/MTProxy-installer.git
cd MTProxy-installer
sudo ./install.sh
```

After installation, the script prints:

-   Server IP
-   Port
-   Secret
-   Ready-to-use Telegram proxy links

```{=html}
<!-- -->

    tg://proxy?server=IP&port=PORT&secret=SECRET
    https://t.me/proxy?server=IP&port=PORT&secret=SECRET
```
You can immediately add the proxy to Telegram.

------------------------------------------------------------------------

## 🏷️ Production pinning

``` bash
sudo ./install.sh --ref <TAG_OR_COMMIT>
```

Allows pinning MTProxy to a specific tag or commit.

------------------------------------------------------------------------

## 📦 What the installer does

-   Installs required dependencies
-   Clones official MTProxy
-   Optionally pins a specific version
-   Builds binary from source
-   Creates systemd service `mtproxy`
-   Enables auto-start
-   Stores parameters in `/etc/mtproxy-installer.env`
-   Prints working proxy links

------------------------------------------------------------------------

## 🔐 Security

✔ Does not modify global git config

✔ Does not modify firewall by default

✔ `/etc/mtproxy-installer.env` is created with 0600 permissions

✔ IP detection prefers local routing

⚠️ Port 443 is not allowed as client-port.

------------------------------------------------------------------------

## 🛡️ Optional anti-abuse protection

``` bash
sudo ./install.sh --anti-abuse
```

Backends supported:

``` bash
sudo ./install.sh --anti-abuse --abuse-backend nft
sudo ./install.sh --anti-abuse --abuse-backend iptables
```

The iptables backend uses `MTPROXY_ABUSE` chain, removed during
uninstall.

------------------------------------------------------------------------

## 🔎 Optional SHA256 verification of proxy-secret

``` bash
sudo PROXY_SECRET_SHA256="<EXPECTED_SHA256>" ./install.sh
```

------------------------------------------------------------------------

## 🧰 Management

``` bash
sudo ./install.sh status
sudo ./install.sh check
sudo systemctl status mtproxy --no-pager -l
sudo journalctl -u mtproxy -f
sudo systemctl restart mtproxy
sudo ./install.sh uninstall
```

------------------------------------------------------------------------

## 🧾 CLI Flags

| Flag | Purpose |
|------|----------|
| `--ref` | Pin MTProxy to a specific tag or commit |
| `--anti-abuse` | Enable minimal connection rate limiting |
| `--abuse-backend` | Select firewall backend: `auto`, `nft`, or `iptables` |
| `--yes` | Non-interactive mode (assume "yes" for confirmations) |
| `--no-external-ip` | Disable external IP detection fallback |

