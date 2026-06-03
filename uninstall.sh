#!/bin/sh
# Полное удаление vpn-keenetic: снимает правила, останавливает службы, чистит автозапуск.
# Пакеты (xray/dnsmasq/ipset/curl/cron) НЕ удаляются - при необходимости: opkg remove xray dnsmasq-full ipset

XDIR=/opt/etc/xray

echo "==> снимаем правила перехвата"
[ -x "$XDIR/fw.sh" ] && sh "$XDIR/fw.sh" stop
ip rule del fwmark 1 lookup 100 2>/dev/null
ip route flush table 100 2>/dev/null

echo "==> останавливаем службы"
/opt/etc/init.d/S24xray stop 2>/dev/null
/opt/etc/init.d/S56dnsmasq stop 2>/dev/null
killall xray 2>/dev/null

echo "==> отключаем автозапуск"
for f in /opt/etc/init.d/S24xray /opt/etc/init.d/S25xrayfw; do
    [ -f "$f" ] && mv "$f" "$f.off"
done
sed -i 's/^ENABLED=.*/ENABLED=no/' /opt/etc/init.d/S56dnsmasq 2>/dev/null
rm -f /opt/etc/ndm/netfilter.d/100-xray.sh

echo "==> убираем cron-задание"
crontab -l 2>/dev/null | grep -v update-domains | crontab - 2>/dev/null

echo "==> чистим ipset"
ipset destroy vpn 2>/dev/null
ipset destroy vpn_tg 2>/dev/null

echo "Готово. DNS вернулся на штатный (ndnproxy). Конфиги в $XDIR оставлены."
echo "Полностью убрать: rm -rf $XDIR /opt/etc/dnsmasq.d/vpn-domains.conf и вернуть свой /opt/etc/dnsmasq.conf"
