#!/bin/sh
export PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin
# Пинг серверов выхода из подписки и ранжирование по задержке.
# Использование: region-ping.sh [--apply] [--json] [SUB_URL]
#   --apply  поставить лучший сервер в sing-box и перезапустить
#   --json   вывод в JSON (для веб-панели)
# Без SUB_URL берёт его из /opt/etc/xray/sub.conf.

CONF=/opt/etc/xray/sub.conf
SBCFG=/opt/etc/sing-box/config.json
APPLY=0; JSON=0
while :; do
  case "$1" in
    --apply) APPLY=1; shift;;
    --json)  JSON=1; shift;;
    *) break;;
  esac
done
SUB_URL="$1"
[ -z "$SUB_URL" ] && [ -f "$CONF" ] && . "$CONF"
[ -z "$SUB_URL" ] && { echo '{"error":"no SUB_URL"}'; exit 1; }

SUB=$(curl -fsSL --max-time 30 "$SUB_URL" 2>/dev/null)
[ -z "$SUB" ] && { echo '{"error":"subscription fetch failed"}'; exit 1; }

SERVERS=$(printf '%s' "$SUB" | grep -oE '"server"[ ]*:[ ]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | grep -E '\.' | sort -u)
[ -z "$SERVERS" ] && { echo '{"error":"no servers in subscription"}'; exit 1; }

# avg RTT по ICMP; недоступные = 9999
rank=$(for s in $SERVERS; do
  avg=$(ping -c 3 -W 2 "$s" 2>/dev/null | sed -n 's#.*= [0-9.]*/\([0-9.]*\)/.*#\1#p')
  [ -z "$avg" ] && avg=9999
  printf '%s %s\n' "$avg" "$s"
done | sort -n)

best=$(echo "$rank" | awk '$1!="9999"{print $2; exit}')

if [ "$APPLY" = 1 ] && [ -n "$best" ]; then
  sed -i "s/\"server\":\"[^\"]*\"/\"server\":\"$best\"/; s/\"server_name\":\"[^\"]*\"/\"server_name\":\"$best\"/" "$SBCFG"
  /opt/etc/init.d/S23singbox restart >/dev/null 2>&1
fi

if [ "$JSON" = 1 ]; then
  printf '{"best":"%s","servers":[' "$best"
  i=0
  echo "$rank" | while read rtt srv; do
    [ "$i" = 0 ] || printf ','
    printf '{"server":"%s","rtt":%s}' "$srv" "$rtt"
    i=1
  done
  printf ']}\n'
else
  echo "задержка(мс)  сервер"
  echo "$rank" | awk '{printf "%-12s  %s\n",$1,$2}'
  [ "$APPLY" = 1 ] && echo "выбран: $best"
fi
