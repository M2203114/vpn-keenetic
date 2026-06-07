# Архитектура

Два независимых механизма обхода, каждый под свой тип блокировки. Это принципиально: смешивать нельзя.

## 1. VPN (xray + sing-box, Hysteria2) - для блокировок по IP/региону

Сервисы, которые режут российские IP на стороне сервера (DPI-обход тут бесполезен, нужен реальный зарубежный IP). Заворачиваются в туннель **только сервисы с выделенными диапазонами IP**:

- **claude / Anthropic** - диапазон `160.79.104.0/23` (статикой) + домены через DNS.
- **Telegram** - статические диапазоны дата-центров (вкл. звонки по UDP).

Механизм: ipset (`vpn` hash:ip из DNS, `vpn_tg` hash:net статикой) + iptables REDIRECT/TPROXY на xray dokodemo, далее цепочка xray -> socks -> sing-box -> Hysteria2 на сервер выхода.

**Нельзя заворачивать в VPN сервисы на общих CDN** (ChatGPT, Gemini - Cloudflare/Google): выделенного диапазона нет, по IP не отделить от чужих сайтов, завернёшь пол-интернета -> туннель захлёбывается. Такие сервисы - только VPN-приложение на устройстве.

## 2. zapret (nfqws) - для DPI-блокировок

Сервисы, которые режутся по DPI/SNI (YouTube, Instagram, Discord и тысячи других). Обходятся **напрямую, без туннеля** (полная скорость, без пинга) фрагментацией/подменой пакетов.

- Списки доменов: `/opt/etc/nfqws/user.list`.
- Списки IP (geoip): `/opt/etc/nfqws/ipset.list` из [runetfreedom/russia-blocked-geoip](https://github.com/runetfreedom/russia-blocked-geoip), автообновление через туннель (`scripts/geoip-update.sh`, cron 12ч).
- Белый список (исключения): `/opt/etc/nfqws/ipset_exclude.list`.

## Выбор сервера выхода

`scripts/region-ping.sh` парсит подписку, пингует серверы, ранжирует по задержке, ставит лучший. `failover.sh` (cron) переключает на живой, если текущий умер.

## Куда что добавлять

| Тип блокировки | Куда | Файл |
|---|---|---|
| По региону/IP, есть выделенный диапазон (claude) | VPN | dnsmasq.conf / fw.sh |
| По региону, общий CDN (ChatGPT/Gemini) | только VPN на устройстве | - |
| DPI/SNI (YouTube/Instagram/...) | zapret | user.list / geoip ipset.list |
