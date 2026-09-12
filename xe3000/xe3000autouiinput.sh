#!/bin/sh
# XE3000 Cloudflare Full-Tunnel — مُثبّت ذاتي التشغيل
# الجهاز: GL.iNet GL-XE3000 (ARM64 / OpenWrt)
# ملف واحد، بلا حمولة مضمّنة — يعمل مع wget/curl إلى ملف ثم sh.
set -u

VERSION="2026-09-12-single-file"

BASE=/etc/xe3000-cf-fulltunnel
CREDS=/etc/xe3000-cf-fulltunnel-creds
STATE=$BASE/state
SETTINGS=$STATE/settings.env
UIROOT=$BASE/ui
CFD_DIR=$BASE/cloudflared
XRAY_DIR=$BASE/xray
LOGFILE=/var/log/xe3000-fulltunnel.log
API=https://api.cloudflare.com/client/v4
UI_PORT=9000
SELF=$0

CF_HOSTNAME=; CF_ACCOUNT=; CF_ZONE=; CF_TOKEN=
TUNNEL_ID=; TUNNEL_NAME=; TUNNEL_SECRET=
XRAY_UUID=; XRAY_PORT=; XRAY_WSPATH=

# ----------------------------------------------------------------- رسائل
say()  { printf '%s\n' "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[!!] %s\n' "$*"; }
err()  { printf '[ER] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '[%s/6] %s\n' "$1" "$2"; }

need_root() {
    [ "$(id -u)" = 0 ] || die "يجب التشغيل بصلاحية root."
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "الأمر المطلوب غير موجود: $1"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ----------------------------------------------------------------- إدخال
# يقرأ ويكتب على /dev/tty مباشرة حتى لا تبتلع إعادة التوجيه الطلبات.
has_tty() { ( exec 3>/dev/tty ) 2>/dev/null; }

read_tty() { # $1 نص الطلب، $2 اسم المتغيّر، $3 =1 للإخفاء
    _prompt=$1; _var=$2; _hide=${3:-0}
    if ! has_tty; then
        die "لا توجد طرفية تفاعلية. استخدم أمر auto مع ملف إعداد أو مرّر متغيّرات البيئة."
    fi
    printf '%s' "$_prompt" >/dev/tty
    [ "$_hide" = 1 ] && stty -echo </dev/tty 2>/dev/null
    IFS= read -r _val </dev/tty || _val=
    if [ "$_hide" = 1 ]; then
        stty echo </dev/tty 2>/dev/null
        printf '\n' >/dev/tty
    fi
    _val=$(printf '%s' "$_val" | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    eval "$_var=\$_val"
}

# ----------------------------------------------------------------- تحقق
valid_id() {
    case "${1:-}" in
        '' ) return 1 ;;
        *[!A-Za-z0-9_.-]* ) return 1 ;;
    esac
    return 0
}

valid_host() {
    case "${1:-}" in
        '' ) return 1 ;;
        *[!A-Za-z0-9.-]* ) return 1 ;;
        *.* ) return 0 ;;
        * ) return 1 ;;
    esac
}

lan_ip() {
    _ip=$(uci -q get network.lan.ipaddr 2>/dev/null)
    [ -n "$_ip" ] || _ip=$(ip -4 addr show br-lan 2>/dev/null | sed -n 's,.*inet \([0-9.]*\)/.*,\1,p' | head -1)
    [ -n "$_ip" ] || _ip=192.168.8.1
    printf '%s' "$_ip"
}

# ----------------------------------------------------------------- البيانات المحفوظة
creds_saved() {
    [ -s "$CREDS/hostname" ] && [ -s "$CREDS/account-id" ] &&
    [ -s "$CREDS/zone-id" ] && [ -s "$CREDS/api-token" ]
}

save_creds() {
    mkdir -p "$CREDS" || die "تعذر إنشاء $CREDS"
    chmod 700 "$CREDS"
    printf '%s' "$CF_HOSTNAME" >"$CREDS/hostname"
    printf '%s' "$CF_ACCOUNT"  >"$CREDS/account-id"
    printf '%s' "$CF_ZONE"     >"$CREDS/zone-id"
    printf '%s' "$CF_TOKEN"    >"$CREDS/api-token"
    chmod 600 "$CREDS"/hostname "$CREDS"/account-id "$CREDS"/zone-id "$CREDS"/api-token
    ok "حُفظت بيانات Cloudflare في $CREDS"
}

load_creds() {
    creds_saved || return 1
    CF_HOSTNAME=$(cat "$CREDS/hostname")
    CF_ACCOUNT=$(cat "$CREDS/account-id")
    CF_ZONE=$(cat "$CREDS/zone-id")
    CF_TOKEN=$(cat "$CREDS/api-token")
    return 0
}

forget_creds() {
    need_root
    creds_saved || { say "لا توجد بيانات محفوظة."; return 0; }
    if [ "${FULLTUNNEL_FORCE:-0}" != 1 ]; then
        read_tty "اكتب FORGET للحذف النهائي: " _c
        [ "$_c" = FORGET ] || die "أُلغي الحذف."
    fi
    rm -rf "$CREDS"
    ok "حُذفت البيانات المحفوظة. (هذا لا يلغي التوكن في حساب Cloudflare.)"
}

creds_status() {
    if creds_saved; then
        say "بيانات Cloudflare: محفوظة"
        say "  المضيف     : $(cat "$CREDS/hostname")"
        say "  الحساب     : $(cat "$CREDS/account-id" | cut -c1-8)…"
        say "  النطاق     : $(cat "$CREDS/zone-id" | cut -c1-8)…"
        say "  التوكن     : محفوظ (لا يُعرض)"
        say "  المسار     : $CREDS (700/600)"
    else
        say "بيانات Cloudflare: غير محفوظة"
    fi
}

# ملف الإعداد التلقائي — لا يُحذف إلا بعد نجاح التثبيت
load_auto_config() {
    _f=${1:-/root/xe3000-fulltunnel-auto.env}
    [ -f "$_f" ] || die "ملف الإعداد غير موجود: $_f"
    _perm=$(stat -c %a "$_f" 2>/dev/null || echo 600)
    case "$_perm" in
        600|400) : ;;
        *) die "صلاحية $_f يجب أن تكون 600 أو 400 بالضبط (الحالية $_perm)." ;;
    esac
    _cr=$(printf '\r')
    case "$(cat "$_f")" in
        *"$_cr"*) die "الملف $_f يحتوي نهايات CRLF. نظّفه بـ: sed -i 's/[[:cntrl:]]*$//' $_f" ;;
    esac
    # shellcheck disable=SC1090
    . "$_f"
    CF_HOSTNAME=${FULLTUNNEL_HOSTNAME:-}
    CF_ACCOUNT=${FULLTUNNEL_ACCOUNT_ID:-}
    CF_ZONE=${FULLTUNNEL_ZONE_ID:-}
    CF_TOKEN=${FULLTUNNEL_API_TOKEN:-}
    AUTO_ENV_FILE=$_f
}

# ترتيب الأولوية: بيئة ← auto.env ← محفوظ ← سؤال تفاعلي
collect_creds() {
    [ -n "$CF_HOSTNAME" ] || CF_HOSTNAME=${FULLTUNNEL_HOSTNAME:-}
    [ -n "$CF_ACCOUNT" ]  || CF_ACCOUNT=${FULLTUNNEL_ACCOUNT_ID:-}
    [ -n "$CF_ZONE" ]     || CF_ZONE=${FULLTUNNEL_ZONE_ID:-}
    [ -n "$CF_TOKEN" ]    || CF_TOKEN=${FULLTUNNEL_API_TOKEN:-}

    if creds_saved; then
        _used=0
        [ -n "$CF_HOSTNAME" ] || { CF_HOSTNAME=$(cat "$CREDS/hostname");   _used=1; }
        [ -n "$CF_ACCOUNT" ]  || { CF_ACCOUNT=$(cat "$CREDS/account-id");  _used=1; }
        [ -n "$CF_ZONE" ]     || { CF_ZONE=$(cat "$CREDS/zone-id");        _used=1; }
        [ -n "$CF_TOKEN" ]    || { CF_TOKEN=$(cat "$CREDS/api-token");     _used=1; }
        [ "$_used" = 1 ] && ok "استُكملت القيم الناقصة من البيانات المحفوظة."
    fi

    [ -n "$CF_HOSTNAME" ] || read_tty "المضيف الكامل (مثل home.example.com): " CF_HOSTNAME
    valid_host "$CF_HOSTNAME" || die "اسم المضيف غير صالح: '$CF_HOSTNAME'"

    [ -n "$CF_ACCOUNT" ] || read_tty "Account ID: " CF_ACCOUNT
    valid_id "$CF_ACCOUNT" || die "Account ID غير صالح. قيمة واحدة لكل سطر، بلا لصق متعدد الأسطر."

    [ -n "$CF_ZONE" ] || read_tty "Zone ID: " CF_ZONE
    valid_id "$CF_ZONE" || die "Zone ID غير صالح. قيمة واحدة لكل سطر، بلا لصق متعدد الأسطر."

    [ -n "$CF_TOKEN" ] || read_tty "API Token: " CF_TOKEN 1
    valid_id "$CF_TOKEN" || die "التوكن غير صالح أو فيه محرف زائد."
}

# ----------------------------------------------------------------- Cloudflare API
cf() { # $1 method  $2 path  [$3 json body]
    _m=$1; _p=$2; _d=${3:-}
    if [ -n "$_d" ]; then
        curl -sS --max-time 30 -X "$_m" \
            -H "Authorization: Bearer $CF_TOKEN" \
            -H "Content-Type: application/json" \
            --data "$_d" "$API$_p" 2>&1
    else
        curl -sS --max-time 30 -X "$_m" \
            -H "Authorization: Bearer $CF_TOKEN" "$API$_p" 2>&1
    fi
}

jf() { jsonfilter -s "$1" -e "$2" 2>/dev/null; }

cf_success() { [ "$(jf "$1" '@.success')" = "true" ]; }

cf_errors() {
    _e=$(jf "$1" '@.errors[*].message' | tr '\n' ';')
    [ -n "$_e" ] || _e=$(printf '%s' "$1" | head -c 200)
    printf '%s' "$_e"
}

# الفحوصات الأربعة — تُشغَّل قبل إنشاء النفق حتى لا يفشل [3/6] بصمت
preflight_cloudflare() {
    _fail=0

    _r=$(cf GET /user/tokens/verify)
    case "$_r" in
        curl:*|*"Could not resolve"*|*"Connection refused"*)
            err "تعذر الوصول إلى api.cloudflare.com: $_r"
            err "لا إنترنت أو DNS معطّل على الراوتر — جرّب: ping -c1 1.1.1.1 و nslookup api.cloudflare.com"
            return 1 ;;
    esac
    if cf_success "$_r"; then
        ok "1/4 التوكن صالح ($(jf "$_r" '@.result.status'))"
    else
        err "1/4 التوكن مرفوض: $(cf_errors "$_r")"
        err "    التوكن خاطئ أو منتهٍ أو فيه محرف زائد."
        return 1
    fi

    _r=$(cf GET "/accounts/$CF_ACCOUNT")
    if cf_success "$_r"; then
        ok "2/4 الحساب: $(jf "$_r" '@.result.name')"
    else
        err "2/4 الحساب مرفوض: $(cf_errors "$_r")"
        err "    Account ID خاطئ."
        _fail=1
    fi

    _r=$(cf GET "/zones/$CF_ZONE")
    if cf_success "$_r"; then
        _zn=$(jf "$_r" '@.result.name')
        ok "3/4 النطاق: $_zn"
        case "$CF_HOSTNAME" in
            "$_zn"|*".$_zn") : ;;
            *) err "3/4 المضيف '$CF_HOSTNAME' ليس تابعًا للنطاق '$_zn'."; _fail=1 ;;
        esac
    else
        err "3/4 النطاق مرفوض: $(cf_errors "$_r")"
        err "    Zone ID خاطئ أو ليس في نفس الحساب."
        _fail=1
    fi

    _r=$(cf GET "/accounts/$CF_ACCOUNT/cfd_tunnel?per_page=1")
    if cf_success "$_r"; then
        ok "4/4 صلاحية الأنفاق متاحة"
    else
        err "4/4 صلاحية الأنفاق مرفوضة: $(cf_errors "$_r")"
        err "    التوكن ينقصه: Account · Cloudflare Tunnel · Edit"
        err "    أنشئ توكنًا من My Profile ← API Tokens ← Create Token بصلاحيتين فقط:"
        err "      Account · Cloudflare Tunnel · Edit"
        err "      Zone    · DNS             · Edit"
        _fail=1
    fi

    return $_fail
}

# ----------------------------------------------------------------- [1/6] الاعتمادات
cfd_arch() {
    case "$(uname -m)" in
        aarch64|arm64) printf 'arm64' ;;
        armv7l|armv7|arm) printf 'arm' ;;
        x86_64|amd64) printf 'amd64' ;;
        *) printf '' ;;
    esac
}

install_cloudflared() {
    have cloudflared && { ok "cloudflared موجود مسبقًا"; return 0; }
    opkg install cloudflared >/dev/null 2>&1 && have cloudflared && \
        { ok "cloudflared من opkg"; return 0; }

    _a=$(cfd_arch)
    [ -n "$_a" ] || die "معمارية غير مدعومة: $(uname -m)"
    _v=${FULLTUNNEL_CLOUDFLARED_VERSION:-2026.8.2}
    _u="https://github.com/cloudflare/cloudflared/releases/download/$_v/cloudflared-linux-$_a"
    say "    تنزيل cloudflared $_v ($_a)..."
    curl -fsSL --max-time 300 "$_u" -o /tmp/cloudflared.bin || die "تعذر تنزيل cloudflared من $_u"

    _sum=$(sha256sum /tmp/cloudflared.bin | cut -d' ' -f1)
    if [ -n "${FULLTUNNEL_CLOUDFLARED_SHA256:-}" ]; then
        [ "$_sum" = "$FULLTUNNEL_CLOUDFLARED_SHA256" ] || \
            { rm -f /tmp/cloudflared.bin; die "بصمة cloudflared لا تطابق المتوقع. المحسوبة: $_sum"; }
        ok "تحقق SHA-256 نجح"
    else
        warn "لم تُمرَّر FULLTUNNEL_CLOUDFLARED_SHA256 — لم يُتحقق من البصمة."
        say  "    البصمة المحسوبة: $_sum"
    fi
    install -m 0755 /tmp/cloudflared.bin /usr/bin/cloudflared || die "تعذر تثبيت cloudflared"
    rm -f /tmp/cloudflared.bin
    ok "cloudflared مثبت"
}

prepare_runtime() {
    step 1 "تثبيت الاعتمادات..."
    for c in uci openssl tar sha256sum; do
        have "$c" || die "متطلب غير مثبت تلقائيًا: $c"
    done
    opkg update >/dev/null 2>&1 || warn "opkg update لم ينجح — سيُكمَل بالمتاح."
    for p in curl jsonfilter; do
        have "$p" || opkg install "$p" >/dev/null 2>&1 || die "تعذر تثبيت $p"
    done
    have xray || opkg install xray-core >/dev/null 2>&1 || die "تعذر تثبيت xray-core"
    install_cloudflared
    ok "الاعتمادات جاهزة"
}

# ----------------------------------------------------------------- [3/6] النفق و DNS
create_tunnel() {
    TUNNEL_NAME=${FULLTUNNEL_TUNNEL_NAME:-xe3000-$(printf '%s' "$CF_HOSTNAME" | tr '.' '-')}

    _r=$(cf GET "/accounts/$CF_ACCOUNT/cfd_tunnel?name=$TUNNEL_NAME&is_deleted=false")
    _old=$(jf "$_r" '@.result[0].id')
    if [ -n "$_old" ]; then
        warn "يوجد نفق بنفس الاسم ($_old) — سيُحذف ويُعاد إنشاؤه."
        _d=$(cf DELETE "/accounts/$CF_ACCOUNT/cfd_tunnel/$_old")
        cf_success "$_d" || die "تعذر حذف النفق القديم: $(cf_errors "$_d")"
    fi

    TUNNEL_SECRET=$(head -c 32 /dev/urandom | openssl base64 -A)
    _body=$(printf '{"name":"%s","tunnel_secret":"%s","config_src":"local"}' \
            "$TUNNEL_NAME" "$TUNNEL_SECRET")
    _r=$(cf POST "/accounts/$CF_ACCOUNT/cfd_tunnel" "$_body")
    cf_success "$_r" || die "فشل إنشاء النفق: $(cf_errors "$_r")"
    TUNNEL_ID=$(jf "$_r" '@.result.id')
    [ -n "$TUNNEL_ID" ] || die "استجابة Cloudflare بلا معرّف نفق."
    ok "أُنشئ النفق $TUNNEL_NAME ($TUNNEL_ID)"
}

create_or_update_dns() {
    _content="$TUNNEL_ID.cfargotunnel.com"
    _r=$(cf GET "/zones/$CF_ZONE/dns_records?type=CNAME&name=$CF_HOSTNAME")
    cf_success "$_r" || die "تعذر قراءة سجلات DNS: $(cf_errors "$_r")"
    _rec=$(jf "$_r" '@.result[0].id')
    _body=$(printf '{"type":"CNAME","name":"%s","content":"%s","proxied":true,"ttl":1}' \
            "$CF_HOSTNAME" "$_content")
    if [ -n "$_rec" ]; then
        _r=$(cf PUT "/zones/$CF_ZONE/dns_records/$_rec" "$_body")
        _act="حُدِّث"
    else
        _r=$(cf POST "/zones/$CF_ZONE/dns_records" "$_body")
        _act="أُنشئ"
    fi
    cf_success "$_r" || die "فشل سجل DNS: $(cf_errors "$_r")"
    ok "$_act سجل CNAME: $CF_HOSTNAME ← $_content"
}

# ----------------------------------------------------------------- [4/6] ملفات الإعداد
write_configs() {
    mkdir -p "$CFD_DIR" "$XRAY_DIR" "$STATE" "$BASE/tunnel"
    chmod 700 "$BASE" "$BASE/tunnel"

    printf '{"AccountTag":"%s","TunnelID":"%s","TunnelSecret":"%s"}\n' \
        "$CF_ACCOUNT" "$TUNNEL_ID" "$TUNNEL_SECRET" >"$BASE/tunnel/$TUNNEL_ID.json"
    chmod 600 "$BASE/tunnel/$TUNNEL_ID.json"

    XRAY_PORT=${FULLTUNNEL_XRAY_PORT:-18443}
    XRAY_UUID=${FULLTUNNEL_XRAY_UUID:-$(cat /proc/sys/kernel/random/uuid)}
    XRAY_WSPATH=${FULLTUNNEL_XRAY_PATH:-/$(head -c 16 /dev/urandom | md5sum | cut -c1-16)}

    cat >"$CFD_DIR/config.yml" <<CFDCFG
tunnel: $TUNNEL_ID
credentials-file: $BASE/tunnel/$TUNNEL_ID.json
protocol: http2
no-autoupdate: true
loglevel: info
ingress:
  - hostname: $CF_HOSTNAME
    service: http://127.0.0.1:$XRAY_PORT
  - service: http_status:404
CFDCFG
    chmod 600 "$CFD_DIR/config.yml"

    cat >"$XRAY_DIR/config.json" <<XRAYCFG
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$XRAY_UUID" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$XRAY_WSPATH" }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
XRAYCFG
    chmod 600 "$XRAY_DIR/config.json"
    ok "كُتبت ملفات الإعداد"
}

write_init() {
    cat >/etc/init.d/xe3000-cf-xray <<'INITXRAY'
#!/bin/sh /etc/rc.common
START=94
STOP=11
USE_PROCD=1
start_service() {
    [ -f /etc/xe3000-cf-fulltunnel/xray/config.json ] || return 1
    procd_open_instance
    procd_set_param command /usr/bin/xray run -c /etc/xe3000-cf-fulltunnel/xray/config.json
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
INITXRAY

    cat >/etc/init.d/xe3000-cf-tunnel <<'INITCFD'
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1
start_service() {
    [ -f /etc/xe3000-cf-fulltunnel/cloudflared/config.yml ] || return 1
    procd_open_instance
    procd_set_param command /usr/bin/cloudflared --no-autoupdate \
        --config /etc/xe3000-cf-fulltunnel/cloudflared/config.yml tunnel run
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
INITCFD

    chmod 755 /etc/init.d/xe3000-cf-xray /etc/init.d/xe3000-cf-tunnel
    ok "كُتب ملفا الخدمة"
}

save_settings() {
    mkdir -p "$STATE"
    cat >"$SETTINGS" <<SET
FULLTUNNEL_VERSION=$VERSION
FULLTUNNEL_HOSTNAME=$CF_HOSTNAME
FULLTUNNEL_TUNNEL_ID=$TUNNEL_ID
FULLTUNNEL_TUNNEL_NAME=$TUNNEL_NAME
FULLTUNNEL_XRAY_PORT=$XRAY_PORT
FULLTUNNEL_XRAY_UUID=$XRAY_UUID
FULLTUNNEL_XRAY_PATH=$XRAY_WSPATH
FULLTUNNEL_INSTALLED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
SET
    chmod 600 "$SETTINGS"
}

load_settings() {
    [ -f "$SETTINGS" ] || return 1
    # shellcheck disable=SC1090
    . "$SETTINGS"
    CF_HOSTNAME=${FULLTUNNEL_HOSTNAME:-}
    TUNNEL_ID=${FULLTUNNEL_TUNNEL_ID:-}
    TUNNEL_NAME=${FULLTUNNEL_TUNNEL_NAME:-}
    XRAY_PORT=${FULLTUNNEL_XRAY_PORT:-}
    XRAY_UUID=${FULLTUNNEL_XRAY_UUID:-}
    XRAY_WSPATH=${FULLTUNNEL_XRAY_PATH:-}
    return 0
}

# ----------------------------------------------------------------- [5/6] التشغيل
enable_services() {
    for s in xe3000-cf-xray xe3000-cf-tunnel; do
        /etc/init.d/$s enable  >/dev/null 2>&1
        /etc/init.d/$s restart >/dev/null 2>&1 || warn "تعذر تشغيل $s"
    done
    sleep 2
    for s in xe3000-cf-xray xe3000-cf-tunnel; do
        if /etc/init.d/$s running >/dev/null 2>&1 || pgrep -f "$s" >/dev/null 2>&1; then
            ok "$s يعمل"
        else
            warn "$s لا يعمل — راجع logread -e $s"
        fi
    done
}

# ----------------------------------------------------------------- [6/6] لوحة 9000
write_ui_files() {
    mkdir -p "$UIROOT/cgi-bin"
    chmod 755 "$UIROOT" "$UIROOT/cgi-bin"

    cat >"$UIROOT/index.html" <<'UIHTML'
<!doctype html><html lang="ar" dir="rtl"><meta charset="utf-8">
<meta http-equiv="refresh" content="0;url=/cgi-bin/control.cgi">
<title>XE3000 Full-Tunnel</title>
<p>جارٍ التحويل إلى <a href="/cgi-bin/control.cgi">لوحة التحكم</a>…</p>
UIHTML

    cat >"$UIROOT/cgi-bin/control.cgi" <<'UICGI'
#!/bin/sh
BASE=/etc/xe3000-cf-fulltunnel
CREDS=/etc/xe3000-cf-fulltunnel-creds
SETTINGS=$BASE/state/settings.env
Q=${QUERY_STRING:-}
arg() { printf '%s' "$Q" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
ACT=$(arg action)
case "$ACT" in
  ''|start|stop|restart|forget) : ;;
  *) ACT=invalid ;;
esac
MSG=

installed() { [ -f "$SETTINGS" ] && [ -x /etc/init.d/xe3000-cf-tunnel ]; }

if [ -n "$ACT" ]; then
  if ! installed; then
    MSG="البوابة غير مثبتة — لا يمكن تنفيذ الأمر. شغّل المُثبّت على الراوتر أولًا."
  else
    case "$ACT" in
      start|stop|restart)
        /etc/init.d/xe3000-cf-xray   "$ACT" >/dev/null 2>&1
        /etc/init.d/xe3000-cf-tunnel "$ACT" >/dev/null 2>&1
        MSG="نُفِّذ الأمر: $ACT" ;;
      forget)
        if [ "$(arg confirm)" = FORGET ]; then
          rm -rf "$CREDS"; MSG="حُذفت بيانات Cloudflare المحفوظة."
        else
          MSG="لم تُحذف — يجب كتابة FORGET بالضبط."
        fi ;;
      *) MSG="أمر غير معروف." ;;
    esac
  fi
fi

svc() {
  if [ -x "/etc/init.d/$1" ]; then
    if /etc/init.d/"$1" running >/dev/null 2>&1; then printf 'يعمل'; else printf 'متوقف'; fi
  else
    printf 'غير مثبت'
  fi
}

HOSTV=; TIDV=
[ -f "$SETTINGS" ] && { HOSTV=$(sed -n 's/^FULLTUNNEL_HOSTNAME=//p' "$SETTINGS"); \
                        TIDV=$(sed -n 's/^FULLTUNNEL_TUNNEL_ID=//p' "$SETTINGS"); }
if [ -s "$CREDS/api-token" ]; then CRED=محفوظة; else CRED="غير محفوظة"; fi

printf 'Content-Type: text/html; charset=utf-8\r\n\r\n'
cat <<HTML
<!doctype html><html lang="ar" dir="rtl"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>XE3000 Full-Tunnel</title>
<style>
body{font-family:system-ui,sans-serif;background:#111;color:#eee;margin:0;padding:16px}
.c{max-width:640px;margin:auto}h1{font-size:1.3rem}
.card{background:#1e1e1e;border:1px solid #333;border-radius:8px;padding:14px;margin:12px 0}
table{width:100%;border-collapse:collapse}td{padding:6px 4px;border-bottom:1px solid #2a2a2a}
a.btn{display:inline-block;background:#2d6cdf;color:#fff;text-decoration:none;
padding:8px 14px;border-radius:6px;margin:4px 4px 0 0}
.msg{background:#332b00;border:1px solid #7a6500;padding:10px;border-radius:6px}
input{padding:6px;border-radius:4px;border:1px solid #444;background:#111;color:#eee}
.warn{color:#ff9a9a}
</style><div class="c">
<h1>XE3000 Cloudflare Full-Tunnel</h1>
HTML
[ -n "$MSG" ] && printf '<div class="msg">%s</div>' "$MSG"
if installed; then
cat <<HTML
<div class="card"><table>
<tr><td>المضيف</td><td>$HOSTV</td></tr>
<tr><td>معرّف النفق</td><td>$TIDV</td></tr>
<tr><td>xray</td><td>$(svc xe3000-cf-xray)</td></tr>
<tr><td>cloudflared</td><td>$(svc xe3000-cf-tunnel)</td></tr>
</table>
<a class="btn" href="?action=start">تشغيل</a>
<a class="btn" href="?action=stop">إيقاف</a>
<a class="btn" href="?action=restart">إعادة تشغيل</a>
</div>
HTML
else
cat <<'HTML'
<div class="card"><p class="warn">البوابة غير مثبتة.</p>
<p>ملفا الخدمة يُنشآن في الخطوة [4/6]. غيابهما يعني أن التثبيت توقف قبلها.
شغّل على الراوتر:</p><pre>sh /root/xe3000autouiinput.sh</pre></div>
HTML
fi
cat <<HTML
<div class="card"><b>بيانات Cloudflare المحفوظة:</b> $CRED
<form method="get"><input type="hidden" name="action" value="forget">
<p>للحذف النهائي اكتب FORGET:
<input name="confirm" size="10"> <button>حذف</button></p></form>
<p>الحذف لا يلغي التوكن في حساب Cloudflare.</p></div>
</div>
HTML
UICGI
    chmod 755 "$UIROOT/cgi-bin/control.cgi"
    ok "كُتبت ملفات اللوحة"
}

set_password() { # $1 = enabled flag
    _enabled=${1:-1}
    if [ "$_enabled" = 0 ]; then
        rm -f "$UIROOT/httpd.conf"
        warn "المصادقة معطّلة بطلبك (auth.enabled=0) — اللوحة بلا كلمة مرور."
        return 0
    fi
    _user=${FULLTUNNEL_UI_USER:-admin}
    _pass=${FULLTUNNEL_UI_PASSWORD:-}
    if [ -z "$_pass" ]; then
        if [ "${FULLTUNNEL_RESTORE_UI:-0}" = 1 ] && [ -f "$UIROOT/httpd.conf" ]; then
            ok "أُبقيت كلمة المرور الحالية"
            return 0
        fi
        if ! has_tty; then
            # لا تُفشل التثبيت بعد اكتمال الخطوات السابقة — ولّد كلمة مرور واطبعها.
            _pass=$(head -c 24 /dev/urandom | openssl base64 -A | tr -dc 'A-Za-z0-9' | cut -c1-16)
            mkdir -p "$UIROOT"
            printf '/:%s:%s\n' "$_user" "$(openssl passwd -1 "$_pass")" >"$UIROOT/httpd.conf"
            chmod 600 "$UIROOT/httpd.conf"
            warn "بلا طرفية تفاعلية — وُلِّدت كلمة مرور للوحة $UI_PORT. اكتبها الآن:"
            say  "    المستخدم    : $_user"
            say  "    كلمة المرور : $_pass"
            say  "    لتغييرها لاحقًا: sh $SELF set-password"
            return 0
        fi
        read_tty "اسم مستخدم لوحة $UI_PORT [$_user]: " _u
        [ -n "$_u" ] && _user=$_u
        read_tty "كلمة المرور: " _pass 1
        [ -n "$_pass" ] || die "كلمة المرور لا يمكن أن تكون فارغة."
    fi
    mkdir -p "$UIROOT"
    printf '/:%s:%s\n' "$_user" "$(openssl passwd -1 "$_pass")" >"$UIROOT/httpd.conf"
    chmod 600 "$UIROOT/httpd.conf"
    ok "ضُبطت كلمة مرور اللوحة للمستخدم $_user"
}

configure_uhttpd() {
    _ip=$(lan_ip)
    case "$_ip" in
        0.0.0.0|::|"") die "رفض الربط على $_ip — اللوحة محلية فقط." ;;
    esac
    [ -f /etc/uhttpd.crt ] && [ -f /etc/uhttpd.key ] || \
        die "شهادة /etc/uhttpd.crt و /etc/uhttpd.key مفقودة. فعّل HTTPS من واجهة GL.iNet."

    uci -q delete uhttpd.xe3000
    uci set uhttpd.xe3000=uhttpd
    uci set uhttpd.xe3000.home="$UIROOT"
    uci add_list uhttpd.xe3000.listen_https="$_ip:$UI_PORT"
    uci set uhttpd.xe3000.cert=/etc/uhttpd.crt
    uci set uhttpd.xe3000.key=/etc/uhttpd.key
    uci set uhttpd.xe3000.cgi_prefix=/cgi-bin
    uci set uhttpd.xe3000.rfc1918_filter=1
    uci add_list uhttpd.xe3000.index_page=index.html
    [ -f "$UIROOT/httpd.conf" ] && uci set uhttpd.xe3000.config="$UIROOT/httpd.conf"
    uci commit uhttpd
    /etc/init.d/uhttpd reload >/dev/null 2>&1 || /etc/init.d/uhttpd restart >/dev/null 2>&1
    ok "اللوحة على https://$_ip:$UI_PORT/"
}

install_ui() {
    write_ui_files
    set_password "${FULLTUNNEL_AUTH_ENABLED:-1}"
    configure_uhttpd
}

# ----------------------------------------------------------------- التثبيت
installed_complete() { [ -f "$SETTINGS" ] && [ -x /etc/init.d/xe3000-cf-tunnel ]; }
installed_partial()  { [ -d "$BASE" ] && ! installed_complete; }

do_install() {
    need_root
    if installed_complete; then
        die "يوجد تثبيت مكتمل. استخدم: sh $SELF status"
    fi
    if installed_partial; then
        die "توجد بقايا تثبيت ناقص. نظّفها أولًا: sh $SELF reset"
    fi

    prepare_runtime

    step 2 "بيانات Cloudflare..."
    collect_creds
    save_creds

    step 3 "إنشاء Tunnel وسجل DNS..."
    preflight_cloudflare || die "فشل فحص Cloudflare — أصلح ما سبق ثم أعد المحاولة."
    create_tunnel
    create_or_update_dns

    step 4 "كتابة الإعداد وملفات الخدمة..."
    write_configs
    write_init
    save_settings

    step 5 "تشغيل الخدمات..."
    enable_services

    step 6 "تثبيت لوحة $UI_PORT..."
    install_ui

    say ""
    ok "اكتمل التثبيت."
    show_client
    [ -n "${AUTO_ENV_FILE:-}" ] && { rm -f "$AUTO_ENV_FILE"; ok "حُذف ملف الإعداد $AUTO_ENV_FILE بعد النجاح."; }
    return 0
}

show_client() {
    say ""
    say "بيانات العميل (VLESS + WebSocket عبر Cloudflare):"
    say "  العنوان : $CF_HOSTNAME   المنفذ: 443   TLS: مُفعّل"
    say "  UUID    : $XRAY_UUID"
    say "  المسار  : $XRAY_WSPATH"
    say "  الشبكة  : ws   |   SNI/Host: $CF_HOSTNAME"
}

do_status() {
    if ! load_settings; then
        err "لا يوجد تثبيت محلي. شغّل install أولًا."
        creds_status
        return 1
    fi
    say "الإصدار    : $VERSION"
    say "المضيف     : $CF_HOSTNAME"
    say "النفق      : $TUNNEL_NAME ($TUNNEL_ID)"
    for s in xe3000-cf-xray xe3000-cf-tunnel; do
        if [ -x /etc/init.d/$s ] && /etc/init.d/$s running >/dev/null 2>&1; then
            say "$s : يعمل"
        elif [ -x /etc/init.d/$s ]; then
            say "$s : متوقف"
        else
            say "$s : غير مثبت"
        fi
    done
    say "اللوحة     : https://$(lan_ip):$UI_PORT/"
    creds_status
}

do_diagnose() {
    say "--- uhttpd ---"
    /etc/init.d/uhttpd status 2>&1 | head -5
    uci -q show uhttpd.xe3000 || say "لا يوجد قسم uhttpd.xe3000"
    say "--- المنفذ $UI_PORT ---"
    netstat -ltn 2>/dev/null | grep ":$UI_PORT " || say "المنفذ $UI_PORT غير مفتوح"
    say "--- الشهادة ---"
    [ -f /etc/uhttpd.crt ] && say "/etc/uhttpd.crt موجودة" || say "/etc/uhttpd.crt مفقودة"
    say "--- الأوامر ---"
    for c in curl jsonfilter xray cloudflared openssl uci; do
        have "$c" && say "$c: $(command -v $c)" || say "$c: مفقود"
    done
}

do_reset() {
    need_root
    installed_complete && die "التثبيت مكتمل — استخدم remove لا reset."
    [ -d "$BASE" ] || { say "لا توجد بقايا."; return 0; }
    _orphan=$(sed -n 's/^FULLTUNNEL_TUNNEL_ID=//p' "$SETTINGS" 2>/dev/null)
    [ -n "$_orphan" ] && warn "معرّف نفق يتيم سيبقى في Cloudflare: $_orphan"
    if [ "${FULLTUNNEL_FORCE:-0}" != 1 ]; then
        read_tty "اكتب RESET لحذف بقايا التثبيت: " _c
        [ "$_c" = RESET ] || die "أُلغي."
    fi
    rm -rf "$BASE"
    rm -f /etc/init.d/xe3000-cf-xray /etc/init.d/xe3000-cf-tunnel
    uci -q delete uhttpd.xe3000 && uci commit uhttpd
    /etc/init.d/uhttpd reload >/dev/null 2>&1
    ok "حُذفت بقايا التثبيت. البيانات المحفوظة في $CREDS لم تُمس."
}

do_remove() {
    need_root
    for s in xe3000-cf-tunnel xe3000-cf-xray; do
        [ -x /etc/init.d/$s ] && { /etc/init.d/$s stop >/dev/null 2>&1; /etc/init.d/$s disable >/dev/null 2>&1; }
        rm -f /etc/init.d/$s
    done
    uci -q delete uhttpd.xe3000 && uci commit uhttpd
    /etc/init.d/uhttpd reload >/dev/null 2>&1
    rm -rf "$BASE"
    ok "أُزيلت البوابة. البيانات المحفوظة في $CREDS لم تُمس (احذفها بـ forget-creds)."
}

do_repair_ui() {
    need_root
    [ -d "$UIROOT" ] || write_ui_files
    configure_uhttpd
}

do_bootstrap() {
    need_root
    write_ui_files
    set_password "${FULLTUNNEL_AUTH_ENABLED:-1}"
    configure_uhttpd
    ok "افتح https://$(lan_ip):$UI_PORT/ لإكمال الإعداد."
}

# لا وسائط: يقرر وحده
do_auto_self() {
    need_root
    if installed_complete; then
        say "بوابة مكتملة — إصلاح لوحة $UI_PORT فقط."
        FULLTUNNEL_RESTORE_UI=1 do_repair_ui
        return 0
    fi
    if installed_partial; then
        say "بقايا تثبيت فاشل — تنظيف تلقائي."
        FULLTUNNEL_FORCE=1 do_reset
    fi
    if creds_saved; then
        say "بيانات محفوظة موجودة — تثبيت كامل بلا أي إدخال."
        do_install
        return $?
    fi
    say "لا توجد بيانات محفوظة — فتح صفحة الإعداد."
    do_bootstrap
}

usage() {
    cat <<USAGE
XE3000 Cloudflare Full-Tunnel — $VERSION

  sh $SELF                  تشغيل ذاتي كامل (الافتراضي)
  sh $SELF install          تثبيت يدوي من البداية
  sh $SELF auto [file]      تثبيت بلا أسئلة من ملف إعداد 600
  sh $SELF bootstrap        صفحة الإعداد العربية على LAN:$UI_PORT
  sh $SELF ui-only          إعادة تثبيت لوحة $UI_PORT
  sh $SELF status           حالة البوابة والواجهة
  sh $SELF diagnose         فحص uhttpd والمنفذ $UI_PORT
  sh $SELF repair-ui        إصلاح ربط HTTPS على LAN
  sh $SELF set-password     كلمة مرور اللوحة
  sh $SELF preflight        فحوصات Cloudflare الأربعة
  sh $SELF creds-status     هل البيانات محفوظة
  sh $SELF forget-creds     حذفها نهائيًا
  sh $SELF reset            حذف بقايا تثبيت ناقص
  sh $SELF remove           إزالة كاملة
  sh $SELF prepare-runtime  الاعتمادات فقط
  sh $SELF version          الإصدار
  sh $SELF help             هذه الشاشة
USAGE
}

# ----------------------------------------------------------------- التوزيع
case "${1:-}" in
    ''|self|auto-self)  do_auto_self ;;
    install)            do_install ;;
    auto)               need_root; load_auto_config "${2:-/root/xe3000-fulltunnel-auto.env}"; do_install ;;
    bootstrap)          do_bootstrap ;;
    ui-only)            need_root; install_ui ;;
    status)             do_status ;;
    diagnose)           do_diagnose ;;
    repair-ui)          do_repair_ui ;;
    set-password)       need_root; set_password 1; configure_uhttpd ;;
    preflight)          need_root; need_cmd curl; need_cmd jsonfilter
                        collect_creds; preflight_cloudflare ;;
    creds-status)       creds_status ;;
    forget-creds)       forget_creds ;;
    reset)              do_reset ;;
    remove)             do_remove ;;
    prepare-runtime)    need_root; prepare_runtime ;;
    version)            say "$VERSION" ;;
    help|-h|--help)     usage ;;
    *)                  err "أمر غير معروف: $1"; usage; exit 1 ;;
esac
