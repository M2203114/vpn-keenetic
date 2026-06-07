#!/bin/sh
# Пинг серверов выхода из подписки и ранжирование по задержке.
# Использование: region-ping.sh [SUB_URL]
# Без аргумента берёт SUB_URL из /opt/etc/xray/sub.conf.
# Выводит таблицу "задержка(мс) сервер", отсортированную по возрастанию.
# С --apply ставит лучший сервер в sing-box и рестартит.

CONF=/opt/etc/xray/sub.conf
SBCFG=/opt/etc/sing-box/config.json
APPLY=0
[ "$1" = "--apply" ] && { APPLY=1; shift; }
SUB_URL="$1"
[ -z "$SUB_URL" ] && [ -f "$CONF" ] && . "$CONF"
[ -z "$SUB_URL" ] && { echo "нет SUB_URL (аргумент или $CONF)"; exit 1; }

SUB=$(curl -fsSL --max-time 30 "$SUB_URL" 2>/dev/null)
[ -z "$SUB" ] && { echo "не скачал подписку"; exit 1; }

# хосты hysteria2-серверов (JSON-формат подписки)
SERVERS=$(printf '%s' "$SUB" | grep -oE '"server"[ ]*:[ ]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | grep -E '\.' | sort -u)
[ -z "$SERVERS" ] && { echo "не нашёл серверов в подписке"; exit 1; }

# avg RTT по ICMP; недоступные в конец (9999)
rank=$(for s in $SERVERS; do
  avg=$(ping -c 3 -W 2 "$s" 2>/dev/null | sed -n 's#.*= [0-9.]*/\([0-9.]*\)/.*#\1#p')
  [ -z "$avg" ] && avg=9999
  printf '%s %s\n' "$avg" "$s"
done | sort -n)

echo "задержка(мс)  сервер"
echo "$rank" | awk '{printf "%-12s  %s\n",$1,$2}'

if [ "$APPLY" = 1 ]; then
  best=$(echo "$rank" | awk '$1!="9999"{print $2; exit}')
  [ -z "$best" ] && { echo "нет живых серверов"; exit 1; }
  echo "ставлю лучший: $best"
  sed -i "s/\"server\":\"[^\"]*\"/\"server\":\"$best\"/; s/\"server_name\":\"[^\"]*\"/\"server_name\":\"$best\"/" "$SBCFG"
  /opt/etc/init.d/S23singbox restart >/dev/null 2>&1
fi
