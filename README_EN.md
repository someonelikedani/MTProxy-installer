# MTProxy Installer (Ubuntu / Debian)

Production-ready installer for private Telegram MTProto Proxy on Ubuntu/Debian VPS.

Upstream: https://github.com/TelegramMessenger/MTProxy  
Repository: https://github.com/someonelikedani/MTProxy-installer

---

## Design Goals

- Minimal system interference
- No hidden firewall modifications
- Deterministic production builds (pin by tag/commit)
- Transparent and explicit security model
- No global git configuration changes

---

## 🚀 Quick Install

```bash
git clone https://github.com/someonelikedani/MTProxy-installer.git
cd MTProxy-installer
sudo ./install.sh
```

### Pinned Version (Recommended for Production)

```bash
sudo ./install.sh --ref <TAG_OR_COMMIT>
```

---

## 📦 What the Installer Does

- Clones official MTProxy
- Builds from source
- Creates systemd unit
- Enables auto-start
- Creates `/etc/mtproxy-installer.env`
- Optional minimal anti-abuse protection

---

## 🔐 Security Principles

✔ No global git config modification  

✔ Firewall untouched by default  

✔ Supply-chain gated self-update  

✔ Root-only state file (0600)  

The state file stores the Telegram secret in plain text for architectural reasons.

---

## 🛡 Optional Anti-Abuse

```bash
sudo ./install.sh --anti-abuse
```

Non-interactive:

```bash
sudo ./install.sh --anti-abuse --yes
```

Features:

- NEW/SYN rate limiting only
- No ban lists
- Not a replacement for real firewall or DDoS mitigation
- Designed for simple VPS environments

iptables backend uses `MTPROXY_ABUSE` chain which is removed during uninstall.

---

## 🌍 IP Detection

Local routing first, external services as fallback.

Disable fallback:

```bash
sudo ./install.sh --no-external-ip
```

---

## 🔎 Optional sha256 Verification

```bash
sudo PROXY_SECRET_SHA256="<EXPECTED_SHA256>" ./install.sh
```

Disabled by default.

---

## 🔄 Installer Self-Update

Before using:

```bash
export INSTALLER_TRUSTED_REMOTE_URL="https://github.com/someonelikedani/MTProxy-installer.git"
```

Works only:

- When launched from a git clone
- When the remote URL matches

---

## 🗑 Uninstall

```bash
sudo ./uninstall.sh
```

---

## CLI Flags

| Flag | Description |
|------|------------|
| `--ref` | Pin MTProxy to tag or commit |
| `--anti-abuse` | Enable minimal rate limiting |
| `--abuse-backend` | nft / iptables backend |
| `--yes` | Non-interactive mode |
| `--no-external-ip` | Disable external IP fallback |