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
| بوابة مكتملة | إصلاح لوحة 9000 فقط، بحالة الحماية الحالية |
| بيانات Cloudflare محفوظة | تثبيت كامل بلا أي إدخال |
| لا شيء محفوظ + طرفية | تثبيت تفاعلي يسأل عن القيم الأربع |
| لا شيء محفوظ بلا طرفية | فتح صفحة الإعداد على `https://192.168.8.1:9000/cgi-bin/setup.cgi` |

### حماية اللوحة

**معطّلة افتراضيًا:** بعد التثبيت تُفتح اللوحة مباشرة من شبكتك المحلية بلا اسم
مستخدم ولا كلمة مرور. الجدار الناري يقصر المنفذ على `lan` فلا يصلها أحد من
الإنترنت، لكن **أي جهاز على شبكتك يرى روابط الاشتراك ويديرها**.

```sh
sh /root/xe3000autouiinput.sh auth status   # مفعّلة أم لا
sh /root/xe3000autouiinput.sh auth off      # فتحها بلا بيانات دخول
sh /root/xe3000autouiinput.sh auth on       # تفعيلها: يسأل عن الاسم والكلمة
```

`auth on` يقبل القيم من البيئة أيضًا: `FULLTUNNEL_UI_USER` و`FULLTUNNEL_UI_PASSWORD`،
وبلا طرفية تفاعلية يولّد كلمة مرور عشوائية ويطبعها مرة واحدة. و`FULLTUNNEL_AUTH_ENABLED=1`
عند التثبيت يجعل اللوحة محميّة من أول لحظة.

التعطيل يحذف `ui/httpd.conf` **ويحذف خيار `config` من قسم uhttpd في uci** — الملف
وحده لا يكفي، فبقاء الخيار يجعل uhttpd يطلب مصادقة على ملف محذوف.

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
وحماية اللوحة. إن كان `/usr/bin/menu` محجوزًا لبرنامج آخر فلن يُستبدل، ويبقى
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

المستخدمون في `state/users.tsv` بصلاحية 600: سطر لكل مستخدم
`uuid<TAB>الاسم<TAB>كلمة مرور trojan`. المعرّف يخدم vless وكلمة المرور تخدم
trojan، وهما **مستقلّان**: كشف أحدهما لا يسلّم الآخر. تثبيت بالمخطّط القديم
(عمودان) يُرقّى تلقائيًا عند أول نداء — تُضاف كلمة مرور لكل مستخدم
**والمعرّفات لا تُمسّ**، فروابط vless القائمة تبقى صالحة.

كل تعديل يعيد بناء قائمة عملاء xray ويعيد تشغيل الخدمة. الأسماء مقيّدة بـ
`A-Za-z0-9_.-` في السطر والصفحة معًا، فلا تمر عبرها أي أوامر.

### البروتوكولان معًا

`vless` و`trojan` يعملان في وقت واحد، لكل واحد **منفذه ومساره**، وتفصل بينهما
حافة Cloudflare بالمسار. تعطيل بروتوكول يحذف مدخله في xray وقواعده في
`ingress` **ولا يمسّ قائمة المستخدمين** — من عُطّل بروتوكوله يبقى مستخدمًا
بمعرّفه وكلمة مروره، ويعود بمجرّد إعادة التفعيل.

```sh
xe3000 proto-list              # البروتوكولات ومساراتها وأصولها
xe3000 proto-enable trojan     # يعمل مع vless لا بدلًا منه
xe3000 proto-disable vless     # trojan وحده (يُرفض تعطيل آخر بروتوكول)
xe3000 set-protocol vless      # قصر العمل على واحد — يُعطّل الآخر
```

`links` يطبع رابطًا لكل (مستخدم × مضيف × بروتوكول)، ويحمل وسم كل رابط المضيف
والبروتوكول حين يتعدّدان حتى لا تتشابه الروابط في تطبيق العميل.

### عدّة نطاقات على نفق واحد

نفق واحد يخدم أكثر من نطاق: قاعدة `ingress` لكل مضيف، وسجل CNAME في كل نطاق
يشير إلى `<TUNNEL_ID>.cfargotunnel.com`. الفائدة توزيع الخطر — حجب نطاق عند
مزوّد الشبكة لا يسقط البقية، ويختار العميل الرابط الذي يعمل في شبكته.

```sh
xe3000 host-list                            # المضيفون ونطاقاتهم
xe3000 host-add static.b.net                # يستدلّ على Zone ID من اسم النطاق
xe3000 host-add static.b.net <zone-id>      # أو مرّره صراحةً
xe3000 host-del static.b.net                # (يُرفض حذف آخر مضيف)
```

المضيفون في `state/hosts.tsv` بصلاحية 600: سطر لكل مضيف
`المضيف<TAB>معرّف النطاق`. `host-add` يتحقّق من تبعية المضيف لنطاقه، ينشئ
سجل CNAME، **ويتراجع عن الإضافة إن فشل السجل** فلا يبقى مضيف بلا DNS.
`set-hostname` يبدّل المضيف الأوّل وحده؛ البقية يديرها `host-add`/`host-del`.

**توكن لكل نطاق:** التوكن العام يكفي إن كانت له صلاحية `Zone · DNS · Edit`
على كل النطاقات. وللتضييق، أعطِ كل نطاق توكنه الخاص:

```sh
xe3000 set-zone-token <zone-id>        # يسأل عن التوكن ويتحقّق منه قبل الحفظ
xe3000 set-zone-token <zone-id> off    # العودة إلى التوكن العام
```

يُحفظ في `/etc/xe3000-cf-fulltunnel-creds/zone-token-<zone-id>` بصلاحية 600.
سحب توكن نطاق واحد لا يعطّل بقية النطاقات.

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

### سياسة VPN تبتلع مرور الراوتر — `ping` ينجح وDNS يفشل

على GL.iNet، الملف `/usr/bin/rtp2.sh` (عبر `firewall.vpnclient`) يبني سياسة توجيه
تدفع **كل ما ينشئه الراوتر** إلى الجدول `2022`، ومساره الافتراضي عبر `tun0`. إن كان
النفق ساقطًا ضاعت الحزم، أو ابتلعتها قاعدة `blackhole` عند الأولوية 9910.

العرَض مميّز: `ping 1.1.1.1` ينجح، بينما `nslookup` يعطي مهلة و`wget` يعطي
`Failed to send request: Operation not permitted`. المشكلة في **التوجيه** لا في
الجدار الناري — `iptables -t filter -L OUTPUT` يكون نظيفًا.

```sh
ip rule                      # ابحث عن blackhole عند 9910 و9920
ip route show table 2022     # default via ... dev tun0
wg show                      # فارغ ⇦ النفق ليس WireGuard بل OpenVPN
```

العلاج:

```sh
sh /root/xe3000autouiinput.sh vpn-bypass auto        # الموصى به
sh /root/xe3000autouiinput.sh vpn-bypass auto 5      # المراجعة كل 5 دقائق (الافتراضي 2)
```

**الوضع التلقائي يفضّل الـ VPN:** حين يكون النفق العام لا يصل إلى Cloudflare
إلا عبر الـ VPN، فالمطلوب أن يسلك المرور الـ VPN. لكن حياة الـ VPN ليست حكمًا
كافيًا — قد يردّ على `ping` بينما يقطع مصافحة TLS مع الحافة على 7844
(`connection reset`). لذلك الحكم على ما يهم فعلًا: **عدد وصلات cloudflared
النشطة**، يقرأه من `/ready` على `127.0.0.1:20241`.

| الحالة | ما يفعله |
|---|---|
| على الـ VPN والنفق قائم | **لا شيء** — هذا هو المطلوب |
| على الـ VPN والنفق لا يقوم | يتجاوزه، يعيد تشغيل cloudflared، ويتحقق |
| متجاوز والنفق قائم | يعود لتجربة الـ VPN كل نصف ساعة؛ نجح بقي عليه، فشل رجع |
| متجاوز ولا يقوم | يجرّب الـ VPN فورًا — فربما عاد |

الملف المولَّد يُستدعى من مكانين: `include` الجدار الناري بلا وسيط، فيعيد آخر
قرار **فورًا** (لا ينتظر شيئًا، فلا يعطّل إعادة تحميل الجدار، وهذا ما يُرجع
قواعد DNS بعد الإقلاع قبل أن تبدأ الخدمة)، و`cron` بـ `probe` كل خمس دقائق
فيقيس ويقرّر. كل تبديل يُسجَّل في `logread -e xe3000`.

### حافة Cloudflare تقطع المصافحة على 7844

`logread -e cloudflared` يُظهر:

```
TLS handshake with edge error: read tcp 172.19.0.1:57792->198.41.192.47:7844:
read: connection reset by peer
```

الحزم تصل إلى الحافة ثم يقطعها شيء في الطريق — ليست مهلة ولا خطأ توجيه. عنوان
المصدر يقول أي مسار سلكته: عنوان النفق (مثل `172.19.0.1`) يعني عبر الـ VPN،
وعنوان الواجهة الخارجية يعني مباشرة.

جرّب المسار الآخر أولًا: `vpn-bypass on` يُخرج 7844 مباشرة، و`off` يعيده إلى
الـ VPN. فإن قُطع في الحالتين فبدّل بروتوكول الوصلة — بعض الشبكات تقطع
7844/TCP وتمرّر 7844/UDP أو العكس:

```sh
sh /root/xe3000autouiinput.sh set-edge-protocol quic     # UDP 7844
sh /root/xe3000autouiinput.sh set-edge-protocol http2    # TCP 7844 (الافتراضي)
sh /root/xe3000autouiinput.sh set-edge-protocol auto     # اترك الاختيار لـ cloudflared
sleep 20; logread -e cloudflared | tail -12
```

`Registered tunnel connection` تعني أن الوصلة قامت. القيمة تُحفظ في
`settings.env` ولا تمسّ النفق ولا المسار ولا المستخدمين.

| الوضع | متى |
|---|---|
| `auto` | الافتراضي — الـ VPN مفضّل، والتجاوز عند فشل النفق عبره |
| `on` | تجاوز دائم؛ لن يسلك المرور الـ VPN حتى وهو يعمل |
| `off` | بلا تجاوز إطلاقًا — كل شيء عبر سياسة الـ VPN |
| `status` | الوضع وحالة المسار وعدد القواعد وجدولة المراجعة |

العلامة `0x8000` تلتقطها قاعدة `ip rule` ذات الأولوية 6000 فتذهب الحزمة إلى
الجدول `main` مباشرة عبر منفذ الإنترنت.

**لا يمسّ كِل‑سويتش أجهزتك:** سلسلة `mangle/OUTPUT` لا ترى إلا ما ينشئه الراوتر؛
مرور أجهزة شبكتك يمرّ بـ `FORWARD` ويبقى محكومًا بالسياسة كما هو.

### اختيار اسم المضيف

```sh
sh /root/xe3000autouiinput.sh set-hostname cdn.example.com
sh /root/xe3000autouiinput.sh set-hostname           # يسأل تفاعليًا
```

الاسم هو ما يظهر في SNI على الشبكة، فاختياره يغيّر ما يراه الفاحص. ينشئ سجل
CNAME جديدًا يشير إلى النفق نفسه، ويحدّث الإعداد ويعيد تشغيل cloudflared،
**ولا يلمس النفق ولا المسار ولا المستخدمين** — تتغيّر روابط العملاء فقط لأن
المضيف فيها تغيّر، فأعد استيرادها. السجل القديم يبقى، فاحذفه من لوحة Cloudflare
إن لم تعد تحتاجه.

الاسم يجب أن يكون داخل نطاق المضيف الأوّل؛ ما عداه يُرفض قبل أي تغيير.
لإضافة مضيف في نطاق **آخر** استعمل `host-add` لا `set-hostname`.

> **حدّ مهم في الشهادة المجانية:** على إعداد full تغطي شهادة Universal SSL
> النطاق والمستوى الأول فقط — `cdn.example.com` مغطّى، أما
> `youtube.com.example.com` فمستوى **ثانٍ** ولا تغطيه، فتفشل مصافحة TLS بخطأ
> شهادة. يحتاج Advanced Certificate Manager أو Total TLS (كلاهما مدفوع)، أو
> إعداد partial (CNAME) حيث تُصدر شهادة لكل مضيف مهما كان عمقه.
> الأمر يحذّرك ويطلب تأكيدًا قبل المتابعة على اسم من المستوى الثاني.

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
sh xe3000autouiinput.sh auth off         # اللوحة بلا اسم مستخدم وكلمة مرور
sh xe3000autouiinput.sh auth on          # تفعيل حماية اللوحة
sh xe3000autouiinput.sh set-password     # كلمة مرور اللوحة
sh xe3000autouiinput.sh set-token        # تبديل توكن Cloudflare وحده ثم فحصه
sh xe3000autouiinput.sh selftest         # فحص السلسلة كاملة
sh xe3000autouiinput.sh menu             # قائمة تفاعلية عبر SSH
sh xe3000autouiinput.sh user-list        # عرض المستخدمين
sh xe3000autouiinput.sh user-add [اسم]   # إضافة مستخدم
sh xe3000autouiinput.sh user-del <اسم>   # حذف مستخدم
sh xe3000autouiinput.sh links            # روابط الاشتراك الكاملة
sh xe3000autouiinput.sh host-list        # المضيفون ونطاقاتهم
sh xe3000autouiinput.sh host-add <مضيف> [zone-id]  # نطاق آخر على النفق نفسه
sh xe3000autouiinput.sh host-del <مضيف>  # إزالة مضيف
sh xe3000autouiinput.sh set-zone-token <zone-id> [off]  # توكن خاص بنطاق
sh xe3000autouiinput.sh proto-list       # البروتوكولات ومساراتها
sh xe3000autouiinput.sh proto-enable <vless|trojan>   # تفعيله مع الآخر
sh xe3000autouiinput.sh proto-disable <vless|trojan>  # تعطيله
sh xe3000autouiinput.sh set-protocol <vless|trojan>   # قصر العمل على واحد
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
| `2026-09-12-single-file` | انظر سجل العمل | — |
| **`2026-09-16-multi-host`** (هذا المستودع) | انظر `SHA256SUMS` | — |

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
