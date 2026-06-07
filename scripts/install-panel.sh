#!/bin/sh
# Установка веб-панели: lighttpd + CGI на порту 8088, доступ только из локалки.
# Запускается из install.sh или вручную. Идемпотентно. best-effort (без set -e).
SRC=$(cd "$(dirname "$0")/.." && pwd)   # корень репо
WWW=/opt/share/www/vpn-panel
PANEL=/opt/etc/vpn-panel
PORT=8088

echo "[panel] ставлю lighttpd + mod-cgi"
opkg update >/dev/null 2>&1 || true
opkg install lighttpd lighttpd-mod-cgi >/dev/null 2>&1 || true
command -v lighttpd >/dev/null || { echo "[panel] lighttpd не установился"; exit 1; }

echo "[panel] раскладываю файлы"
mkdir -p "$WWW/cgi-bin" "$PANEL/scripts" /opt/var/log /opt/var/run
cp "$SRC/web/index.html" "$WWW/index.html"
cp "$SRC/web/cgi-bin/api.sh" "$WWW/cgi-bin/api.sh"
chmod +x "$WWW/cgi-bin/api.sh"
for s in status.sh selftest.sh region-ping.sh geoip-update.sh; do
  cp "$SRC/scripts/$s" "$PANEL/scripts/$s"; chmod +x "$PANEL/scripts/$s"
done
cp "$SRC/web/lighttpd.conf" "$PANEL/lighttpd.conf"

echo "[panel] init-скрипт автозапуска"
cat > /opt/etc/init.d/S99vpnpanel <<'INIT'
#!/bin/sh
CONF=/opt/etc/vpn-panel/lighttpd.conf
PIDF=/opt/var/run/lighttpd-panel.pid
case "$1" in
  start) lighttpd -f "$CONF" && echo "vpn-panel started" ;;
  stop)  [ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null; rm -f "$PIDF" ;;
  restart) "$0" stop; sleep 1; "$0" start ;;
  *) echo "usage: $0 {start|stop|restart}" ;;
esac
INIT
chmod +x /opt/etc/init.d/S99vpnpanel

echo "[panel] firewall: 8088 только из локалки (drop с WAN eth3)"
WAN=$(ip route get 8.8.8.8 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
[ -z "$WAN" ] && WAN=eth3
# хук, переживающий сбросы Keenetic
cat > /opt/etc/ndm/netfilter.d/090-vpnpanel.sh <<HOOK
#!/bin/sh
[ "\$table" = "filter" ] || exit 0
iptables -D INPUT -i $WAN -p tcp --dport $PORT -j DROP 2>/dev/null
iptables -I INPUT -i $WAN -p tcp --dport $PORT -j DROP
HOOK
chmod +x /opt/etc/ndm/netfilter.d/090-vpnpanel.sh
sh /opt/etc/ndm/netfilter.d/090-vpnpanel.sh table=filter 2>/dev/null || \
  { iptables -D INPUT -i "$WAN" -p tcp --dport $PORT -j DROP 2>/dev/null; iptables -I INPUT -i "$WAN" -p tcp --dport $PORT -j DROP; }

# Entware-пакет lighttpd поднимает свой S80lighttpd на :8088 с чужим докрутом - отключаем
if [ -f /opt/etc/init.d/S80lighttpd ]; then
  echo "[panel] отключаю дефолтный S80lighttpd (конфликт по :8088)"
  /opt/etc/init.d/S80lighttpd stop 2>/dev/null
  mv /opt/etc/init.d/S80lighttpd /opt/etc/init.d/S80lighttpd.off
fi
killall lighttpd 2>/dev/null; sleep 1
/opt/etc/init.d/S99vpnpanel restart >/dev/null 2>&1
LANIP=$(ip -4 addr show br0 2>/dev/null | sed -n 's#.*inet \([0-9.]*\)/.*#\1#p' | head -1)
echo "[panel] готово: http://${LANIP:-192.168.1.1}:$PORT"
