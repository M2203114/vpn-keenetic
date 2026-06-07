#!/bin/sh
export PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin
# Обновление geoip-списков заблокированных в РФ для zapret (nfqws).
# Тянет CIDR-списки из runetfreedom/russia-blocked-geoip через VPN-туннель
# (github в РФ режется), валидирует и подменяет ipset-файлы nfqws, рестартит сервис.
#
# Категория задаётся в /opt/etc/nfqws/geoip.conf (GEOIP_LIST), по умолчанию re-filter.
# Доступные: re-filter (рекоменд.), ru-blocked (полный реестр РКН), ru-blocked-community.

DIR=/opt/etc/nfqws
CONF=$DIR/geoip.conf
LOG=/opt/var/log/geoip-update.log
SOCKS="--socks5-hostname 127.0.0.1:10808"   # выход через xray (туннель)
BASE="https://raw.githubusercontent.com/runetfreedom/russia-blocked-geoip/release/text"

GEOIP_LIST=re-filter
[ -f "$CONF" ] && . "$CONF"

log(){ echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$LOG"; }
# скачать: сначала через туннель, потом напрямую (фолбэк)
get(){ curl -fsSL --max-time 150 $SOCKS "$1" -o "$2" 2>/dev/null || curl -fsSL --max-time 150 "$1" -o "$2" 2>/dev/null; }
# валидно, если непусто и >1000 строк вида CIDR
okc(){ [ -s "$1" ] && [ "$(grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' "$1")" -gt 1000 ]; }

changed=0

get "$BASE/$GEOIP_LIST.txt" /tmp/gi_block
if okc /tmp/gi_block; then
  mv /tmp/gi_block "$DIR/ipset.list"; changed=1
  log "ipset.list ($GEOIP_LIST) = $(wc -l < "$DIR/ipset.list") строк"
else
  rm -f /tmp/gi_block; log "ОШИБКА: не скачал $GEOIP_LIST, оставил старый список"
fi

# белый список + пользовательские исключения (ipset_exclude.user сохраняется между обновлениями)
get "$BASE/ru-whitelist.txt" /tmp/gi_wl
if okc /tmp/gi_wl; then
  cat "$DIR/ipset_exclude.user" /tmp/gi_wl 2>/dev/null | sort -u > "$DIR/ipset_exclude.list"
  rm -f /tmp/gi_wl; changed=1
  log "ipset_exclude.list = $(wc -l < "$DIR/ipset_exclude.list") строк"
else
  rm -f /tmp/gi_wl
fi

[ "$changed" = 1 ] && /opt/etc/init.d/S51nfqws restart >/dev/null 2>&1
