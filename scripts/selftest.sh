#!/bin/sh
# Проверка, что ключевые сервисы реально доступны через туннель. JSON для веб-панели.
# Тесты идут через xray socks (127.0.0.1:10808) - тот же путь, что и у клиентов.

SK="--socks5-hostname 127.0.0.1:10808"
UA='Mozilla/5.0'

# claude: 200/403 = достаём (403 = Cloudflare-челлендж, браузер проходит); 000 = не достаём
code(){ curl -s --max-time 12 $SK -A "$UA" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null; }
ok(){ case "$1" in 2??|3??|403) echo true;; *) echo false;; esac; }

CLAUDE=$(code https://claude.ai/)
CLAUDE_COM=$(code https://claude.com/)
# Telegram: web-эндпоинт DC
TG=$(code https://core.telegram.org/)
# контроль: туннель вообще жив
NET=$(curl -s --max-time 8 --socks5-hostname 127.0.0.1:11080 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null)

printf '{'
printf '"net":{"code":"%s","ok":%s},' "$NET" "$([ "$NET" = 204 ] && echo true || echo false)"
printf '"claude":{"code":"%s","ok":%s},' "$CLAUDE" "$(ok "$CLAUDE")"
printf '"claude_com":{"code":"%s","ok":%s},' "$CLAUDE_COM" "$(ok "$CLAUDE_COM")"
printf '"telegram":{"code":"%s","ok":%s}' "$TG" "$(ok "$TG")"
printf '}\n'
