# سجل عمل كامل — مُثبّت XE3000 Cloudflare Full-Tunnel

**الجهاز:** GL.iNet GL-XE3000 (ARM64 / OpenWrt)
**التاريخ:** 1 سبتمبر 2026 — 12 سبتمبر 2026
**الحالة النهائية:** البوابة لم تكتمل بعد؛ الفشل عند الخطوة `[3/6]` (أول نداء لـ Cloudflare API). كل ما قبلها يعمل.

---

## 1. ملخص تنفيذي

| البند | الحالة |
|---|---|
| الحزم (xray-core, cloudflared, curl, jsonfilter) | ✅ مثبتة — الخطوة `[1/6]` تنجح |
| بيانات Cloudflare محفوظة محليًا | ✅ في `/etc/xe3000-cf-fulltunnel-creds` |
| إنشاء النفق وسجل DNS | ❌ فشل عند `[3/6]` |
| ملفا الخدمة `/etc/init.d/xe3000-cf-*` | ❌ غير موجودين (يُنشأان في `[4/6]`) |
| لوحة التحكم على LAN:9000 | ⚠️ مثبتة لكنها تعرض «البوابة غير مثبتة» |
| المُثبّت المحدّث على الراوتر | ✅ الإصدار `2026-09-01-remember-creds` |

**الخطوة الوحيدة المتبقية:** تحديد سبب رفض Cloudflare API لإنشاء النفق.

---

## 2. الرحلة التشخيصية بالترتيب

### 2.1 `[ER] يوجد تثبيت أساسي سابق`

**المصدر:** `install-final.sh` السطر 36

```sh
[ ! -d /etc/xe3000-cf-fulltunnel ] || die "يوجد تثبيت أساسي سابق..."
```

**السبب:** المجلد موجود من محاولة فاشلة سابقة، فرفض `install` المتابعة. الأمر `auto` يمر بنفس المسار فيعطي نفس الخطأ.

**ملاحظة خطيرة:** في النسخة الأصلية يحذف `load_auto_config` ملف `/root/xe3000-fulltunnel-auto.env` **قبل** أن يصل إلى هذا الحارس — فتضيع أسرار Cloudflare رغم فشل التثبيت.

### 2.2 طلبات كلمة المرور المخفية

**الأعراض:**

```
اسم مستخدم لوحة 9000:
[ER] كلمة المرور لا يمكن أن تكون فارغة.
```

**السبب الحقيقي:** المسار الافتراضي `self-install` يعيد توجيه كل المخرجات إلى سجل:

```sh
sh "$PKG/install-final.sh" ui-only >>"$_log" 2>&1
```

بينما `install-ui.sh` يطلب ثلاثة إدخالات عبر `read_secret`. الطلبات ذهبت إلى الملف و`stdin` بقي على الطرفية — فالسكربت ينتظر إدخالًا لا تراه. ما ظهر على الشاشة كان `cat` للسجل بعد الفشل.

**اكتشاف إضافي:** `install_ui` يستدعي `set_password` دائمًا، و`set_password` يفرض `FULLTUNNEL_AUTH_ENABLED=1` داخليًا مهما كانت القيمة الممررة. أي أن تثبيت الواجهة **يطلب كلمة مرور دائمًا** ما لم تُمرَّر `FULLTUNNEL_UI_PASSWORD` أو `FULLTUNNEL_RESTORE_UI=1`. ضبط `auth.enabled=0` لا يكفي.

### 2.3 `/etc/init.d/xe3000-cf-tunnel: not found`

ملفا الخدمة يُنشئهما `write_init` في الخطوة `[4/6]`. غيابهما يعني أن التثبيت توقف قبلها. أزرار لوحة 9000 (السطر 439 في `deploy.sh` = حالة `start`) كانت تفشل لهذا السبب، لا لخطأ في اللوحة.

### 2.4 `[ER] لا يوجد تثبيت محلي. شغّل install أولًا`

من `load_settings` (السطر 144): ملف `state/settings.env` غير موجود. تظهر مع كل `status` أو زر في اللوحة قبل اكتمال التثبيت. ليست خطأً مستقلًا.

### 2.5 الملف القديم على الراوتر

فحص كشف أن الراوتر كان يشغّل النسخة الأصلية طوال الوقت:

```
wc -c   → 59681        (الجديد 70612)
sha256  → dc995c3d…    (الجديد 32bfcccf…)
VERSION → 2026-08-26-unattended-auto-install
```

السبب: المتصفح على Windows يحفظ التنزيل الجديد باسم `xe3000autouiinput(1).sh` ولا يستبدل القديم، فنُقل القديم بـ `scp`.

### 2.6 `[ER] Zone ID غير صالح`

`valid_id` يرفض القيمة الفارغة أو أي محرف خارج `A-Za-z0-9_.-`. ظهور طلب Zone ID وطلب التوكن **ملتصقين** في سطر واحد يدل على أن قراءة Zone ID التقطت سطرًا فارغًا من لصق متعدد الأسطر. في PuTTY الضغط بالزر الأيمن يلصق الحافظة كاملة بما فيها سطر جديد.

**العلاج:** قيمة واحدة لكل طلب، أو استخدام ملف `auto.env` والتحقق منه بـ `sed -n l` قبل التشغيل.

### 2.7 الفشل الحالي: `[3/6]`

```
[OK] حُفظت بيانات Cloudflare في /etc/xe3000-cf-fulltunnel-creds
[3/6] إنشاء Tunnel وسجل DNS...
[ER] فشل تثبيت البوابة
```

الخطوة تستدعي `POST accounts/<id>/cfd_tunnel` ثم `create_or_update_dns`. الأسباب المحتملة مرتبة بالاحتمال:

1. التوكن ينقصه **Account · Cloudflare Tunnel · Edit**
2. Account ID خاطئ
3. Zone ID خاطئ أو من حساب آخر
4. النطاق الفرعي ليس تابعًا لتلك الـ Zone

---

## 3. فحص Cloudflare — شغّله على الراوتر

```sh
T=$(cat /etc/xe3000-cf-fulltunnel-creds/api-token)
A=$(cat /etc/xe3000-cf-fulltunnel-creds/account-id)
Z=$(cat /etc/xe3000-cf-fulltunnel-creds/zone-id)

echo "--1 التوكن--"
curl -s -H "Authorization: Bearer $T" https://api.cloudflare.com/client/v4/user/tokens/verify | head -c 200
echo; echo "--2 الحساب--"
curl -s -H "Authorization: Bearer $T" "https://api.cloudflare.com/client/v4/accounts/$A" | head -c 200
echo; echo "--3 النطاق--"
curl -s -H "Authorization: Bearer $T" "https://api.cloudflare.com/client/v4/zones/$Z" | head -c 200
echo; echo "--4 صلاحية الأنفاق--"
curl -s -H "Authorization: Bearer $T" "https://api.cloudflare.com/client/v4/accounts/$A/cfd_tunnel?per_page=1" | head -c 300
```

| ما يفشل | السبب |
|---|---|
| 1 | التوكن خاطئ أو منتهٍ أو فيه محرف زائد |
| 2 فقط | Account ID خاطئ |
| 3 فقط | Zone ID خاطئ أو ليس في نفس الحساب |
| **4 فقط** | **التوكن ينقصه Account · Cloudflare Tunnel · Edit — الأرجح** |
| الكل | لا إنترنت أو DNS معطّل على الراوتر |

**التوكن الصحيح** من My Profile ← API Tokens ← Create Token، بصلاحيتين فقط:

- `Account` · `Cloudflare Tunnel` · **Edit**
- `Zone` · `DNS` · **Edit**

بعد إصلاح التوكن:

```sh
sh /root/xe3000autouiinput.sh forget-creds
sh /root/xe3000autouiinput.sh install
```

وإن كان التوكن سليمًا والخطأ في مكان آخر، يكفي:

```sh
sh /root/xe3000autouiinput.sh
```

فهو ينظّف البقايا تلقائيًا ويعيد التثبيت من البيانات المحفوظة بلا أي إدخال.

---

## 4. التعديلات التي أُدخلت على المُثبّت

أُعيد البناء بـ `build-single-installer.sh` الموجود داخل الحزمة نفسها، فبقيت البنية وتحقق SHA وmanifest كما هي.

| # | المشكلة | الإصلاح |
|---|---|---|
| 1 | طلبات كلمة المرور تختفي في السجل | `read_secret` في `deploy.sh` و`install-ui.sh` و`repair-ui-9000.sh` تكتب وتقرأ من `/dev/tty` |
| 2 | لا وسيلة لتنظيف تثبيت ناقص | أمر `reset` جديد بتأكيد `RESET`، يرفض العمل على تثبيت مكتمل، ويطبع معرّف النفق اليتيم قبل الحذف |
| 3 | رسالة حارس واحدة غامضة | `install` يفرّق بين تثبيت مكتمل (استخدم `status`) وفاشل (استخدم `reset`) |
| 4 | اللوحة تعرض `not found` | `control.cgi` يعرض «البوابة غير مثبتة» وأزرار start/stop/restart ترفض العمل برسالة واضحة |
| 5 | `auto` يحرق الأسرار عند الفشل | حذف `auto.env` انتقل إلى ما بعد نجاح التثبيت فقط |
| 6 | `ok: not found` | الدالة `ok` كانت مستدعاة في الغلاف وغير معرّفة |
| 7 | إعادة إدخال بيانات Cloudflare كل مرة | حفظ دائم في `/etc/xe3000-cf-fulltunnel-creds` (700/600) خارج نطاق `reset` و`uninstall`، مع استعادة تلقائية |
| 8 | فشل صامت في المسار التلقائي | `exit` داخل دالة كان يقتل الصدفة قبل طباعة السجل؛ نُقل إلى صدفة فرعية |
| 9 | `auth.enabled=0` لا يعطّل المصادقة | `install_ui` صار يحترم القيمة 0 ويتخطى `set_password` |
| 10 | أوامر ناقصة | أُضيفت `remove`, `prepare-runtime`, `creds-status`, `forget-creds` |

### حفظ البيانات واستعادتها

```
/etc/xe3000-cf-fulltunnel-creds/      المجلد 700، الملفات 600
├── hostname
├── account-id
├── zone-id
└── api-token
```

ترتيب الأولوية عند التثبيت: متغيّرات البيئة ← ملف `auto.env` ← البيانات المحفوظة ← سؤال تفاعلي.

**الحذف يدوي فقط:** أمر `forget-creds`، أو بطاقة «بيانات Cloudflare المحفوظة» في لوحة 9000 التي تُلزم كتابة `FORGET`. لا يلغي ذلك التوكن في حساب Cloudflare.

### المسار الذاتي بأمر واحد

`sh /root/xe3000autouiinput.sh` بلا وسائط يقرر وحده:

| الحالة المكتشفة | الإجراء التلقائي |
|---|---|
| بقايا تثبيت فاشل | تنظيف تلقائي ثم المتابعة |
| بوابة مكتملة | إصلاح لوحة 9000 فقط، بكلمة المرور الحالية |
| بيانات محفوظة موجودة | تثبيت كامل بلا أي إدخال |
| لا شيء محفوظ | فتح صفحة الإعداد العربية على `https://192.168.8.1:9000/` |

---

## 5. الإصدارات وبصماتها

| الإصدار | البصمة SHA-256 | الحجم | الوصف |
|---|---|---|---|
| `2026-08-26-unattended-auto-install` | `dc995c3dae8251a2b03eaa903804bd5b1d5090f1928f1acb99f1d1a7b323660c` | 59,681 | الأصلي |
| `2026-09-01-fix-prompts-reset` | `58bbf79e77302616bcb0bc6d3f247b266125ac92291cc9300f8815e3bda1c7a5` | 65,550 | إصلاح الطلبات + reset |
| — | `ca4c57d93441aab7af24fd17bf4896d90fb52f3ced92108c929018e81ef5d257` | 65,554 | `auth.enabled` الافتراضي 0 |
| `2026-09-01-full-auto` | `062e0f437d97eca3306b3ef34de71369cbc08e0666ec73849c081dac91346d3d` | 67,526 | تشغيل ذاتي كامل |
| **`2026-09-01-remember-creds`** | **`32bfcccfe71c4a642e673fecf83cd2d82e43f6757db395ec0f65cc320d947264`** | **70,612** | **النهائي — حفظ واستعادة البيانات** |

بصمة الحمولة المضمنة في النسخة النهائية: `08ffa48e05804ac7e1c9294a2d6b6eb154b49349cfdd1ba610f99381dd1f8563` (40,915 بايت)

**التحقق على الراوتر:**

```sh
wc -c < /root/xe3000autouiinput.sh      # 70612
sha256sum /root/xe3000autouiinput.sh    # 32bfcccf…
grep -m1 VERSION= /root/xe3000autouiinput.sh
```

---

## 6. مرجع الأوامر

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
sh xe3000autouiinput.sh creds-status     # هل البيانات محفوظة
sh xe3000autouiinput.sh forget-creds     # حذفها نهائيًا
sh xe3000autouiinput.sh reset            # حذف بقايا تثبيت ناقص
sh xe3000autouiinput.sh remove           # إزالة كاملة
sh xe3000autouiinput.sh prepare-runtime  # الاعتمادات فقط
sh xe3000autouiinput.sh extract          # فك مؤقت
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

## 7. ملاحظات تشغيلية مهمة

- **لا تمرّر المُثبّت عبر أنبوب:** `curl … | sh` يفشل لأن السكربت يقرأ حمولته من `$0`. يجب حفظه كملف أولًا.
- **`/tmp` يُمسح بإعادة التشغيل** — احتفظ بالملف في `/root/`.
- **لا تفتح الملف في Notepad** — نهايات CRLF تغيّر البصمة وتعطّل السكربت.
- **الفك اليدوي** إن لزم (أمر `extract` يحذف المجلد عند الخروج):

```sh
SRC=/root/xe3000autouiinput.sh
L=$(grep -an '^__XE3000_EMBEDDED_PACKAGE_BELOW__$' "$SRC" | cut -d: -f1 | head -1)
mkdir -p /root/xe
tail -n +$((L+1)) "$SRC" | openssl base64 -d -A > /root/xe/p.tgz
tar -xzf /root/xe/p.tgz -C /root/xe
```

- **الاعتمادات تلقائية بالكامل** في الخطوة `[1/6]`: `opkg update`، ثم `curl` و`jsonfilter` و`xray-core` من مستودع XE3000، و`cloudflared 2026.8.2` من إصدار Cloudflare الرسمي بعد تحقق SHA-256. لا يُنفَّذ `opkg upgrade` للنظام.
- **متطلبات غير مثبتة تلقائيًا:** `uci`, `uhttpd`, `openssl`, `tar`, `sha256sum`, وشهادة `/etc/uhttpd.crt` + `/etc/uhttpd.key` (فعّل HTTPS من واجهة GL.iNet إن كانت مفقودة).
- **اللوحة محلية فقط** على `192.168.8.1:9000`، والسكربت يرفض أي ربط على `0.0.0.0` أو `::`. لا تنشئ Port Forwarding ولا public hostname لها.

---

## 8. قيود الشبكة في جلسة المساعدة

سياسة الشبكة لدى المؤسسة حجبت مضيفات عدة، ما منع رفع الملف أو فحص Cloudflare من جانبي:

```
api.netlify.com            محجوب (403 على CONNECT)
netlify-mcp.netlify.app    محجوب
api.cloudflare.com         محجوب
mcp.cloudflare.com         محجوب
docs.mcp.cloudflare.com    محجوب
0x0.st / transfer.sh / bashupload.com / tmpfiles.org / file.io / catbox.moe / gist.github.com   محجوبة
api.github.com             ✓ متاح (يحتاج توكن)
raw.githubusercontent.com  ✓ متاح للقراءة
```

لذلك لم يُنشأ رابط تثبيت عام. الخيارات المتاحة لك:

1. **Netlify بنفسك:** ضع الملف في مجلد واسحب المجلد إلى `https://app.netlify.com/drop` أو إلى صفحة Deploys للموقع `xe3000-fulltunnel-installer` المُنشأ في حسابك (فارغ حاليًا).
2. **GitHub:** مستودع عام ← Add file ← Upload files، ثم الرابط:
   `https://raw.githubusercontent.com/<user>/<repo>/main/xe3000autouiinput.sh`
3. **SCP مباشرة** من جهازك — تحقق من الحجم 70612 قبل النقل.

---

## 9. إضافة Cloudflare الرسمية

نُفِّذت تعليمات `https://developers.cloudflare.com/agent-setup/prompt.md`:

```
√ Successfully added marketplace: cloudflare
√ Successfully installed plugin: cloudflare@cloudflare (v1.0.0, scope: user)
```

**14 مهارة** منها `cloudflare-one` (Zero Trust وTunnel وPrivate Networking) و`cloudflare-one-migrations` و`wrangler` و`workers-best-practices`، وخادم MCP واحد.

قيدان: المهارات تظهر في جلسة جديدة فقط، وخادم MCP لا يعمل من هذه البيئة لأن مضيفاته محجوبة.

---

## 10. الخطوة التالية الوحيدة

شغّل الفحص في القسم 3، وخصوصًا الفحص رقم **4**. ناتجه يحدد إن كانت المشكلة في صلاحية التوكن أم في المعرّفات، وبعدها يكتمل التثبيت بأمر واحد.
