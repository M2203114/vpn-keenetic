#!/bin/sh
# CGI-бэкенд веб-панели. Отдаёт JSON. Доступен только из локалки (lighttpd слушает LAN).
# Действия через ?action=... :
#   status            статус служб и туннеля
#   selftest          проверка claude/telegram через туннель
#   ping              пинг серверов подписки (JSON)
#   set_region&server=HOST   поставить сервер выхода
#   set_geoip&list=NAME      сменить geoip-категорию zapret и обновить
#   restart&svc=vpn|zapret   перезапуск службы
#   logs&name=geoip|failover хвост лога

PANEL=/opt/etc/vpn-panel
SCR=$PANEL/scripts

printf 'Content-Type: application/json; charset=utf-8\r\n'
printf 'Cache-Control: no-store\r\n\r\n'

qval(){ printf '%s' "$QUERY_STRING" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
# жёсткая санитизация: только безопасные символы
san(){ printf '%s' "$1" | tr -cd 'a-zA-Z0-9.:_-'; }

ACTION=$(san "$(qval action)")

case "$ACTION" in
  status)   sh "$SCR/status.sh" ;;
  selftest) sh "$SCR/selftest.sh" ;;
  ping)     sh "$SCR/region-ping.sh" --json ;;
  set_region)
      SRV=$(san "$(qval server)")
      if [ -n "$SRV" ]; then
        sed -i "s/\"server\":\"[^\"]*\"/\"server\":\"$SRV\"/; s/\"server_name\":\"[^\"]*\"/\"server_name\":\"$SRV\"/" /opt/etc/sing-box/config.json
        /opt/etc/init.d/S23singbox restart >/dev/null 2>&1
        printf '{"ok":true,"server":"%s"}\n' "$SRV"
      else printf '{"ok":false,"error":"no server"}\n'; fi ;;
  set_geoip)
      L=$(san "$(qval list)")
      case "$L" in
        re-filter|ru-blocked|ru-blocked-community)
          printf 'GEOIP_LIST=%s\n' "$L" > /opt/etc/nfqws/geoip.conf
          sh "$SCR/geoip-update.sh" >/dev/null 2>&1 &
          printf '{"ok":true,"list":"%s","note":"updating"}\n' "$L" ;;
        *) printf '{"ok":false,"error":"bad list"}\n' ;;
      esac ;;
  restart)
      case "$(san "$(qval svc)")" in
        vpn)    /opt/etc/init.d/S23singbox restart >/dev/null 2>&1; /opt/etc/init.d/S24xray restart >/dev/null 2>&1; printf '{"ok":true}\n' ;;
        zapret) /opt/etc/init.d/S51nfqws restart >/dev/null 2>&1; printf '{"ok":true}\n' ;;
        *) printf '{"ok":false,"error":"bad svc"}\n' ;;
      esac ;;
  logs)
      case "$(san "$(qval name)")" in
        geoip)    F=/opt/var/log/geoip-update.log ;;
        failover) F=/opt/var/log/failover.log ;;
        *) F= ;;
      esac
      if [ -n "$F" ] && [ -f "$F" ]; then
        printf '{"ok":true,"text":"'; tail -20 "$F" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n",$0}'; printf '"}\n'
      else printf '{"ok":false}\n'; fi ;;
  *) printf '{"error":"unknown action"}\n' ;;
esac
