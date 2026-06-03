# vpn-keenetic

Транспарентный обход блокировок на роутере Keenetic (через Entware). Заворачивает в VLESS+Reality **только заблокированные сервисы** (по списку, наполняемому через DNS), весь остальной трафик идёт напрямую на полной скорости. Работает для всей сети (провод + WiFi), на всех клиентах, без настройки на устройствах.

## Что делает

- Заблокированные/замедленные в РФ сервисы (ChatGPT, Claude, Gemini, Instagram, Discord, YouTube, X и т.д. - список ~1100+ доменов от [itdoginfo](https://github.com/itdoginfo/allow-domains)) идут через ваш VLESS-сервер.
- Telegram: сообщения, медиа и **звонки** (через статические IP-диапазоны дата-центров Telegram).
- Всё остальное (российские сайты, Кинопоиск, проводной трафик) - напрямую, без потери скорости.
- Список заблокированного обновляется сам раз в сутки (cron), загрузка идёт через сам VPN - источник списка нельзя заблокировать.
- Переживает перезагрузки роутера и сбросы firewall Keenetic.

## Требования

- Роутер Keenetic с установленным **Entware** (opkg) и доступом root по SSH.
- Подписка с VLESS+Reality сервером (ссылка на subscription).
- Свободно ~10 МБ на разделе Entware.

## Установка

На роутере (SSH, root) одной командой:

```sh
opkg update && opkg install curl && \
curl -fsSL https://raw.githubusercontent.com/M2203114/vpn-keenetic/main/install.sh -o /tmp/install.sh && \
SUB_URL="https://ваша-подписка/sub/xxxx" sh /tmp/install.sh
```

Выбрать страну выхода (подстрока в имени сервера из подписки, по умолчанию `nl`):

```sh
SUB_URL="https://..." EXIT=de sh /tmp/install.sh
```

Альтернатива (без скачивания): скопируйте `install.sh` любым способом (scp, вставка через `cat > install.sh`) и запустите `SUB_URL="..." sh install.sh`.

## Как это работает

```
клиент --DNS:53--> [iptables REDIRECT] --> dnsmasq:5353 --> ndnproxy (DNS Keenetic)
                                              |
                              домен из списка -> его IP добавляется в ipset "vpn"
клиент --TCP--> [iptables: dst в ipset?] --да--> xray REDIRECT:12345 --> VLESS --> выход
                                          --нет--> напрямую (аппаратное ускорение, полная скорость)
Telegram UDP (звонки) --> [TPROXY] --> xray:12346 --> VLESS --> выход
```

- **dnsmasq** (порт 5353) перехватывает DNS клиентов, форвардит в штатный DNS Keenetic (ndnproxy), и для доменов из списка добавляет полученные IP в ipset `vpn`.
- **iptables**: DNS клиентов заворачивается в dnsmasq; TCP к адресам из ipset - в xray (REDIRECT); UDP к диапазонам Telegram - в xray (TPROXY, для звонков).
- **xray** (dokodemo-door) принимает завёрнутый трафик и гонит через VLESS+Reality на сервер выхода.

## Управление

```sh
sh /opt/etc/xray/fw.sh status          # состояние правил и размер ipset
sh /opt/etc/xray/update-domains.sh     # обновить список доменов вручную
tail -f /opt/var/log/xray.log          # лог xray (какие соединения куда)
curl --socks5-hostname 127.0.0.1:10808 https://ifconfig.co   # проверить IP выхода
```

- **Добавить свой домен** сверх списка: допишите в `/opt/etc/dnsmasq.conf` строку `ipset=/ваш-домен.com/vpn` и `/opt/etc/init.d/S56dnsmasq restart`.
- **Сменить страну выхода**: поле `address` в outbound `proxy` в `/opt/etc/xray/config.json`, затем `/opt/etc/init.d/S24xray restart`.

## Файлы

| Путь | Назначение |
|---|---|
| `/opt/etc/xray/config.json` | конфиг xray (содержит креды сервера) |
| `/opt/etc/xray/fw.sh` | правила iptables (start/stop/status) |
| `/opt/etc/xray/update-domains.sh` | обновление списка доменов |
| `/opt/etc/dnsmasq.conf`, `/opt/etc/dnsmasq.d/` | DNS + список доменов |
| `/opt/etc/init.d/S24xray`, `S25xrayfw`, `S56dnsmasq` | автозапуск |
| `/opt/etc/ndm/netfilter.d/100-xray.sh` | переустановка правил после сбросов Keenetic |

## Ограничения

- Звонки Telegram едут внутри TCP-туннеля VLESS - работают, но возможна доп. задержка против прямого UDP.
- Если приложение использует своё шифрованное DNS (DoH/DoT), его запросы идут мимо dnsmasq и в ipset не попадут - такие сервисы нужно добавлять по IP отдельно.
- Скрипт рассчитан на VLESS+Reality (tcp, flow vision) - именно такой формат в типовых подписках.

## Удаление

```sh
sh uninstall.sh
```

## Лицензия

MIT.
