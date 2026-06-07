#!/bin/sh
# Удаление vpn-keenetic: снимает правила, останавливает VPN-службы и панель, чистит автозапуск.
# zapret (nfqws-keenetic) НЕ трогается (это отдельный пакет) - убирается только наш geoip-слой.
# Пакеты (xray/sing-box/dnsmasq/ipset) не удаляются: opkg remove xray-core sing-box при желании.

XDIR=/opt/etc/xray

echo "==> снимаем правила перехвата"
[ -x "$XDIR/fw.sh" ] && sh "$XDIR/fw.sh" stop
ip rule del fwmark 1 lookup 100 2>/dev/null
ip route flush table 100 2>/dev/null

echo "==> останавливаем службы VPN и панель"
/opt/etc/init.d/S24xray stop 2>/dev/null
/opt/etc/init.d/S23singbox stop 2>/dev/null
/opt/etc/init.d/S99vpnpanel stop 2>/dev/null
/opt/etc/init.d/S56dnsmasq stop 2>/dev/null
killall xray sing-box 2>/dev/null

echo "==> отключаем автозапуск"
for f in /opt/etc/init.d/S23singbox /opt/etc/init.d/S24xray /opt/etc/init.d/S25xrayfw /opt/etc/init.d/S99vpnpanel; do
    [ -f "$f" ] && mv "$f" "$f.off"
done
sed -i 's/^ENABLED=.*/ENABLED=no/' /opt/etc/init.d/S56dnsmasq 2>/dev/null
rm -f /opt/etc/ndm/netfilter.d/100-xray.sh /opt/etc/ndm/netfilter.d/090-vpnpanel.sh

echo "==> убираем наши cron-задания"
crontab -l 2>/dev/null | grep -vE 'save-ipset|failover|geoip-update' | crontab - 2>/dev/null

echo "==> чистим ipset VPN"
ipset destroy vpn 2>/dev/null
ipset destroy vpn_tg 2>/dev/null

echo "==> возвращаем дефолтный lighttpd (если был отключён)"
[ -f /opt/etc/init.d/S80lighttpd.off ] && mv /opt/etc/init.d/S80lighttpd.off /opt/etc/init.d/S80lighttpd

echo "==> убираем geoip-слой из zapret (nfqws сам остаётся)"
[ -d /opt/etc/nfqws ] && { : > /opt/etc/nfqws/ipset.list; rm -f /opt/etc/nfqws/geoip-update.sh /opt/etc/nfqws/geoip.conf; /opt/etc/init.d/S51nfqws restart 2>/dev/null; }

echo "Готово. DNS вернулся на штатный (ndnproxy). zapret (nfqws-keenetic) работает дальше."
echo "Полностью убрать VPN: rm -rf $XDIR /opt/etc/sing-box /opt/share/www/vpn-panel /opt/etc/vpn-panel и вернуть свой /opt/etc/dnsmasq.conf"
