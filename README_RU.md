# MTProxy Installer (Ubuntu / Debian)

Production-ready installer for private Telegram MTProto Proxy on Ubuntu/Debian VPS.

Upstream: https://github.com/TelegramMessenger/MTProxy  
Repository: https://github.com/someonelikedani/MTProxy-installer

---

## Design Goals

- Минимальное вмешательство в систему
- Отсутствие скрытых изменений firewall
- Детерминированные production-сборки (фиксация tag/commit)
- Прозрачная и явная модель безопасности
- Без изменения глобальной git-конфигурации

---

## 🚀 Быстрая установка

```bash
git clone https://github.com/someonelikedani/MTProxy-installer.git
cd MTProxy-installer
sudo ./install.sh
```

### Production режим (фиксация версии)

```bash
sudo ./install.sh --ref <TAG_OR_COMMIT>
```

---

## 📦 Что делает установщик

- Клонирует официальный MTProxy
- Собирает из исходников
- Создаёт systemd unit
- Включает автозапуск
- Создаёт state-файл `/etc/mtproxy-installer.env`
- Опционально включает минимальную anti-abuse защиту

---

## 🔐 Принципы безопасности

✔ Не меняет глобальный git config  

✔ Не трогает firewall по умолчанию  
Без `--anti-abuse` сетевые правила не изменяются.

✔ Self-update с защитой supply chain  
Работает только если remote совпадает с `INSTALLER_TRUSTED_REMOTE_URL`.

✔ Права доступа  
`/etc/mtproxy-installer.env` создаётся с правами 0600 (root-only).  
Файл содержит Telegram secret в открытом виде по архитектурным причинам.

---

## 🛡 Опциональная защита (anti-abuse)

```bash
sudo ./install.sh --anti-abuse
```

Автоматический режим:

```bash
sudo ./install.sh --anti-abuse --yes
```

Особенности:

- Только rate-limit NEW/SYN
- Без ban-листов
- Не заменяет полноценный firewall или DDoS-защиту
- Предназначена для простых VPS

### Backends

```bash
sudo ./install.sh --anti-abuse --abuse-backend nft
sudo ./install.sh --anti-abuse --abuse-backend iptables
```

iptables backend использует цепочку `MTPROXY_ABUSE`, которая удаляется при uninstall.  
Не добавляйте в неё собственные правила.

---

## 🌍 IP-детект

Локальная маршрутизация используется в первую очередь.  
Внешние сервисы — только fallback.

Отключить fallback:

```bash
sudo ./install.sh --no-external-ip
```

---

## 🔎 Проверка sha256 proxy-secret (опционально)

```bash
sudo PROXY_SECRET_SHA256="<EXPECTED_SHA256>" ./install.sh
```

По умолчанию отключено.

---

## 🔄 Self-update установщика

Перед использованием:

```bash
export INSTALLER_TRUSTED_REMOTE_URL="https://github.com/someonelikedani/MTProxy-installer.git"
```

Работает только:

- При запуске из git-клона
- При совпадении URL remote

---

## 📊 Управление

```bash
sudo ./install.sh status
sudo systemctl restart mtproxy
sudo ./uninstall.sh
```

---

## CLI Flags

| Flag | Назначение |
|------|------------|
| `--ref` | Фиксация версии MTProxy |
| `--anti-abuse` | Включить минимальный rate limiting |
| `--abuse-backend` | nft / iptables backend |
| `--yes` | Неинтерактивный режим |
| `--no-external-ip` | Отключить внешние IP fallback |