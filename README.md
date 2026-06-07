# vpn-keenetic

Разблокировка всей сети на роутере Keenetic (Entware) для провода и WiFi, без настройки на устройствах. Правильно делит трафик по типу блокировки: VPN-туннель только для сервисов с блокировкой по IP/региону, zapret (DPI-обход) для всего остального, прямой трафик на полной скорости.

Подробнее об архитектуре - [ARCHITECTURE.md](ARCHITECTURE.md).

## Как делит трафик

| Тип блокировки | Механизм | Примеры |
|---|---|---|
| По IP/региону, выделенный диапазон | VPN-туннель (Hysteria2) | claude, Telegram (вкл. звонки) |
| По DPI/SNI | zapret (nfqws, напрямую) | YouTube, Instagram, Discord, тысячи доменов/IP |
| Не блокируется | напрямую | российские сайты, остальное |

ChatGPT/Gemini не заворачиваются (общие CDN Cloudflare/Google, по IP не отделить) - для них нужен VPN на самом устройстве.

## Состав

- **VPN**: xray (перехват ipset+REDIRECT/TPROXY) + sing-box (Hysteria2-клиент).
- **zapret**: пакет [nfqws-keenetic](https://github.com/Anonym-tsk/nfqws-keenetic) - ставится автоматически, если его нет; приносит свою стратегию desync. Наш слой сверху - geoip-список заблокированных в РФ ([runetfreedom](https://github.com/runetfreedom/russia-blocked-geoip), re-filter ~25k подсетей) с автообновлением.
- **Веб-панель**: lighttpd + CGI на `:8088` (только из локалки).

## Требования

- Keenetic с **Entware** (opkg), root по SSH.
- Подписка с Hysteria2-сервером (формат pablovpn: пароль = UUID в ссылке).
- ~30 МБ на разделе Entware.

## Установка

```sh
opkg update && opkg install curl && \
curl -fsSL https://raw.githubusercontent.com/M2203114/vpn-keenetic/main/install.sh -o /tmp/install.sh && \
SUB_URL="https://ваша-подписка/sub/UUID" sh /tmp/install.sh
```

Скрипт сам пингует серверы и берёт быстрый. Опции:

```sh
SUB_URL="..." EXIT_SERVER=nl02s2.pablo.support sh install.sh   # конкретный сервер
SUB_URL="..." NO_PANEL=1 sh install.sh                         # без веб-панели
```

После установки - панель на `http://IP-роутера:8088`.

## Веб-панель

- Статус служб, туннеля, выхода, geoip, памяти.
- Самотест: claude / claude.com / Telegram / сеть через туннель.
- Пинг серверов выхода (Hysteria2) + переключение кликом.
- Выбор geoip-категории (re-filter / ru-blocked / community).
- Рестарт VPN / zapret.

## Управление

```sh
sh /opt/etc/xray/fw.sh status                    # состояние правил и ipset
sh /opt/etc/nfqws/geoip-update.sh                # обновить geoip вручную
sh /opt/etc/vpn-panel/scripts/region-ping.sh     # пинг серверов
curl --socks5-hostname 127.0.0.1:11080 https://ifconfig.co   # IP выхода
```

- **Добавить домен в VPN** (только с выделенным IP): строка `ipset=/домен/vpn` в `/opt/etc/dnsmasq.conf`, затем `S56dnsmasq restart`.
- **Добавить домен в zapret**: строкой в `/opt/etc/nfqws/user.list`, затем `S51nfqws restart`.
- **Сменить регион**: панель или `region-ping.sh --apply`.

## Файлы

| Путь | Назначение |
|---|---|
| `/opt/etc/sing-box/config.json` | Hysteria2-клиент (сервер, пароль) |
| `/opt/etc/xray/config.json` | xray (перехват) |
| `/opt/etc/xray/fw.sh` | ipset + iptables (start/stop/status) |
| `/opt/etc/xray/failover.sh` | авто-переключение сервера |
| `/opt/etc/xray/servers.list` | серверы выхода (Hysteria2) |
| `/opt/etc/dnsmasq.conf` | DNS + домены claude |
| `/opt/etc/nfqws/` | zapret: стратегия, geoip, списки |
| `/opt/share/www/vpn-panel/`, `/opt/etc/vpn-panel/` | веб-панель |

## Claude Code и приложения с полным туннелем

Прозрачный туннель заворачивает только claude+Telegram (по выделенным IP). Приложения, которые ходят на много эндпоинтов на общих CDN (например **Claude Code**: api.anthropic.com + Statsig/featuregates.org + Sentry), по IP не завернуть - часть их трафика пойдёт напрямую и может тормозить/висеть.

Для них есть **HTTP-прокси на роутере** (`http://<LAN_IP>:10809`, только из локалки) - он пускает ВЕСЬ трафик приложения через туннель:

```sh
# разово
HTTPS_PROXY=http://192.168.1.1:10809 HTTP_PROXY=http://192.168.1.1:10809 claude
# удобно (алиас в ~/.zshrc)
alias claude='HTTPS_PROXY=http://192.168.1.1:10809 HTTP_PROXY=http://192.168.1.1:10809 claude'
```

Работает для любого устройства в сети (тот же `HTTPS_PROXY`). Подставь LAN-адрес своего роутера.

## Ограничения

- Звонки Telegram идут внутри туннеля - работают, возможна доп. задержка против прямого UDP.
- DoH/DoT на устройстве в обход роутерного DNS: домены не попадут в ipset; claude страхуется статическим диапазоном Anthropic.
- Рассчитан на подписку с Hysteria2 (формат pablovpn). Под другой формат - правка парсинга в install.sh.

## Удаление

```sh
sh uninstall.sh
```

zapret (nfqws-keenetic) при удалении остаётся - убирается только наш geoip-слой и VPN.

## Лицензия

MIT.
