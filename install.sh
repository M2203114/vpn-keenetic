#!/bin/sh
# vpn-keenetic: установщик связки VPN (Hysteria2) + zapret(geoip) + веб-панель для Keenetic/Entware.
# Заворачивает в туннель сервисы с выделенными IP (claude, Telegram), остальное отдаёт zapret/напрямую.
#
# Запуск:
#   SUB_URL="https://.../sub/UUID" sh install.sh
# Опции (env):
#   EXIT_SERVER=nl02s2.pablo.support   конкретный сервер выхода (иначе - пинг и выбор лучшего)
#   LANS="br0 br1"                     LAN-интерфейсы (по умолчанию автоопределение)
#   NO_PANEL=1                         не ставить веб-панель
# best-effort: не используем set -e (рестарты служб через rc.func часто дают ненулевой код),
# критичные проверки делаем явно.
SUB_URL="${SUB_URL:-}"
[ -z "$SUB_URL" ] && { echo "Задай SUB_URL: SUB_URL=\"https://.../sub/UUID\" sh install.sh"; exit 1; }
PASS=$(printf '%s' "$SUB_URL" | sed 's#.*/##')   # пароль hysteria2 = UUID в конце ссылки (pablovpn)
[ -z "$PASS" ] && { echo "не извлёк пароль из SUB_URL"; exit 1; }

OPT=/opt/etc
log(){ echo "[*] $1"; }

# --- встроенный список серверов выхода (Hysteria2) ---
DEFAULT_SERVERS="nl02s2.pablo.support sp01s1.pablo.support fr03s2.pablo.support fr02s1.pablo.support eng04s2.pablo.support ger04s2.pablo.support ger03s2.pablo.support us06s1.pablo.support tr3s02.pablo.support"

# --- LAN автоопределение ---
if [ -z "$LANS" ]; then
  LANS=$(for i in br0 br1; do ip link show "$i" >/dev/null 2>&1 && printf '%s ' "$i"; done)
  LANS=${LANS:-br0}
fi
LAN_IPS=$(for i in $LANS; do ip -4 addr show "$i" 2>/dev/null | sed -n 's#.*inet \([0-9.]*\)/.*#\1#p'; done | tr '\n' ',' | sed 's/,$//')
log "LAN: $LANS ($LAN_IPS)"

# ===================== пакеты =====================
log "ставлю пакеты"
opkg update >/dev/null 2>&1 || true
for p in curl drill ipset iptables ip6tables dnsmasq-full xray-core; do
  opkg install "$p" >/dev/null 2>&1 || true
done

# sing-box (Hysteria2-клиент): ставим, если нет
if [ ! -x /opt/bin/sing-box ] && [ ! -x /opt/sbin/sing-box ]; then
  log "ставлю sing-box"
  opkg install sing-box >/dev/null 2>&1 || true
fi
command -v xray >/dev/null || { echo "xray не установился - проверь feed Entware"; exit 1; }

mkdir -p $OPT/xray $OPT/sing-box /opt/var/log /opt/var/run

# ===================== выбор сервера =====================
echo "$DEFAULT_SERVERS" | tr ' ' '\n' > $OPT/xray/servers.list
echo "SUB_URL=\"$SUB_URL\"" > $OPT/xray/sub.conf; chmod 600 $OPT/xray/sub.conf
SERVER="${EXIT_SERVER:-}"
if [ -z "$SERVER" ]; then
  log "пингую серверы, выбираю лучший"
  SERVER=$(for s in $DEFAULT_SERVERS; do
    a=$(ping -c 2 -W 2 "$s" 2>/dev/null | sed -n 's#.*= [0-9.]*/\([0-9.]*\)/.*#\1#p'); [ -z "$a" ] && a=9999
    echo "$a $s"; done | sort -n | awk 'NR==1{print $2}')
fi
SERVER=${SERVER:-nl02s2.pablo.support}
log "сервер выхода: $SERVER"

# ===================== sing-box (Hysteria2) =====================
cat > $OPT/sing-box/config.json <<JSON
{ "log":{"level":"warn"}, "inbounds":[{"type":"socks","listen":"127.0.0.1","listen_port":11080}],
"outbounds":[{"type":"hysteria2","server":"$SERVER","server_port":443,"password":"$PASS","tls":{"enabled":true,"server_name":"$SERVER","alpn":["h3"]}}] }
JSON

# ===================== xray =====================
cat > $OPT/xray/config.json <<'JSON'
{
"log": { "access": "/opt/var/log/xray.log", "loglevel": "warning" },
"inbounds": [
{ "tag":"redir-in","listen":"0.0.0.0","port":12345,"protocol":"dokodemo-door","settings":{"network":"tcp","followRedirect":true},"sniffing":{"enabled":true,"destOverride":["http","tls"]} },
{ "tag":"tproxy-udp","listen":"0.0.0.0","port":12346,"protocol":"dokodemo-door","settings":{"network":"udp","followRedirect":true},"streamSettings":{"sockopt":{"tproxy":"tproxy"}} },
{ "tag":"socks-in","listen":"127.0.0.1","port":10808,"protocol":"socks","settings":{"udp":true} }
],
"outbounds": [
{ "tag":"proxy","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":11080}]},"streamSettings":{"sockopt":{"mark":255}} },
{ "tag":"direct","protocol":"freedom","settings":{"domainStrategy":"AsIs"},"streamSettings":{"sockopt":{"mark":255}} },
{ "tag":"block","protocol":"blackhole" }
],
"routing": { "domainStrategy":"AsIs","rules":[ {"type":"field","ip":["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8","100.64.0.0/10","169.254.0.0/16"],"outboundTag":"direct"} ] }
}
JSON

# ===================== firewall (ipset + iptables) =====================
cat > $OPT/xray/fw.sh <<FW
#!/bin/sh
PATH=/opt/sbin:/opt/bin:/sbin:/bin:/usr/sbin:/usr/bin
IPSET=vpn; IPSET_TG=vpn_tg; REDIR=12345; TPROXY_UDP=12346; DNSP=5353; MARK=1; RT=100
LANS="$LANS"
MD="/lib/modules/\$(uname -r)"
TG_NETS="160.79.104.0/23 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 95.161.64.0/20 149.154.160.0/20 91.105.192.0/23 185.76.151.0/24"
mods(){ for m in ip_set ip_set_hash_ip ip_set_hash_net xt_set nf_nat_redirect xt_TPROXY; do lsmod|grep -q "^\$m " || insmod \$MD/\$m.ko 2>/dev/null; done; }
ensure_sets(){
  ipset create \$IPSET hash:ip 2>/dev/null
  [ -f $OPT/xray/vpn.ipset ] && ipset restore -! < $OPT/xray/vpn.ipset 2>/dev/null
  ipset create \$IPSET_TG hash:net 2>/dev/null
  for n in \$TG_NETS; do ipset add \$IPSET_TG \$n 2>/dev/null; done
}
start(){
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
    ip6tables -A FORWARD -i \$i -p tcp --dport 443 -j REJECT 2>/dev/null
    ip6tables -A FORWARD -i \$i -p tcp --dport 80 -j REJECT 2>/dev/null
    ip6tables -A FORWARD -i \$i -p udp --dport 443 -j REJECT 2>/dev/null
  done
}
stop(){
  for i in \$LANS; do
    iptables -t nat -D PREROUTING -i \$i -p udp --dport 53 -j REDIRECT --to-ports \$DNSP 2>/dev/null
    iptables -t nat -D PREROUTING -i \$i -p tcp --dport 53 -j REDIRECT --to-ports \$DNSP 2>/dev/null
    iptables -t nat -D PREROUTING -i \$i -p tcp -m set --match-set \$IPSET dst -j REDIRECT --to-ports \$REDIR 2>/dev/null
    iptables -t nat -D PREROUTING -i \$i -p tcp -m set --match-set \$IPSET_TG dst -j REDIRECT --to-ports \$REDIR 2>/dev/null
    iptables -D FORWARD -i \$i -p udp --dport 443 -m set --match-set \$IPSET dst -j DROP 2>/dev/null
    iptables -t mangle -D PREROUTING -i \$i -p udp -m set --match-set \$IPSET_TG dst -j TPROXY --on-port \$TPROXY_UDP --tproxy-mark \$MARK 2>/dev/null
    ip6tables -D FORWARD -i \$i -p tcp --dport 443 -j REJECT 2>/dev/null
    ip6tables -D FORWARD -i \$i -p tcp --dport 80 -j REJECT 2>/dev/null
    ip6tables -D FORWARD -i \$i -p udp --dport 443 -j REJECT 2>/dev/null
  done
}
case "\$1" in
  start) stop; start; echo "fw started";;
  stop) stop; echo "fw stopped";;
  status) iptables -t nat -L PREROUTING -n -v|grep REDIRECT; echo "vpn=\$(ipset list \$IPSET 2>/dev/null|grep -cE '^[0-9]') vpn_tg=\$(ipset list \$IPSET_TG 2>/dev/null|grep -cE '^[0-9]')";;
esac
FW
chmod +x $OPT/xray/fw.sh

# ===================== dnsmasq (claude-домены -> ipset vpn) =====================
cat > $OPT/dnsmasq.conf <<DM
port=5353
listen-address=127.0.0.1,$LAN_IPS
bind-interfaces
no-resolv
server=127.0.0.1#53
cache-size=1000
ipset=/anthropic.com/claude.ai/claude.com/vpn
DM

# ===================== failover =====================
cat > $OPT/xray/failover.sh <<FO
#!/bin/sh
PATH=/opt/sbin:/opt/bin:/sbin:/bin:/usr/sbin:/usr/bin
CFG=$OPT/sing-box/config.json
LOG=/opt/var/log/failover.log
AUTH="$PASS"
SERVERS="$DEFAULT_SERVERS"
ok(){ c=\$(curl -s --max-time 8 --socks5-hostname 127.0.0.1:11080 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null); [ "\$c" = "204" ]; }
ok && exit 0
cur=\$(sed -n 's/.*"server":"\([^"]*\)".*/\1/p' "\$CFG" | head -1)
echo "\$(date): выход \$cur не отвечает, перебираю" >> "\$LOG"
for s in \$SERVERS; do
  sed -i "s/\"server\":\"[^\"]*\"/\"server\":\"\$s\"/; s/\"server_name\":\"[^\"]*\"/\"server_name\":\"\$s\"/" "\$CFG"
  /opt/etc/init.d/S23singbox restart >/dev/null 2>&1; sleep 4
  if ok; then echo "\$(date): переключился на \$s" >> "\$LOG"; exit 0; fi
done
echo "\$(date): рабочих серверов не найдено" >> "\$LOG"
FO
chmod +x $OPT/xray/failover.sh

# ===================== init-скрипты =====================
cat > $OPT/init.d/S23singbox <<'INIT'
#!/bin/sh
ENABLED=yes
PROCS=sing-box
ARGS="run -c /opt/etc/sing-box/config.json"
PREARGS=""
DESC=sing-box
PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin
. /opt/etc/init.d/rc.func
INIT
cat > $OPT/init.d/S24xray <<'INIT'
#!/bin/sh
ENABLED=yes
PROCS=xray
ARGS="run -c /opt/etc/xray/config.json"
PREARGS=""
DESC=xray
PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin
. /opt/etc/init.d/rc.func
INIT
cat > $OPT/init.d/S25xrayfw <<'INIT'
#!/bin/sh
case "$1" in
start) sh /opt/etc/xray/fw.sh start;;
stop) sh /opt/etc/xray/fw.sh stop;;
restart) sh /opt/etc/xray/fw.sh start;;
esac
INIT
chmod +x $OPT/init.d/S23singbox $OPT/init.d/S24xray $OPT/init.d/S25xrayfw
rm -f $OPT/init.d/S23singbox.off $OPT/init.d/S24xray.off $OPT/init.d/S25xrayfw.off $OPT/init.d/S99vpnpanel.off
# вернуть автозапуск dnsmasq (uninstall мог поставить ENABLED=no)
sed -i 's/^ENABLED=.*/ENABLED=yes/' $OPT/init.d/S56dnsmasq 2>/dev/null

# netfilter-хук: переустановка правил после сбросов Keenetic
mkdir -p $OPT/ndm/netfilter.d
cat > $OPT/ndm/netfilter.d/100-xray.sh <<'HOOK'
#!/bin/sh
[ "$type" = "ip6tables" ] && exit 0
[ "$table" = "nat" ] || [ "$table" = "filter" ] || exit 0
sh /opt/etc/xray/fw.sh start
HOOK
chmod +x $OPT/ndm/netfilter.d/100-xray.sh

# ===================== персистентность ipset =====================
cat > $OPT/xray/save-ipset.sh <<SAVE
#!/bin/sh
[ "\$(ipset list vpn 2>/dev/null|grep -cE '^[0-9]')" -gt 0 ] && ipset save vpn > $OPT/xray/vpn.ipset
SAVE
chmod +x $OPT/xray/save-ipset.sh

# ===================== zapret (nfqws-keenetic) + geoip =====================
NFQWS_INIT=$(ls $OPT/init.d/S51nfqws $OPT/init.d/K51nfqws 2>/dev/null | head -1)
if [ -z "$NFQWS_INIT" ]; then
  log "ставлю nfqws-keenetic (zapret)"
  echo 'src/gz nfqws-keenetic https://anonym-tsk.github.io/nfqws-keenetic/all' >> $OPT/opkg.conf 2>/dev/null || true
  opkg update >/dev/null 2>&1 || true
  opkg install nfqws-keenetic >/dev/null 2>&1 || echo "[!] nfqws-keenetic не поставился авто - см. github Anonym-tsk/nfqws-keenetic"
else
  log "nfqws-keenetic уже стоит - использую как есть"
  # включить, если выключен (K-префикс = disabled)
  case "$NFQWS_INIT" in */K51nfqws) mv "$NFQWS_INIT" $OPT/init.d/S51nfqws; log "включил nfqws (был выключен)";; esac
  /opt/etc/init.d/S51nfqws start >/dev/null 2>&1
fi
# geoip-обновлятор + конфиг категории
if [ -d $OPT/nfqws ]; then
  echo "GEOIP_LIST=re-filter" > $OPT/nfqws/geoip.conf
  [ -f $OPT/nfqws/ipset_exclude.user ] || cp $OPT/nfqws/ipset_exclude.list $OPT/nfqws/ipset_exclude.user 2>/dev/null || : > $OPT/nfqws/ipset_exclude.user
  cp scripts/geoip-update.sh $OPT/nfqws/geoip-update.sh 2>/dev/null && chmod +x $OPT/nfqws/geoip-update.sh
fi

# ===================== cron =====================
( crontab -l 2>/dev/null | grep -vE 'save-ipset|failover|geoip-update'
  echo "*/30 * * * * $OPT/xray/save-ipset.sh"
  echo "*/10 * * * * $OPT/xray/failover.sh"
  echo "0 */12 * * * $OPT/nfqws/geoip-update.sh"
) | crontab - 2>/dev/null

# ===================== старт =====================
log "запускаю службы"
/opt/etc/init.d/S56dnsmasq restart >/dev/null 2>&1 || true
$OPT/init.d/S23singbox restart >/dev/null 2>&1
$OPT/init.d/S24xray restart >/dev/null 2>&1
sh $OPT/xray/fw.sh start >/dev/null 2>&1
[ -x $OPT/nfqws/geoip-update.sh ] && sh $OPT/nfqws/geoip-update.sh >/dev/null 2>&1 &

# выбор сервера по пингу не проверяет, жив ли Hysteria2 - проверяем туннель и при провале перебираем
sleep 2
if [ "$(curl -s --max-time 8 --socks5-hostname 127.0.0.1:11080 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null)" != "204" ]; then
  log "сервер $SERVER не поднял туннель - перебираю рабочий (failover)"
  sh $OPT/xray/failover.sh
fi

# ===================== веб-панель =====================
if [ -z "$NO_PANEL" ] && [ -f scripts/install-panel.sh ]; then
  log "ставлю веб-панель"
  sh scripts/install-panel.sh || echo "[!] панель не поставилась"
fi

log "готово. Статус: sh $OPT/xray/fw.sh status"
[ -z "$NO_PANEL" ] && log "панель: http://${LAN_IPS%%,*}:${PANEL_PORT:-8088}"
