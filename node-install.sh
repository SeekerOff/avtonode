#!/usr/bin/env bash
# Установка ноды Remnawave: сама нода, страница-заглушка и сертификат.
#
# Запускать НА СЕРВЕРЕ НОВОЙ НОДЫ, от root:
#
#   bash node-install.sh            — установка или обновление, с вопросами
#   bash node-install.sh status     — что работает сейчас
#   bash node-install.sh check      — только проверки, ничего не меняет
#
# Любой ответ можно задать заранее переменной окружения — тогда вопроса не будет:
#
#   DOMAIN=node2.example.org NODE_TAG=2.8.0 NODE_PORT=2222 \
#   NODE_SECRET='...' LE_EMAIL=you@example.org PANEL_IP=1.2.3.4 \
#   bash node-install.sh
#
# Как устроено:
#   - нода слушает NODE_PORT только для панели, порт 443 занимает её Xray;
#   - Caddy рядом держит сертификат Let's Encrypt и отдаёт заглушку в
#     unix-сокет /dev/shm/nginx.sock, а 443 не трогает вовсе. Reality
#     заворачивает чужой трафик в этот сокет и показывает настоящий сайт
#     с настоящим сертификатом;
#   - сертификат Caddy продлевает сам, cron и certbot не нужны.
#
# Повторный запуск безопасен: файлы сохраняются в копии, заглушка не
# перезаписывается. Сменить версию ноды или порт — просто запустить снова.
set -uo pipefail

NODE_DIR=${NODE_DIR:-/opt/remnanode}
SITE_DIR=${SITE_DIR:-/var/www/html}
SOCKET=${SOCKET:-/dev/shm/nginx.sock}
CADDY_TAG=${CADDY_TAG:-2.11.7-alpine}
LOG_DIR=${LOG_DIR:-/var/log/remnanode}

DOMAIN=${DOMAIN:-}
NODE_TAG=${NODE_TAG:-}
NODE_PORT=${NODE_PORT:-}
NODE_SECRET=${NODE_SECRET:-}
SECRET_NAME=${SECRET_NAME:-}
LE_EMAIL=${LE_EMAIL:-}
PANEL_IP=${PANEL_IP:-}
FORCE=${FORCE:-0}

STAMP=$(date +%Y%m%d-%H%M%S)
CMD=${1:-install}

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
no()   { printf '  \033[31m✗\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { no "$*"; exit 1; }

# ---------------------------------------------------------------- вопросы

ask() { # ask ПЕРЕМЕННАЯ "вопрос" "по умолчанию"
    local var=$1 q=$2 def=${3:-} cur=${!1:-} reply
    if [ -n "$cur" ]; then ok "$q: $cur"; return; fi
    [ -t 0 ] || { [ -n "$def" ] && { declare -g "$var=$def"; ok "$q: $def"; return; }
                  die "$q — задайте переменной окружения, ответить некому"; }
    while :; do
        read -r -p "  $q${def:+ [$def]}: " reply
        reply=${reply:-$def}
        [ -n "$reply" ] && { declare -g "$var=$reply"; return; }
    done
}

# Ключ панели — одной строкой. Панель отдаёт его в диалоге добавления ноды
# как SSL_CERT=... или SECRET_KEY=..., имя переменной забираем оттуда же.
ask_secret() {
    [ -n "$NODE_SECRET" ] && { ok "ключ панели: задан"; return; }
    [ -t 0 ] || die "NODE_SECRET не задан — в неинтерактивном режиме он обязателен"
    echo "  Вставьте строку из панели (SSL_CERT=... или SECRET_KEY=...) и нажмите Enter дважды:"
    local line value=""
    while IFS= read -r line; do
        if [ -z "$line" ]; then [ -n "$value" ] && break || continue; fi
        value+="$line"
    done
    NODE_SECRET=$value
}

# ------------------------------------------------------------- проверки

need_root() { [ "$(id -u)" = 0 ] || die "запускать от root: sudo bash $0"; }

have() { command -v "$1" >/dev/null 2>&1; }

port_user() { # кто слушает порт: имя процесса или пусто
    ss -ltnpH "sport = :$1" 2>/dev/null | grep -o 'users:((\"[^\"]*' | head -1 | sed 's/.*"//'
}

check_port() { # check_port ПОРТ "чем занят можно" ...
    local port=$1; shift
    # Занят ли порт — по самой строке ss, а не по имени процесса: имя
    # видно только root, и на нём проверка молча считала бы порт свободным
    local row; row=$(ss -ltnH "sport = :$port" 2>/dev/null | head -1)
    [ -z "$row" ] && { ok "порт $port свободен"; return 0; }
    local who; who=$(port_user "$port")
    local allowed
    for allowed in "$@"; do
        [ "$who" = "$allowed" ] && { ok "порт $port занят $who — это наше, переподнимем"; return 0; }
    done
    no "порт $port занят${who:+ процессом $who}"
    return 1
}

check_tag() { # есть ли такой тег у remnawave/node
    local tag=$1 code
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 \
        "https://hub.docker.com/v2/repositories/remnawave/node/tags/$tag")
    [ "$code" = "200" ] && return 0
    no "тега remnawave/node:$tag на Docker Hub нет (ответ $code)"
    echo "     последние выпуски:"
    curl -s -m 15 "https://hub.docker.com/v2/repositories/remnawave/node/tags?page_size=12&ordering=last_updated" \
        | tr ',' '\n' | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | sed 's/^/       /'
    return 1
}

check_domain() {
    local ip_dns ip_self
    ip_dns=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')
    [ -n "$ip_dns" ] || { no "домен $DOMAIN не разрешается в адрес"; return 1; }
    ip_self=$(curl -4 -s -m 10 https://api.ipify.org 2>/dev/null) \
        || ip_self=$(curl -4 -s -m 10 https://ifconfig.me 2>/dev/null)
    if [ -z "$ip_self" ]; then warn "не удалось узнать свой внешний адрес, сверить не с чем"; return 0; fi
    if [ "$ip_dns" = "$ip_self" ]; then ok "$DOMAIN → $ip_dns, это мы"; return 0; fi
    no "$DOMAIN ведёт на $ip_dns, а сервер — $ip_self"
    echo "     A-запись должна указывать прямо на этот сервер, без прокси Cloudflare:"
    echo "     иначе Let's Encrypt не выдаст сертификат, а Reality не прикроется сайтом."
    return 1
}

preflight() {
    say "1/7  Система"
    need_root
    [ -f /etc/debian_version ] || warn "система не Debian/Ubuntu — проверьте пакеты сами"
    for t in curl ss; do have "$t" || die "нет команды $t"; done
    ok "root, нужные команды на месте"

    if have docker && docker compose version >/dev/null 2>&1; then
        ok "docker и compose уже стоят"
    else
        [ "$CMD" = check ] && { warn "docker не установлен — установка его поставит"; return 0; }
        warn "docker не найден, поставлю официальным установщиком get.docker.com"
        if [ -t 0 ]; then
            read -r -p "  Ставить? [y/N]: " a; [[ "$a" =~ ^[yYдД]$ ]] || die "без docker продолжать нечем"
        fi
        curl -fsSL https://get.docker.com | sh || die "docker не поставился"
        docker compose version >/dev/null 2>&1 || die "docker compose не работает"
        ok "docker поставлен"
    fi
}

questions() {
    say "2/7  Что ставим"
    ask DOMAIN "Домен заглушки (он же serverName в Reality)"
    DOMAIN=${DOMAIN#http://}; DOMAIN=${DOMAIN#https://}; DOMAIN=${DOMAIN%%/*}
    ask NODE_TAG "Версия ноды (тег образа)" "2.8.0"
    ask NODE_PORT "Порт ноды для панели" "2222"
    [[ "$NODE_PORT" =~ ^[0-9]+$ ]] && [ "$NODE_PORT" -ge 1 ] && [ "$NODE_PORT" -le 65535 ] \
        || die "порт должен быть числом 1–65535"
    ask_secret

    # Имя переменной забираем из вставленной строки, если оно там есть
    if [[ "$NODE_SECRET" =~ ^([A-Z_]+)=(.*)$ ]]; then
        SECRET_NAME=${SECRET_NAME:-${BASH_REMATCH[1]}}
        NODE_SECRET=${BASH_REMATCH[2]}
    fi
    NODE_SECRET=${NODE_SECRET%\"}; NODE_SECRET=${NODE_SECRET#\"}
    NODE_SECRET=${NODE_SECRET%\'}; NODE_SECRET=${NODE_SECRET#\'}
    [ -n "$NODE_SECRET" ] || die "ключ панели пустой"

    if [ -z "$SECRET_NAME" ]; then
        warn "в строке не было имени переменной — запишу и SSL_CERT, и SECRET_KEY"
        warn "(панели 2.x ждут SSL_CERT, 3.x — SECRET_KEY; лишняя переменная не мешает)"
    else
        ok "переменная ключа: $SECRET_NAME"
    fi

    [ -n "$LE_EMAIL" ] && ok "почта для Let's Encrypt: $LE_EMAIL" \
        || warn "почта для Let's Encrypt не задана (LE_EMAIL) — письма об истечении не придут"
    [ -n "$PANEL_IP" ] && ok "адрес панели: $PANEL_IP" \
        || warn "адрес панели не задан (PANEL_IP) — правило ufw для порта ноды не добавлю"
}

checks() {
    say "3/7  Домен и порты"
    local bad=0
    check_domain || bad=1
    check_tag "$NODE_TAG" || bad=1
    check_port 80 caddy || bad=1
    check_port 443 xray sing-box || bad=1
    check_port "$NODE_PORT" remnanode xray node || bad=1
    if [ "$bad" = 1 ]; then
        [ "$FORCE" = 1 ] && warn "FORCE=1 — продолжаю, несмотря на замечания выше" \
            || die "исправьте замечания выше или запустите с FORCE=1"
    fi
}

# ---------------------------------------------------------------- файлы

keep() { [ -f "$1" ] && cp -a "$1" "$1.bak-$STAMP" && ok "копия: $(basename "$1").bak-$STAMP"; }

write_files() {
    say "4/7  Файлы ноды в $NODE_DIR"
    mkdir -p "$NODE_DIR" "$SITE_DIR" "$LOG_DIR"
    chmod 755 "$LOG_DIR"

    keep "$NODE_DIR/docker-compose.yml"
    cat > "$NODE_DIR/docker-compose.yml" <<COMPOSE
# Создано node-install.sh $STAMP — правки сохраняются при повторном запуске
x-common: &common
  restart: always
  network_mode: host
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: 5

services:
  caddy:
    image: caddy:${CADDY_TAG}
    container_name: caddy-remnawave
    hostname: caddy-remnawave
    <<: *common
    environment:
      - SELF_STEAL_DOMAIN=${DOMAIN}
      - CADDY_SOCKET_PATH=${SOCKET}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ${SITE_DIR}:/var/www/html:ro
      - /dev/shm:/dev/shm:rw
      - caddy_data:/data
    # Сокет мог остаться после прошлого запуска — Caddy не станет его занимать
    command: sh -c 'rm -f ${SOCKET} && caddy run --config /etc/caddy/Caddyfile --adapter caddyfile'
    healthcheck:
      test: ["CMD", "test", "-S", "${SOCKET}"]
      interval: 5s
      timeout: 5s
      retries: 12
      start_period: 10s

  remnanode:
    image: remnawave/node:${NODE_TAG}
    container_name: remnanode
    hostname: remnanode
    <<: *common
    cap_add:
      - NET_ADMIN
    env_file: .env
    volumes:
      - /dev/shm:/dev/shm:rw
      - ${LOG_DIR}:/var/log/remnanode

volumes:
  caddy_data:
    name: caddy_data
COMPOSE
    ok "docker-compose.yml: нода ${NODE_TAG}, caddy ${CADDY_TAG}"

    keep "$NODE_DIR/.env"
    {
        echo "# Создано node-install.sh $STAMP"
        echo "NODE_PORT=$NODE_PORT"
        if [ -n "$SECRET_NAME" ]; then
            echo "$SECRET_NAME=$NODE_SECRET"
        else
            echo "SSL_CERT=$NODE_SECRET"
            echo "SECRET_KEY=$NODE_SECRET"
        fi
    } > "$NODE_DIR/.env"
    chmod 600 "$NODE_DIR/.env"
    ok ".env: порт $NODE_PORT и ключ панели, права 600"

    keep "$NODE_DIR/Caddyfile"
    cat > "$NODE_DIR/Caddyfile" <<'CADDY'
# Создано node-install.sh — заглушка и сертификат для Reality.
#
# HTTPS отдаётся только в unix-сокет: порт 443 держит Xray ноды, он же
# заворачивает в этот сокет всех, кто пришёл на домен не по Reality.
# Поэтому и проверка Let's Encrypt идёт только через порт 80.
{
    admin off
#EMAIL#
    auto_https disable_redirects
    servers {
        listener_wrappers {
            proxy_protocol
            tls
        }
    }
}

https://{$SELF_STEAL_DOMAIN} {
    bind unix/{$CADDY_SOCKET_PATH}
    tls {
        issuer acme {
            disable_tlsalpn_challenge
#ISSUER_EMAIL#
        }
    }
    root * /var/www/html
    try_files {path} /index.html
    file_server
    header -Server
}

http://{$SELF_STEAL_DOMAIN} {
    bind 0.0.0.0
    redir https://{$SELF_STEAL_DOMAIN}{uri} permanent
}

# Всё остальное, что стучится на 80 по адресу, а не по имени
:80 {
    bind 0.0.0.0
    respond 204
}
CADDY
    # Почта уходит и в общие настройки, и в сам выдающий — явно заданный
    # issuer общую настройку не наследует
    if [ -n "$LE_EMAIL" ]; then
        sed -i "s|#EMAIL#|    email $LE_EMAIL|" "$NODE_DIR/Caddyfile"
        sed -i "s|#ISSUER_EMAIL#|            email $LE_EMAIL|" "$NODE_DIR/Caddyfile"
    else
        sed -i '/#EMAIL#/d;/#ISSUER_EMAIL#/d' "$NODE_DIR/Caddyfile"
    fi
    ok "Caddyfile: заглушка в сокет $SOCKET, проверка домена по порту 80"
}

write_site() {
    say "5/7  Страница-заглушка в $SITE_DIR"
    if [ -s "$SITE_DIR/index.html" ]; then
        ok "страница уже есть, не трогаю (свою можно просто положить сюда)"
        return
    fi
    cat > "$SITE_DIR/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Welcome</title>
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0; min-height: 100vh; display: grid; place-items: center;
    font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif;
    background: #fafafa; color: #222;
  }
  main { max-width: 32rem; padding: 2rem; text-align: center; }
  h1 { font-size: 1.5rem; font-weight: 600; margin: 0 0 .75rem; }
  p { margin: 0; color: #666; }
  @media (prefers-color-scheme: dark) {
    body { background: #111; color: #eee; }
    p { color: #999; }
  }
</style>
</head>
<body>
<main>
  <h1>Welcome</h1>
  <p>This site is not configured yet.</p>
</main>
</body>
</html>
HTML
    chmod 644 "$SITE_DIR/index.html"
    ok "простая страница записана"
}

write_logrotate() {
    local f=/etc/logrotate.d/remnanode
    if [ -f "$f" ]; then ok "logrotate уже настроен"; return; fi
    cat > "$f" <<'ROTATE'
/var/log/remnanode/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
ROTATE
    ok "logrotate: логи ноды не разрастутся"
}

setup_ufw() {
    if ! have ufw || ! ufw status 2>/dev/null | head -1 | grep -q active; then
        warn "ufw не включён — порт $NODE_PORT окажется открыт всем, закройте его сами"
        return
    fi
    ufw allow 80/tcp comment 'HTTP (Let us Encrypt)' >/dev/null 2>&1
    ufw allow 443/tcp comment 'Reality' >/dev/null 2>&1
    if [ -n "$PANEL_IP" ]; then
        ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp comment 'Remnawave panel' >/dev/null 2>&1
        ufw reload >/dev/null 2>&1
        ok "ufw: открыты 80 и 443, порт $NODE_PORT — только для $PANEL_IP"
    else
        ufw reload >/dev/null 2>&1
        warn "ufw: открыты 80 и 443; порт $NODE_PORT не ограничен — задайте PANEL_IP"
    fi
}

# ---------------------------------------------------------------- запуск

start() {
    say "6/7  Запуск"
    cd "$NODE_DIR" || die "нет каталога $NODE_DIR"
    docker compose pull 2>&1 | sed 's/^/    /'
    [ "${PIPESTATUS[0]}" = 0 ] || die "образ не скачался — проверьте тег и связь"
    docker compose up -d 2>&1 | sed 's/^/    /' || die "контейнеры не поднялись"
    ok "docker compose up -d прошёл"
}

wait_for() { # wait_for "что ждём" ПОПЫТОК команда...
    local what=$1 tries=$2; shift 2
    local i
    for i in $(seq 1 "$tries"); do
        if "$@" >/dev/null 2>&1; then ok "$what"; return 0; fi
        sleep 2
    done
    no "$what — не дождался"
    return 1
}

verify() {
    say "7/7  Проверка"
    local bad=0

    wait_for "нода запущена" 15 \
        bash -c "[ \"\$(docker inspect remnanode --format '{{.State.Status}}' 2>/dev/null)\" = running ]" || bad=1
    wait_for "порт $NODE_PORT слушается" 15 \
        bash -c "ss -ltnH \"sport = :$NODE_PORT\" | grep -q ." || bad=1
    wait_for "Caddy отдаёт сокет $SOCKET" 15 \
        docker exec caddy-remnawave test -S "$SOCKET" || bad=1

    # Порт 80 снаружи: без него Let's Encrypt не выдаст сертификат
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "http://$DOMAIN" 2>/dev/null)
    if [ "$code" = "301" ] || [ "$code" = "204" ] || [ "$code" = "200" ]; then
        ok "порт 80 отвечает снаружи (HTTP $code)"
    else
        no "порт 80 снаружи не отвечает (HTTP ${code:-нет ответа}) — проверьте файрвол"
        bad=1
    fi

    if wait_for "сертификат Let's Encrypt выписан" 45 \
        bash -c "docker exec caddy-remnawave find /data/caddy/certificates -name '$DOMAIN.crt' | grep -q ."; then
        local till
        till=$(docker exec caddy-remnawave sh -c "cat \$(find /data/caddy/certificates -name '$DOMAIN.crt' | head -1)" 2>/dev/null \
               | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
        [ -n "$till" ] && ok "действует до $till (Caddy продлит сам)"
    else
        bad=1
        echo "     чаще всего причина одна из двух:"
        echo "       - A-запись домена ведёт не на этот сервер или через прокси Cloudflare;"
        echo "       - порт 80 закрыт файрволом хостера."
        echo "     что сказал Caddy: docker logs --tail 30 caddy-remnawave"
    fi

    [ "$bad" = 0 ] && ok "всё на месте" || warn "есть замечания — смотрите выше"
    return "$bad"
}

summary() {
    local ip; ip=$(curl -4 -s -m 10 https://api.ipify.org 2>/dev/null)
    cat <<SUM

$(printf '\033[1m')Что вписать в панели$(printf '\033[0m')

  Ноды → добавить ноду:
      адрес       ${ip:-адрес этого сервера}
      порт        $NODE_PORT

  Профиль конфигурации, inbound с Reality:
      порт        443
      serverNames $DOMAIN
      dest        $SOCKET
      xver        1

  Заглушку увидит только тот, кто придёт на домен без ключа Reality —
  до того, как панель выдаст ноде конфигурацию, HTTPS не ответит вовсе:
  порт 443 ещё никто не слушает. Это нормально.

$(printf '\033[1m')Дальше$(printf '\033[0m')

  что работает       bash $0 status
  логи ноды          docker logs --tail 50 remnanode
  логи заглушки      docker logs --tail 50 caddy-remnawave
  сменить версию     NODE_TAG=3.4.2 bash $0
  своя страница      положить файлы в $SITE_DIR
SUM
}

status() {
    say "Контейнеры"
    docker ps --filter name=remnanode --filter name=caddy-remnawave \
        --format '  {{.Names}}  {{.Image}}  {{.Status}}' 2>/dev/null | sed 's/^/ /' \
        || no "docker не отвечает"

    say "Порты"
    local p
    for p in 80 443 $(grep -oP '(?<=^NODE_PORT=).*' "$NODE_DIR/.env" 2>/dev/null); do
        local who; who=$(port_user "$p")
        [ -n "$who" ] && ok "$p — $who" || no "$p — никто не слушает"
    done

    say "Сертификат"
    local dom crt
    dom=$(grep -oP '(?<=SELF_STEAL_DOMAIN=).*' "$NODE_DIR/docker-compose.yml" 2>/dev/null | head -1)
    if [ -n "$dom" ]; then
        crt=$(docker exec caddy-remnawave find /data/caddy/certificates -name "$dom.crt" 2>/dev/null | head -1)
        if [ -n "$crt" ]; then
            docker exec caddy-remnawave cat "$crt" 2>/dev/null \
                | openssl x509 -noout -subject -enddate 2>/dev/null | sed 's/^/  /'
        else
            no "сертификата для $dom ещё нет"
        fi
    else
        no "не нашёл домен в docker-compose.yml"
    fi
}

# ---------------------------------------------------------------- точка входа

case "$CMD" in
    install)
        preflight
        questions
        checks
        write_files
        write_site
        write_logrotate
        setup_ufw
        start
        verify
        summary
        ;;
    check)
        preflight
        questions
        checks
        echo
        echo "Это была только проверка — ничего не менялось."
        ;;
    status)
        need_root
        status
        ;;
    *)
        die "команда: install (по умолчанию), check или status"
        ;;
esac
