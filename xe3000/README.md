# XE3000 Cloudflare Full-Tunnel

مُثبّت **XE3000 Cloudflare Full-Tunnel** وسجلّ عمله، يُنزَّل مباشرة على الراوتر عبر
`raw.githubusercontent.com`. يسكن في مجلد `xe3000/` داخل مستودع `eprofdev/sub`
ولا علاقة له ببقية المستودع (مشروع v2ray-worker في الجذر).

**الجهاز المستهدف:** GL.iNet GL-XE3000 (ARM64 / OpenWrt)

---

## محتويات المستودع

| الملف | الوصف |
|---|---|
| `xe3000autouiinput.sh` | المُثبّت — ملف واحد قائم بذاته، بلا حمولة مضمّنة |
| `check-cloudflare.sh` | فحوصات Cloudflare الأربعة لتشخيص فشل الخطوة `[3/6]` |
| `xe3000-fulltunnel-worklog.md` | سجل العمل الكامل: التشخيص، الإصلاحات، مرجع الأوامر |
| `SHA256SUMS` | بصمات الملفات للتحقق بعد التنزيل |

> **تنبيه:** `xe3000autouiinput.sh` هنا **إعادة بناء** من مواصفات سجل العمل، وليس نسخة
> من المُثبّت الأصلي `2026-09-01-remember-creds` (70,612 بايت، `32bfcccf…`). البصمة
> والحجم مختلفان بالضرورة. الفرق الجوهري: هذه النسخة سكربت `sh` واحد مقروء بلا
> حمولة base64 مضمّنة، لذلك لا يلزمها أمر `extract` ولا القراءة من `$0`.

## التثبيت على الراوتر

### wget (الافتراضي على OpenWrt)

```sh
cd /root
wget -O xe3000autouiinput.sh \
  https://raw.githubusercontent.com/eprofdev/sub/main/xe3000/xe3000autouiinput.sh
wget -O check-cloudflare.sh \
  https://raw.githubusercontent.com/eprofdev/sub/main/xe3000/check-cloudflare.sh
chmod +x xe3000autouiinput.sh check-cloudflare.sh
sh xe3000autouiinput.sh
```

إن اشتكى `wget` من الشهادة (`wget: SSL support not available` أو خطأ تحقق):

```sh
opkg update && opkg install wget-ssl ca-bundle ca-certificates
```

أو استخدم `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/eprofdev/sub/main/xe3000/xe3000autouiinput.sh \
  -o /root/xe3000autouiinput.sh
```

### التحقق بعد التنزيل

```sh
wget -O /tmp/SHA256SUMS https://raw.githubusercontent.com/eprofdev/sub/main/xe3000/SHA256SUMS
cd /root && sha256sum -c /tmp/SHA256SUMS 2>/dev/null | grep -v 'No such file'
```

**تحذيرات:**

- **لا تمرّره عبر أنبوب** — استخدم `wget -O ملف` ثم `sh ملف`، لا `wget -O- … | sh`.
- **احفظه في `/root/` لا `/tmp/`** — الأخير يُمسح بإعادة التشغيل.
- لا تفتحه في Notepad على Windows؛ نهايات CRLF تعطّل السكربت. إن حدث:
  `sed -i 's/[[:cntrl:]]*$//' /root/xe3000autouiinput.sh`

### التشغيل الذاتي

`sh /root/xe3000autouiinput.sh` بلا وسائط يقرر وحده:

| الحالة المكتشفة | الإجراء |
|---|---|
| بقايا تثبيت فاشل | تنظيف تلقائي ثم متابعة التثبيت |
| بوابة مكتملة | إصلاح لوحة 9000 فقط، بكلمة المرور الحالية |
| بيانات Cloudflare محفوظة | تثبيت كامل بلا أي إدخال |
| لا شيء محفوظ + طرفية | تثبيت تفاعلي يسأل عن القيم الأربع |
| لا شيء محفوظ بلا طرفية | فتح صفحة الإعداد على `https://192.168.8.1:9000/cgi-bin/setup.cgi` |

### كلمة مرور اللوحة

عند التشغيل بلا طرفية تفاعلية (من Routine أو سكربت) ولم تُمرَّر `FULLTUNNEL_UI_PASSWORD`،
يولّد المُثبّت كلمة مرور عشوائية ويطبعها مرة واحدة بدل أن يفشل بعد اكتمال الخطوات
السابقة. غيّرها بـ `sh /root/xe3000autouiinput.sh set-password`.
لتعطيل المصادقة كليًا: `FULLTUNNEL_AUTH_ENABLED=0`.

---

## الحالة الحالية

البوابة **لم تكتمل بعد**. الفشل عند الخطوة `[3/6]` — أول نداء لـ Cloudflare API
(`POST accounts/<id>/cfd_tunnel`). كل ما قبلها يعمل: الحزم مثبتة، وبيانات
Cloudflare محفوظة في `/etc/xe3000-cf-fulltunnel-creds`.

تسلسل الأسباب كما انكشف:

1. **عطل DNS على الراوتر** — `curl (6) Could not resolve host`. أُصلح بضبط مُوجِّه DNS على WAN.
2. **توكن غير صالح** — الفحص 1 ردّ `Invalid API Token`. أُصلح بتوكن جديد عبر `set-token`.
3. **قراءة خاطئة للفحص 2** في هذا السكربت نفسه، لا في إعدادات Cloudflare.

### الفحص 2 ليس حاسمًا

`GET /accounts/<id>` يحتاج صلاحية `Account Settings · Read`، وهي **ليست** من صلاحيتي
التوكن الموصى به. سقوطه وحده طبيعي ولا يعني أن Account ID خاطئ.

الحاسم هو الفحص 4 على `/accounts/<id>/cfd_tunnel`: نجاحه يثبت أن المعرّف صحيح وأن
صلاحية الأنفاق متاحة. الحكم الآن:

| 2 | 4 | الاستنتاج |
|---|---|---|
| ✗ | ✓ | كل شيء سليم — التوكن بلا Account Settings · Read فقط |
| ✓ | ✗ | التوكن ينقصه `Account · Cloudflare Tunnel · Edit` |
| ✗ | ✗ | Account ID خاطئ أو التوكن ليس لهذا الحساب |

**الخطوة التالية:** شغّل `sh /root/check-cloudflare.sh` على الراوتر، وخصوصًا الفحص
رقم **4**. تفاصيل التشخيص في [سجل العمل](xe3000-fulltunnel-worklog.md).

التوكن الصحيح يُنشأ من My Profile ← API Tokens ← Create Token بصلاحيتين فقط:

- `Account` · `Cloudflare Tunnel` · **Edit**
- `Zone` · `DNS` · **Edit**

ثم:

```sh
sh /root/xe3000autouiinput.sh forget-creds
sh /root/xe3000autouiinput.sh install
```

المُثبّت يشغّل الفحوصات الأربعة تلقائيًا قبل إنشاء النفق، فلن تفشل الخطوة `[3/6]`
بصمت مرة أخرى — بل تطبع أي فحص سقط وسببه.

---

## الاتصال لا يعمل — أين تنقطع السلسلة؟

```sh
sh /root/xe3000autouiinput.sh selftest
```

يتتبع المسار حلقة حلقة ويتوقف أول سطر أحمر عند موضع العطل:

| الحلقة | ما تعنيه إن سقطت |
|---|---|
| 1 الخدمتان | xray أو cloudflared لا يعمل — `logread \| grep -E 'xray\|cloudflared'` |
| 2 المنفذ المحلي | xray لم يبدأ أو إعداده خاطئ |
| 3 مصافحة WS محليًا | المسار في الإعداد لا يطابق ما يستمع إليه xray |
| 4 حالة النفق | cloudflared لا يصل إلى حافة Cloudflare |
| 5 DNS | سجل CNAME مفقود أو لم ينتشر |
| 6 الطلب العام | 530 = لا اتصال نشط · 404 على المسار = تعارض path |

> **تنبيه على `logread -e xe3000`:** `-e` يرشّح بالنص، و«xe3000» لا يظهر إلا في سطور
> المسارات، فتُحجب كل سطور cloudflared المهمة. استخدم:
> `logread | grep -E 'xray|cloudflared' | tail -40`

---

## لوحة 9000 لا تفتح

```sh
sh /root/xe3000autouiinput.sh diagnose     # uhttpd، المنفذ، العملية، الجدار الناري، عنوان LAN
sh /root/xe3000autouiinput.sh repair-ui    # يعيد بناء قسم uhttpd وقاعدة الجدار ثم يعيد التشغيل
```

اللوحة لا تُنشأ إلا بعد `install` أو `ui-only` أو `bootstrap`. أشيع سببين:

- **الشهادة مفقودة** — يحتاج الربط `/etc/uhttpd.crt` و`/etc/uhttpd.key`. فعّل HTTPS من واجهة GL.iNet.
- **المنفذ مغلق في الجدار الناري** — يضيف المُثبّت قاعدة `xe3000-panel` تقبل TCP/9000 من منطقة `lan` فقط.

الربط على `192.168.8.1` حصرًا؛ السكربت يرفض `0.0.0.0` و`::`.

---

## الناقل: ws أم xhttp

```sh
xe3000 set-transport xhttp     # أو ws
```

`ws` يحتاج ترقية HTTP، و**cloudflared لا يمرّر الترقية إلى أصل من نوع `unix:`** فيردّ 502
بينما الطلبات العادية تمر. `xhttp` يستعمل HTTP عاديًا بلا ترقية فيعبر.

| الحالة | الناقل الصالح |
|---|---|
| xray على TCP (`set-listen <ip>`) | `ws` أو `xhttp` |
| xray على مقبس Unix (`set-listen unix`) | **`xhttp`** |

تبديل الناقل يغيّر روابط العملاء — أعد استيرادها بـ `xe3000 links` أو من رمز QR في اللوحة.

---

## المستخدمون والروابط ورموز QR

### لوحة 9000

`https://192.168.8.1:9443/cgi-bin/control.cgi` تعرض لكل مستخدم:

- **الرابط الكامل** جاهزًا في حقل للقراءة
- **زر نسخ** بضغطة واحدة
- **رمز QR** للرابط نفسه، مولَّد في المتصفح بلا أي CDN أو اتصال خارجي
- زر حذف، ونموذج إضافة مستخدم جديد

مولّد QR مكتوب خصيصًا لهذا المشروع ومضمَّن في الصفحة: وضع البايت، تصحيح مستوى L،
الإصدارات 1..15 (حتى 523 بايت). لا يعتمد على أي مكتبة خارجية لأن الراوتر معزول
والمتصفح قد لا يصل إلى الإنترنت.

> **المنفذان:** uhttpd لا يجمع HTTP وHTTPS على منفذ واحد، فـ **9000 مدخل HTTP يحوّل تلقائيًا**
> إلى **9443 (HTTPS)** حيث اللوحة فعليًا. اكتب `192.168.8.1:9000` في المتصفح وسيصلك التحويل.
> لتغيير منفذ HTTPS: `FULLTUNNEL_UI_PORT_HTTPS=9444 sh xe3000autouiinput.sh ui-only`

> **بعد ترقية السكربت** شغّل `sh xe3000autouiinput.sh ui-only` لتحديث صفحات اللوحة —
> الترقية لا تلمسها من تلقاء نفسها.

### قائمة SSH

```sh
menu                 # أو: xe3000 menu
```

يُثبَّت الأمران `menu` و`xe3000` في `/usr/bin` ضمن الخطوة `[6/6]`. القائمة تعطيك
الحالة، وإدارة المستخدمين، والروابط، وتشغيل/إيقاف الخدمات، والتشخيص، وتبديل التوكن،
وكلمة مرور اللوحة. إن كان `/usr/bin/menu` محجوزًا لبرنامج آخر فلن يُستبدل، ويبقى
`xe3000 menu`.

> رموز QR تظهر في اللوحة لا في الطرفية — توليدها في صدفة busybox يحتاج مولّدًا
> ثانيًا بلا مكسب حقيقي، فالقائمة تطبع الرابط والقراءة البصرية عبر اللوحة.

### من سطر الأوامر

```sh
xe3000 user-list          # عرض المستخدمين
xe3000 user-add ahmed     # إضافة، ثم إعادة توليد إعداد xray وإعادة تشغيله
xe3000 user-del ahmed     # حذف (يُرفض حذف آخر مستخدم)
xe3000 links              # طباعة روابط الاشتراك الكاملة
```

المستخدمون في `state/users.tsv` بصلاحية 600: سطر لكل مستخدم `uuid<TAB>الاسم`.
كل تعديل يعيد بناء قائمة عملاء xray ويعيد تشغيل الخدمة. الأسماء مقيّدة بـ
`A-Za-z0-9_.-` في السطر والصفحة معًا، فلا تمر عبرها أي أوامر.

---

## تشخيص فشل `[3/6]`

```sh
sh /root/check-cloudflare.sh                 # يقرأ البيانات المحفوظة
sh /root/check-cloudflare.sh <token> <account-id> <zone-id>
```

يطبع نتيجة الفحوصات الأربعة ثم خلاصة تحدد أي قيمة هي السبب. نفس الفحوصات مدمجة
في المُثبّت وتُشغَّل تلقائيًا قبل إنشاء النفق:

```sh
sh /root/xe3000autouiinput.sh preflight
```

---

## مرجع الأوامر

```sh
sh xe3000autouiinput.sh                  # تشغيل ذاتي كامل (الافتراضي)
sh xe3000autouiinput.sh install          # تثبيت يدوي من البداية
sh xe3000autouiinput.sh auto [file]      # تثبيت بلا أسئلة من ملف إعداد 600
sh xe3000autouiinput.sh bootstrap        # صفحة الإعداد العربية على LAN:9000
sh xe3000autouiinput.sh ui-only          # إعادة تثبيت لوحة 9000
sh xe3000autouiinput.sh status           # حالة البوابة والواجهة
sh xe3000autouiinput.sh diagnose         # فحص uhttpd والمنفذ 9000
sh xe3000autouiinput.sh repair-ui        # إصلاح ربط HTTPS على LAN
sh xe3000autouiinput.sh set-password     # كلمة مرور اللوحة
sh xe3000autouiinput.sh set-token        # تبديل توكن Cloudflare وحده ثم فحصه
sh xe3000autouiinput.sh selftest         # فحص السلسلة كاملة
sh xe3000autouiinput.sh menu             # قائمة تفاعلية عبر SSH
sh xe3000autouiinput.sh user-list        # عرض المستخدمين
sh xe3000autouiinput.sh user-add [اسم]   # إضافة مستخدم
sh xe3000autouiinput.sh user-del <اسم>   # حذف مستخدم
sh xe3000autouiinput.sh links            # روابط الاشتراك الكاملة
sh xe3000autouiinput.sh creds-status     # هل البيانات محفوظة
sh xe3000autouiinput.sh forget-creds     # حذفها نهائيًا
sh xe3000autouiinput.sh reset            # حذف بقايا تثبيت ناقص
sh xe3000autouiinput.sh remove           # إزالة كاملة
sh xe3000autouiinput.sh preflight        # فحوصات Cloudflare الأربعة
sh xe3000autouiinput.sh prepare-runtime  # الاعتمادات فقط
sh xe3000autouiinput.sh version          # الإصدار
sh xe3000autouiinput.sh help
```

### ملف الإعداد التلقائي

```sh
cat > /root/xe3000-fulltunnel-auto.env <<'EOF'
FULLTUNNEL_HOSTNAME=home.example.com
FULLTUNNEL_ACCOUNT_ID=...
FULLTUNNEL_ZONE_ID=...
FULLTUNNEL_API_TOKEN=...
EOF
chmod 600 /root/xe3000-fulltunnel-auto.env
sed -n l /root/xe3000-fulltunnel-auto.env   # كل سطر ينتهي بـ $ بلا \r ولا مسافة
sh /root/xe3000autouiinput.sh auto
```

بلا مسافات حول `=`، بلا علامات اقتباس، والصلاحية 600 أو 400 بالضبط.

---

## إصدارات المُثبّت

| الإصدار | SHA-256 | الحجم |
|---|---|---|
| `2026-08-26-unattended-auto-install` | `dc995c3d…` | 59,681 |
| `2026-09-01-fix-prompts-reset` | `58bbf79e…` | 65,550 |
| `2026-09-01-full-auto` | `062e0f43…` | 67,526 |
| **`2026-09-01-remember-creds`** | **`32bfcccf…`** | **70,612** |
| `2026-09-12-single-file` (هذا المستودع) | انظر `SHA256SUMS` | — |

البصمات الكاملة في [سجل العمل](xe3000-fulltunnel-worklog.md#5-الإصدارات-وبصماتها).

---

## الفحص الآلي

`.github/workflows/verify.yml` يعمل عند كل دفعة تمسّ `xe3000/` ويتحقق من:

- صحة صياغة الملفين تحت `sh` و`dash`
- صحة صياغة `control.cgi` المولَّد
- أن اللوحة لا تعكس مدخل `action` في HTML
- تطابق `SHA256SUMS` مع الملفات الفعلية
- `shellcheck` (إرشادي، لا يُفشل الفحص)

---

## أمان

- **لا ترفع أسرارًا إلى هذا المستودع.** لا `api-token`، ولا `account-id`، ولا `zone-id`،
  ولا نسخة من `/root/xe3000-fulltunnel-auto.env` أو `/etc/xe3000-cf-fulltunnel-creds/`.
- لوحة التحكم محلية فقط على `192.168.8.1:9000`. لا تنشئ لها Port Forwarding
  ولا public hostname.
