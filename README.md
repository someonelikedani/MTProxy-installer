# MTProxy Installer (Ubuntu / Debian)

Production-ready installer for private Telegram MTProto Proxy on
Ubuntu/Debian VPS.

Upstream: https://github.com/TelegramMessenger/MTProxy

Repository: https://github.com/someonelikedani/MTProxy-installer

------------------------------------------------------------------------

## 📌 О проекте

Данный проект --- это установщик приватного MTProxy для VPS под
Ubuntu/Debian.

Скрипт:

-   автоматически собирает MTProxy из исходников
-   создаёт systemd unit
-   включает автозапуск
-   безопасно сохраняет состояние установки
-   опционально включает минимальную anti-abuse защиту
-   выводит готовые ссылки подключения для Telegram

Проект ориентирован на приватное использование MTProxy на VPS с
минимальным вмешательством в систему.

------------------------------------------------------------------------

## 🧩 Дизайн-принципы

-   Минимальное вмешательство в систему
-   Отсутствие скрытых изменений firewall
-   Возможность фиксации версии (tag/commit)
-   Прозрачная модель безопасности
-   Без изменения глобального git-конфига
-   Используется безопасный локальный override
    `git -c safe.directory=...`

------------------------------------------------------------------------

## 🚀 Быстрая установка

``` bash
git clone https://github.com/someonelikedani/MTProxy-installer.git
cd MTProxy-installer
sudo ./install.sh
```

После завершения установки скрипт выведет:

-   IP сервера
-   порт
-   secret
-   готовые ссылки подключения для Telegram

```{=html}
    tg://proxy?server=IP&port=PORT&secret=SECRET
    https://t.me/proxy?server=IP&port=PORT&secret=SECRET
```

Прокси можно сразу добавить в Telegram.
------------------------------------------------------------------------

## 🏷️ Production режим (фиксация версии)

``` bash
sudo ./install.sh --ref <TAG_OR_COMMIT>
```

Позволяет зафиксировать конкретный tag или commit MTProxy.

------------------------------------------------------------------------

## 📦 Что делает установщик

-   Устанавливает необходимые зависимости
-   Клонирует официальный MTProxy
-   При необходимости фиксирует конкретную версию
-   Собирает бинарник из исходников
-   Создаёт systemd сервис `mtproxy`
-   Включает автозапуск
-   Сохраняет параметры в `/etc/mtproxy-installer.env`
-   Выводит рабочие ссылки прокси

------------------------------------------------------------------------

## 🔐 Безопасность

✔ Не изменяет глобальный git config

✔ Не изменяет firewall по умолчанию

✔ State-файл `/etc/mtproxy-installer.env` создаётся с правами 0600

✔ IP-детект: сначала используется локальная маршрутизация

⚠️ Порт 443 запрещён для использования как client-port.

------------------------------------------------------------------------

## 🛡️ Опциональная защита (anti-abuse)

``` bash
sudo ./install.sh --anti-abuse
```

Поддерживаются backends:

``` bash
sudo ./install.sh --anti-abuse --abuse-backend nft
sudo ./install.sh --anti-abuse --abuse-backend iptables
```

iptables backend использует цепочку `MTPROXY_ABUSE`, которая удаляется
при uninstall.

------------------------------------------------------------------------

## 🔎 Проверка sha256 proxy-secret (опционально)

``` bash
sudo PROXY_SECRET_SHA256="<EXPECTED_SHA256>" ./install.sh
```

------------------------------------------------------------------------

## 🧰 Управление

``` bash
sudo ./install.sh status
sudo ./install.sh check
sudo systemctl status mtproxy --no-pager -l
sudo journalctl -u mtproxy -f
sudo systemctl restart mtproxy
sudo ./uninstall.sh 
```

------------------------------------------------------------------------

## 🧾 CLI Flags

| Флаг | Назначение |
|------|------------|
| `--ref` | Фиксация версии MTProxy |
| `--anti-abuse` | Включить минимальный rate limiting |
| `--abuse-backend` | nft / iptables backend |
| `--yes` | Неинтерактивный режим |
| `--no-external-ip` | Отключить внешние IP fallback |

