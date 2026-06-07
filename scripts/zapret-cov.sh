#!/bin/sh
export PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin
# Проверка покрытия домена в zapret: резолв, в каких списках, ICMP-пинг. JSON.
# ВАЖНО: "в списке" = домен настроен на обход (hostlist-совпадение по суффиксу).
# Реальный факт "пробивает ли DPI" с роутера проверить нельзя (трафик роутера идёт мимо nfqws).
D=$(printf '%s' "$1" | tr -cd 'a-zA-Z0-9.-')
[ -z "$D" ] && { echo '{"error":"no domain"}'; exit 0; }

IP=$(drill -p 5353 @127.0.0.1 "$D" 2>/dev/null | awk '/IN[ \t]+A[ \t]/{print $NF; exit}')
[ -z "$IP" ] && IP=$(drill "$D" 2>/dev/null | awk '/IN[ \t]+A[ \t]/{print $NF; exit}')

# суффиксное совпадение, как у nfqws hostlist
inlist(){
  f="$1"; [ -f "$f" ] || return 1
  while IFS= read -r L; do
    [ -z "$L" ] && continue
    case "$L" in \#*) continue;; esac
    case "$D" in "$L"|*".$L") return 0;; esac
  done < "$f"
  return 1
}
inuser=false; inlist /opt/etc/nfqws/user.list && inuser=true
ingoog=false; inlist /opt/etc/nfqws/google.list && ingoog=true
# geoip: грубо по /24 (точное CIDR-сопоставление в shell дорого)
ingeoip=false
[ -n "$IP" ] && grep -qF "${IP%.*}." /opt/etc/nfqws/ipset.list 2>/dev/null && ingeoip=true

ping_ms=$(ping -c 2 -W 2 "$IP" 2>/dev/null | sed -n 's#.*= [0-9.]*/\([0-9.]*\)/.*#\1#p')

printf '{"domain":"%s","ip":"%s","in_userlist":%s,"in_google":%s,"in_geoip":%s,"ping_ms":"%s"}\n' \
  "$D" "${IP:-}" "$inuser" "$ingoog" "$ingeoip" "${ping_ms:-—}"
