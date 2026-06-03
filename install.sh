#!/bin/sh
# vpn-keenetic: транспарентный обход блокировок на Keenetic (Entware).
# Заворачивает в VLESS+Reality только заблокированные сервисы (по ipset, наполняемому
# через DNS), остальной трафик идёт напрямую на полной скорости.
#
# Использование:
#   SUB_URL="https://ваша-подписка" sh install.sh
#   SUB_URL="https://..." EXIT=de sh install.sh      # выбрать страну выхода (подстрока в имени сервера)
#
# Требования: роутер Keenetic с установленным Entware (opkg), доступ root по SSH.

SUB_URL="${SUB_URL:-$1}"
EXIT="${EXIT:-nl}"                       # подстрока для выбора сервера из подписки
XDIR=/opt/etc/xray
REDIR=12345; TPROXY_UDP=12346; SOCKS=10808; DNSP=5353; MARK=1; RT=100
DOMAINS_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-ipset.lst"
# Официальные диапазоны дата-центров Telegram (приложение ходит на них по IP, без DNS).
TG_NETS="91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 95.161.64.0/20 149.154.160.0/20 91.105.192.0/23 185.76.151.0/24"
# Базовый список доменов (на случай, если авто-список не скачается на первом запуске).
BASE_DOMAINS="openai.com chatgpt.com oaistatic.com oaiusercontent.com anthropic.com claude.ai claude.com gemini.google.com generativelanguage.googleapis.com discord.com discord.gg discordapp.com discordapp.net discord.media instagram.com cdninstagram.com fbcdn.net facebook.com meta.ai x.com twitter.com twimg.com t.co youtube.com youtu.be ytimg.com googlevideo.com ggpht.com telegram.org t.me telegram.me spotify.com scdn.co netflix.com nflxvideo.net"

[ -z "$SUB_URL" ] && { echo "ОШИБКА: задайте подписку: SUB_URL=\"https://...\" sh install.sh"; exit 1; }

echo "==> [1/8] Установка пакетов (opkg)"
opkg update >/dev/null 2>&1 || true
opkg install xray ipset dnsmasq-full curl ca-bundle cron iptables 2>&1 | grep -iE "Installing|up to date|error" || true

echo "==> [2/8] Определение LAN-сегментов"
LANS=""; LAN_LISTEN="127.0.0.1"
for br in $(ls /sys/class/net/ 2>/dev/null | grep '^br'); do
    ip=$(ip -o -4 addr show dev "$br" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    case "$ip" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
            LANS="$LANS $br"; LAN_LISTEN="$LAN_LISTEN,$ip" ;;
    esac
done
LANS=$(echo $LANS | xargs)
[ -z "$LANS" ] && { echo "ОШИБКА: не найдено ни одного LAN-моста (br*) с приватным IP"; exit 1; }
echo "    сегменты: $LANS   dnsmasq слушает: $LAN_LISTEN"

echo "==> [3/8] Разбор подписки (страна выхода: $EXIT)"
curl -s --max-time 40 "$SUB_URL" -o /tmp/sub.raw
base64 -d /tmp/sub.raw 2>/dev/null > /tmp/sub.txt || true
grep -q '^vless://' /tmp/sub.txt 2>/dev/null || cp /tmp/sub.raw /tmp/sub.txt
LINE=$(grep -i "vless://[^#]*$EXIT" /tmp/sub.txt | head -1)
[ -z "$LINE" ] && LINE=$(grep '^vless://' /tmp/sub.txt | head -1)
[ -z "$LINE" ] && { echo "ОШИБКА: в подписке не найдено vless-серверов"; exit 1; }
LINE=${LINE%%#*}
HOST=$(echo "$LINE" | sed -n 's#vless://[^@]*@\([^:]*\):.*#\1#p')
PORT=$(echo "$LINE" | sed -n 's#vless://[^@]*@[^:]*:\([0-9]*\).*#\1#p')
UUID=$(echo "$LINE" | sed -n 's#vless://\([^@]*\)@.*#\1#p')
PBK=$(echo "$LINE"  | sed -n 's#.*[?&]pbk=\([^&]*\).*#\1#p')
SID=$(echo "$LINE"  | sed -n 's#.*[?&]sid=\([^&]*\).*#\1#p')
SNI=$(echo "$LINE"  | sed -n 's#.*[?&]sni=\([^&]*\).*#\1#p')
FLOW=$(echo "$LINE" | sed -n 's#.*[?&]flow=\([^&]*\).*#\1#p')
[ -z "$PORT" ] && PORT=443
[ -z "$FLOW" ] && FLOW=xtls-rprx-vision
[ -z "$SNI" ] && SNI=www.google.com
if [ -z "$UUID" ] || [ -z "$HOST" ] || [ -z "$PBK" ]; then
    echo "ОШИБКА: не удалось разобрать сервер (нужны uuid/host/pbk). Строка: $HOST"; exit 1
fi
echo "    сервер: $HOST:$PORT  sni=$SNI"

echo "==> [4/8] Конфиг xray ($XDIR/config.json)"
mkdir -p "$XDIR" /opt/var/log
cat > "$XDIR/config.json" <<XCFG
{
  "log": { "access": "/opt/var/log/xray.log", "loglevel": "warning" },
  "inbounds": [
    { "tag":"redir-in","listen":"0.0.0.0","port":$REDIR,"protocol":"dokodemo-door","settings":{"network":"tcp","followRedirect":true},"sniffing":{"enabled":true,"destOverride":["http","tls"]} },
    { "tag":"tproxy-udp","listen":"0.0.0.0","port":$TPROXY_UDP,"protocol":"dokodemo-door","settings":{"network":"udp","followRedirect":true},"streamSettings":{"sockopt":{"tproxy":"tproxy"}} },
    { "tag":"socks-in","listen":"127.0.0.1","port":$SOCKS,"protocol":"socks","settings":{"udp":true} }
  ],
  "outbounds": [
    { "tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"$HOST","port":$PORT,"users":[{"id":"$UUID","encryption":"none","flow":"$FLOW"}]}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":false,"serverName":"$SNI","fingerprint":"chrome","publicKey":"$PBK","shortId":"$SID","spiderX":""},"sockopt":{"mark":255}} },
    { "tag":"direct","protocol":"freedom","settings":{"domainStrategy":"AsIs"},"streamSettings":{"sockopt":{"mark":255}} },
    { "tag":"block","protocol":"blackhole" }
  ],
  "routing": { "domainStrategy":"AsIs","rules":[ {"type":"field","ip":["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8","100.64.0.0/10","169.254.0.0/16"],"outboundTag":"direct"} ] }
}
XCFG

echo "==> [5/8] dnsmasq на :$DNSP (наполняет ipset)"
/opt/etc/init.d/S56dnsmasq stop 2>/dev/null || true
BASE_IPSET=$(echo "$BASE_DOMAINS" | tr ' ' '\n' | sed 's#^#/#' | tr -d '\n')
cat > /opt/etc/dnsmasq.conf <<DCFG
port=$DNSP
listen-address=$LAN_LISTEN
bind-interfaces
no-resolv
server=127.0.0.1#53
cache-size=1000
conf-dir=/opt/etc/dnsmasq.d/,*.conf
ipset=${BASE_IPSET}/vpn
DCFG
mkdir -p /opt/etc/dnsmasq.d

echo "==> [6/8] Правила перехвата ($XDIR/fw.sh)"
cat > "$XDIR/fw.sh" <<FW
#!/bin/sh
PATH=/opt/sbin:/opt/bin:/sbin:/bin:/usr/sbin:/usr/bin
IPSET=vpn
IPSET_TG=vpn_tg
REDIR=$REDIR
TPROXY_UDP=$TPROXY_UDP
DNSP=$DNSP
MARK=$MARK
RT=$RT
LANS="$LANS"
MD="/lib/modules/\$(uname -r)"
TG_NETS="$TG_NETS"
mods() { for m in ip_set ip_set_hash_ip ip_set_hash_net xt_set nf_nat_redirect xt_TPROXY; do lsmod|grep -q "^\$m " || insmod \$MD/\$m.ko 2>/dev/null; done; }
ensure_sets() {
  ipset create \$IPSET hash:ip 2>/dev/null
  ipset create \$IPSET_TG hash:net 2>/dev/null
  for n in \$TG_NETS; do ipset add \$IPSET_TG \$n 2>/dev/null; done
}
start() {
  mods; ensure_sets
  ip rule add fwmark \$MARK lookup \$RT 2>/dev/null
  ip route show table \$RT 2>/dev/null | grep -q "local default" || ip route add local default dev lo table \$RT 2>/dev/null
  for i in \$LANS; do
    iptables -t nat -A PREROUTING -i \$i -p udp --dport 53 -j REDIRECT --to-ports \$DNSP
    iptables -t nat -A PREROUTING -i \$i -p tcp --dport 53 -j REDIRECT --to-ports \$DNSP
    iptables -t nat -A PREROUTING -i \$i -p tcp -m set --match-set \$IPSET dst -j REDIRECT --to-ports \$REDIR
    iptables -t nat -A PREROUTING -i \$i -p tcp -m set --match-set \$IPSET_TG dst -j REDIRECT --to-ports \$REDIR
    iptables -A FORWARD -i \$i -p udp --dport 443 -m set --match-set \$IPSET dst -j DROP
    iptables -t mangle -A PREROUTING -i \$i -p udp -m set --match-set \$IPSET_TG dst -j TPROXY --on-port \$TPROXY_UDP --tproxy-mark \$MARK
  done
}
stop() {
  for i in \$LANS; do
    iptables -t nat -D PREROUTING -i \$i -p udp --dport 53 -j REDIRECT --to-ports \$DNSP 2>/dev/null
    iptables -t nat -D PREROUTING -i \$i -p tcp --dport 53 -j REDIRECT --to-ports \$DNSP 2>/dev/null
    iptables -t nat -D PREROUTING -i \$i -p tcp -m set --match-set \$IPSET dst -j REDIRECT --to-ports \$REDIR 2>/dev/null
    iptables -t nat -D PREROUTING -i \$i -p tcp -m set --match-set \$IPSET_TG dst -j REDIRECT --to-ports \$REDIR 2>/dev/null
    iptables -D FORWARD -i \$i -p udp --dport 443 -m set --match-set \$IPSET dst -j DROP 2>/dev/null
    iptables -t mangle -D PREROUTING -i \$i -p udp -m set --match-set \$IPSET_TG dst -j TPROXY --on-port \$TPROXY_UDP --tproxy-mark \$MARK 2>/dev/null
  done
}
case "\$1" in
  start) stop; start; echo "fw started";;
  stop) stop; echo "fw stopped";;
  status) echo "-- nat --"; iptables -t nat -L PREROUTING -n -v|grep REDIRECT; echo "-- mangle --"; iptables -t mangle -L PREROUTING -n -v|grep TPROXY; echo "vpn=\$(ipset list \$IPSET 2>/dev/null|grep -cE '^[0-9]') vpn_tg=\$(ipset list \$IPSET_TG 2>/dev/null|grep -cE '^[0-9]')";;
  *) echo "usage: start|stop|status";;
esac
FW
chmod +x "$XDIR/fw.sh"

echo "==> [7/8] Автообновление списка + автозапуск"
cat > "$XDIR/update-domains.sh" <<UPD
#!/bin/sh
PATH=/opt/sbin:/opt/bin:/sbin:/bin:/usr/sbin:/usr/bin
URL="$DOMAINS_URL"
TMP=/tmp/vpn-domains.new
OUT=/opt/etc/dnsmasq.d/vpn-domains.conf
curl -s --max-time 90 --socks5-hostname 127.0.0.1:$SOCKS "\$URL" -o "\$TMP" 2>/dev/null
[ -s "\$TMP" ] && grep -q "ipset=" "\$TMP" || curl -sk --max-time 90 "\$URL" -o "\$TMP" 2>/dev/null
if [ -s "\$TMP" ] && grep -q "ipset=" "\$TMP"; then
  sed 's#/[^/]*\$#/vpn#' "\$TMP" > "\$OUT"
  if /opt/sbin/dnsmasq --test -C /opt/etc/dnsmasq.conf >/dev/null 2>&1; then
    /opt/etc/init.d/S56dnsmasq restart >/dev/null 2>&1
    echo "\$(date): updated \$(grep -c ipset= "\$OUT") domains"
  else
    rm -f "\$OUT"; echo "\$(date): config test FAILED, reverted"
  fi
else
  echo "\$(date): fetch failed, kept current"
fi
UPD
chmod +x "$XDIR/update-domains.sh"

# init.d: firewall после xray (S24xray ставит пакет xray)
cat > /opt/etc/init.d/S25xrayfw <<IEOF
#!/bin/sh
case "\$1" in
  start) sh $XDIR/fw.sh start;;
  stop) sh $XDIR/fw.sh stop;;
  restart) sh $XDIR/fw.sh start;;
esac
IEOF
chmod +x /opt/etc/init.d/S25xrayfw

# netfilter.d-хук: Keenetic сбрасывает наши правила -> переустанавливаем после его реконфигов
mkdir -p /opt/etc/ndm/netfilter.d
cat > /opt/etc/ndm/netfilter.d/100-xray.sh <<HEOF
#!/bin/sh
[ "\$type" = "ip6tables" ] && exit 0
[ "\$table" = "nat" ] || [ "\$table" = "filter" ] || exit 0
sh $XDIR/fw.sh start
HEOF
chmod +x /opt/etc/ndm/netfilter.d/100-xray.sh

# cron daily 05:00
( crontab -l 2>/dev/null | grep -v update-domains; echo "0 5 * * * $XDIR/update-domains.sh >> /opt/var/log/vpn-update.log 2>&1" ) | crontab - 2>/dev/null

echo "==> [8/8] Запуск"
# Восстанавливаем службы, если ранее были отключены (например, прошлым uninstall).
[ -f /opt/etc/init.d/S24xray.off ] && mv -f /opt/etc/init.d/S24xray.off /opt/etc/init.d/S24xray
sed -i 's/^ENABLED=.*/ENABLED=yes/' /opt/etc/init.d/S56dnsmasq 2>/dev/null
/opt/etc/init.d/S24xray restart >/dev/null 2>&1; sleep 2
/opt/etc/init.d/S56dnsmasq restart >/dev/null 2>&1; sleep 1
/opt/etc/init.d/S10cron start     >/dev/null 2>&1 || true
sh "$XDIR/fw.sh" start >/dev/null 2>&1
sh "$XDIR/update-domains.sh" || true

echo
echo "================ ГОТОВО ================"
echo "Сервер выхода : $HOST:$PORT"
echo "Сегменты      : $LANS"
echo "xray          : $(ps w|grep -v grep|grep -c 'xray run') | dnsmasq: $(ps w|grep -v grep|grep -c '[d]nsmasq') | cron: $(ps w|grep -v grep|grep -c '[c]ron ')"
sh "$XDIR/fw.sh" status
echo "Проверка выхода: curl --socks5-hostname 127.0.0.1:$SOCKS https://ifconfig.co"
echo "========================================"
