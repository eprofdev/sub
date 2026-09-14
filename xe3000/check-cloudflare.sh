#!/bin/sh
# فحوصات Cloudflare الأربعة — القسم 3 من سجل العمل.
# يُشغَّل على الراوتر لتحديد سبب فشل الخطوة [3/6].
#   sh check-cloudflare.sh                 # يقرأ البيانات المحفوظة
#   sh check-cloudflare.sh <token> <account> <zone>
set -u

CREDS=/etc/xe3000-cf-fulltunnel-creds
API=https://api.cloudflare.com/client/v4

if [ $# -ge 3 ]; then
    T=$1; A=$2; Z=$3
elif [ -s "$CREDS/api-token" ]; then
    T=$(cat "$CREDS/api-token")
    A=$(cat "$CREDS/account-id")
    Z=$(cat "$CREDS/zone-id")
else
    echo "[ER] لا توجد بيانات محفوظة في $CREDS" >&2
    echo "الاستخدام: sh $0 <api-token> <account-id> <zone-id>" >&2
    exit 1
fi

command -v curl >/dev/null 2>&1 || { echo "[ER] curl غير مثبت: opkg install curl" >&2; exit 1; }

get() { curl -sS --max-time 30 -H "Authorization: Bearer $T" "$API$1" 2>&1; }
okjson() { printf '%s' "$1" | grep -q '"success":[[:space:]]*true'; }

RESULT=
REACHED=0          # 1 إذا ردّ Cloudflare بجسم JSON ولو مرة واحدة

check() { # $1 رقم، $2 وصف، $3 مسار
    printf -- '--%s %s--\n' "$1" "$2"
    _r=$(get "$3")
    printf '%s\n' "$_r" | head -c 300; echo
    # ردّ Cloudflare يحوي دائمًا "success" — غيابه يعني أن الطلب لم يصل أصلًا
    case "$_r" in
        *'"success"'*) REACHED=1 ;;
    esac
    if okjson "$_r"; then
        echo "[OK] نجح"
        RESULT="$RESULT$1:ok "
    else
        echo "[ER] فشل"
        RESULT="$RESULT$1:fail "
    fi
    echo
}

check 1 "التوكن"          "/user/tokens/verify"
check 2 "الحساب"          "/accounts/$A"
check 3 "النطاق"          "/zones/$Z"
check 4 "صلاحية الأنفاق"  "/accounts/$A/cfd_tunnel?per_page=1"

echo "================ الخلاصة ================"
echo "$RESULT"

if [ "$REACHED" = 0 ]; then
    echo "لم يصل أي طلب إلى api.cloudflare.com → لا إنترنت أو DNS معطّل على الراوتر."
    echo "جرّب: ping -c1 1.1.1.1   ثم   nslookup api.cloudflare.com"
    exit 1
fi

# وصلت الطلبات وردّ Cloudflare — إذًا السبب في القيم أو الصلاحيات لا في الشبكة.
# الفحص 2 يحتاج Account Settings · Read وهي ليست من صلاحيات التوكن الموصى به،
# فسقوطه وحده لا يدل على شيء. الحاسم للحساب هو الفحص 4.
case "$RESULT" in
    *1:fail*)
        echo "الفحص 1 فشل → التوكن خاطئ أو منتهٍ أو فيه محرف زائد."
        echo "أنشئ توكنًا جديدًا، ثم: sh /root/xe3000autouiinput.sh set-token"
        exit 1 ;;
esac

case "$RESULT" in
    *3:fail*)
        echo "الفحص 3 فشل → Zone ID خاطئ أو ليس في نفس الحساب."
        ZONEBAD=1 ;;
    *) ZONEBAD=0 ;;
esac

case "$RESULT" in
    *4:fail*)
        case "$RESULT" in
            *2:ok*)
                echo "الفحص 4 فشل والحساب مقروء → التوكن ينقصه: Account · Cloudflare Tunnel · Edit" ;;
            *)
                echo "الفحصان 2 و 4 فشلا → Account ID خاطئ، أو التوكن ليس لهذا الحساب."
                echo "انسخ Account ID من الشريط الجانبي في لوحة Cloudflare." ;;
        esac
        echo "التوكن الصحيح بصلاحيتين فقط:"
        echo "  Account · Cloudflare Tunnel · Edit"
        echo "  Zone    · DNS             · Edit"
        exit 1 ;;
esac

[ "$ZONEBAD" = 1 ] && exit 1

echo "التوكن والحساب والنطاق وصلاحية الأنفاق كلها سليمة."
case "$RESULT" in
    *2:fail*)
        echo "(الفحص 2 سقط لأن التوكن بلا Account Settings · Read — غير مطلوبة.)" ;;
esac
echo "أكمل التثبيت: sh /root/xe3000autouiinput.sh"
exit 0
