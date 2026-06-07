#!/bin/sh
# Статус VPN + zapret в JSON (для веб-панели). Без jq - JSON собирается вручную.

running(){ ps w 2>/dev/null | grep -v grep | grep -qE "$1"; }
bool(){ if "$@"; then printf true; else printf false; fi; }

XRAY=$(bool running '[x]ray run')
SINGBOX=$(bool running '[s]ing-box')
DNSMASQ=$(bool running '[d]nsmasq')
NFQWS=$(bool running '[n]fqws')

SERVER=$(sed -n 's/.*"server"[: ]*"\([^"]*\)".*/\1/p' /opt/etc/sing-box/config.json 2>/dev/null | head -1)

# здоровье туннеля: generate_204 через sing-box socks
T204=$(curl -s --max-time 6 --socks5-hostname 127.0.0.1:11080 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null)
EXIP=$(curl -s --max-time 6 --socks5-hostname 127.0.0.1:11080 https://ifconfig.co 2>/dev/null | tr -d '\r\n ' | cut -c1-45)

# zapret: длина очереди (затор = завис) и размер geoip
QTOTAL=$(awk '$1==200{print $3}' /proc/net/netfilter/nfnetlink_queue 2>/dev/null | head -1)
GEOIP=$(grep -cE '^[0-9]' /opt/etc/nfqws/ipset.list 2>/dev/null)
GEOIP_LIST=re-filter; [ -f /opt/etc/nfqws/geoip.conf ] && . /opt/etc/nfqws/geoip.conf 2>/dev/null

VPN_IPS=$(ipset list vpn 2>/dev/null | grep -cE '^[0-9]')
VPN_TG=$(ipset list vpn_tg 2>/dev/null | grep -cE '^[0-9]')

UPTIME=$(cut -d. -f1 /proc/uptime 2>/dev/null)
MEM=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{if(t)printf "%d", (t-a)*100/t}' /proc/meminfo 2>/dev/null)

printf '{'
printf '"xray":%s,"singbox":%s,"dnsmasq":%s,"nfqws":%s,' "$XRAY" "$SINGBOX" "$DNSMASQ" "$NFQWS"
printf '"server":"%s","tunnel_204":"%s","exit_ip":"%s",' "$SERVER" "$T204" "$EXIP"
printf '"queue_total":%s,"geoip_count":%s,"geoip_list":"%s",' "${QTOTAL:-0}" "${GEOIP:-0}" "$GEOIP_LIST"
printf '"vpn_ips":%s,"vpn_tg":%s,' "${VPN_IPS:-0}" "${VPN_TG:-0}"
printf '"uptime":%s,"mem_pct":%s' "${UPTIME:-0}" "${MEM:-0}"
printf '}\n'
