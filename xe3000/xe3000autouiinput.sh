#!/bin/sh
# XE3000 Cloudflare Full-Tunnel — مُثبّت ذاتي التشغيل
# الجهاز: GL.iNet GL-XE3000 (ARM64 / OpenWrt)
# ملف واحد، بلا حمولة مضمّنة — يعمل مع wget/curl إلى ملف ثم sh.
set -u

VERSION="2026-09-16-multi-host"

BASE=/etc/xe3000-cf-fulltunnel
CREDS=/etc/xe3000-cf-fulltunnel-creds
STATE=$BASE/state
SETTINGS=$STATE/settings.env
UIROOT=$BASE/ui
CFD_DIR=$BASE/cloudflared
XRAY_DIR=$BASE/xray
LOGFILE=/var/log/xe3000-fulltunnel.log
API=https://api.cloudflare.com/client/v4
UI_PORT=9000            # مدخل HTTP، يحوّل إلى HTTPS
UI_PORT_S=9443          # منفذ HTTPS الفعلي
SELF=$0
case "$0" in
    /*) SELF_ABS=$0 ;;
    *)  SELF_ABS=$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0") ;;
esac

CF_HOSTNAME=; CF_ACCOUNT=; CF_ZONE=; CF_TOKEN=
TUNNEL_ID=; TUNNEL_NAME=; TUNNEL_SECRET=
XRAY_UUID=; XRAY_PORT=; XRAY_WSPATH=; XRAY_LISTEN=; XRAY_NET=
XRAY_PROTO=; SSHWS=; SSH_PATH=; SSH_PORT=; CFD_PROTO=; CFD_EDGE_IP=; CFD_METRICS=
# قائمة البروتوكولات المفعّلة معًا، ومسار/منفذ trojan المستقلّين عن vless
XRAY_PROTOS=; TROJAN_PATH=; TROJAN_PORT=

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
        _zt=$(ls "$CREDS" 2>/dev/null | sed -n 's/^zone-token-//p' | tr '\n' ' ')
        [ -n "$_zt" ] && say "  توكن لكل نطاق: $_zt"
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
    _acct_read=0

    _r=$(cf GET /user/tokens/verify)
    case "$_r" in
        curl:*|*"Could not resolve"*|*"Connection refused"*)
            err "تعذر الوصول إلى api.cloudflare.com: $_r"
            err "لا إنترنت أو DNS معطّل على الراوتر."
            net_check
            return 1 ;;
    esac
    if cf_success "$_r"; then
        ok "1/4 التوكن صالح ($(jf "$_r" '@.result.status'))"
    else
        err "1/4 التوكن مرفوض: $(cf_errors "$_r")"
        err "    التوكن خاطئ أو منتهٍ أو فيه محرف زائد."
        return 1
    fi

    # قراءة تفاصيل الحساب تحتاج Account Settings · Read، وهي ليست من صلاحيات
    # التوكن الموصى به. سقوطها وحده لا يعني شيئًا — الفحص 4 هو الحاسم.
    _r=$(cf GET "/accounts/$CF_ACCOUNT")
    if cf_success "$_r"; then
        _acct_read=1
        ok "2/4 الحساب: $(jf "$_r" '@.result.name')"
    else
        _acct_read=0
        say "[--] 2/4 تفاصيل الحساب غير مقروءة — يحسمها الفحص 4."
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
        ok "4/4 صلاحية الأنفاق متاحة — ومعها ثبت أن Account ID صحيح."
        [ "$_acct_read" = 0 ] && \
            say "     (سقوط الفحص 2 سببه أن التوكن بلا Account Settings · Read، وهي غير مطلوبة.)"
    else
        err "4/4 صلاحية الأنفاق مرفوضة: $(cf_errors "$_r")"
        if [ "$_acct_read" = 1 ]; then
            err "    الحساب مقروء لكن الأنفاق لا — التوكن ينقصه: Account · Cloudflare Tunnel · Edit"
        else
            err "    لا الحساب ولا الأنفاق — Account ID خاطئ، أو التوكن ليس لهذا الحساب."
            err "    انسخ Account ID من الشريط الجانبي في لوحة Cloudflare."
        fi
        err "    التوكن الصحيح من My Profile ← API Tokens ← Create Token بصلاحيتين:"
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

# ----------------------------------------------------------------- المستخدمون
USERS=$STATE/users.tsv     # سطر لكل مستخدم: uuid<TAB>الاسم<TAB>كلمة مرور trojan
HOSTS=$STATE/hosts.tsv     # سطر لكل مضيف: المضيف<TAB>معرّف النطاق

gen_pass() { head -c 32 /dev/urandom | md5sum | cut -c1-24; }

# ----------------------------------------------------------------- المضيفون
# نفق واحد يخدم كل النطاقات: قاعدة ingress لكل مضيف، وسجل CNAME في كل نطاق
# يشير إلى النفق نفسه. التعدّد يوزّع الخطر — حجب نطاق لا يسقط البقية.
hosts_init() {
    mkdir -p "$STATE"
    [ -f "$HOSTS" ] || { : >"$HOSTS"; chmod 600 "$HOSTS"; }
    # صفّ بلا معرّف نطاق: كُتب من سياق لم يقرأ البيانات المحفوظة (نداء بلا root
    # مثلًا). يُستكمل هنا، وإلا فشل تجديد سجل DNS للمضيف الأوّل بلا سبب ظاهر.
    # لا يطال إلا الأوّل: host-add لا يقبل مضيفًا بلا معرّف نطاق.
    if [ -s "$HOSTS" ]; then
        awk -F'\t' 'NF && $2==""{f=1} END{exit !f}' "$HOSTS" 2>/dev/null || return 0
        _hz=${CF_ZONE:-}
        [ -n "$_hz" ] || _hz=$(cat "$CREDS/zone-id" 2>/dev/null)
        [ -n "$_hz" ] || return 0
        _ht=$STATE/.hosts.fix.$$
        awk -F'\t' -v z="$_hz" 'NF{ printf "%s\t%s\n", $1, ($2==""?z:$2) }' "$HOSTS" >"$_ht" 2>/dev/null &&
            [ -s "$_ht" ] && mv "$_ht" "$HOSTS" && chmod 600 "$HOSTS" || rm -f "$_ht"
        return 0
    fi
    # ترقية تثبيت بمضيف واحد: المضيف كان في settings.env والنطاق في ملف البيانات
    _hh=${CF_HOSTNAME:-}
    [ -n "$_hh" ] || _hh=$(sed -n 's/^FULLTUNNEL_HOSTNAME=//p' "$SETTINGS" 2>/dev/null | head -1)
    [ -n "$_hh" ] || return 0
    _hz=${CF_ZONE:-}
    [ -n "$_hz" ] || _hz=$(cat "$CREDS/zone-id" 2>/dev/null)
    printf '%s\t%s\n' "$_hh" "$_hz" >"$HOSTS"
    chmod 600 "$HOSTS"
}

hosts_names()  { hosts_init; awk -F'\t' 'NF{print $1}' "$HOSTS" 2>/dev/null; }
hosts_count()  { hosts_init; awk -F'\t' 'NF{n++} END{print n+0}' "$HOSTS" 2>/dev/null || echo 0; }
host_zone()    { awk -F'\t' -v h="$1" '$1==h{print $2; exit}' "$HOSTS" 2>/dev/null; }
host_primary() { hosts_init; awk -F'\t' 'NF{print $1; exit}' "$HOSTS" 2>/dev/null; }
host_known()   { hosts_init; awk -F'\t' -v h="$1" '$1==h{f=1} END{exit !f}' "$HOSTS" 2>/dev/null; }

hosts_list() {
    hosts_init
    [ -s "$HOSTS" ] || { say "لا يوجد مضيفون."; return 0; }
    _i=0
    while IFS="$(printf '\t')" read -r _h _z; do
        [ -n "$_h" ] || continue
        _i=$((_i+1))
        [ -s "$CREDS/zone-token-$_z" ] && _tk="توكن خاص" || _tk="التوكن العام"
        printf '%2d) %-28s zone=%s  (%s)\n' "$_i" "$_h" "$(printf '%s' "$_z" | cut -c1-8)…" "$_tk"
    done <"$HOSTS"
}

# توكن مقصور على نطاق واحد أضيق صلاحية: سحبه لا يعطّل بقية النطاقات. وإن لم
# يوجد فالتوكن العام — فحسابٌ بتوكن واحد يظل يعمل بلا إعداد إضافي.
zone_token() {
    if [ -n "${1:-}" ] && [ -s "$CREDS/zone-token-$1" ]; then cat "$CREDS/zone-token-$1"
    else printf '%s' "$CF_TOKEN"; fi
}

# ----------------------------------------------------------------- البروتوكولات
# vless وtrojan يعملان معًا: لكل واحد منفذه ومساره، وتفصل بينهما الحافة بالمسار.
# تعطيل بروتوكول لا يمسّ قائمة المستخدمين — من عُطّل بروتوكوله يبقى مستخدمًا.
protos_enabled() {
    _pe=${XRAY_PROTOS:-}
    [ -n "$_pe" ] || _pe=${XRAY_PROTO:-vless}
    _pe=$(printf '%s' "$_pe" | tr ',' ' ')
    # ترتيب ثابت وتصفية القيم المجهولة: inbounds[0] يبقى vless متى كان مفعّلًا
    _po=
    for _pc in vless trojan; do
        for _pt in $_pe; do
            [ "$_pt" = "$_pc" ] && { _po="$_po${_po:+ }$_pc"; break; }
        done
    done
    [ -n "$_po" ] || _po=vless
    printf '%s' "$_po"
}

protos_count() { protos_enabled | tr ' ' '\n' | awk 'NF{n++} END{print n+0}'; }

proto_on() { # $1 = vless|trojan
    for _pp in $(protos_enabled); do [ "$_pp" = "$1" ] && return 0; done
    return 1
}

users_init() {
    mkdir -p "$STATE"
    [ -f "$USERS" ] || { : >"$USERS"; chmod 600 "$USERS"; }
    # ترقية تثبيت سابق لميزة تعدّد المستخدمين: المعرّف الوحيد كان في settings.env
    if [ ! -s "$USERS" ] && [ -f "$SETTINGS" ]; then
        _mu=$(sed -n 's/^FULLTUNNEL_XRAY_UUID=//p' "$SETTINGS" | head -1)
        if [ -n "$_mu" ]; then
            printf '%s\t%s\t%s\n' "$_mu" "${FULLTUNNEL_USER:-user1}" "$(gen_pass)" >"$USERS"
            chmod 600 "$USERS"
            ok "رُحِّل المستخدم الموجود من settings.env — معرّفه لم يتغيّر." >&2
        fi
    fi
    users_migrate_pw
}

# المخطّط القديم سطران: uuid<TAB>الاسم. الجديد يضيف كلمة مرور trojan مستقلّة
# لكل مستخدم. المعرّفات لا تُمسّ، فروابط vless القائمة تبقى صالحة بعد الترقية.
# الرسائل إلى stderr: users_init تُنادى داخل $(…) فأي طباعة تفسد القيمة.
users_migrate_pw() {
    [ -s "$USERS" ] || return 0
    awk -F'\t' 'NF && NF<3 {f=1} END{exit !f}' "$USERS" 2>/dev/null || return 0
    _mt=$STATE/.users.mig.$$
    : >"$_mt" 2>/dev/null || { warn "تعذّرت ترقية قائمة المستخدمين — لم يتغيّر شيء." >&2; return 1; }
    while IFS="$(printf '\t')" read -r _mu _mn _mp; do
        [ -n "$_mu" ] || continue
        [ -n "$_mp" ] || _mp=$(gen_pass)
        printf '%s\t%s\t%s\n' "$_mu" "$_mn" "$_mp" >>"$_mt"
    done <"$USERS"
    # القياس من الملف نفسه: عدد السطور يجب أن يطابق قبل الاستبدال
    if [ "$(awk 'NF{n++} END{print n+0}' "$_mt")" != "$(awk 'NF{n++} END{print n+0}' "$USERS")" ]; then
        rm -f "$_mt"; warn "ترقية القائمة غير مكتملة — أُبقيت القديمة." >&2; return 1
    fi
    mv "$_mt" "$USERS" && chmod 600 "$USERS" &&
        ok "رُقّيت قائمة المستخدمين: كلمة مرور trojan مستقلّة لكل مستخدم." >&2
}

users_count() { users_init; awk 'NF{n++} END{print n+0}' "$USERS" 2>/dev/null || echo 0; }

users_list() {
    users_init
    [ -s "$USERS" ] || { say "لا يوجد مستخدمون."; return 0; }
    _i=0
    while IFS="$(printf '\t')" read -r _u _n _p; do
        [ -n "$_u" ] || continue
        _i=$((_i+1))
        printf '%2d) %-20s %s\n' "$_i" "$_n" "$_u"
        printf '    كلمة مرور trojan: %s\n' "${_p:-—}"
    done <"$USERS"
}

user_name_free() {
    users_init
    ! awk -F'\t' -v n="$1" '$2==n{found=1} END{exit !found}' "$USERS" 2>/dev/null
}

user_add() { # $1 الاسم (اختياري)
    users_init
    _n=${1:-}
    [ -n "$_n" ] || _n="user$(( $(users_count) + 1 ))"
    case "$_n" in *[!A-Za-z0-9_.-]*) die "اسم غير صالح: استخدم حروفًا وأرقامًا و . _ - فقط." ;; esac
    user_name_free "$_n" || die "الاسم '$_n' مستخدم بالفعل."
    _u=$(cat /proc/sys/kernel/random/uuid)
    # معرّف vless وكلمة مرور trojan مستقلّان: كشف أحدهما لا يسلّم الآخر
    printf '%s\t%s\t%s\n' "$_u" "$_n" "$(gen_pass)" >>"$USERS"
    chmod 600 "$USERS"
    ok "أُضيف المستخدم $_n"
    printf '%s' "$_u"
}

user_del() { # $1 اسم أو uuid
    users_init
    _k=${1:-}
    [ -n "$_k" ] || die "حدّد اسم المستخدم أو معرّفه."
    _tmp=$STATE/.users.$$
    awk -F'\t' -v k="$_k" '$1!=k && $2!=k' "$USERS" >"$_tmp" || { rm -f "$_tmp"; die "فشل التحرير."; }
    if cmp -s "$USERS" "$_tmp"; then rm -f "$_tmp"; die "لا يوجد مستخدم بهذا الاسم أو المعرّف: $_k"; fi
    mv "$_tmp" "$USERS"; chmod 600 "$USERS"
    ok "حُذف المستخدم $_k"
}

# مسار مستقلّ لكل بروتوكول — به تفصل الحافة بينهما على المضيف نفسه
proto_path() { # $1 = vless|trojan
    case "$1" in
        trojan) printf '%s' "${TROJAN_PATH:-$XRAY_WSPATH}" ;;
        *)      printf '%s' "$XRAY_WSPATH" ;;
    esac
}

# وسم الرابط يفرّق بين نسخه: المضيف حين يتعدّد، والبروتوكول حين يعمل الاثنان.
# بلا ذلك تستورد تطبيقات العملاء روابط متطابقة الاسم فيضيع أيّها يعمل.
link_tag() { # $1 اسم المستخدم  $2 المضيف  $3 البروتوكول
    _tg=$1
    [ "$(hosts_count)" -gt 1 ] && _tg="$_tg@${2%%.*}"
    [ "$(protos_count)" -gt 1 ] && _tg="$_tg-$3"
    printf '%s' "$_tg"
}

user_link() { # $1 uuid  $2 الاسم  $3 كلمة مرور trojan  $4 المضيف  $5 البروتوكول
    _lu=$1; _ln=$2; _lp=${3:-}; _lh=${4:-$CF_HOSTNAME}; _lpr=${5:-vless}
    [ -n "$_lp" ] || _lp=$_lu
    _ep=$(proto_path "$_lpr" | sed 's|/|%2F|g')
    case "${XRAY_NET:-ws}" in
        xhttp) _extra='&mode=auto' ;;
        *)     _extra= ;;
    esac
    _lt=$(link_tag "$_ln" "$_lh" "$_lpr")
    case "$_lpr" in
        trojan)
            printf 'trojan://%s@%s:443?security=tls&sni=%s&type=%s&host=%s&path=%s%s#%s' \
                "$_lp" "$_lh" "$_lh" "${XRAY_NET:-ws}" "$_lh" "$_ep" "$_extra" "$_lt" ;;
        *)
            printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&type=%s&host=%s&path=%s%s#%s' \
                "$_lu" "$_lh" "$_lh" "${XRAY_NET:-ws}" "$_lh" "$_ep" "$_extra" "$_lt" ;;
    esac
}

users_links() {
    load_settings || die "لا يوجد تثبيت محلي. شغّل install أولًا."
    users_init; hosts_init
    [ -s "$USERS" ] || { say "لا يوجد مستخدمون."; return 0; }
    _hn=$(hosts_names)
    [ -n "$_hn" ] || _hn=$CF_HOSTNAME
    while IFS="$(printf '\t')" read -r _u _n _p; do
        [ -n "$_u" ] || continue
        say ""
        say "[$_n]"
        for _lh in $_hn; do
            for _lpr in $(protos_enabled); do
                user_link "$_u" "$_n" "$_p" "$_lh" "$_lpr"; say ""
            done
        done
    done <"$USERS"
    show_ssh
}

# يعيد بناء عملاء xray من ملف المستخدمين ثم يعيد تشغيل الخدمة
users_apply() {
    need_root
    load_settings || die "لا يوجد تثبيت محلي."
    users_init
    [ -s "$USERS" ] || die "لا يمكن ترك القائمة فارغة — أضف مستخدمًا أولًا."
    [ -n "$XRAY_WSPATH" ] || die "إعداد ناقص في $SETTINGS — أعد التثبيت."
    write_xray_config
    if [ -x /etc/init.d/xe3000-cf-xray ]; then
        /etc/init.d/xe3000-cf-xray restart >/dev/null 2>&1 || warn "تعذر إعادة تشغيل xray"
    else
        warn "خدمة xray غير مثبتة بعد — سيُستخدم الإعداد عند اكتمال التثبيت."
    fi
    ok "طُبّقت القائمة ($(users_count) مستخدم)"
}

# عنوان الاستماع قد يكون IP أو مسار مقبس Unix يبدأ بـ /
is_sock() { case "${1:-$XRAY_LISTEN}" in /*) return 0 ;; *) return 1 ;; esac; }

cfd_service() {
    if is_sock; then printf 'unix:%s' "$XRAY_LISTEN"
    else printf 'http://%s:%s' "$XRAY_LISTEN" "$XRAY_PORT"; fi
}

trojan_port()   { printf '%s' "${TROJAN_PORT:-$(( ${XRAY_PORT:-18443} + 2 ))}"; }
# مقبس ثانٍ في وضع unix، منفذ ثانٍ في وضع TCP — المنفذ +1 محجوز لجسر SSH
trojan_listen() { if is_sock; then printf '%s-trojan' "$XRAY_LISTEN"
                  else printf '%s' "$XRAY_LISTEN"; fi; }
trojan_service(){ if is_sock; then printf 'unix:%s-trojan' "$XRAY_LISTEN"
                  else printf 'http://%s:%s' "$XRAY_LISTEN" "$(trojan_port)"; fi; }

write_cfd_config() {
    # حارس: منادٍ نسي load_settings كان يولّد "service: http://:" فيرفضه cloudflared
    hosts_init
    _hn=$(hosts_names)
    [ -n "$_hn" ] || _hn=${CF_HOSTNAME:-}
    [ -n "$TUNNEL_ID" ] && [ -n "$_hn" ] ||
        die "لا يمكن كتابة إعداد cloudflared بلا معرّف نفق واسم مضيف — حمّل الإعدادات أولًا."
    mkdir -p "$CFD_DIR"
    # أصل unix: بلا اسم مضيف يجعل cloudflared يفشل بـ "no Host in request URL"
    if is_sock; then
        _oreq='
    originRequest:
      httpHostHeader: localhost'
    else
        _oreq=
    fi
    # قاعدة لكل (مضيف × بروتوكول). القواعد ذات المسار أولًا لأن cloudflared
    # يطابق بالترتيب: قاعدة المضيف بلا مسار تبتلع كل شيء لو سبقتها.
    _nl='
'
    _ing=
    for _ch in $_hn; do
        if [ "${SSHWS:-0}" = 1 ] && ! is_sock; then
            _ing="$_ing  - hostname: $_ch$_nl    path: ^$SSH_PATH$_nl    service: http://$XRAY_LISTEN:$SSH_PORT$_nl"
        fi
        if proto_on trojan; then
            _ing="$_ing  - hostname: $_ch$_nl    path: ^$(proto_path trojan)$_nl    service: $(trojan_service)$_oreq$_nl"
        fi
        if proto_on vless; then
            _ing="$_ing  - hostname: $_ch$_nl    service: $(cfd_service)$_oreq$_nl"
        fi
    done
    [ -n "$_ing" ] || die "لا قاعدة ingress — لا مضيف مفعّل ولا بروتوكول."
    # القيم النصّية بين علامتي اقتباس: YAML تقرأ 4 عددًا وcloudflared يتوقع نصًّا
    # فيرفض الملف كله ويخرج قبل أن يفتح أي شيء.
    cat >"$CFD_DIR/config.yml.new" <<CFDCFG
tunnel: $TUNNEL_ID
credentials-file: $BASE/tunnel/$TUNNEL_ID.json
protocol: "${CFD_PROTO:-http2}"
# تجاوز سياسة الـ VPN يعمل على IPv4 فقط (iptables لا ip6tables)، فمرور IPv6
# يبقى يسلك السياسة المكسورة: cloudflared يجرّب عناوين حافة IPv6 فيحصل على
# "network is unreachable" ويضيّع دورات قبل أن يصادف عنوان IPv4.
edge-ip-version: "${CFD_EDGE_IP:-4}"
# /ready يعيد عدد الوصلات النشطة — هو الحكم على نجاح المسار الحالي
metrics: "127.0.0.1:${CFD_METRICS:-20241}"
no-autoupdate: true
loglevel: info
ingress:
$_ing  - service: http_status:404
CFDCFG
    [ -s "$CFD_DIR/config.yml.new" ] || { rm -f "$CFD_DIR/config.yml.new"
        die "فشلت كتابة إعداد cloudflared."; }
    # لا تستبدل إعدادًا عاملًا بآخر لا يقبله cloudflared: تحقّق قبل النقل
    # حالة الخروج أصدق من مطابقة نصّ قد يتغيّر بين الإصدارات
    if have cloudflared; then
        if ! _v=$(cloudflared --config "$CFD_DIR/config.yml.new" \
                    tunnel ingress validate 2>&1); then
            rm -f "$CFD_DIR/config.yml.new"
            die "cloudflared رفض الإعداد الجديد — أُبقي القديم:
    $(printf '%s' "$_v" | head -3)"
        fi
    fi
    mv "$CFD_DIR/config.yml.new" "$CFD_DIR/config.yml" || die "تعذر تثبيت إعداد cloudflared."
    chmod 600 "$CFD_DIR/config.yml"
}

write_xray_config() {
    mkdir -p "$XRAY_DIR" || die "تعذر إنشاء $XRAY_DIR"
    users_init
    [ -s "$USERS" ] || die "لا يوجد مستخدمون."
    # مدخل مستقلّ لكل بروتوكول مفعّل: منفذه ومساره وقائمة عملائه. تعطيل
    # بروتوكول يحذف مدخله وحده — قائمة المستخدمين لا تُمسّ.
    _inb=
    for _wp in $(protos_enabled); do
        case "$_wp" in
            trojan)
                # الحقل الثالث كلمة مرور trojan؛ سطر لم يُرحَّل بعد يقع على المعرّف
                _cl=$(awk -F'\t' 'NF{ printf "%s{ \"password\": \"%s\", \"email\": \"%s\" }", (n++?", ":""), ($3!=""?$3:$1), $2 }' "$USERS")
                _settings="{ \"clients\": [ $_cl ] }"
                _wl=$(trojan_listen); _wport=$(trojan_port) ;;
            vless)
                _cl=$(awk -F'\t' 'NF{ printf "%s{ \"id\": \"%s\", \"email\": \"%s\" }", (n++?", ":""), $1, $2 }' "$USERS")
                _settings="{ \"clients\": [ $_cl ], \"decryption\": \"none\" }"
                _wl=$XRAY_LISTEN; _wport=$XRAY_PORT ;;
            *) continue ;;
        esac
        if is_sock; then
            _addr="\"listen\": \"$_wl\","
            _sock=', "sockopt": { "domainSockets": {} }'
            rm -f "$_wl"
        else
            _addr="\"listen\": \"$_wl\", \"port\": $_wport,"
            # TFO معطّل: نواة هذا الجهاز تُنشئ معه طلبات اتصال بعناوين مصفّرة
            _sock=', "sockopt": { "tcpFastOpen": false }'
        fi
        _wpath=$(proto_path "$_wp")
        case "${XRAY_NET:-ws}" in
            xhttp) _stream="\"network\": \"xhttp\", \"xhttpSettings\": { \"path\": \"$_wpath\", \"mode\": \"auto\" }" ;;
            *)     _stream="\"network\": \"ws\", \"wsSettings\": { \"path\": \"$_wpath\" }" ;;
        esac
        _inb="$_inb${_inb:+,}
    {
      $_addr
      \"protocol\": \"$_wp\",
      \"settings\": $_settings,
      \"streamSettings\": { $_stream$_sock }
    }"
    done
    [ -n "$_inb" ] || die "لا بروتوكول مفعّل — فعّل واحدًا: sh $SELF proto-enable vless"

    # جسر SSH عبر WebSocket: منفذ ثانٍ يمرّر البايتات الخام إلى خادم SSH المحلي
    _ssh=
    if [ "${SSHWS:-0}" = 1 ] && ! is_sock; then
        _ssh=",
    {
      \"listen\": \"$XRAY_LISTEN\", \"port\": $SSH_PORT,
      \"protocol\": \"dokodemo-door\",
      \"settings\": { \"address\": \"127.0.0.1\", \"port\": 22, \"network\": \"tcp\" },
      \"streamSettings\": { \"network\": \"ws\", \"wsSettings\": { \"path\": \"$SSH_PATH\" }, \"sockopt\": { \"tcpFastOpen\": false } }
    }"
    fi

    cat >"$XRAY_DIR/config.json.new" <<XRAYCFG
{
  "log": { "loglevel": "warning" },
  "inbounds": [$_inb$_ssh
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
XRAYCFG
    [ -s "$XRAY_DIR/config.json.new" ] && grep -q '"clients"' "$XRAY_DIR/config.json.new" || {
        rm -f "$XRAY_DIR/config.json.new"; die "فشلت كتابة إعداد xray."; }
    mv "$XRAY_DIR/config.json.new" "$XRAY_DIR/config.json" || die "تعذر تثبيت إعداد xray."
    chmod 600 "$XRAY_DIR/config.json"
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

# سجل واحد لكل مضيف في نطاقه هو، موكَّلًا إلى النفق نفسه. النطاق قد يكون له
# توكنه الخاص، فيُبدَّل التوكن لمدة النداء ثم يُعاد.
dns_one() { # $1 المضيف  $2 معرّف النطاق
    _dh=$1; _dz=${2:-}
    [ -n "$_dh" ] || return 1
    if [ -z "$_dz" ]; then
        err "لا معرّف نطاق للمضيف $_dh — عيّنه بـ: sh $SELF host-add $_dh <zone-id>"
        return 1
    fi
    _content="$TUNNEL_ID.cfargotunnel.com"
    _keep=$CF_TOKEN
    CF_TOKEN=$(zone_token "$_dz")
    _r=$(cf GET "/zones/$_dz/dns_records?type=CNAME&name=$_dh")
    if ! cf_success "$_r"; then
        CF_TOKEN=$_keep
        err "تعذر قراءة سجلات DNS لـ $_dh: $(cf_errors "$_r")"
        return 1
    fi
    _rec=$(jf "$_r" '@.result[0].id')
    _body=$(printf '{"type":"CNAME","name":"%s","content":"%s","proxied":true,"ttl":1}' \
            "$_dh" "$_content")
    if [ -n "$_rec" ]; then
        _r=$(cf PUT "/zones/$_dz/dns_records/$_rec" "$_body")
        _act="حُدِّث"
    else
        _r=$(cf POST "/zones/$_dz/dns_records" "$_body")
        _act="أُنشئ"
    fi
    CF_TOKEN=$_keep
    cf_success "$_r" || { err "فشل سجل DNS لـ $_dh: $(cf_errors "$_r")"; return 1; }
    ok "$_act سجل CNAME: $_dh ← $_content"
}

create_or_update_dns() {
    hosts_init
    _any=0; _bad=0
    while IFS="$(printf '\t')" read -r _dh0 _dz0; do
        [ -n "$_dh0" ] || continue
        _any=1
        dns_one "$_dh0" "$_dz0" || _bad=1
    done <"$HOSTS"
    # تثبيت جديد: hosts.tsv لم يُكتب بعد، فالمضيف الوحيد من المتغيّرات
    [ "$_any" = 1 ] || { dns_one "$CF_HOSTNAME" "$CF_ZONE" || return 1; return 0; }
    [ "$_bad" = 0 ] || die "فشل سجل DNS لمضيف واحد على الأقل — راجع الأسطر الحمراء أعلاه."
    return 0
}

# ----------------------------------------------------------------- [4/6] ملفات الإعداد
write_configs() {
    mkdir -p "$CFD_DIR" "$XRAY_DIR" "$STATE" "$BASE/tunnel"
    chmod 700 "$BASE" "$BASE/tunnel"

    printf '{"AccountTag":"%s","TunnelID":"%s","TunnelSecret":"%s"}\n' \
        "$CF_ACCOUNT" "$TUNNEL_ID" "$TUNNEL_SECRET" >"$BASE/tunnel/$TUNNEL_ID.json"
    chmod 600 "$BASE/tunnel/$TUNNEL_ID.json"

    XRAY_PORT=${FULLTUNNEL_XRAY_PORT:-18443}
    XRAY_LISTEN=${FULLTUNNEL_XRAY_LISTEN:-127.0.0.1}
    XRAY_NET=${FULLTUNNEL_XRAY_NET:-ws}
    XRAY_PROTO=${FULLTUNNEL_PROTO:-vless}
    XRAY_PROTOS=${FULLTUNNEL_PROTOS:-$XRAY_PROTO}
    TROJAN_PORT=$(( XRAY_PORT + 2 ))
    TROJAN_PATH=${FULLTUNNEL_TROJAN_PATH:-/$(head -c 16 /dev/urandom | md5sum | cut -c1-16)}
    SSHWS=${FULLTUNNEL_SSHWS:-0}
    SSH_PATH=${FULLTUNNEL_SSH_PATH:-/ssh-$(head -c 8 /dev/urandom | md5sum | cut -c1-8)}
    SSH_PORT=$(( XRAY_PORT + 1 ))
    XRAY_WSPATH=${FULLTUNNEL_XRAY_PATH:-/$(head -c 16 /dev/urandom | md5sum | cut -c1-16)}
    users_init
    if [ ! -s "$USERS" ]; then
        XRAY_UUID=${FULLTUNNEL_XRAY_UUID:-$(cat /proc/sys/kernel/random/uuid)}
        printf '%s\t%s\t%s\n' "$XRAY_UUID" "${FULLTUNNEL_USER:-user1}" "$(gen_pass)" >"$USERS"
        chmod 600 "$USERS"
    else
        XRAY_UUID=$(awk -F'\t' 'NF{print $1; exit}' "$USERS")
    fi
    hosts_init
    write_cfd_config
    write_xray_config
    ok "كُتبت ملفات الإعداد"
}

write_init() {
    mkdir -p /etc/xe3000-cf-fulltunnel
    cat >/etc/init.d/xe3000-cf-xray <<'INITXRAY'
#!/bin/sh /etc/rc.common
START=94
STOP=11
USE_PROCD=1
start_service() {
    [ -f /etc/xe3000-cf-fulltunnel/xray/config.json ] || return 1
    procd_open_instance
    procd_set_param command /usr/bin/xray run -c /etc/xe3000-cf-fulltunnel/xray/config.json
    # Go 1.24+ يفتح المستمعين بـ MPTCP افتراضيًا، وبعض النوى (ومنها هذا الجهاز)
    # تُنشئ معه طلبات اتصال بعناوين صفرية فلا تكتمل المصافحة.
    procd_set_param env GODEBUG=multipathtcp=0
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
INITXRAY

    # cloudflared يترجم سجل SRV قبل أي شيء ويخرج إن فشل. عند الإقلاع لا يكون
    # DNS جاهزًا بعد، فتموت الخدمة بينما xray يبدأ بلا مشكلة لأنه لا يحتاج شبكة.
    # هذا الغلاف ينتظر الترجمة ثم يستبدل نفسه بـ cloudflared.
    {
    printf '#!/bin/sh\n'
    printf 'MET="127.0.0.1:%s"\n' "${CFD_METRICS:-20241}"
    cat <<'RUNCFD'
# نفس علّة xray: Go 1.24+ يفتح المستمعين بـ MPTCP، وMPTCP في هذه النواة لا
# تكتمل معه المصافحة. وصلات cloudflared الصادرة سليمة، لكن مستمع /ready
# يبقى مفتوحًا بلا أن يقبل اتصالًا — فيُظهر netstat LISTEN وcurl مهلة.
GODEBUG=multipathtcp=0
export GODEBUG
_i=0
while [ "$_i" -lt 90 ]; do
    nslookup region1.v2.argotunnel.com >/dev/null 2>&1 && break
    _i=$((_i + 1))
    [ "$_i" = 1 ] && logger -t xe3000 "cloudflared: بانتظار جهوزية DNS قبل البدء"
    sleep 2
done
[ "$_i" -lt 90 ] || logger -t xe3000 "cloudflared: DNS لم يجهز خلال 3 دقائق — سأبدأ رغم ذلك"
# --metrics صراحةً: مفتاح metrics في ملف الإعداد لا تقرؤه كل الإصدارات،
# ووجود /ready شرطٌ لعمل الوضع التلقائي.
exec /usr/bin/cloudflared --no-autoupdate --metrics "$MET" \
    --config /etc/xe3000-cf-fulltunnel/cloudflared/config.yml tunnel run
RUNCFD
    } >/etc/xe3000-cf-fulltunnel/run-cloudflared.sh
    chmod 750 /etc/xe3000-cf-fulltunnel/run-cloudflared.sh

    cat >/etc/init.d/xe3000-cf-tunnel <<'INITCFD'
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1
start_service() {
    [ -f /etc/xe3000-cf-fulltunnel/cloudflared/config.yml ] || return 1
    [ -x /etc/xe3000-cf-fulltunnel/run-cloudflared.sh ] || return 1
    procd_open_instance
    procd_set_param command /etc/xe3000-cf-fulltunnel/run-cloudflared.sh
    procd_set_param env GODEBUG=multipathtcp=0
    # retry=0 يعني بلا حدّ لعدد المحاولات في procd
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
FULLTUNNEL_XRAY_LISTEN=$XRAY_LISTEN
FULLTUNNEL_XRAY_NET=${XRAY_NET:-ws}
FULLTUNNEL_PROTO=${XRAY_PROTO:-vless}
FULLTUNNEL_PROTOS=$(protos_enabled | tr ' ' ',')
FULLTUNNEL_TROJAN_PATH=${TROJAN_PATH:-}
FULLTUNNEL_TROJAN_PORT=$(trojan_port)
FULLTUNNEL_SSHWS=${SSHWS:-0}
FULLTUNNEL_SSH_PATH=${SSH_PATH:-/ssh}
FULLTUNNEL_SSH_PORT=${SSH_PORT:-0}
FULLTUNNEL_CFD_PROTO=${CFD_PROTO:-http2}
FULLTUNNEL_CFD_EDGE_IP=${CFD_EDGE_IP:-4}
FULLTUNNEL_CFD_METRICS=${CFD_METRICS:-20241}
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
    XRAY_LISTEN=${FULLTUNNEL_XRAY_LISTEN:-127.0.0.1}
    XRAY_NET=${FULLTUNNEL_XRAY_NET:-ws}
    XRAY_PROTO=${FULLTUNNEL_PROTO:-vless}
    XRAY_PROTOS=${FULLTUNNEL_PROTOS:-$XRAY_PROTO}
    TROJAN_PORT=${FULLTUNNEL_TROJAN_PORT:-$(( ${XRAY_PORT:-18443} + 2 ))}
    # تثبيت أقدم بلا مسار trojan: يُشتقّ من مسار vless اشتقاقًا ثابتًا بدل
    # مشاركته — مساران متطابقان يجعلان الحافة توجّه البروتوكولين إلى مدخل واحد.
    TROJAN_PATH=${FULLTUNNEL_TROJAN_PATH:-}
    [ -n "$TROJAN_PATH" ] || TROJAN_PATH="${FULLTUNNEL_XRAY_PATH:-/tj}-tj"
    SSHWS=${FULLTUNNEL_SSHWS:-0}
    SSH_PATH=${FULLTUNNEL_SSH_PATH:-/ssh}
    SSH_PORT=${FULLTUNNEL_SSH_PORT:-0}
    [ "$SSH_PORT" = 0 ] && SSH_PORT=$(( ${XRAY_PORT:-18443} + 1 ))
    CFD_PROTO=${FULLTUNNEL_CFD_PROTO:-http2}
    CFD_EDGE_IP=${FULLTUNNEL_CFD_EDGE_IP:-4}
    CFD_METRICS=${FULLTUNNEL_CFD_METRICS:-20241}
    XRAY_UUID=${FULLTUNNEL_XRAY_UUID:-}
    XRAY_WSPATH=${FULLTUNNEL_XRAY_PATH:-}
    return 0
}

# ----------------------------------------------------------------- [5/6] التشغيل
# MPTCP: إن كان مفعّلًا فمستمعو Go يُفتحون به. لا نعطّله على مستوى النظام
# (قد يعتمد عليه دمج الوصلات في الراوتر) بل نعطّله لعملية xray وحدها.
mptcp_note() {
    _m=/proc/sys/net/mptcp/enabled
    [ -r "$_m" ] || return 0
    [ "$(cat "$_m" 2>/dev/null)" = 1 ] &&
        say "    MPTCP مفعّل في النظام — xray يعمل بـ GODEBUG=multipathtcp=0"
    return 0
}

# نواة هذا الجهاز تُنتج طلبات اتصال بعناوين صفرية حين يكون TFO فعّالًا
disable_tfo() {
    _f=/proc/sys/net/ipv4/tcp_fastopen
    [ -w "$_f" ] || return 0
    _cur=$(cat "$_f" 2>/dev/null)
    [ "$_cur" = 0 ] && return 0
    echo 0 >"$_f" 2>/dev/null && ok "عُطّل TCP Fast Open (كان $_cur)"
    # التثبيت بعد إعادة التشغيل
    if [ -d /etc/sysctl.d ]; then
        printf 'net.ipv4.tcp_fastopen=0\n' >/etc/sysctl.d/99-xe3000-tfo.conf
    elif [ -f /etc/sysctl.conf ]; then
        grep -q '^net.ipv4.tcp_fastopen' /etc/sysctl.conf 2>/dev/null ||
            printf 'net.ipv4.tcp_fastopen=0\n' >>/etc/sysctl.conf
    fi
    return 0
}

# تشغيلها الآن لا يعني أنها تبدأ بعد الإقلاع: ذلك رابط منفصل في /etc/rc.d
svc_boot_enabled() { ls /etc/rc.d/S[0-9][0-9]"$1" >/dev/null 2>&1; }

enable_services() {
    disable_tfo
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
        # الفشل هنا صامت تمامًا حتى أول إقلاع، فتحقّق منه الآن
        if svc_boot_enabled "$s"; then
            ok "$s سيبدأ تلقائيًا بعد الإقلاع"
        else
            warn "$s لن يبدأ بعد الإقلاع — لا رابط في /etc/rc.d"
            say "  جرّب: /etc/init.d/$s enable && ls -l /etc/rc.d/ | grep $s"
        fi
    done
}

# ----------------------------------------------------------------- [6/6] لوحة 9000
# مولّد QR مضمّن — بلا أي اعتماد خارجي أو CDN
write_qrlib() {
    cat >"$UIROOT/qr.js" <<'QRLIB'
// مولّد QR — وضع البايت، مستوى تصحيح L، الإصدارات 1..15. بلا اعتمادات.
var QR = (function () {
  var EXP = [], LOG = [];
  (function () {
    var x = 1;
    for (var i = 0; i < 256; i++) { EXP[i] = x; x <<= 1; if (x & 256) x ^= 0x11d; }
    for (var j = 0; j < 255; j++) LOG[EXP[j]] = j;
  })();
  function mul(a, b) { return (a === 0 || b === 0) ? 0 : EXP[(LOG[a] + LOG[b]) % 255]; }

  // [إجمالي رموز البيانات, رموز التصحيح لكل كتلة, [ [عدد الكتل, رموز بيانات الكتلة], ... ] ]
  var L = {
    1:[19,7,[[1,19]]],           2:[34,10,[[1,34]]],          3:[55,15,[[1,55]]],
    4:[80,20,[[1,80]]],          5:[108,26,[[1,108]]],        6:[136,18,[[2,68]]],
    7:[156,20,[[2,78]]],         8:[194,24,[[2,97]]],         9:[232,30,[[2,116]]],
    10:[274,18,[[2,68],[2,69]]], 11:[324,20,[[4,81]]],        12:[370,24,[[2,92],[2,93]]],
    13:[428,26,[[4,107]]],       14:[461,30,[[3,115],[1,116]]],15:[523,22,[[5,87],[1,88]]]
  };
  var ALIGN = {
    1:[],2:[6,18],3:[6,22],4:[6,26],5:[6,30],6:[6,34],7:[6,22,38],8:[6,24,42],
    9:[6,26,46],10:[6,28,50],11:[6,30,54],12:[6,32,58],13:[6,34,62],
    14:[6,26,46,66],15:[6,26,48,70]
  };

  function rsGen(n) {
    var g = [1];
    for (var i = 0; i < n; i++) {
      var ng = new Array(g.length + 1).fill(0);
      for (var j = 0; j < g.length; j++) {
        ng[j] ^= g[j];                    // الضرب في x
        ng[j + 1] ^= mul(g[j], EXP[i]);   // الضرب في α^i
      }
      g = ng;
    }
    return g;
  }
  function rsEnc(data, n) {
    var g = rsGen(n), res = new Array(n).fill(0);
    for (var i = 0; i < data.length; i++) {
      var f = data[i] ^ res[0];
      res.shift(); res.push(0);
      if (f !== 0) for (var j = 0; j < n; j++) res[j] ^= mul(g[j + 1], f);
    }
    return res;
  }

  function utf8(str) {
    var out = [], s = unescape(encodeURIComponent(str));
    for (var i = 0; i < s.length; i++) out.push(s.charCodeAt(i));
    return out;
  }

  function bch15(v) { var d = v << 10; while (Math.floor(Math.log2(d)) >= 10) d ^= 0x537 << (Math.floor(Math.log2(d)) - 10); return ((v << 10) | d) ^ 0x5412; }
  function bch18(v) { var d = v << 12; while (Math.floor(Math.log2(d)) >= 12) d ^= 0x1f25 << (Math.floor(Math.log2(d)) - 12); return (v << 12) | d; }

  function build(text) {
    var bytes = utf8(text), ver = 0;
    for (var v = 1; v <= 15; v++) {
      var cap = L[v][0], ccBits = v < 10 ? 8 : 16;
      if (bytes.length + 2 + Math.ceil(ccBits / 8) <= cap + 1 &&
          (4 + ccBits + bytes.length * 8) <= cap * 8) { ver = v; break; }
    }
    if (!ver) throw new Error('النص أطول مما يتسع في الإصدار 15');

    var totalData = L[ver][0], ecLen = L[ver][1], groups = L[ver][2];
    var ccBits = ver < 10 ? 8 : 16;
    var bits = [];
    function put(val, n) { for (var i = n - 1; i >= 0; i--) bits.push((val >> i) & 1); }
    put(4, 4); put(bytes.length, ccBits);
    for (var i = 0; i < bytes.length; i++) put(bytes[i], 8);
    var rem = totalData * 8 - bits.length;
    put(0, Math.min(4, rem));
    while (bits.length % 8) bits.push(0);
    var pad = [0xEC, 0x11], pi = 0;
    while (bits.length < totalData * 8) { put(pad[pi++ % 2], 8); }

    var cw = [];
    for (var i = 0; i < bits.length; i += 8) {
      var b = 0; for (var j = 0; j < 8; j++) b = (b << 1) | bits[i + j];
      cw.push(b);
    }

    var blocks = [], ecs = [], off = 0;
    for (var g = 0; g < groups.length; g++) {
      for (var k = 0; k < groups[g][0]; k++) {
        var d = cw.slice(off, off + groups[g][1]); off += groups[g][1];
        blocks.push(d); ecs.push(rsEnc(d, ecLen));
      }
    }
    var maxD = 0; for (var i = 0; i < blocks.length; i++) maxD = Math.max(maxD, blocks[i].length);
    var out = [];
    for (var i = 0; i < maxD; i++) for (var b = 0; b < blocks.length; b++) if (i < blocks[b].length) out.push(blocks[b][i]);
    for (var i = 0; i < ecLen; i++) for (var b = 0; b < ecs.length; b++) out.push(ecs[b][i]);
    return { ver: ver, cw: out };
  }

  function matrix(ver) {
    var n = ver * 4 + 17, m = [], f = [];
    for (var i = 0; i < n; i++) { m.push(new Array(n).fill(0)); f.push(new Array(n).fill(0)); }
    function set(r, c, v) { m[r][c] = v; f[r][c] = 1; }
    function finder(r, c) {
      for (var dr = -1; dr <= 7; dr++) for (var dc = -1; dc <= 7; dc++) {
        var rr = r + dr, cc = c + dc;
        if (rr < 0 || cc < 0 || rr >= n || cc >= n) continue;
        var inner = (dr >= 0 && dr <= 6 && dc >= 0 && dc <= 6);
        var on = inner && (dr === 0 || dr === 6 || dc === 0 || dc === 6 ||
                 (dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4));
        set(rr, cc, on ? 1 : 0);
      }
    }
    finder(0, 0); finder(0, n - 7); finder(n - 7, 0);
    for (var i = 8; i < n - 8; i++) { set(6, i, i % 2 === 0 ? 1 : 0); set(i, 6, i % 2 === 0 ? 1 : 0); }
    var ap = ALIGN[ver];
    for (var a = 0; a < ap.length; a++) for (var b = 0; b < ap.length; b++) {
      var r = ap[a], c = ap[b];
      if ((r <= 8 && c <= 8) || (r <= 8 && c >= n - 9) || (r >= n - 9 && c <= 8)) continue;
      for (var dr = -2; dr <= 2; dr++) for (var dc = -2; dc <= 2; dc++)
        set(r + dr, c + dc, (Math.abs(dr) === 2 || Math.abs(dc) === 2 || (dr === 0 && dc === 0)) ? 1 : 0);
    }
    for (var i = 0; i <= 8; i++) { if (!f[8][i]) set(8, i, 0); if (!f[i][8]) set(i, 8, 0); }
    for (var i = n - 8; i < n; i++) { set(8, i, 0); set(i, 8, 0); }
    set(n - 8, 8, 1);   // النقطة الداكنة — بعد الحجز حتى لا تُمسح
    if (ver >= 7) for (var i = 0; i < 18; i++) {
      var r = Math.floor(i / 3), c = i % 3;
      set(n - 11 + c, r, 0); set(r, n - 11 + c, 0);
    }
    return { m: m, f: f, n: n };
  }

  function place(mm, cw) {
    var m = mm.m, f = mm.f, n = mm.n, bi = 0, up = true;
    for (var col = n - 1; col > 0; col -= 2) {
      if (col === 6) col--;
      for (var t = 0; t < n; t++) {
        var row = up ? n - 1 - t : t;
        for (var k = 0; k < 2; k++) {
          var c = col - k;
          if (f[row][c]) continue;
          var bit = 0;
          if (bi < cw.length * 8) bit = (cw[bi >> 3] >> (7 - (bi & 7))) & 1;
          m[row][c] = bit; bi++;
        }
      }
      up = !up;
    }
  }

  function maskFn(k, r, c) {
    switch (k) {
      case 0: return (r + c) % 2 === 0;
      case 1: return r % 2 === 0;
      case 2: return c % 3 === 0;
      case 3: return (r + c) % 3 === 0;
      case 4: return (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0;
      case 5: return (r * c) % 2 + (r * c) % 3 === 0;
      case 6: return ((r * c) % 2 + (r * c) % 3) % 2 === 0;
      case 7: return ((r + c) % 2 + (r * c) % 3) % 2 === 0;
    }
  }

  function penalty(m, n) {
    var p = 0, i, j, k;
    for (i = 0; i < n; i++) {
      for (var dir = 0; dir < 2; dir++) {
        var run = 1, prev = dir ? m[0][i] : m[i][0];
        for (j = 1; j < n; j++) {
          var v = dir ? m[j][i] : m[i][j];
          if (v === prev) { run++; } else { if (run >= 5) p += 3 + (run - 5); run = 1; prev = v; }
        }
        if (run >= 5) p += 3 + (run - 5);
      }
    }
    for (i = 0; i < n - 1; i++) for (j = 0; j < n - 1; j++) {
      var s = m[i][j] + m[i][j+1] + m[i+1][j] + m[i+1][j+1];
      if (s === 0 || s === 4) p += 3;
    }
    var pat1 = [1,0,1,1,1,0,1,0,0,0,0], pat2 = [0,0,0,0,1,0,1,1,1,0,1];
    for (i = 0; i < n; i++) for (j = 0; j + 10 < n; j++) {
      var okH1 = true, okH2 = true, okV1 = true, okV2 = true;
      for (k = 0; k < 11; k++) {
        if (m[i][j+k] !== pat1[k]) okH1 = false;
        if (m[i][j+k] !== pat2[k]) okH2 = false;
        if (m[j+k][i] !== pat1[k]) okV1 = false;
        if (m[j+k][i] !== pat2[k]) okV2 = false;
      }
      if (okH1) p += 40; if (okH2) p += 40; if (okV1) p += 40; if (okV2) p += 40;
    }
    var dark = 0;
    for (i = 0; i < n; i++) for (j = 0; j < n; j++) dark += m[i][j];
    var pct = dark * 100 / (n * n);
    p += Math.floor(Math.abs(pct - 50) / 5) * 10;
    return p;
  }

  function encode(text) {
    var b = build(text), mm = matrix(b.ver), n = mm.n;
    place(mm, b.cw);
    var best = null, bestP = Infinity, bestK = 0;
    for (var k = 0; k < 8; k++) {
      var m = [];
      for (var i = 0; i < n; i++) m.push(mm.m[i].slice());
      for (var i = 0; i < n; i++) for (var j = 0; j < n; j++)
        if (!mm.f[i][j] && maskFn(k, i, j)) m[i][j] ^= 1;
      var fmt = bch15((1 << 3) | k);          // مستوى L = 01
      for (var i = 0; i < 15; i++) {
        var bit = (fmt >> i) & 1;
        // النسخة العمودية على العمود 8
        if (i < 6) m[i][8] = bit;
        else if (i < 8) m[i + 1][8] = bit;
        else m[n - 15 + i][8] = bit;
        // النسخة الأفقية على الصف 8
        if (i < 8) m[8][n - i - 1] = bit;
        else if (i === 8) m[8][7] = bit;
        else m[8][14 - i] = bit;
      }
      if (b.ver >= 7) {
        var vi = bch18(b.ver);
        for (var i = 0; i < 18; i++) {
          var bit = (vi >> i) & 1, r = Math.floor(i / 3), c = i % 3;
          m[n - 11 + c][r] = bit; m[r][n - 11 + c] = bit;
        }
      }
      var p = penalty(m, n);
      if (p < bestP) { bestP = p; best = m; bestK = k; }
    }
    return { size: n, modules: best, version: b.ver, mask: bestK };
  }

  function svg(text, scale, quiet) {
    var q = qr = encode(text), n = q.size, s = scale || 4, qz = (quiet === undefined ? 4 : quiet);
    var dim = (n + qz * 2) * s, d = '';
    for (var r = 0; r < n; r++) for (var c = 0; c < n; c++)
      if (q.modules[r][c]) d += 'M' + ((c + qz) * s) + ' ' + ((r + qz) * s) + 'h' + s + 'v' + s + 'h-' + s + 'z';
    return '<svg xmlns="http://www.w3.org/2000/svg" width="' + dim + '" height="' + dim +
           '" viewBox="0 0 ' + dim + ' ' + dim + '" shape-rendering="crispEdges">' +
           '<rect width="100%" height="100%" fill="#fff"/><path fill="#000" d="' + d + '"/></svg>';
  }
  return { encode: encode, svg: svg };
})();
if (typeof module !== 'undefined') module.exports = QR;
QRLIB
}

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
USERS=$BASE/state/users.tsv
HOSTS=$BASE/state/hosts.tsv
INSTALLER='@SELF@'
Q=${QUERY_STRING:-}
MSG=; CLS=msg

dec() { printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g; s/%\(..\)/\\x\1/g')"; }
arg() { printf '%s' "$BODY$Q" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }

BODY=
if [ "${REQUEST_METHOD:-GET}" = POST ] && [ -n "${CONTENT_LENGTH:-}" ]; then
  BODY=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
fi
ACT=$(arg action)
case "$ACT" in ''|start|stop|restart|useradd|userdel|forget) : ;; *) ACT=invalid ;; esac

installed() { [ -f "$SETTINGS" ] && [ -x /etc/init.d/xe3000-cf-tunnel ]; }
run() { [ -f "$INSTALLER" ] && sh "$INSTALLER" "$@" 2>&1; }

if [ -n "$ACT" ]; then
  if ! installed && [ "$ACT" != forget ]; then
    MSG="البوابة غير مثبتة — لا يمكن تنفيذ الأمر."; CLS=err
  else
    case "$ACT" in
      start|stop|restart)
        /etc/init.d/xe3000-cf-xray   "$ACT" >/dev/null 2>&1
        /etc/init.d/xe3000-cf-tunnel "$ACT" >/dev/null 2>&1
        MSG="نُفِّذ الأمر: $ACT"; CLS=ok ;;
      useradd)
        N=$(dec "$(arg name)")
        case "$N" in
          '' ) MSG=$(run user-add); CLS=ok ;;
          *[!A-Za-z0-9_.-]* ) MSG="اسم غير صالح — حروف وأرقام و . _ - فقط."; CLS=err ;;
          * ) MSG=$(run user-add "$N"); CLS=ok ;;
        esac ;;
      userdel)
        U=$(dec "$(arg uid)")
        case "$U" in
          ''|*[!A-Za-z0-9_.-]* ) MSG="معرّف غير صالح."; CLS=err ;;
          * ) MSG=$(run user-del "$U"); CLS=ok ;;
        esac ;;
      forget)
        if [ "$(dec "$(arg confirm)")" = FORGET ]; then
          rm -rf "$CREDS"; MSG="حُذفت بيانات Cloudflare المحفوظة."; CLS=ok
        else MSG="لم تُحذف — يجب كتابة FORGET بالضبط."; CLS=err; fi ;;
    esac
  fi
fi

svc() {
  if [ -x "/etc/init.d/$1" ]; then
    /etc/init.d/"$1" running >/dev/null 2>&1 && printf 'يعمل' || printf 'متوقف'
  else printf 'غير مثبت'; fi
}

HOSTV=; TIDV=; PATHV=; TPATHV=; PROTOSV=; NETV=
if [ -f "$SETTINGS" ]; then
  HOSTV=$(sed -n 's/^FULLTUNNEL_HOSTNAME=//p' "$SETTINGS")
  TIDV=$(sed -n 's/^FULLTUNNEL_TUNNEL_ID=//p' "$SETTINGS")
  PATHV=$(sed -n 's/^FULLTUNNEL_XRAY_PATH=//p' "$SETTINGS")
  TPATHV=$(sed -n 's/^FULLTUNNEL_TROJAN_PATH=//p' "$SETTINGS")
  PROTOSV=$(sed -n 's/^FULLTUNNEL_PROTOS=//p' "$SETTINGS" | tr ',' ' ')
  [ -n "$PROTOSV" ] || PROTOSV=$(sed -n 's/^FULLTUNNEL_PROTO=//p' "$SETTINGS")
  NETV=$(sed -n 's/^FULLTUNNEL_XRAY_NET=//p' "$SETTINGS")
fi
[ -n "$PROTOSV" ] || PROTOSV=vless
[ -n "$NETV" ] || NETV=ws
# نفس اشتقاق load_settings: مساران متطابقان يوجّهان البروتوكولين إلى مدخل واحد
[ -n "$TPATHV" ] || TPATHV="$PATHV-tj"
HOSTLIST=$(awk -F'\t' 'NF{print $1}' "$HOSTS" 2>/dev/null)
[ -n "$HOSTLIST" ] || HOSTLIST=$HOSTV
NHOST=$(printf '%s\n' $HOSTLIST | awk 'NF{n++} END{print n+0}')
NPROTO=$(printf '%s\n' $PROTOSV | awk 'NF{n++} END{print n+0}')
EPATH=$(printf '%s' "$PATHV" | sed 's|/|%2F|g')
ETPATH=$(printf '%s' "$TPATHV" | sed 's|/|%2F|g')
[ -s "$CREDS/api-token" ] && CRED=محفوظة || CRED="غير محفوظة"

printf 'Content-Type: text/html; charset=utf-8\r\n\r\n'
cat <<HTML
<!doctype html><html lang="ar" dir="rtl"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>XE3000 Full-Tunnel</title>
<style>
:root{--bg:#111;--card:#1c1c1c;--line:#333;--fg:#eee;--mut:#9a9a9a;--acc:#2d6cdf}
body{font-family:system-ui,-apple-system,sans-serif;background:var(--bg);color:var(--fg);margin:0;padding:16px}
.c{max-width:720px;margin:auto}h1{font-size:1.25rem;margin:.2rem 0 1rem}
h2{font-size:1rem;margin:0 0 .6rem;color:var(--mut);font-weight:600}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px;margin:12px 0}
table{width:100%;border-collapse:collapse}td{padding:6px 2px;border-bottom:1px solid #2a2a2a}
td:first-child{color:var(--mut);width:9rem}
a.btn,button{display:inline-block;background:var(--acc);color:#fff;text-decoration:none;border:0;
padding:8px 14px;border-radius:7px;margin:4px 0 0 6px;font-size:.92rem;cursor:pointer}
button.sec{background:#444}button.del{background:#7a2020}
.msg,.ok,.err{padding:10px;border-radius:7px;margin:10px 0;white-space:pre-wrap}
.msg{background:#332b00;border:1px solid #7a6500}
.ok{background:#0f2d16;border:1px solid #2a6b3a}
.err{background:#3a1111;border:1px solid #7a2020}
input{padding:8px;border-radius:6px;border:1px solid #444;background:#0d0d0d;color:var(--fg);font-size:.9rem}
.u{border:1px solid var(--line);border-radius:9px;padding:12px;margin:10px 0;background:#161616}
.uh{display:flex;justify-content:space-between;align-items:center;gap:8px;flex-wrap:wrap}
.uh b{font-size:1.02rem}.uid{color:var(--mut);font-size:.78rem;word-break:break-all}
.lk{display:flex;gap:6px;margin-top:8px;flex-wrap:wrap}
.lk input{flex:1 1 16rem;min-width:0;font-family:ui-monospace,monospace;font-size:.76rem}
.qr{margin-top:10px;background:#fff;padding:8px;border-radius:8px;display:inline-block;line-height:0}
.qr svg{display:block;width:180px;height:180px}
.warn{color:#ff9a9a}
</style><div class="c">
<h1>XE3000 Cloudflare Full-Tunnel</h1>
HTML
[ -n "$MSG" ] && { printf '<div class="%s">' "$CLS"; printf '%s' "$MSG" | esc; printf '</div>'; }

if installed; then
cat <<HTML
<div class="card"><h2>الحالة</h2><table>
<tr><td>المضيفون</td><td>$(printf '%s ' $HOSTLIST)</td></tr>
<tr><td>البروتوكولات</td><td>$PROTOSV</td></tr>
<tr><td>معرّف النفق</td><td class="uid">$TIDV</td></tr>
<tr><td>xray</td><td>$(svc xe3000-cf-xray)</td></tr>
<tr><td>cloudflared</td><td>$(svc xe3000-cf-tunnel)</td></tr>
</table>
<a class="btn" href="?action=start">تشغيل</a>
<a class="btn" href="?action=stop">إيقاف</a>
<a class="btn" href="?action=restart">إعادة تشغيل</a>
</div>

<div class="card"><h2>المستخدمون</h2>
HTML
  if [ -s "$USERS" ]; then
    while IFS="$(printf '\t')" read -r U N P; do
      [ -n "$U" ] || continue
      NE=$(printf '%s' "$N" | esc)
      cat <<HTML
<div class="u">
  <div class="uh"><b>$NE</b>
    <form method="post" onsubmit="return confirm('حذف $NE ؟')">
      <input type="hidden" name="action" value="userdel">
      <input type="hidden" name="uid" value="$U">
      <button class="del">حذف</button></form>
  </div>
  <div class="uid">$U</div>
HTML
      # رابط لكل (مضيف × بروتوكول): يختار العميل ما يعمل في شبكته
      for H in $HOSTLIST; do
        for PR in $PROTOSV; do
          TAG=$N
          [ "$NHOST" -gt 1 ] && TAG="$TAG@${H%%.*}"
          [ "$NPROTO" -gt 1 ] && TAG="$TAG-$PR"
          case "$PR" in
            trojan) LINK="trojan://$P@$H:443?security=tls&sni=$H&type=$NETV&host=$H&path=$ETPATH#$TAG" ;;
            *)      LINK="vless://$U@$H:443?encryption=none&security=tls&sni=$H&type=$NETV&host=$H&path=$EPATH#$TAG" ;;
          esac
          LE=$(printf '%s' "$LINK" | esc)
          TE=$(printf '%s' "$TAG" | esc)
          cat <<HTML
  <div class="lk">
    <input readonly value="$LE">
    <button class="sec" onclick="cp(this)">نسخ $TE</button>
  </div>
  <div class="qr" data-link="$LE"></div>
HTML
        done
      done
      printf '</div>'
    done <"$USERS"
  else
    printf '<p class="warn">لا يوجد مستخدمون.</p>'
  fi
cat <<'HTML'
<form method="post">
  <input type="hidden" name="action" value="useradd">
  <input name="name" placeholder="اسم المستخدم (اختياري)" size="18">
  <button>إضافة مستخدم</button>
</form>
</div>
HTML
else
cat <<'HTML'
<div class="card"><p class="warn">البوابة غير مثبتة.</p>
<p>ملفا الخدمة يُنشآن في الخطوة [4/6]. غيابهما يعني أن التثبيت توقف قبلها.</p>
<p><a class="btn" href="setup.cgi">افتح صفحة الإعداد</a></p>
<p>أو على الراوتر: <code>sh /root/xe3000autouiinput.sh install</code></p></div>
HTML
fi

cat <<HTML
<div class="card"><h2>بيانات Cloudflare المحفوظة</h2><p>$CRED</p>
<form method="post"><input type="hidden" name="action" value="forget">
<input name="confirm" size="10" placeholder="FORGET"> <button class="del">حذف نهائي</button></form>
<p class="uid">الحذف لا يلغي التوكن في حساب Cloudflare.</p></div>
</div>
<script>
HTML
cat <<'JSLIB'
@QRLIB@
function cp(b){
  var i=b.parentNode.querySelector('input'), t=i.value, done=function(){
    var o=b.textContent; b.textContent='تم النسخ ✓';
    setTimeout(function(){b.textContent=o;},1400);
  };
  if(navigator.clipboard&&navigator.clipboard.writeText){
    navigator.clipboard.writeText(t).then(done,function(){i.select();document.execCommand('copy');done();});
  } else { i.select(); i.setSelectionRange(0,99999); document.execCommand('copy'); done(); }
}
(function(){
  var els=document.querySelectorAll('.qr');
  for(var i=0;i<els.length;i++){
    try{ els[i].innerHTML=QR.svg(els[i].getAttribute('data-link'),4,2); }
    catch(e){ els[i].textContent='تعذّر توليد رمز QR: '+e.message; }
  }
})();
JSLIB
printf '</script>'
UICGI
    cat >"$UIROOT/cgi-bin/setup.cgi" <<'UISETUP'
#!/bin/sh
CREDS=/etc/xe3000-cf-fulltunnel-creds
INSTALLER='@SELF@'
LOG=/var/log/xe3000-fulltunnel-setup.log
MSG=; OKMSG=

dec() { # فك ترميز URL
    printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g; s/%\(..\)/\\x\1/g')"
}
field() { printf '%s' "$BODY" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
valid_id()   { case "${1:-}" in ''|*[!A-Za-z0-9_.-]*) return 1;; esac; }
valid_host() { case "${1:-}" in ''|*[!A-Za-z0-9.-]*) return 1;; *.*) return 0;; esac; return 1; }

BODY=
if [ "${REQUEST_METHOD:-GET}" = POST ] && [ -n "${CONTENT_LENGTH:-}" ]; then
    BODY=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
fi

if [ -n "$BODY" ]; then
    H=$(dec "$(field hostname)"); A=$(dec "$(field account)")
    Z=$(dec "$(field zone)");     T=$(dec "$(field token)")
    if ! valid_host "$H"; then MSG="اسم المضيف غير صالح."
    elif ! valid_id "$A";  then MSG="Account ID غير صالح."
    elif ! valid_id "$Z";  then MSG="Zone ID غير صالح."
    elif ! valid_id "$T";  then MSG="التوكن غير صالح أو فيه محرف زائد."
    else
        mkdir -p "$CREDS" && chmod 700 "$CREDS"
        printf '%s' "$H" >"$CREDS/hostname";   printf '%s' "$A" >"$CREDS/account-id"
        printf '%s' "$Z" >"$CREDS/zone-id";    printf '%s' "$T" >"$CREDS/api-token"
        chmod 600 "$CREDS"/hostname "$CREDS"/account-id "$CREDS"/zone-id "$CREDS"/api-token
        if [ -x "$INSTALLER" ] || [ -f "$INSTALLER" ]; then
            : >"$LOG"; chmod 600 "$LOG"
            FULLTUNNEL_RESTORE_UI=1 setsid sh "$INSTALLER" >>"$LOG" 2>&1 &
            OKMSG="حُفظت البيانات وبدأ التثبيت في الخلفية. تابع السجل أدناه."
        else
            OKMSG="حُفظت البيانات. شغّل على الراوتر: sh $INSTALLER"
        fi
    fi
fi

printf 'Content-Type: text/html; charset=utf-8\r\n\r\n'
cat <<HTML
<!doctype html><html lang="ar" dir="rtl"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>إعداد XE3000</title>
<style>
body{font-family:system-ui,sans-serif;background:#111;color:#eee;margin:0;padding:16px}
.c{max-width:560px;margin:auto}h1{font-size:1.25rem}
.card{background:#1e1e1e;border:1px solid #333;border-radius:8px;padding:14px;margin:12px 0}
label{display:block;margin:10px 0 4px}
input{width:100%;box-sizing:border-box;padding:8px;border-radius:4px;border:1px solid #444;background:#111;color:#eee}
button{margin-top:14px;background:#2d6cdf;color:#fff;border:0;padding:10px 18px;border-radius:6px;font-size:1rem}
.err{background:#3a1111;border:1px solid #7a2020;padding:10px;border-radius:6px}
.ok{background:#0f2d16;border:1px solid #2a6b3a;padding:10px;border-radius:6px}
pre{background:#0b0b0b;padding:10px;border-radius:6px;overflow-x:auto;max-height:260px}
small{color:#9a9a9a}
</style><div class="c"><h1>إعداد XE3000 Cloudflare Full-Tunnel</h1>
HTML
[ -n "$MSG" ]   && printf '<div class="err">%s</div>' "$MSG"
[ -n "$OKMSG" ] && printf '<div class="ok">%s</div>' "$OKMSG"
cat <<'HTML'
<form method="post" class="card">
<label>المضيف الكامل<input name="hostname" placeholder="home.example.com" required></label>
<label>Account ID<input name="account" required></label>
<label>Zone ID<input name="zone" required></label>
<label>API Token<input name="token" type="password" required></label>
<small>التوكن يحتاج صلاحيتين فقط: Account · Cloudflare Tunnel · Edit، و Zone · DNS · Edit</small>
<button>احفظ وابدأ التثبيت</button>
</form>
HTML
if [ -s "$LOG" ]; then
    printf '<div class="card"><b>سجل التثبيت</b><pre>'
    tail -40 "$LOG" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
    printf '</pre><a href="">تحديث</a></div>'
fi
printf '<p><a href="control.cgi">لوحة التحكم</a></p></div>'
UISETUP
    sed -i "s#@SELF@#$SELF_ABS#" "$UIROOT/cgi-bin/setup.cgi"
    sed -i "s#@SELF@#$SELF_ABS#" "$UIROOT/cgi-bin/control.cgi"
    write_qrlib
    awk -v f="$UIROOT/qr.js" '/@QRLIB@/{while((getline l < f)>0) print l; next} {print}' \
        "$UIROOT/cgi-bin/control.cgi" >"$UIROOT/cgi-bin/control.cgi.new" &&
        mv "$UIROOT/cgi-bin/control.cgi.new" "$UIROOT/cgi-bin/control.cgi"
    rm -f "$UIROOT/qr.js"
    chmod 755 "$UIROOT/cgi-bin/control.cgi" "$UIROOT/cgi-bin/setup.cgi"
    ok "كُتبت ملفات اللوحة"
}

set_password() { # $1 = enabled flag
    _enabled=${1:-1}
    if [ "$_enabled" = 0 ]; then
        rm -f "$UIROOT/httpd.conf"
        # الملف وحده لا يكفي: الخيار في uci يظل يشير إليه فيطلب uhttpd مصادقة
        uci -q delete uhttpd.xe3000.config 2>/dev/null
        uci commit uhttpd 2>/dev/null
        say "اللوحة تُفتح بلا اسم مستخدم ولا كلمة مرور (شبكة LAN فقط)."
        say "لتفعيل الحماية لاحقًا: sh $SELF auth on"
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

# حماية اللوحة: معطّلة افتراضيًا، وتُفعَّل باسم وكلمة مرور عند الطلب فقط
do_auth() {
    need_root
    case "${1:-status}" in
        off|0)
            set_password 0
            /etc/init.d/uhttpd restart >/dev/null 2>&1 || warn "تعذر إعادة تشغيل uhttpd"
            ok "الحماية معطّلة — اللوحة تُفتح مباشرة من شبكة LAN" ;;
        on|1)
            set_password 1
            configure_uhttpd ;;
        status)
            if [ -s "$UIROOT/httpd.conf" ]; then
                say "الحماية: مفعّلة (المستخدم: $(cut -d: -f2 "$UIROOT/httpd.conf"))"
            else
                say "الحماية: معطّلة — اللوحة بلا اسم مستخدم ولا كلمة مرور"
            fi ;;
        *) die "الاستعمال: auth on|off|status" ;;
    esac
}

# مُثبّتات سابقة تركت نسخة uhttpd تحجز المنفذ، فيفشل ارتباط لوحتنا صامتًا
drop_legacy_uhttpd() {
    _changed=0
    for _sec in $(uci -q show uhttpd 2>/dev/null | sed -n 's/^uhttpd\.\([^.]*\)=uhttpd$/\1/p'); do
        [ "$_sec" = xe3000 ] && continue
        _home=$(uci -q get "uhttpd.$_sec.home" 2>/dev/null)
        _bind="$(uci -q get "uhttpd.$_sec.listen_https" 2>/dev/null) $(uci -q get "uhttpd.$_sec.listen_http" 2>/dev/null)"
        case "$_home" in
            *xe3000*)
                uci -q delete "uhttpd.$_sec"
                warn "أُزيلت نسخة uhttpd من مُثبّت سابق: $_sec ($_home)"
                _changed=1; continue ;;
        esac
        case "$_bind" in
            *":$UI_PORT"*)
                uci -q delete "uhttpd.$_sec"
                warn "أُزيلت نسخة uhttpd كانت تحجز المنفذ $UI_PORT: $_sec"
                _changed=1 ;;
        esac
    done
    [ "$_changed" = 1 ] && uci commit uhttpd
    rm -rf /www/xe3000-fulltunnel-bootstrap 2>/dev/null
    return 0
}

configure_uhttpd() {
    _ip=$(lan_ip)
    case "$_ip" in
        0.0.0.0|::|"") die "رفض الربط على $_ip — اللوحة محلية فقط." ;;
    esac
    [ -f /etc/uhttpd.crt ] && [ -f /etc/uhttpd.key ] || \
        die "شهادة /etc/uhttpd.crt و /etc/uhttpd.key مفقودة. فعّل HTTPS من واجهة GL.iNet."

    drop_legacy_uhttpd
    UI_PORT_S=${FULLTUNNEL_UI_PORT_HTTPS:-$UI_PORT_S}
    uci -q delete uhttpd.xe3000
    uci set uhttpd.xe3000=uhttpd
    uci set uhttpd.xe3000.home="$UIROOT"
    # uhttpd لا يجمع HTTP وHTTPS على منفذ واحد: 9000 مدخل HTTP يحوّل إلى HTTPS
    uci add_list uhttpd.xe3000.listen_http="$_ip:$UI_PORT"
    uci add_list uhttpd.xe3000.listen_https="$_ip:$UI_PORT_S"
    uci set uhttpd.xe3000.redirect_https=1
    uci set uhttpd.xe3000.cert=/etc/uhttpd.crt
    uci set uhttpd.xe3000.key=/etc/uhttpd.key
    uci set uhttpd.xe3000.cgi_prefix=/cgi-bin
    uci set uhttpd.xe3000.rfc1918_filter=1
    uci add_list uhttpd.xe3000.index_page=index.html
    if [ -s "$UIROOT/httpd.conf" ]; then
        uci set uhttpd.xe3000.config="$UIROOT/httpd.conf"
    else
        uci -q delete uhttpd.xe3000.config
    fi
    uci commit uhttpd

    # فتح المنفذ على شبكة LAN فقط — بعض صور GL.iNet ترفض المدخلات غير المصرّح بها
    # قاعدة لكل منفذ: fw3 لا يضمن قائمة منافذ في dest_port
    for _p in "xe3000_panel:$UI_PORT" "xe3000_panel_s:$UI_PORT_S"; do
        _sec=${_p%%:*}; _pt=${_p##*:}
        uci -q delete "firewall.$_sec"
        uci set "firewall.$_sec=rule"
        uci set "firewall.$_sec.name=xe3000-panel-$_pt"
        uci set "firewall.$_sec.src=lan"
        uci set "firewall.$_sec.proto=tcp"
        uci set "firewall.$_sec.dest_port=$_pt"
        uci set "firewall.$_sec.target=ACCEPT"
    done
    uci commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1 || warn "تعذر إعادة تحميل الجدار الناري"

    # قسم جديد لا يلتقطه reload دائمًا — أعد التشغيل
    /etc/init.d/uhttpd restart >/dev/null 2>&1 || die "تعذر إعادة تشغيل uhttpd"
    sleep 1
    if netstat -ltn 2>/dev/null | grep -q "$_ip:$UI_PORT_S "; then
        ok "اللوحة على https://$_ip:$UI_PORT_S/cgi-bin/control.cgi"
        ok "و http://$_ip:$UI_PORT/ يحوّل إليها تلقائيًا"
    else
        warn "uhttpd أُعيد تشغيله لكن المنفذ $UI_PORT لا يستمع — شغّل: sh $SELF diagnose"
    fi
}

install_ui() {
    write_ui_files
    set_password "${FULLTUNNEL_AUTH_ENABLED:-0}"
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
    install_launchers

    say ""
    ok "اكتمل التثبيت."
    show_client
    [ -n "${AUTO_ENV_FILE:-}" ] && { rm -f "$AUTO_ENV_FILE"; ok "حُذف ملف الإعداد $AUTO_ENV_FILE بعد النجاح."; }
    return 0
}

show_client() {
    say ""
    say "بيانات العميل (عبر Cloudflare، المنفذ 443، TLS مُفعّل):"
    hosts_init
    for _ch in $(hosts_names); do say "  المضيف  : $_ch"; done
    for _cp in $(protos_enabled); do
        say "  $_cp: المسار $(proto_path "$_cp")   |   الشبكة: ${XRAY_NET:-ws}"
    done
    say ""
    say "روابط الاشتراك الكاملة:"
    # نفس مولّد links: رابط لكل (مستخدم × مضيف × بروتوكول) وبكلمة مرور trojan
    users_links
    say ""
    say "لرمز QR ونسخ الروابط بضغطة: https://$(lan_ip):$UI_PORT/cgi-bin/control.cgi"
}

do_status() {
    if ! load_settings; then
        err "لا يوجد تثبيت محلي. شغّل install أولًا."
        creds_status
        return 1
    fi
    say "الإصدار    : $VERSION"
    say "المضيفون   : $(hosts_names | tr '\n' ' ')"
    say "البروتوكول : $(protos_enabled)"
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
    say "اللوحة     : https://$(lan_ip):$UI_PORT_S/  (مدخل http://$(lan_ip):$UI_PORT/)"
    creds_status
}

do_diagnose() {
    say "--- uhttpd ---"
    /etc/init.d/uhttpd status 2>&1 | head -5
    uci -q show uhttpd.xe3000 || say "لا يوجد قسم uhttpd.xe3000"
    say "--- كل نسخ uhttpd ---"
    for _s in $(uci -q show uhttpd 2>/dev/null | sed -n 's/^uhttpd\.\([^.]*\)=uhttpd$/\1/p'); do
        say "  $_s  home=$(uci -q get "uhttpd.$_s.home")  https=$(uci -q get "uhttpd.$_s.listen_https")"
    done
    say "--- المنفذ $UI_PORT ---"
    netstat -ltn 2>/dev/null | grep -E ":($UI_PORT|$UI_PORT_S) " || say "المنفذ $UI_PORT لا يستمع"
    say "--- عملية uhttpd ---"
    ps w 2>/dev/null | grep -v grep | grep uhttpd || say "لا توجد عملية uhttpd"
    say "--- الجدار الناري ---"
    uci -q show firewall.xe3000_panel || say "لا توجد قاعدة xe3000_panel — شغّل repair-ui"
    say "--- عنوان LAN ---"
    say "المتوقع: $(lan_ip):$UI_PORT"
    say "--- الشهادة ---"
    [ -f /etc/uhttpd.crt ] && say "/etc/uhttpd.crt موجودة" || say "/etc/uhttpd.crt مفقودة"
    say "--- الأوامر ---"
    for c in curl jsonfilter xray cloudflared openssl uci; do
        have "$c" && say "$c: $(command -v $c)" || say "$c: مفقود"
    done
    net_check
}

# فشل DNS هو أشيع سبب لسقوط [3/6] بعد أن تصبح البيانات سليمة
net_check() {
    say "--- الشبكة ---"
    if ping -c2 -W3 1.1.1.1 >/dev/null 2>&1; then
        ok "اتصال IP يعمل (1.1.1.1)"
    else
        err "لا اتصال IP — راجع WAN قبل أي شيء آخر."
        return 1
    fi

    say "resolv.conf: $(sed -n 's/^nameserver //p' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"

    if nslookup api.cloudflare.com >/dev/null 2>&1; then
        ok "DNS يحوّل api.cloudflare.com"
    elif nslookup api.cloudflare.com 1.1.1.1 >/dev/null 2>&1; then
        err "المُحلِّل المحلي معطّل: 1.1.1.1 يحوّل الاسم لكن الراوتر لا يفعل."
        say "    العلاج:"
        say "      uci set network.wan.peerdns='0'"
        say "      uci add_list network.wan.dns='1.1.1.1'"
        say "      uci add_list network.wan.dns='8.8.8.8'"
        say "      uci commit network && /etc/init.d/network restart"
        return 1
    else
        err "لا DNS إطلاقًا — حتى الاستعلام المباشر من 1.1.1.1 يفشل."
        # ping ينجح وDNS يفشل = الحزم تُوجَّه لا تُحجب. سياسة VPN في GL.iNet
        # تدفع ما ينشئه الراوتر إلى tun0، فإن كان النفق ساقطًا ضاع كل شيء.
        if ip rule 2>/dev/null | grep -q 'blackhole' || ip link show tun0 >/dev/null 2>&1; then
            say "    على الجهاز سياسة VPN (قاعدة blackhole أو واجهة tun0):"
            say "    الأرجح أن استعلاماتك تُدفع إلى نفق ساقط. العلاج:"
            say "      sh $SELF vpn-bypass auto"
        fi
        say "    وتحقق من dnsmasq: /etc/init.d/dnsmasq status ثم logread -e dnsmasq"
        return 1
    fi

    if curl -sS --max-time 15 -o /dev/null -w '' https://api.cloudflare.com/client/v4/ 2>/dev/null; then
        ok "الوصول إلى api.cloudflare.com يعمل"
    else
        warn "DNS يعمل لكن الاتصال بـ api.cloudflare.com فشل — تحقق من ساعة الراوتر (TLS): date"
    fi
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
    drop_legacy_uhttpd
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
    drop_legacy_uhttpd
    uci -q delete uhttpd.xe3000 && uci commit uhttpd
    uci -q delete firewall.xe3000_panel
    uci -q delete firewall.xe3000_panel_s
    uci commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1
    /etc/init.d/uhttpd reload >/dev/null 2>&1
    rm -rf "$BASE"
    for _l in /usr/bin/xe3000 /usr/bin/menu; do
        grep -q xe3000autouiinput "$_l" 2>/dev/null && rm -f "$_l"
    done
    ok "أُزيلت البوابة. البيانات المحفوظة في $CREDS لم تُمس (احذفها بـ forget-creds)."
}

do_repair_ui() {
    need_root
    write_ui_files          # دائمًا: الترقية يجب أن تحدّث الصفحات
    configure_uhttpd
}

do_bootstrap() {
    need_root
    write_ui_files
    set_password "${FULLTUNNEL_AUTH_ENABLED:-0}"
    configure_uhttpd
    ok "افتح https://$(lan_ip):$UI_PORT_S/cgi-bin/setup.cgi وأدخل بيانات Cloudflare."
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
    if has_tty; then
        say "لا توجد بيانات محفوظة — تثبيت تفاعلي."
        do_install
        return $?
    fi
    say "لا توجد بيانات محفوظة وبلا طرفية — فتح صفحة الإعداد."
    do_bootstrap
}

# تبديل التوكن وحده — أشيع إصلاح بعد "Invalid API Token"
do_set_token() {
    need_root
    need_cmd curl; need_cmd jsonfilter
    creds_saved || die "لا توجد بيانات محفوظة. شغّل install أولًا."
    load_creds
    _t=${FULLTUNNEL_API_TOKEN:-}
    [ -n "$_t" ] || read_tty "API Token الجديد: " _t 1
    valid_id "$_t" || die "التوكن غير صالح أو فيه محرف زائد."
    [ "$_t" = "$CF_TOKEN" ] && warn "التوكن الجديد مطابق للقديم المرفوض."
    CF_TOKEN=$_t
    printf '%s' "$CF_TOKEN" >"$CREDS/api-token"
    chmod 600 "$CREDS/api-token"
    ok "حُدِّث التوكن. المضيف والمعرّفان كما هما."
    say ""
    if preflight_cloudflare; then
        say ""
        ok "الفحوصات الأربعة نجحت — أكمل التثبيت: sh $SELF"
        return 0
    fi
    return 1
}

# ----------------------------------------------------------------- قائمة SSH
menu_pause() { read_tty "اضغط Enter للمتابعة… " _x; }

do_menu() {
    has_tty || die "الأمر menu تفاعلي — شغّله من جلسة SSH."
    while : ; do
        printf '\n'
        say "══════ XE3000 Full-Tunnel ══════"
        if load_settings 2>/dev/null; then
            say "  المضيفون: $(hosts_names | tr '\n' ' ')   المستخدمون: $(users_count)   البروتوكول: $(protos_enabled)"
            say "  xray: $(/etc/init.d/xe3000-cf-xray running >/dev/null 2>&1 && echo يعمل || echo متوقف)   cloudflared: $(/etc/init.d/xe3000-cf-tunnel running >/dev/null 2>&1 && echo يعمل || echo متوقف)"
        else
            say "  غير مثبت"
        fi
        say "────────────────────────────────"
        say "  1) الحالة            2) المستخدمون"
        say "  3) الروابط           4) تشغيل/إيقاف/إعادة"
        say "  5) تشخيص             6) تبديل التوكن"
        say "  7) حماية اللوحة      8) لوحة 9000"
        say "  9) تثبيت/إكمال      10) المضيفون والبروتوكولات"
        say "  0) خروج"
        read_tty "الاختيار: " _c
        case "$_c" in
            1) do_status ;;
            2) menu_users ;;
            3) users_links ;;
            4) menu_services ;;
            5) do_diagnose; say ""; do_selftest || true ;;
            6) do_set_token || true ;;
            7) say "  1) بلا اسم مستخدم وكلمة مرور   2) تفعيل الحماية"
               read_tty "الاختيار: " _a
               case "$_a" in
                   1) do_auth off ;;
                   2) do_auth on ;;
                   *) : ;;
               esac ;;
            8) say "https://$(lan_ip):$UI_PORT_S/cgi-bin/control.cgi  (أو http://$(lan_ip):$UI_PORT/)" ;;
            9) do_auto_self || true ;;
            10) menu_hosts ;;
            0|q|Q) return 0 ;;
            *) warn "اختيار غير معروف." ;;
        esac
        menu_pause
    done
}

menu_hosts() {
    say "  1) المضيفون   2) إضافة مضيف   3) حذف مضيف   4) البروتوكولات   0) رجوع"
    read_tty "الاختيار: " _c
    case "$_c" in
        1) hosts_list ;;
        2) read_tty "المضيف الجديد: " _n; read_tty "Zone ID (اتركه فارغًا للاستدلال): " _z
           do_host_add "$_n" "$_z" ;;
        3) hosts_list; read_tty "المضيف المراد حذفه: " _n; do_host_del "$_n" ;;
        4) do_proto_list
           read_tty "بروتوكول للتبديل (vless/trojan، فارغ للرجوع): " _p
           [ -n "$_p" ] || return 0
           if proto_on "$_p"; then do_proto_set off "$_p"; else do_proto_set on "$_p"; fi ;;
        *) return 0 ;;
    esac
}

menu_users() {
    while : ; do
        printf '\n'
        say "── المستخدمون ──"
        users_list
        say "  a) إضافة   d) حذف   r) تطبيق وإعادة تشغيل   b) رجوع"
        read_tty "الاختيار: " _c
        case "$_c" in
            a|A) read_tty "الاسم (فارغ = تلقائي): " _n
                 user_add "$_n" >/dev/null && users_apply ;;
            d|D) read_tty "الاسم أو المعرّف للحذف: " _k
                 [ "$(users_count)" -gt 1 ] || { warn "لا يمكن حذف آخر مستخدم."; continue; }
                 user_del "$_k" && users_apply ;;
            r|R) users_apply ;;
            b|B|'') return 0 ;;
            *) warn "اختيار غير معروف." ;;
        esac
    done
}

menu_services() {
    say "  1) تشغيل   2) إيقاف   3) إعادة تشغيل"
    read_tty "الاختيار: " _c
    case "$_c" in
        1) _a=start ;; 2) _a=stop ;; 3) _a=restart ;; *) return 0 ;;
    esac
    for _s in xe3000-cf-xray xe3000-cf-tunnel; do
        [ -x /etc/init.d/$_s ] && /etc/init.d/$_s "$_a" >/dev/null 2>&1 && ok "$_s: $_a" || warn "$_s: تعذر $_a"
    done
}

# اختصارات الصدفة: xe3000 و menu
install_launchers() {
    [ -f "$SELF_ABS" ] || return 0
    if [ ! -e /usr/bin/xe3000 ] || grep -q xe3000autouiinput /usr/bin/xe3000 2>/dev/null; then
        printf '#!/bin/sh\nexec sh %s "$@"\n' "$SELF_ABS" >/usr/bin/xe3000
        chmod 755 /usr/bin/xe3000
    fi
    if [ ! -e /usr/bin/menu ] || grep -q xe3000autouiinput /usr/bin/menu 2>/dev/null; then
        printf '#!/bin/sh\nexec sh %s menu "$@"\n' "$SELF_ABS" >/usr/bin/menu
        chmod 755 /usr/bin/menu
        ok "الأمران xe3000 و menu متاحان من أي مسار"
    else
        warn "/usr/bin/menu موجود لجهة أخرى — استخدم الأمر xe3000 menu"
    fi
}

# ----------------------------------------------------------------- فحص السلسلة
# يتتبع المسار كاملًا: xray ← cloudflared ← حافة Cloudflare ← DNS ← الطلب العام
# سطر حالة مصافحة WebSocket — الترقية الناجحة تُبقي الاتصال مفتوحًا
# سطر الحالة من curl. لا يُمزج stderr في الأنبوب: المزج يجعل الترتيب غير محدد
# فيبتلع سطر 101 أحيانًا. نفصل التيارين ونقع على خطأ curl فقط عند غياب الرد.
_probe() { # $1 = رابط، بقية الوسائط ترويسات
    _u=$1; shift
    _us=
    case "$_u" in
        http://localhost*) is_sock && _us="--unix-socket ${PROBE_SOCK:-$XRAY_LISTEN}" ;;
    esac
    _pe=/tmp/.xe3000probe.$$
    _po=$(curl -sSi --noproxy '*' $_us --max-time 6 --http1.1 "$@" "$_u" 2>"$_pe")
    _pl=$(printf '%s' "$_po" | head -n1 | tr -d '\r')
    [ -n "$_pl" ] || _pl=$(head -n1 "$_pe" 2>/dev/null | tr -d '\r')
    case "$_pl" in
        *"(48)"*) _pl="curl: لا يدعم --unix-socket في هذا البناء" ;;
    esac
    rm -f "$_pe"
    printf '%s' "$_pl"
}

# مقبس/منفذ كل بروتوكول على حدة — لكل مدخل أصله الخاص
proto_sock() { if [ "${1:-vless}" = trojan ]; then trojan_listen
               else printf '%s' "$XRAY_LISTEN"; fi; }

local_url() { # $1 = البروتوكول (افتراضيًا vless)
    _lu=${1:-vless}
    if is_sock; then printf 'http://localhost%s' "$(proto_path "$_lu")"
    elif [ "$_lu" = trojan ]; then
        printf 'http://%s:%s%s' "$XRAY_LISTEN" "$(trojan_port)" "$(proto_path trojan)"
    else printf 'http://%s:%s%s' "$XRAY_LISTEN" "$XRAY_PORT" "$(proto_path "$_lu")"; fi
}

ws_probe() {
    _probe "$1" \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
        -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA=='
}

# GET عادي: خادم ws في Xray يردّ 400، ومسار خاطئ 404 — دليل حياة بلا تعليق
# الاتصال الذي تسببه ترقية ناجحة.
http_probe() { _probe "$1"; }

# تسريع NAT في MediaTek يتلف عناوين الحزم المحلية: SYN-ACK يخرج بعنوان 0.0.0.0
# فيردّ العميل RST وتنتهي المهلة. المنفذ يبدو مستمعًا والجدار الناري نظيفًا.
check_offload() {
    _h1=$(uci -q get mtkhnat.global.enable)
    _h2=$(uci -q get firewall.@defaults[0].flow_offloading_hw)
    _h3=$(uci -q get firewall.@defaults[0].flow_offloading)
    if [ "$_h1" = 1 ] || [ "$_h2" = 1 ] || [ "$_h3" = 1 ]; then
        err "    تسريع NAT مفعّل (mtkhnat=$_h1 hw=$_h2 sw=$_h3) — سبب معروف لهذا العطل."
        say "        يتلف عناوين الحزم المحلية فلا تكتمل المصافحة. للتعطيل:"
        say "          uci set mtkhnat.global.enable='0'"
        say "          uci -q set firewall.@defaults[0].flow_offloading='0'"
        say "          uci -q set firewall.@defaults[0].flow_offloading_hw='0'"
        say "          uci commit mtkhnat; uci commit firewall; /etc/init.d/firewall restart"
        say "        ثم أعد المحاولة، وإن بقي العطل أعد تشغيل الراوتر."
    fi
}

do_selftest() {
    load_settings || die "لا يوجد تثبيت محلي. شغّل install أولًا."
    need_cmd curl
    _fail=0; _public_ok=0

    say "── 1) الخدمتان ──"
    for _s in xe3000-cf-xray xe3000-cf-tunnel; do
        if [ -x /etc/init.d/$_s ] && /etc/init.d/$_s running >/dev/null 2>&1; then
            svc_boot_enabled "$_s" && ok "$_s يعمل" ||
                { ok "$_s يعمل"; warn "  لكنه لن يبدأ بعد الإقلاع: /etc/init.d/$_s enable"; }
        else
            err "$_s متوقف"; _fail=1
            if [ -x /etc/init.d/$_s ] && ! svc_boot_enabled "$_s"; then
                say "    ولا رابط إقلاع في /etc/rc.d — لهذا لم يبدأ وحده:"
                say "      /etc/init.d/$_s enable && /etc/init.d/$_s start"
            elif [ "$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 9999)" -lt 240 ]; then
                say "    الجهاز أقلع قبل قليل — cloudflared ينتظر جهوزية DNS ثم"
                say "    يسجّل وصلاته تباعًا. انتظر دقيقتين وأعد الفحص."
            fi
        fi
    done

    say ""
    say "── 2) xray يستمع محليًا ──"
    if is_sock; then
        if [ -S "$XRAY_LISTEN" ]; then
            ok "مقبس Unix موجود: $XRAY_LISTEN"
        else
            err "مقبس Unix مفقود: $XRAY_LISTEN — xray لم يبدأ."; _fail=1
        fi
    elif netstat -ltn 2>/dev/null | grep -q "$XRAY_LISTEN:$XRAY_PORT "; then
        ok "المنفذ $XRAY_PORT مفتوح على $XRAY_LISTEN"
    else
        err "المنفذ $XRAY_PORT غير مفتوح — xray لم يبدأ أو الإعداد خاطئ."
        say "    logread | grep xray | tail -20"
        _fail=1
    fi

    say ""
    say "── 2ب) الإعداد الفعلي لـ xray ──"
    _cfg=$XRAY_DIR/config.json
    if [ -s "$_cfg" ]; then
        _j=$(cat "$_cfg")
        say "    البروتوكولات في settings.env: $(protos_enabled)"
        _ix=0
        for _sp in $(protos_enabled); do
            _cpr=$(jf "$_j" "@.inbounds[$_ix].protocol")
            _cl=$(jf "$_j" "@.inbounds[$_ix].listen")
            _cp=$(jf "$_j" "@.inbounds[$_ix].port")
            _cn=$(jf "$_j" "@.inbounds[$_ix].streamSettings.network")
            _cw=$(jf "$_j" "@.inbounds[$_ix].streamSettings.wsSettings.path")
            _cw=${_cw:-$(jf "$_j" "@.inbounds[$_ix].streamSettings.xhttpSettings.path")}
            say "    [$_ix] protocol=$_cpr  listen=$_cl  port=$_cp  network=$_cn"
            say "         path في config.json : $_cw"
            say "         path في settings.env: $(proto_path "$_sp")"
            [ "$_cpr" = "$_sp" ] || {
                err "المدخل $_ix بروتوكوله '$_cpr' والمتوقع '$_sp' — أعد التطبيق: sh $SELF users-apply"
                _fail=1; }
            case "$_cn" in ws|xhttp) : ;; *) err "network غير مدعوم: $_cn"; _fail=1 ;; esac
            [ "$_cw" = "$(proto_path "$_sp")" ] || {
                err "مسار $_sp غير متطابق — أعد التطبيق: sh $SELF users-apply"; _fail=1; }
            if ! is_sock; then
                if [ "$_sp" = trojan ]; then _xp=$(trojan_port); else _xp=$XRAY_PORT; fi
                [ "$_cp" = "$_xp" ] || { err "منفذ $_sp غير متطابق ($_cp ≠ $_xp)."; _fail=1; }
            fi
            _ix=$((_ix+1))
        done
    else
        err "$_cfg مفقود أو فارغ."; _fail=1
    fi

    # links يطبع من users.tsv بينما xray يعمل بـ config.json. تفاوتهما يُظهر
    # رابطًا يبدو سليمًا ويرفضه الخادم بـ "invalid request user id".
    # grep -o لا sed: كل العملاء على سطر واحد في config.json، و.* الجَشِعة
    # كانت تُرجع آخر معرّف في السطر وحده فيبدو التطابق فاشلًا بلا سبب.
    if [ -f "$XRAY_DIR/config.json" ] && [ -s "$USERS" ]; then
        _match=1
        if proto_on vless; then
            _uids=$(awk -F'\t' 'NF{print $1}' "$USERS" | sort | tr '\n' ' ')
            _cids=$(grep -o '"id": "[^"]*"' "$XRAY_DIR/config.json" |
                    sed 's/.*"id": "//; s/"$//' | sort | tr '\n' ' ')
            [ "$_uids" = "$_cids" ] || { err "معرّفات vless لا تطابق قائمة المستخدمين."; _match=0; }
        fi
        if proto_on trojan; then
            _upw=$(awk -F'\t' 'NF{print ($3!=""?$3:$1)}' "$USERS" | sort | tr '\n' ' ')
            _cpw=$(grep -o '"password": "[^"]*"' "$XRAY_DIR/config.json" |
                   sed 's/.*"password": "//; s/"$//' | sort | tr '\n' ' ')
            [ "$_upw" = "$_cpw" ] || { err "كلمات مرور trojan لا تطابق قائمة المستخدمين."; _match=0; }
        fi
        if [ "$_match" = 1 ]; then
            ok "قائمة المستخدمين وبيانات xray متطابقة ($(users_count))"
        else
            _fail=1
            say "    xray سيردّ: invalid request user id"
            say "    أصلحه بـ: sh $SELF users-apply"
        fi
    fi

    say ""
    say "── 2ج) وصول TCP إلى المنفذ المحلي ──"
    # فشل بمهلة على منفذ مستمع = إسقاط حزم، لا رفض اتصال
    # nc في BusyBox لا يدعم -z ولا -w، فاستعماله هنا يعطي فشلًا كاذبًا.
    # مرحلة الاتصال في curl هي القياس الصحيح: أي ردّ HTTP أو رفض = وصلنا.
    if is_sock; then
        _t=$(curl -sS --noproxy '*' --unix-socket "$XRAY_LISTEN" --connect-timeout 5 \
             -o /dev/null -w 'code=%{http_code}' "http://localhost/" 2>&1)
        case "$_t" in *"(48)"*) _t="skip" ;; esac
    else
        _t=$(curl -sS --noproxy '*' --connect-timeout 5 -o /dev/null \
             -w 'connect=%{time_connect} code=%{http_code}' \
             "http://$XRAY_LISTEN:$XRAY_PORT/" 2>&1)
    fi
    case "$_t" in
        *"Connection refused"*|*"No such file"*)
            err "الاتصال مرفوض على $XRAY_LISTEN — لا شيء يستمع فعلًا."
            _lo=1; _fail=1 ;;
        *"timed out"*|*"Timeout"*|*"Connection timeout"*)
            err "انتهت مهلة الاتصال بـ $XRAY_LISTEN:$XRAY_PORT رغم أن المنفذ مستمع."
            check_offload
            say "    SYN يخرج ولا تكتمل المصافحة — المقبس يستمع لكن الردّ لا يصل سليمًا."
            mptcp_note
            grep -q 'multipathtcp' /etc/init.d/xe3000-cf-xray 2>/dev/null ||
                say "    ملف الخدمة قديم بلا GODEBUG — شغّل: sh $SELF reinstall-services"
            # ضابط: خادم الويب المحلي يفصل بين عطل عام في loopback وعطل في xray
            _ctl=$(curl -sS --noproxy '*' --connect-timeout 4 -o /dev/null \
                   -w '%{http_code}' "http://127.0.0.1:80/" 2>&1)
            case "$_ctl" in
                [1-5][0-9][0-9])
                    err "    الضابط: 127.0.0.1:80 ردّ $_ctl — loopback سليم، العطل في xray وحده."
                    say "        جرّب: /etc/init.d/xe3000-cf-xray restart" ;;
                *)  warn "    الضابط: 127.0.0.1:80 فشل أيضًا ($_ctl) — loopback معطوب لكل الخدمات." ;;
            esac
            say "    ── طابور الاستماع ──"
            netstat -ant 2>/dev/null | grep ":$XRAY_PORT " | head -5
            netstat -s 2>/dev/null | grep -iE 'listen|overflow' | head -4
            _lo=1; _fail=1 ;;
        skip)
            warn "curl هنا بلا دعم --unix-socket — يُتخطّى الفحص المحلي."
            say  "    الحلقة 6 عبر Cloudflare هي الحكم." ;;
        curl:*)
            err "تعذر الاتصال: $_t"; _lo=1; _fail=1 ;;
        *)
            ok "مصافحة TCP اكتملت ($_t)" ;;
    esac
    if [ "${FULLTUNNEL_SHOW_RULES:-0}" = 1 ]; then
        # EPERM على حزمة محلية = إسقاط في LOCAL_OUT، فالدليل في سلسلة OUTPUT
        say "    ── conntrack ──"
        _cc=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
        _cm=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
        if [ -n "$_cc" ] && [ -n "$_cm" ]; then
            say "    مستخدم $_cc من $_cm"
            [ "$_cc" -ge $(( _cm - _cm / 10 )) ] && \
                err "    جدول conntrack شبه ممتلئ — يُسقط الاتصالات الجديدة بـ EPERM."
        fi
        dmesg 2>/dev/null | grep -iE 'conntrack|table full' | tail -5

        say "    ── INPUT/OUTPUT (filter) مع العدّادات بعد محاولة اتصال ──"
        iptables -Z OUTPUT >/dev/null 2>&1
        iptables -Z INPUT  >/dev/null 2>&1
        curl -sS --noproxy '*' --connect-timeout 5 -o /dev/null \
             "http://$XRAY_LISTEN:$XRAY_PORT/" >/dev/null 2>&1 || true
        iptables -L INPUT  -n -v --line-numbers 2>/dev/null | head -18 || say "    (iptables غير متاح)"
        iptables -L OUTPUT -n -v --line-numbers 2>/dev/null | head -18
        say "    ── OUTPUT (mangle) ──"
        iptables -t mangle -L OUTPUT -n -v --line-numbers 2>/dev/null | head -20
        say "    ── mangle: السلاسل الفرعية بعدّاداتها ──"
        for _ch in $(iptables -t mangle -S 2>/dev/null | sed -n 's/^-N //p'); do
            iptables -t mangle -L "$_ch" -n -v --line-numbers 2>/dev/null | head -12
        done
        say "    ── raw/nat OUTPUT ──"
        iptables -t raw -L OUTPUT -n -v --line-numbers 2>/dev/null | head -8
        iptables -t nat -L OUTPUT -n -v --line-numbers 2>/dev/null | head -12
        say "    ── سلاسل السياسة ──"
        iptables -S 2>/dev/null | grep -E '^-A (OUTPUT|policy_|.*_output)' | head -25
        say "    ── قواعد تخص المنفذ $XRAY_PORT ──"
        { nft list ruleset 2>/dev/null | grep -iE "$XRAY_PORT|tproxy|redirect"
          iptables-save 2>/dev/null | grep -iE "$XRAY_PORT|TPROXY|REDIRECT"
        } | head -20 || say "    (لا قواعد مطابقة)"
        say "    ── قبول loopback ──"
        { nft list ruleset 2>/dev/null | grep -A2 'iif "lo"'
          iptables -S INPUT 2>/dev/null | grep -i ' lo '
        } | head -10 || say "    (لا قاعدة صريحة لقبول lo)"
        say "    ── وكيل في البيئة (الأسماء فقط، لا القيم) ──"
        env | grep -i proxy | cut -d= -f1 || say "    (لا متغيّرات وكيل)"
    fi

    say ""
    say "── 3أ) هل يتكلم xray بروتوكول HTTP على المنفذ؟ ──"
    for _sp in $(protos_enabled); do
    PROBE_SOCK=$(proto_sock "$_sp")
    say "  [$_sp] $(local_url "$_sp")"
    _h=$(http_probe "$(local_url "$_sp")")
    case "$_h" in
        *400*)  ok "ردّ 400 على GET عادي — خادم ws حيّ (هذا هو المتوقع)" ;;
        *404*)  warn "ردّ 404 — الخادم حيّ لكن المسار لا يطابق" ;;
        curl:*) if is_sock; then
                    warn "الفحص المحلي غير متاح: $_h"
                    say  "    الحلقة 6 هي الحكم في وضع مقبس Unix."
                else
                    err "curl لم يصل إلى $XRAY_LISTEN:$XRAY_PORT — $_h"
                    _fail=1
                fi
                case "$_h" in
                  *"Connection timed out"*)
                      say "    مهلة على منفذ مستمع = المقبس لا يردّ بـ SYN-ACK." ;;
                  *"Connection refused"*)
                      say "    رفض اتصال = لا شيء يستمع فعلًا على هذا المنفذ." ;;
                esac
                ;;
        '')     err "لا مخرجات من curl على المنفذ المحلي."; _fail=1 ;;
        *)      say "    ردّ: $_h" ;;
    esac
    done
    PROBE_SOCK=

    say ""
    say "── 3ب) مصافحة WebSocket محليًا ──"
    # ترقية ناجحة تُبقي الاتصال مفتوحًا، فلا يصلح %{http_code}: نقرأ سطر الحالة نفسه.
    for _sp in $(protos_enabled); do
    PROBE_SOCK=$(proto_sock "$_sp")
    _l=$(ws_probe "$(local_url "$_sp")")
    case "$_l" in
        *101*) ok "[$_sp] xray قبل الترقية على المسار $(proto_path "$_sp")" ;;
        curl:*) if is_sock; then warn "الفحص المحلي غير متاح: $_l"
                else err "curl لم يصل إلى xray — $_l"; _fail=1; fi ;;
        '')    err "لا سطر استجابة من xray على $XRAY_WSPATH"
               say "    (اتصال مقبول ثم مغلق بلا ردّ HTTP)"
               say ""
               say "    ── من يستمع على المنفذ ──"
               netstat -ltnp 2>/dev/null | grep ":$XRAY_PORT " || say "    (netstat بلا -p على هذا النظام)"
               say "    ── آخر سطور xray ──"
               logread 2>/dev/null | grep -i xray | tail -15 || say "    (لا سجل)"
               _fail=1 ;;
        *)     err "xray ردّ: $_l (المتوقع 101)"; _fail=1 ;;
    esac
    done
    PROBE_SOCK=

    say ""
    say "── 4) اتصالات النفق لدى Cloudflare ──"
    if creds_saved && [ -n "$TUNNEL_ID" ]; then
        load_creds
        _r=$(cf GET "/accounts/$CF_ACCOUNT/cfd_tunnel/$TUNNEL_ID")
        if cf_success "$_r"; then
            _st=$(jf "$_r" '@.result.status')
            case "$_st" in
                healthy) ok "حالة النفق: healthy" ;;
                degraded)
                    # الحالة لدى Cloudflare تتأخر وتحتسب موصّلات ماتت عند إعادة
                    # التشغيل. عدّ الوصلات المسجّلة محليًا منذ آخر إقلاع أصدق.
                    _rc=$(logread -e cloudflared 2>/dev/null |
                          grep -c 'Registered tunnel connection')
                    if [ "${_rc:-0}" -ge 4 ]; then
                        ok "حالة النفق لدى Cloudflare: degraded، لكن $_rc وصلات مسجّلة محليًا"
                        say "    الحالة لديهم تتأخر بعد إعادة التشغيل — الحلقة 6 هي الفصل."
                    else
                        warn "حالة النفق: degraded — وصلات مسجّلة محليًا: ${_rc:-0} من 4"
                        say "    جرّب ناقلًا آخر للحافة: sh $SELF set-edge-protocol quic"
                    fi ;;
                down|inactive|'') err "حالة النفق: ${_st:-غير معروفة} — cloudflared لا يصل إلى الحافة."
                                  say "    logread | grep cloudflared | tail -30"; _fail=1 ;;
                *) say "    حالة النفق: $_st" ;;
            esac
        else
            warn "تعذر الاستعلام عن النفق: $(cf_errors "$_r")"
        fi
    else
        warn "لا بيانات محفوظة — تُخطّى هذه الخطوة."
    fi

    say ""
    say "── 5) DNS للمضيفين ──"
    _sh_all=$(hosts_names)
    [ -n "$_sh_all" ] || _sh_all=$CF_HOSTNAME
    for _sh in $_sh_all; do
        if nslookup "$_sh" >/dev/null 2>&1; then
            ok "$_sh يُحوّل"
        else
            err "$_sh لا يُحوّل — سجل CNAME مفقود أو لم ينتشر بعد."
            _fail=1
        fi
    done

    say ""
    say "── 6) الطلب العام عبر Cloudflare ──"
    for _sh in $_sh_all; do
        _e=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$_sh/" 2>&1)
        case "$_e" in
            404) ok "$_sh: الحافة تصل إلى cloudflared (404 من ingress متوقع للجذر)" ;;
            530) err "$_sh: خطأ 530 — DNS يشير إلى النفق ولا اتصال نشط من cloudflared."; _fail=1 ;;
            000|curl*)
                warn "الراوتر نفسه لم يصل إلى https://$_sh/ ($_e)"
                say  "    كثيرًا ما يعجز الراوتر عن طلب مضيفه العام من الداخل؛"
                say  "    جرّبه من الهاتف أو حاسوب خارج الشبكة قبل عدّه عطلًا." ;;
            *)   say "    $_sh: الحافة ردّت $_e" ;;
        esac
    done

    say ""
    # 101 من مضيف واحد يثبت السلسلة؛ البقية قد تتأخّر بانتشار DNS أو حجب محلي
    for _sh in $_sh_all; do
      for _sp in $(protos_enabled); do
        _l=$(ws_probe "https://$_sh$(proto_path "$_sp")")
        case "$_l" in
            *101*) ok "$_sh [$_sp]: المسار العام يصل إلى xray."; _public_ok=1 ;;
            *404*) err "$_sh [$_sp]: الحافة ترد 404 — المسار لا يطابق قاعدة ingress."; _fail=1 ;;
            curl:*) err "$_sh [$_sp]: curl لم يصل — $_l"
                    say "    (الراوتر كثيرًا ما يعجز عن طلب مضيفه العام من الداخل)" ;;
            '')    err "$_sh [$_sp]: لا سطر استجابة على المسار العام."; _fail=1 ;;
            *)     err "$_sh [$_sp]: ردّ $_l (المتوقع 101)"; _fail=1 ;;
        esac
      done
    done

    say ""
    if [ "$_fail" = 0 ]; then
        ok "كل الحلقات سليمة. إن فشل التطبيق فالخلل في إعداد العميل:"
        users_links
    elif [ "${_public_ok:-0}" = 1 ]; then
        # 101 من الإنترنت العام يثبت السلسلة كاملة. ما فشل قبله عابر —
        # خدمة أثناء إعادة التشغيل، أو حالة لدى Cloudflare لم تُحدَّث بعد.
        ok "المسار العام يعمل — 101 من الإنترنت يثبت السلسلة كاملة."
        warn "ما ظهر أحمر أعلاه عابر (خدمة تبدأ، أو حالة متأخرة لدى Cloudflare)."
        say "أعد الفحص بعد دقيقتين؛ إن تكرّر فهو عطل حقيقي."
        users_links
        return 0
    else
        err "انقطاع في السلسلة — أول سطر أحمر أعلاه هو موضعه."
    fi
    return $_fail
}

# مخرج حين يكون loopback معطوبًا على الراوتر: اربط xray على عنوان آخر
do_set_listen() {
    need_root
    load_settings || die "لا يوجد تثبيت محلي."
    _a=${1:-}
    [ -n "$_a" ] || _a=$(lan_ip)
    case "$_a" in
        unix|socket) _a=/var/run/xe3000-xray.sock ;;
        /*)          : ;;
        0.0.0.0|::)  die "رفض الربط على $_a — سيعرّض xray للإنترنت." ;;
        *[!0-9.]*)   die "عنوان غير صالح: $_a (استخدم IP أو unix)" ;;
    esac
    XRAY_LISTEN=$_a
    save_settings
    disable_tfo
    users_apply
    write_cfd_config
    /etc/init.d/xe3000-cf-tunnel restart >/dev/null 2>&1 || warn "تعذر إعادة تشغيل cloudflared"
    if is_sock; then
        ok "xray يستمع على مقبس Unix: $XRAY_LISTEN — وcloudflared يقصده عبر unix:"
        say "هذا يتجاوز مسار TCP المحلي كليًا."
    else
        ok "xray يستمع الآن على $XRAY_LISTEN:$XRAY_PORT وcloudflared يقصده."
    fi
    say "تحقق: sh $SELF selftest"
}

# تبديل منفذ xray المحلي — منفذ بعينه قد يكون محجوزًا أو معترَضًا
do_set_port() {
    need_root
    load_settings || die "لا يوجد تثبيت محلي."
    _p=${1:-}
    case "$_p" in
        ''|*[!0-9]*) die "المنفذ يجب أن يكون رقمًا." ;;
    esac
    [ "$_p" -ge 1024 ] && [ "$_p" -le 65535 ] || die "اختر منفذًا بين 1024 و65535."
    XRAY_PORT=$_p
    is_sock && { warn "الاستماع على مقبس Unix — المنفذ غير مستعمل."; \
                 say "بدّل أولًا: sh $SELF set-listen 127.0.0.1"; }
    save_settings
    disable_tfo
    users_apply
    write_cfd_config
    /etc/init.d/xe3000-cf-tunnel restart >/dev/null 2>&1 || warn "تعذر إعادة تشغيل cloudflared"
    ok "المنفذ المحلي الآن $XRAY_PORT"
    say "تحقق: sh $SELF selftest"
}

# ws يحتاج ترقية HTTP وcloudflared لا يمرّرها إلى أصل unix؛ xhttp لا يحتاجها
do_set_transport() {
    need_root
    load_settings || die "لا يوجد تثبيت محلي."
    case "${1:-}" in
        ws|xhttp) XRAY_NET=$1 ;;
        *) die "الناقل: ws أو xhttp" ;;
    esac
    save_settings
    users_apply
    ok "الناقل الآن: $XRAY_NET"
    warn "روابط العملاء تغيّرت — أعد استيرادها من: sh $SELF links"
    say "أو من اللوحة برمز QR."
}

# مسار trojan يُولَّد عشوائيًا عند أول تفعيل. تثبيت أقدم بلا مسار محفوظ
# يشتقّ واحدًا في load_settings، لكن مسارًا عشوائيًا أفضل حين نكتبه أصلًا.
trojan_path_init() {
    grep -q '^FULLTUNNEL_TROJAN_PATH=.' "$SETTINGS" 2>/dev/null && return 0
    TROJAN_PATH=/$(head -c 16 /dev/urandom | md5sum | cut -c1-16)
}

do_proto_list() {
    load_settings || die "لا يوجد تثبيت محلي."
    for _p in vless trojan; do
        if proto_on "$_p"; then
            if [ "$_p" = trojan ]; then _pp=$(trojan_port); else _pp=$XRAY_PORT; fi
            is_sock && _pp=$(if [ "$_p" = trojan ]; then trojan_listen; else printf '%s' "$XRAY_LISTEN"; fi)
            printf '%-7s مفعّل   مسار=%-20s  أصل=%s\n' "$_p" "$(proto_path "$_p")" "$_pp"
        else
            printf '%-7s معطّل\n' "$_p"
        fi
    done
    say ""
    say "الاثنان يعملان معًا: تفصل بينهما الحافة بالمسار، ولكل واحد أصله."
    say "  sh $SELF proto-enable trojan   /  proto-disable trojan"
}

# تفعيل/تعطيل بروتوكول بلا مساس بقائمة المستخدمين: من عُطّل بروتوكوله يبقى
# مستخدمًا بمعرّفه وكلمة مروره، ويعود بمجرّد إعادة التفعيل.
do_proto_set() { # $1 = on|off   $2 = vless|trojan
    need_root
    load_settings || die "لا يوجد تثبيت محلي."
    _op=$1
    case "${2:-}" in
        vless|trojan) _tp=$2 ;;
        *) die "الاستعمال: proto-$( [ "$_op" = on ] && printf enable || printf disable ) <vless|trojan>" ;;
    esac
    _was=$(protos_enabled)
    _new=
    for _p in vless trojan; do
        if [ "$_p" = "$_tp" ]; then
            [ "$_op" = on ] && _new="$_new${_new:+ }$_p"
        elif proto_on "$_p"; then
            _new="$_new${_new:+ }$_p"
        fi
    done
    [ -n "$_new" ] || die "لا يمكن تعطيل آخر بروتوكول — فعّل الآخر أولًا."
    [ "$_new" = "$_was" ] && { ok "لا تغيير — القائمة هي نفسها: $_was"; return 0; }
    [ "$_tp" = trojan ] && [ "$_op" = on ] && trojan_path_init
    XRAY_PROTOS=$_new
    XRAY_PROTO=${_new%% *}
    save_settings
    users_apply
    write_cfd_config
    /etc/init.d/xe3000-cf-tunnel restart >/dev/null 2>&1 || warn "تعذر إعادة تشغيل cloudflared"
    # القياس من الملف المكتوب لا من المتغيّر: كتابة فاشلة كانت تُعلن نجاحًا
    _now=$(sed -n 's/^FULLTUNNEL_PROTOS=//p' "$SETTINGS" | head -1 | tr ',' ' ')
    [ "$_now" = "$_new" ] || die "لم تُكتب القائمة في $SETTINGS (فيه '$_now')."
    ok "البروتوكولات المفعّلة: $_new"
    warn "روابط العملاء تغيّرت — أعد استيرادها: sh $SELF links"
}

do_set_protocol() {
    need_root
    load_settings || die "لا يوجد تثبيت محلي."
    case "${1:-}" in
        vless|trojan) XRAY_PROTO=$1; XRAY_PROTOS=$1 ;;
        *) die "البروتوكول: vless أو trojan  (لتشغيلهما معًا: sh $SELF proto-enable <اسم>)" ;;
    esac
    [ "$XRAY_PROTO" = trojan ] && trojan_path_init
    save_settings; users_apply; write_cfd_config
    /etc/init.d/xe3000-cf-tunnel restart >/dev/null 2>&1 || warn "تعذر إعادة تشغيل cloudflared"
    ok "البروتوكول الآن: $XRAY_PROTO (وحده)"
    warn "روابط العملاء تغيّرت — أعد استيرادها: sh $SELF links"
}

do_sshws() {
    need_root
    load_settings || die "لا يوجد تثبيت محلي."
    case "${1:-}" in
        on|1)
            is_sock && die "جسر SSH يحتاج استماعًا على TCP: sh $SELF set-listen 127.0.0.1"
            command -v dropbear >/dev/null 2>&1 || command -v sshd >/dev/null 2>&1 ||
                warn "لم أجد خادم SSH على الجهاز — الجسر سيُنشأ لكنه لن يجد ما يتصل به."
            SSHWS=1
            case "$SSH_PATH" in /ssh|'') SSH_PATH=/ssh-$(head -c 8 /dev/urandom | md5sum | cut -c1-8) ;; esac
            SSH_PORT=$(( XRAY_PORT + 1 )) ;;
        off|0) SSHWS=0 ;;
        *) die "الاستعمال: ssh-ws on|off" ;;
    esac
    save_settings; users_apply; write_cfd_config
    /etc/init.d/xe3000-cf-tunnel restart >/dev/null 2>&1 || warn "تعذر إعادة تشغيل cloudflared"
    if [ "$SSHWS" = 1 ]; then
        ok "جسر SSH عبر WebSocket مفعّل"
        show_ssh
    else
        ok "جسر SSH معطّل"
    fi
}

show_ssh() {
    [ "${SSHWS:-0}" = 1 ] || return 0
    say ""
    say "SSH عبر WebSocket (wss):"
    say "  العنوان : $CF_HOSTNAME   المنفذ: 443   TLS: مُفعّل"
    say "  المسار  : $SSH_PATH"
    say "  الوجهة  : خادم SSH المحلي 127.0.0.1:22"
    say "  في تطبيقات SSH/WS: اجعل payload يطلب المسار أعلاه على المضيف نفسه."
}

# مراقبة دورية: إن سقط المسار العام تُعاد الخدمتان — ولا تُعاد إن كان العطل في الإنترنت
write_watchdog() {
    cat >"$BASE/watchdog.sh" <<WDOG
#!/bin/sh
. $SETTINGS 2>/dev/null || exit 0
H=\$FULLTUNNEL_HOSTNAME
[ -n "\$H" ] || exit 0
# لا إنترنت؟ إعادة التشغيل لا تُصلح شيئًا
ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || exit 0
_c=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://\$H/" 2>/dev/null)
case "\$_c" in
    2*|4*) exit 0 ;;
esac
logger -t xe3000 "watchdog: المسار العام ردّ '\$_c' — إعادة تشغيل الخدمتين"
/etc/init.d/xe3000-cf-xray restart >/dev/null 2>&1
/etc/init.d/xe3000-cf-tunnel restart >/dev/null 2>&1
WDOG
    chmod 750 "$BASE/watchdog.sh"
}

do_watchdog() {
    need_root
    load_settings || die "لا يوجد تثبيت محلي."
    _cron=/etc/crontabs/root
    case "${1:-}" in
        on|1)
            _m=${2:-5}
            case "$_m" in ''|*[!0-9]*) die "الفاصل بالدقائق رقم." ;; esac
            write_watchdog
            mkdir -p /etc/crontabs
            touch "$_cron"
            sed -i '\#xe3000-cf-fulltunnel/watchdog.sh#d' "$_cron"
            printf '*/%s * * * * %s/watchdog.sh\n' "$_m" "$BASE" >>"$_cron"
            /etc/init.d/cron enable >/dev/null 2>&1
            /etc/init.d/cron restart >/dev/null 2>&1
            ok "المراقبة مفعّلة كل $_m دقائق" ;;
        off|0)
            [ -f "$_cron" ] && sed -i '\#xe3000-cf-fulltunnel/watchdog.sh#d' "$_cron"
            /etc/init.d/cron restart >/dev/null 2>&1
            rm -f "$BASE/watchdog.sh"
            ok "المراقبة معطّلة" ;;
        test)
            write_watchdog; sh "$BASE/watchdog.sh"; ok "شُغّلت مرة واحدة — راجع: logread -e xe3000" ;;
        *) die "الاستعمال: watchdog on [دقائق] | off | test" ;;
    esac
}

# كِل‑سويتش WireGuard يوجّه كل مرور الراوتر إلى النفق ويحجب ما عداه، فيسقط
# اتصال cloudflared بحافة Cloudflare. نعلّم مروره ليخرج مباشرة عبر WAN.
# المنافذ التي يحتاجها الراوتر نفسه حين يسقط مسار الـ VPN:
#   7844 tcp/udp  اتصال cloudflared بحافة Cloudflare
#   53   udp/tcp  ترجمة الأسماء — بدونها لا يصل cloudflared ولا API إلى أي مضيف
#   443  tcp      Cloudflare API وتنزيل الملفات الثنائية والتحديث الذاتي
#   80   tcp      opkg ومرايا الحزم
FW_BYPASS_PORTS='tcp:7844 udp:7844 udp:53 tcp:53 tcp:443 tcp:80'
BYPASS_MODE="$BASE/state/vpn-bypass.mode"

# الملف المولَّد هو مصدر القرار الوحيد: يعمل من include الجدار الناري عند الإقلاع
# ومن cron دوريًا، فلا يتكرّر المنطق في مكانين.
write_fwinclude() {
    mkdir -p "$BASE" "$STATE" || die "تعذر إنشاء $BASE"
    chmod 700 "$BASE" 2>/dev/null
    {
    cat <<'FWIHEAD'
#!/bin/sh
# سياسة VPN في GL.iNet (rtp2.sh) تدفع كل ما ينشئه الراوتر إلى جدول سياسة
# مساره الافتراضي عبر نفق VPN. هذا هو المطلوب: النفق العام يمرّ عبر الـ VPN.
#
# لكن حياة الـ VPN لا تكفي حكمًا: قد يكون النفق حيًّا ويردّ على ping بينما
# يقطع مصافحة TLS مع حافة Cloudflare على 7844 ("connection reset"). لذلك
# الحكم هنا على ما يهم فعلًا: عدد وصلات cloudflared النشطة من /ready.
#
#   auto  = فضّل الـ VPN. تجاوزه فقط إن سقط النفق عبره، وعُد لتجربته دوريًا.
#   on    = تجاوز دائم.    off = بلا تجاوز إطلاقًا.
#
# العلامة 0x8000 تلتقطها قاعدة ip rule ذات الأولوية 6000 فتذهب الحزمة إلى
# الجدول main مباشرة عبر منفذ الإنترنت.
#
# mangle/OUTPUT لا يرى إلا ما ينشئه الراوتر: مرور أجهزة الشبكة يمرّ بـ FORWARD،
# فكِل‑سويتش أجهزتك لا يتأثر بهذا الملف إطلاقًا.
FWIHEAD
    printf 'PORTS="%s"\n' "$FW_BYPASS_PORTS"
    printf 'MODEF="%s"\n' "$BYPASS_MODE"
    printf 'STAMP="%s"\n' "$STATE/vpn-bypass.lastretry"
    printf 'APPLIED="%s"\n' "$STATE/vpn-bypass.applied"
    printf 'METRICS="127.0.0.1:%s"\n' "${CFD_METRICS:-20241}"
    printf 'TUNSVC="%s"\n' "/etc/init.d/xe3000-cf-tunnel"
    printf 'RETRY_AFTER=%s\n' "${BYPASS_RETRY:-1800}"
    cat <<'FWIBODY'

_rule() { # $1=عملية $2=بروتوكول $3=منفذ
    iptables -w -t mangle "$1" OUTPUT -p "$2" --dport "$3" -m mark --mark 0x0/0xf000 \
        -j MARK --set-xmark 0x8000/0xf000 2>/dev/null
}

# اختيار عنوان المصدر يقع في أول بحث عن مسار، قبل mangle/OUTPUT. فإن كان نفق
# الـ VPN حيًّا اختير عنوانه (مثل 172.19.0.1)، ثم تُعيد علامتنا التوجيه عبر
# منفذ الإنترنت والمصدر باقٍ كما هو — فتخرج الحزم بعنوان لا يخصّ ذلك المنفذ
# ولا يعود لها جواب: "i/o timeout". هذه القاعدة تصحّح المصدر عند الخروج.
_snat() { iptables -w -t nat "$1" POSTROUTING -m mark --mark 0x8000/0xf000 ! -o lo \
              -j MASQUERADE 2>/dev/null; }

add_rules() {
    for _e in $PORTS; do _rule -C "${_e%%:*}" "${_e##*:}" || _rule -I "${_e%%:*}" "${_e##*:}"; done
    _snat -C || _snat -I
}
del_rules() {
    for _e in $PORTS; do while _rule -D "${_e%%:*}" "${_e##*:}"; do :; done; done
    while _snat -D; do :; done
}
count_rules() {
    _n=0
    for _e in $PORTS; do _rule -C "${_e%%:*}" "${_e##*:}" && _n=$((_n+1)); done
    _snat -C && _n=$((_n+1))
    echo "$_n"
}

# عدد وصلات cloudflared النشطة الآن: -1 يعني تعذّرت القراءة
ready_conns() {
    _j=$(curl -s --max-time 4 "http://$METRICS/ready" 2>/dev/null)
    case "$_j" in
        *readyConnections*)
            echo "$_j" | sed -n 's/.*"readyConnections":[ ]*\([0-9]*\).*/\1/p' | head -1 ;;
        *) echo -1 ;;
    esac
}

tun_running() { [ -x "$TUNSVC" ] && "$TUNSVC" running >/dev/null 2>&1; }

# انتظر حتى تستقر الوصلات بعد إعادة التشغيل
wait_ready() {
    _w=0
    while [ "$_w" -lt 12 ]; do
        sleep 5; _w=$((_w+1))
        [ "$(ready_conns)" -ge 1 ] 2>/dev/null && return 0
    done
    return 1
}

restart_tun() { [ -x "$TUNSVC" ] && "$TUNSVC" restart >/dev/null 2>&1; }

MODE=$(cat "$MODEF" 2>/dev/null)
[ -n "$MODE" ] || MODE=auto
case "$MODE" in
    on)  add_rules; exit 0 ;;
    off) del_rules; exit 0 ;;
esac

# يُستدعى من مكانين: include الجدار الناري (بلا وسيط) وcron (بـ probe).
# الأول يعمل داخل إعادة تحميل الجدار فيجب ألا ينتظر: يُعيد آخر قرار فورًا،
# وهذا هو ما يُرجع قواعد DNS بعد الإقلاع قبل أن تبدأ الخدمة أصلًا.
if [ "${1:-}" != probe ]; then
    [ "$(cat "$APPLIED" 2>/dev/null)" = 1 ] && add_rules || del_rules
    exit 0
fi

# ── الفحص الدوري: الـ VPN هو المفضّل ──
# قبل أن تبدأ الخدمة لا يوجد ما يُحكم عليه: اترك الحالة كما هي.
tun_running || exit 0

_marks=$(count_rules)
_ready=$(ready_conns)
[ "$_ready" -ge 0 ] 2>/dev/null || exit 0     # تعذّرت القراءة: لا تقرّر على غير بيّنة
_now=$(date +%s)

if [ "$_marks" = 0 ]; then
    # على مسار الـ VPN — وهو المطلوب. لا تتحرّك إلا إن سقط النفق عبره.
    [ "$_ready" -ge 1 ] && exit 0
    logger -t xe3000 "vpn-bypass: النفق لا يقوم عبر الـ VPN — أتجاوزه مؤقتًا"
    add_rules; echo 1 >"$APPLIED" 2>/dev/null; restart_tun
    wait_ready && logger -t xe3000 "vpn-bypass: قام النفق مباشرةً" ||
        logger -t xe3000 "vpn-bypass: لم يقم في الحالتين — راجع logread -e cloudflared"
    echo "$_now" >"$STAMP" 2>/dev/null
    exit 0
fi

# على المسار المباشر. النفق يعمل؟ جرّب العودة إلى الـ VPN بين حين وآخر.
if [ "$_ready" -ge 1 ]; then
    _last=$(cat "$STAMP" 2>/dev/null); [ -n "$_last" ] || _last=0
    [ $((_now - _last)) -ge "$RETRY_AFTER" ] || exit 0
    echo "$_now" >"$STAMP" 2>/dev/null
    logger -t xe3000 "vpn-bypass: أجرّب إعادة المرور إلى الـ VPN"
    del_rules; echo 0 >"$APPLIED" 2>/dev/null; restart_tun
    if wait_ready; then
        logger -t xe3000 "vpn-bypass: نجح — المرور يسلك الـ VPN الآن"
    else
        add_rules; echo 1 >"$APPLIED" 2>/dev/null; restart_tun
        logger -t xe3000 "vpn-bypass: الـ VPN ما زال يقطع الوصلة — عدتُ إلى المباشر"
    fi
    exit 0
fi

# مباشر ولا يعمل أيضًا: جرّب الـ VPN، فربما عاد.
logger -t xe3000 "vpn-bypass: النفق لا يقوم مباشرةً — أجرّب الـ VPN"
del_rules; echo 0 >"$APPLIED" 2>/dev/null; restart_tun
if wait_ready; then
    logger -t xe3000 "vpn-bypass: قام عبر الـ VPN"
else
    add_rules; echo 1 >"$APPLIED" 2>/dev/null; restart_tun
    logger -t xe3000 "vpn-bypass: لم يقم في الحالتين — راجع logread -e cloudflared"
fi
echo "$_now" >"$STAMP" 2>/dev/null
exit 0
FWIBODY
    } >"$BASE/firewall.sh" || die "تعذر كتابة $BASE/firewall.sh"
    [ -s "$BASE/firewall.sh" ] || die "$BASE/firewall.sh كُتب فارغًا"
    chmod 750 "$BASE/firewall.sh"
}

fw_snat() { iptables -w -t nat "$1" POSTROUTING -m mark --mark 0x8000/0xf000 ! -o lo \
                -j MASQUERADE 2>/dev/null; }

fw_bypass_del() {
    for _e in $FW_BYPASS_PORTS; do
        _pr=${_e%%:*}; _pt=${_e##*:}
        while iptables -w -t mangle -D OUTPUT -p "$_pr" --dport "$_pt" \
                -m mark --mark 0x0/0xf000 -j MARK --set-xmark 0x8000/0xf000 2>/dev/null; do :; done
    done
    while fw_snat -D; do :; done
}

# لا تُقرأ الحالة من مخرجات السكربت المولَّد بل من الجدول نفسه
fw_bypass_count() {
    _n=0
    for _e in $FW_BYPASS_PORTS; do
        _pr=${_e%%:*}; _pt=${_e##*:}
        iptables -w -t mangle -C OUTPUT -p "$_pr" --dport "$_pt" -m mark --mark 0x0/0xf000 \
            -j MARK --set-xmark 0x8000/0xf000 2>/dev/null && _n=$((_n+1))
    done
    fw_snat -C && _n=$((_n+1))
    printf '%s' "$_n"
}

# المنافذ + قاعدة تصحيح المصدر
fw_bypass_total() { set -- $FW_BYPASS_PORTS; printf '%s' "$(( $# + 1 ))"; }

# بعض الشبكات تقطع مصافحة TLS إلى حافة Cloudflare على 7844/TCP بينما تمرّر
# 7844/UDP (quic) أو العكس. هذا يبدّل الاثنين بلا مساس بأي إعداد آخر.
# اسم المضيف يُختار بحرية داخل نطاقك — مثل cdn أو youtube — لأن الاسم هو ما
# يراه الفاحص في SNI. يُنشأ سجل CNAME جديد ويُبقى القديم فلا ينقطع من يستعمله.
do_set_hostname() {
    need_root
    load_settings || die "لا يوجد تثبيت محلي."
    [ -n "$TUNNEL_ID" ] || die "لا يوجد نفق — ثبّت أولًا: sh $SELF auto"
    _new=${1:-}
    if [ -z "$_new" ]; then
        has_tty || die "الاستعمال: set-hostname <اسم.نطاقك>"
        say "المضيف الحالي: $CF_HOSTNAME"
        read_tty "المضيف الجديد (مثل cdn.example.com): " _new
    fi
    valid_host "$_new" || die "اسم مضيف غير صالح: '$_new'"
    [ "$_new" = "$CF_HOSTNAME" ] && { ok "لا تغيير — المضيف هو نفسه."; return 0; }

    collect_creds
    hosts_init
    _old=$CF_HOSTNAME
    _oz=$(host_zone "$_old"); [ -n "$_oz" ] || _oz=$CF_ZONE
    _keep=$CF_TOKEN; CF_TOKEN=$(zone_token "$_oz")
    _r=$(cf GET "/zones/$_oz")
    CF_TOKEN=$_keep
    cf_success "$_r" || die "تعذر قراءة النطاق: $(cf_errors "$_r")"
    _zn=$(jf "$_r" '@.result.name')
    case "$_new" in
        "$_zn"|*".$_zn") : ;;
        *) die "'$_new' ليس تابعًا للنطاق '$_zn' — لا يمكن إنشاء سجل له.
    لإضافة مضيف في نطاق آخر: sh $SELF host-add $_new" ;;
    esac

    host_depth_warn "$_new" "$_zn"

    dns_one "$_new" "$_oz" || die "فشل إنشاء السجل — لم يتغيّر شيء."
    CF_HOSTNAME=$_new
    # التبديل يمسّ المضيف الأوّل وحده؛ بقية المضيفين تديرها host-add/host-del
    hosts_init
    _ht=$STATE/.hosts.$$
    if host_known "$_old"; then
        awk -F'\t' -v o="$_old" -v n="$_new" -v z="$_oz" \
            '{ if ($1==o) printf "%s\t%s\n", n, z; else print }' "$HOSTS" >"$_ht" &&
            mv "$_ht" "$HOSTS" || { rm -f "$_ht"; die "تعذر تحديث $HOSTS."; }
    else
        printf '%s\t%s\n' "$_new" "$_oz" >"$HOSTS"
    fi
    chmod 600 "$HOSTS"
    host_known "$_new" || die "لم يُكتب المضيف الجديد في $HOSTS."
    save_settings
    write_cfd_config
    /etc/init.d/xe3000-cf-tunnel restart >/dev/null 2>&1 || warn "تعذر إعادة تشغيل cloudflared"
    ok "المضيف الآن: $CF_HOSTNAME"
    say "سجل $_old لم يُحذف — احذفه من لوحة Cloudflare إن لم تعد تحتاجه."
    say "انتظر انتشار DNS دقيقة ثم: sh $SELF selftest"
    warn "روابط العملاء تغيّرت — أعد استيرادها:"
    users_links
}

# شهادة Universal SSL على إعداد full تغطي النطاق والمستوى الأول فقط. اسم مثل
# youtube.com.example.com مستوى ثانٍ فتفشل مصافحة TLS بخطأ شهادة.
host_depth_warn() { # $1 المضيف  $2 اسم النطاق
    _sub=${1%".$2"}
    case "$_sub" in
        "$1") return 0 ;;
        *.*)  : ;;
        *)    return 0 ;;
    esac
    warn "'$1' نطاق فرعي من المستوى الثاني."
    say  "    شهادة Cloudflare المجانية (Universal SSL) تغطي النطاق والمستوى"
    say  "    الأول فقط، فمصافحة TLS ستفشل بخطأ شهادة ما لم تكن مشتركًا في"
    say  "    Advanced Certificate Manager أو Total TLS."
    say  "    البديل المجاني: اسم من مستوى واحد مثل ${_sub%%.*}.$2"
    if has_tty && [ "${FULLTUNNEL_FORCE:-0}" != 1 ]; then
        read_tty "أتابع رغم ذلك؟ (اكتب نعم): " _y
        [ "$_y" = "نعم" ] || die "أُلغي — لم يتغيّر شيء."
    fi
}

# استدلال Zone ID من اسم المضيف: تُجرَّب لواحق الاسم من الأطول إلى الأقصر.
# يحتاج صلاحية سرد النطاقات؛ إن لم تتوفّر يمرّر المستخدم المعرّف يدويًا.
zone_lookup() {
    _zc=$1
    while : ; do
        case "$_zc" in *.*) : ;; *) return 1 ;; esac
        _r=$(cf GET "/zones?name=$_zc")
        if cf_success "$_r"; then
            _zi=$(jf "$_r" '@.result[0].id')
            [ -n "$_zi" ] && { printf '%s' "$_zi"; return 0; }
        fi
        _zc=${_zc#*.}
    done
}

do_host_list() {
    load_settings >/dev/null 2>&1 || true
    hosts_list
}

# إضافة نطاق آخر إلى النفق نفسه: قاعدة ingress جديدة وسجل CNAME في نطاقه.
do_host_add() { # $1 المضيف  $2 معرّف النطاق (اختياري)
    need_root
    load_settings || die "لا يوجد تثبيت محلي."
    [ -n "$TUNNEL_ID" ] || die "لا يوجد نفق — ثبّت أولًا: sh $SELF auto"
    hosts_init
    _nh=${1:-}
    if [ -z "$_nh" ]; then
        has_tty || die "الاستعمال: host-add <مضيف.نطاق> [zone-id]"
        read_tty "المضيف الجديد (مثل cdn.example.net): " _nh
    fi
    valid_host "$_nh" || die "اسم مضيف غير صالح: '$_nh'"
    host_known "$_nh" && { ok "المضيف $_nh مضاف مسبقًا."; return 0; }

    collect_creds
    _nz=${2:-}
    [ -n "$_nz" ] || _nz=$(zone_lookup "$_nh")
    [ -n "$_nz" ] ||
        die "لم أستدلّ على Zone ID لـ '$_nh' — مرّره: sh $SELF host-add $_nh <zone-id>"
    valid_id "$_nz" || die "Zone ID غير صالح: '$_nz'"

    _keep=$CF_TOKEN; CF_TOKEN=$(zone_token "$_nz")
    _r=$(cf GET "/zones/$_nz")
    CF_TOKEN=$_keep
    cf_success "$_r" || die "تعذر قراءة النطاق $_nz: $(cf_errors "$_r")
    إن كان لهذا النطاق توكن خاص فعيّنه أولًا: sh $SELF set-zone-token $_nz"
    _zn=$(jf "$_r" '@.result.name')
    case "$_nh" in
        "$_zn"|*".$_zn") : ;;
        *) die "'$_nh' ليس تابعًا للنطاق '$_zn' — راجع Zone ID." ;;
    esac
    host_depth_warn "$_nh" "$_zn"

    printf '%s\t%s\n' "$_nh" "$_nz" >>"$HOSTS"
    chmod 600 "$HOSTS"
    # القياس من المصدر بعد الكتابة — لا إعلان نجاح قبل أن يقرأه الملف
    host_known "$_nh" || die "لم تُكتب الإضافة في $HOSTS."
    if ! dns_one "$_nh" "$_nz"; then
        _ht=$STATE/.hosts.$$
        awk -F'\t' -v h="$_nh" '$1!=h' "$HOSTS" >"$_ht" && mv "$_ht" "$HOSTS"
        chmod 600 "$HOSTS"
        die "فشل سجل DNS — أُزيل المضيف ولم يتغيّر شيء."
    fi
    save_settings
    write_cfd_config
    /etc/init.d/xe3000-cf-tunnel restart >/dev/null 2>&1 || warn "تعذر إعادة تشغيل cloudflared"
    ok "أُضيف المضيف $_nh (المجموع $(hosts_count))"
    say "انتظر انتشار DNS دقيقة ثم: sh $SELF selftest"
    users_links
}

do_host_del() { # $1 المضيف
    need_root
    load_settings || die "لا يوجد تثبيت محلي."
    hosts_init
    _dh=${1:-}
    [ -n "$_dh" ] || die "الاستعمال: host-del <مضيف>"
    host_known "$_dh" || die "لا مضيف بهذا الاسم: $_dh"
    [ "$(hosts_count)" -gt 1 ] ||
        die "لا يمكن حذف آخر مضيف — للتبديل: sh $SELF set-hostname <اسم>"
    _ht=$STATE/.hosts.$$
    awk -F'\t' -v h="$_dh" '$1!=h' "$HOSTS" >"$_ht" || { rm -f "$_ht"; die "فشل التحرير."; }
    mv "$_ht" "$HOSTS"; chmod 600 "$HOSTS"
    host_known "$_dh" && die "لم يُحذف المضيف من $HOSTS."
    CF_HOSTNAME=$(host_primary)
    save_settings
    write_cfd_config
    /etc/init.d/xe3000-cf-tunnel restart >/dev/null 2>&1 || warn "تعذر إعادة تشغيل cloudflared"
    ok "حُذف المضيف $_dh (بقي $(hosts_count))"
    say "سجل CNAME لـ $_dh لم يُحذف — احذفه من لوحة Cloudflare إن لم تعد تحتاجه."
}

# توكن مقصور على نطاق واحد: أضيق صلاحية من توكن يملك كل النطاقات.
do_set_zone_token() { # $1 معرّف النطاق  $2 off لحذفه
    need_root
    _zz=${1:-}
    [ -n "$_zz" ] || die "الاستعمال: set-zone-token <zone-id> [off]"
    valid_id "$_zz" || die "Zone ID غير صالح: '$_zz'"
    mkdir -p "$CREDS" || die "تعذر إنشاء $CREDS"
    chmod 700 "$CREDS"
    if [ "${2:-}" = off ]; then
        rm -f "$CREDS/zone-token-$_zz"
        [ -s "$CREDS/zone-token-$_zz" ] && die "لم يُحذف التوكن الخاص."
        ok "حُذف التوكن الخاص بالنطاق $_zz — سيُستعمل التوكن العام."
        return 0
    fi
    _zt=${FULLTUNNEL_ZONE_TOKEN:-}
    [ -n "$_zt" ] || read_tty "توكن النطاق $_zz (Zone · DNS · Edit): " _zt 1
    valid_id "$_zt" || die "التوكن غير صالح أو فيه محرف زائد."
    # يُقاس قبل الحفظ: توكن لا يقرأ نطاقه يكسر host-add وتجديد السجلات
    _keep=${CF_TOKEN:-}; CF_TOKEN=$_zt
    _r=$(cf GET "/zones/$_zz")
    CF_TOKEN=$_keep
    cf_success "$_r" || die "التوكن لا يقرأ النطاق $_zz: $(cf_errors "$_r")"
    printf '%s' "$_zt" >"$CREDS/zone-token-$_zz"
    chmod 600 "$CREDS/zone-token-$_zz"
    [ -s "$CREDS/zone-token-$_zz" ] || die "فشلت كتابة التوكن."
    ok "حُفظ توكن النطاق $(jf "$_r" '@.result.name') ($_zz)"
}

do_set_edge_proto() {
    need_root
    load_settings || die "لا يوجد تثبيت محلي."
    case "${1:-}" in
        http2|quic|auto) CFD_PROTO=$1 ;;
        '') say "بروتوكول الحافة الآن: ${CFD_PROTO:-http2}"
            say "الاستعمال: set-edge-protocol http2|quic|auto"
            return 0 ;;
        *) die "الاستعمال: set-edge-protocol http2|quic|auto  (http2=TCP 7844، quic=UDP 7844)" ;;
    esac
    save_settings
    write_cfd_config
    /etc/init.d/xe3000-cf-tunnel restart >/dev/null 2>&1 || warn "تعذر إعادة تشغيل cloudflared"
    ok "بروتوكول الحافة الآن: $CFD_PROTO"
    say "انتظر نحو 20 ثانية ثم: logread -e cloudflared | tail -12"
    say "ابحث عن Registered tunnel connection — ظهورها يعني أن الوصلة قامت."
}

do_vpn_bypass() {
    need_root
    # بلا هذا تكون كل القيم فارغة، فيولّد write_cfd_config إعدادًا بلا مضيف.
    # الأمر يُستعمل قبل التثبيت أيضًا، فغياب الإعدادات ليس خطأً بذاته.
    load_settings 2>/dev/null || true
    _cron=/etc/crontabs/root
    case "${1:-auto}" in
        auto|on|1)
            case "${1:-auto}" in on|1) _mode=on ;; *) _mode=auto ;; esac
            mkdir -p "$STATE" || die "تعذر إنشاء $STATE"
            printf '%s\n' "$_mode" >"$BYPASS_MODE"
            write_fwinclude
            uci -q delete firewall.xe3000_inc
            uci set firewall.xe3000_inc=include
            uci set firewall.xe3000_inc.path="$BASE/firewall.sh"
            uci set firewall.xe3000_inc.reload=1
            uci commit firewall
            # في on: طبّق فورًا وسجّل القرار. في auto: لا تغيّر المسار قبل القياس —
            # الفتح والإغلاق العشوائي يُسقط النفق بدل أن يجرّبه.
            if [ "$_mode" = on ]; then
                printf '1\n' >"$STATE/vpn-bypass.applied" 2>/dev/null
                sh "$BASE/firewall.sh" || die "تعذر تطبيق قواعد التجاوز"
            else
                [ "$(fw_bypass_count)" = 0 ] &&
                    printf '0\n' >"$STATE/vpn-bypass.applied" 2>/dev/null ||
                    printf '1\n' >"$STATE/vpn-bypass.applied" 2>/dev/null
            fi

            # في الوضع التلقائي تُعاد المراجعة دوريًا: النفق قد يسقط أو يعود
            mkdir -p /etc/crontabs; touch "$_cron"
            sed -i "\\#$BASE/firewall.sh#d" "$_cron"
            if [ "$_mode" = auto ]; then
                printf '*/%s * * * * %s/firewall.sh probe\n' "${2:-5}" "$BASE" >>"$_cron"
                /etc/init.d/cron enable  >/dev/null 2>&1
                /etc/init.d/cron restart >/dev/null 2>&1
            fi

            _have=$(fw_bypass_count); _all=$(fw_bypass_total)
            if [ "$_mode" = on ]; then
                [ "$_have" = "$_all" ] ||
                    die "طُبّقت $_have من $_all قاعدة فقط — راجع: iptables -t mangle -L OUTPUT -n -v"
                ok "تجاوز دائم: مرور الراوتر نحو 53 و80 و443 و7844 يخرج مباشرة ($_have/$_all)"
                warn "دائم يعني أن النفق لن يسلك الـ VPN حتى وهو يعمل. للسلوك المفضّل: vpn-bypass auto"
            else
                # بلا مقياس لا قرار: تأكّد أن /ready يجيب قبل إعلان أي شيء
                if ! cfd_ready_ok; then
                    [ -n "$TUNNEL_ID" ] && [ -n "$CF_HOSTNAME" ] || {
                        add_bypass_now
                        die "لا يوجد تثبيت مكتمل — الوضع التلقائي يحتاج نفقًا قائمًا.
    أبقيتُ التجاوز مفعّلًا. ثبّت أولًا: sh $SELF auto"; }
                    say "منفذ المقاييس غير مهيّأ — أضيفه إلى الإعداد وإلى أمر التشغيل."
                    write_cfd_config
                    write_init          # الوسيط --metrics يقع في غلاف التشغيل
                    /etc/init.d/xe3000-cf-tunnel restart >/dev/null 2>&1
                    _w=0; while [ "$_w" -lt 10 ] && ! cfd_ready_ok; do sleep 3; _w=$((_w+1)); done
                fi
                if ! cfd_ready_ok; then
                    add_bypass_now
                    die "تعذّر قراءة /ready من cloudflared — لا يمكن للوضع التلقائي أن يقرّر.
    أبقيتُ التجاوز مفعّلًا حتى لا يسقط النفق. راجع: logread -e cloudflared | tail -20"
                fi
                ok "الوضع التلقائي مفعّل — الـ VPN هو المفضّل، ويُراجَع كل ${2:-5} دقائق"
                say "يتجاوز الـ VPN فقط إن لم يقم النفق عبره، ويعود لتجربته كل نصف ساعة."
                say "القرار الأول جارٍ الآن: يجرّب الـ VPN ويقيس وصلات cloudflared."
                say "قد ينقطع النفق دقيقة أثناء التجربة، ثم يستقرّ على ما نجح."
                say "راجع بعد دقيقتين: sh $SELF vpn-bypass status"
                sh "$BASE/firewall.sh" probe >/dev/null 2>&1 &
            fi
            say "مرور أجهزة شبكتك لا يتأثر — هذا يخص ما ينشئه الراوتر وحده."
            say "يصمد بعد إعادة تشغيل الجدار الناري والجهاز." ;;
        off|0)
            uci -q delete firewall.xe3000_inc && uci commit firewall
            [ -f "$_cron" ] && sed -i "\\#$BASE/firewall.sh#d" "$_cron"
            /etc/init.d/cron restart >/dev/null 2>&1
            fw_bypass_del
            rm -f "$BASE/firewall.sh"
            printf 'off\n' >"$BYPASS_MODE" 2>/dev/null
            _left=$(fw_bypass_count)
            [ "$_left" = 0 ] || warn "بقيت $_left قاعدة — راجع: iptables -t mangle -L OUTPUT -n -v"
            ok "أُلغي التجاوز — كل مرور الراوتر يسلك سياسة الـ VPN" ;;
        status)
            _m=$(cat "$BYPASS_MODE" 2>/dev/null); [ -n "$_m" ] || _m="(غير مضبوط)"
            _rc=$(curl -s --max-time 4 "http://127.0.0.1:${CFD_METRICS:-20241}/ready" 2>/dev/null |
                  sed -n 's/.*"readyConnections":[ ]*\([0-9]*\).*/\1/p' | head -1)
            _have=$(fw_bypass_count)
            say "الوضع    : $_m"
            say "المسار   : $([ "$_have" = 0 ] && echo 'عبر الـ VPN' || echo 'مباشر (تجاوز)')"
            say "مسار VPN : $(vpn_link_state)"
            say "الوصلات  : ${_rc:-غير متاح} نشطة لدى cloudflared"
            say "القواعد  : $_have/$(fw_bypass_total)"
            grep -qF "$BASE/firewall.sh" "$_cron" 2>/dev/null &&
                say "المراجعة : مجدولة في cron" || say "المراجعة : غير مجدولة" ;;
        *) die "الاستعمال: vpn-bypass auto|on|off|status" ;;
    esac
}

# هل يجيب منفذ مقاييس cloudflared؟ هو مصدر القرار الوحيد في الوضع التلقائي.
cfd_ready_ok() {
    curl -s --max-time 4 "http://127.0.0.1:${CFD_METRICS:-20241}/ready" 2>/dev/null |
        grep -q readyConnections
}

# شبكة أمان: لا تترك النفق على مسار غير مثبت إن فشل الإعداد التلقائي
add_bypass_now() {
    write_fwinclude 2>/dev/null
    printf 'on\n' >"$BYPASS_MODE" 2>/dev/null
    sh "$BASE/firewall.sh" >/dev/null 2>&1
    /etc/init.d/xe3000-cf-tunnel restart >/dev/null 2>&1
}

# نفس منطق الملف المولَّد، للعرض في الطرفية
vpn_link_state() {
    [ -x "$BASE/firewall.sh" ] || { printf 'غير معروف (لم يُكتب الملف بعد)'; return; }
    _r=$(for _t in $(ip rule 2>/dev/null | sed -n 's/.*lookup \([0-9][0-9]*\).*/\1/p' | sort -un); do
            ip route show table "$_t" 2>/dev/null | awk '/^default via /{print $3" "$5; exit}'
         done | grep -E ' (tun|wg|ppp|ovpn|vti)' | head -1)
    [ -n "$_r" ] || { printf none; return; }
    _gw=${_r%% *}; _dev=${_r##* }
    ip link show "$_dev" >/dev/null 2>&1 || { printf down; return; }
    case "$_dev" in
        wg*) _h=$(wg show "$_dev" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
             if [ -n "$_h" ] && [ "$_h" -gt 0 ] && [ $(( $(date +%s) - _h )) -lt 240 ]; then
                 printf up
             else
                 printf down
             fi ;;
        *)   ping -c1 -W2 "$_gw" >/dev/null 2>&1 && printf up || printf down ;;
    esac
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
  sh $SELF auth on|off|status  حماية اللوحة (معطّلة افتراضيًا)
  sh $SELF set-password     كلمة مرور اللوحة
  sh $SELF set-token        تبديل توكن Cloudflare وحده ثم فحصه
  sh $SELF set-listen [عنوان] ربط xray على عنوان آخر أو unix
  sh $SELF set-transport <ws|xhttp>  تبديل الناقل
  sh $SELF set-port <رقم>   تبديل المنفذ المحلي
  sh $SELF set-protocol <vless|trojan>  قصر العمل على بروتوكول واحد
  sh $SELF proto-list       البروتوكولات ومساراتها
  sh $SELF proto-enable <vless|trojan>   تفعيله مع الآخر لا بدلًا منه
  sh $SELF proto-disable <vless|trojan>  تعطيله دون مساس بالمستخدمين
  sh $SELF ssh-ws on|off    جسر SSH عبر WebSocket
  sh $SELF watchdog on [د]|off|test  مراقبة دورية وإعادة تشغيل تلقائية
  sh $SELF set-hostname <اسم>  تبديل المضيف الأوّل داخل نطاقه
  sh $SELF host-list        المضيفون ونطاقاتهم
  sh $SELF host-add <مضيف> [zone-id]  إضافة نطاق آخر إلى النفق نفسه
  sh $SELF host-del <مضيف>  إزالة مضيف من النفق
  sh $SELF set-zone-token <zone-id> [off]  توكن خاص بنطاق واحد
  sh $SELF set-edge-protocol <http2|quic|auto>  بروتوكول وصلة الحافة
  sh $SELF vpn-bypass auto|on|off|status  الـ VPN مفضّل، والتجاوز عند فشله
  sh $SELF selftest         فحص السلسلة: xray ← cloudflared ← Cloudflare ← DNS
  sh $SELF menu             قائمة تفاعلية عبر SSH (أو الأمر menu مباشرة)
  sh $SELF user-list        عرض المستخدمين
  sh $SELF users-apply      إعادة بناء إعداد xray من قائمة المستخدمين
  sh $SELF user-add [اسم]   إضافة مستخدم وتطبيقه
  sh $SELF user-del <اسم>   حذف مستخدم وتطبيقه
  sh $SELF links            طباعة روابط الاشتراك الكاملة
  sh $SELF preflight        فحوصات Cloudflare الأربعة
  sh $SELF creds-status     هل البيانات محفوظة
  sh $SELF forget-creds     حذفها نهائيًا
  sh $SELF reset            حذف بقايا تثبيت ناقص
  sh $SELF remove           إزالة كاملة
  sh $SELF prepare-runtime  الاعتمادات فقط
  sh $SELF reinstall-services إعادة كتابة ملفي الخدمة وتشغيلهما
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
    auth)               do_auth "${2:-status}" ;;
    set-password)       need_root; set_password 1; configure_uhttpd ;;
    set-token)          do_set_token ;;
    selftest)           do_selftest ;;
    set-listen)         do_set_listen "${2:-}" ;;
    set-transport)      do_set_transport "${2:-}" ;;
    set-port)           do_set_port "${2:-}" ;;
    set-protocol)       do_set_protocol "${2:-}" ;;
    proto-list)         do_proto_list ;;
    proto-enable)       do_proto_set on  "${2:-}" ;;
    proto-disable)      do_proto_set off "${2:-}" ;;
    ssh-ws)             do_sshws "${2:-}" ;;
    watchdog)           do_watchdog "${2:-}" "${3:-}" ;;
    set-hostname)       do_set_hostname "${2:-}" ;;
    host-list)          do_host_list ;;
    host-add)           do_host_add "${2:-}" "${3:-}" ;;
    host-del)           do_host_del "${2:-}" ;;
    set-zone-token)     do_set_zone_token "${2:-}" "${3:-}" ;;
    set-edge-protocol)  do_set_edge_proto "${2:-}" ;;
    vpn-bypass)         do_vpn_bypass "${2:-auto}" "${3:-}" ;;
    menu)               do_menu ;;
    user-list)          load_settings >/dev/null 2>&1; users_list ;;
    users-apply)        need_root; users_apply ;;
    user-add)           need_root; user_add "${2:-}" >/dev/null && users_apply ;;
    user-del)           need_root
                        [ "$(users_count)" -gt 1 ] || die "لا يمكن حذف آخر مستخدم."
                        user_del "${2:-}" && users_apply ;;
    links)              users_links ;;
    preflight)          need_root; need_cmd curl; need_cmd jsonfilter
                        collect_creds; preflight_cloudflare ;;
    creds-status)       creds_status ;;
    forget-creds)       forget_creds ;;
    reset)              do_reset ;;
    remove)             do_remove ;;
    prepare-runtime)    need_root; prepare_runtime ;;
    reinstall-services) need_root; load_settings || die "لا يوجد تثبيت محلي."
                        # الإعداد أيضًا: ملفا الخدمة وحدهما لا يحملان تغييرات config.yml
                        write_cfd_config; write_xray_config; write_init; enable_services ;;
    version)            say "$VERSION" ;;
    help|-h|--help)     usage ;;
    *)                  err "أمر غير معروف: $1"; usage; exit 1 ;;
esac
