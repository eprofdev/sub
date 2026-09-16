# XE3000 Full‑Tunnel — ملف التسليم

مرجع كامل لنقل العمل إلى محادثة جديدة. كل ما فيه مستخلص من تشخيص فعلي على
جهاز GL‑XE3000 حقيقي، لا من افتراضات.

> **قيد قائم:** البيانات الحساسة (التوكن، المعرّفات، اسم المضيف الحقيقي) تبقى
> على الراوتر ولا تصل إلى GitHub إطلاقًا. القيم هنا كلها بدائل.

---

## 1. ما هو المشروع

بوابة على راوتر GL‑XE3000 تُخرج مرور العملاء عبر **Cloudflare Tunnel**:

```
عميل (هاتف/حاسوب)
  └─ VLESS + WebSocket + TLS
      └─ حافة Cloudflare  (مضيفك، المنفذ 443)
          └─ cloudflared على الراوتر (وصلة صادرة إلى المنفذ 7844)
              └─ xray على 127.0.0.1:18443
                  └─ الإنترنت
```

لا يحتاج عنوانًا عامًا ولا إعادة توجيه منافذ — الاتصال من الراوتر إلى الخارج.

### المستودع

| | |
|---|---|
| المستودع | `https://github.com/eprofdev/sub` |
| مجلد المشروع | `xe3000/` |
| السكربت | `xe3000/xe3000autouiinput.sh` — ملف واحد مكتفٍ بذاته |
| التنزيل | `https://raw.githubusercontent.com/eprofdev/sub/main/xe3000/xe3000autouiinput.sh` |
| البصمات | `xe3000/SHA256SUMS` |
| التوثيق | `xe3000/README.md` |
| سجل التشخيص | `xe3000/xe3000-fulltunnel-worklog.md` |
| فحص Cloudflare | `xe3000/check-cloudflare.sh` |
| CI | `.github/workflows/verify.yml` — صيغة POSIX، صيغة CGI، منع الانعكاس، قائمة المستخدمين، منع تسرّب الأسرار، تطابق البصمات |

**تحقق من البصمة قبل كل تشغيل** — تشغيل نسخة أقدم مما تقصد أضاع وقتًا طويلًا:

```sh
sha256sum /root/xe3000autouiinput.sh
```

---

## 2. بيئة الجهاز

| | |
|---|---|
| الجهاز | GL.iNet GL‑XE3000، ARM64 |
| النظام | OpenWrt 21.02‑SNAPSHOT، BusyBox 1.33.2 (ash) |
| الاتصال | مودم 4G على `rmnet_mhi0` — بلا عنوان عام |
| xray | 26.3.27 (go1.26.1) |
| cloudflared | 2026.8.2 (go1.26.4) |
| مسارات | `/etc/xe3000-cf-fulltunnel/` للإعداد، `/etc/xe3000-cf-fulltunnel-creds/` للبيانات (700/600) |

---

## 3. الأعطال التي حُلّت — وهذا أثمن ما في الملف

كل عطل هنا كلّف ساعات. العرَض أولًا لأنه ما ستراه.

### 3.1 مستمعو Go لا تكتمل معهم المصافحة (MPTCP)

**العرَض:** `netstat` يقول `LISTEN` و`curl` على العنوان المحلي يعطي **مهلة** لا
رفضًا. حدث لـ xray أولًا، ثم لمنفذ مقاييس cloudflared.

**السبب:** Go من الإصدار 1.24 يفتح المستمعين بـ MPTCP افتراضيًا، وMPTCP في نواة
هذا الجهاز لا تكتمل معه المصافحة. الاتصالات **الصادرة** سليمة — المتضرر
المستمعون وحدهم، ولهذا بقي النفق يعمل بينما المقياس ميت.

**العلاج:** `GODEBUG=multipathtcp=0` في الخدمتين كلتيهما.

> القاعدة: **مستمع مفتوح + مهلة (لا رفض) = اشتبه بـ MPTCP فورًا.**

### 3.2 سياسة VPN تبتلع مرور الراوتر

**العرَض:** `ping 1.1.1.1` ينجح، و`nslookup` يعطي مهلة، و`wget` يعطي
`Failed to send request: Operation not permitted`.

**السبب:** `/usr/bin/rtp2.sh` (عبر `firewall.vpnclient`) يبني سياسة توجيه تدفع
**كل ما ينشئه الراوتر** إلى جدول `2022` ومساره عبر `tun0`. إن كان النفق ساقطًا
ضاعت الحزم أو ابتلعتها `ip rule` ذات الأولوية `9910: blackhole`.
**المشكلة في التوجيه لا في الجدار الناري** — `iptables -t filter -L OUTPUT` نظيف.

**العلاج:** العلامة `0x8000` تلتقطها قاعدة `ip rule` ذات الأولوية `6000` فتذهب
الحزمة إلى الجدول `main` مباشرة:

```sh
iptables -w -t mangle -I OUTPUT -p tcp --dport 443 \
  -m mark --mark 0x0/0xf000 -j MARK --set-xmark 0x8000/0xf000
```

المنافذ المشمولة: `53` (udp+tcp)، `80`، `443`، `7844` (udp+tcp).

**تُثبَّت في `include` تابع للجدار الناري** — القواعد اليدوية تُمسح مع كل إعادة
تحميل، وهذا أوقعنا في حلقة: لا يمكن تنزيل الإصلاح لأن الإصلاح غير مطبّق.

`mangle/OUTPUT` لا ترى إلا ما ينشئه الراوتر؛ مرور أجهزة الشبكة يمرّ بـ `FORWARD`
فكِل‑سويتش أجهزتك لا يتأثر.

### 3.3 الـ VPN يقطع مصافحة TLS مع حافة Cloudflare

**العرَض:** في `logread -e cloudflared`:

```
TLS handshake with edge error: read tcp 172.19.0.1:57792->198.41.192.47:7844:
read: connection reset by peer
```

**عنوان المصدر يقول أي مسار سلكته الحزمة:** عنوان النفق (`172.19.0.x`) يعني عبر
الـ VPN، وغيره يعني مباشرة.

**السبب:** الـ VPN حيّ ويردّ على `ping`، لكنه يقطع المنفذ 7844.
**حياة الـ VPN ليست دليلًا على صلاحيته لحمل النفق.**

**العلاج:** `vpn-bypass auto` — يفضّل الـ VPN ويقيس النتيجة من
`readyConnections` في `/ready`، فإن كانت صفرًا تجاوزه وأعاد المحاولة كل نصف ساعة.

### 3.4 عناوين حافة IPv6 بلا مسار

**العرَض:** `dial tcp [2606:4700:a0::5]:7844: connect: network is unreachable`،
ومحاولات ضائعة قبل أن يصادف عنوان IPv4.

**السبب:** التجاوز مبني على `iptables` (IPv4)، فمرور IPv6 يبقى على السياسة المكسورة.

**العلاج:** `edge-ip-version: "4"` في إعداد cloudflared.

### 3.5 cloudflared يخرج إن عجز عن ترجمة SRV عند الإقلاع

**العرَض:** بعد الإقلاع، `xray` يعمل و`cloudflared` متوقف. في السجل:
`Could not lookup srv records on _v2-origintunneld._tcp.argotunnel.com`.

**السبب:** يترجم SRV قبل أي شيء ويخرج إن فشل، وعند الإقلاع لا يكون DNS جاهزًا.

**العلاج:** غلاف `run-cloudflared.sh` ينتظر ترجمة `region1.v2.argotunnel.com`
حتى ثلاث دقائق ثم يشغّله على أي حال ويترك إعادة المحاولة لـ procd.

### 3.6 قيم YAML غير مقتبسة

**العرَض:** `yaml: line 14: mapping values are not allowed in this context`،
وcloudflared يخرج فورًا.

**السبب:** `edge-ip-version: 4` تُقرأ عددًا وcloudflared يتوقع نصًّا، فيرفض
الملف كله. وحالة ثانية: منادٍ نسي `load_settings` فوُلِّد `service: http://:`.

**العلاج:** اقتباس القيم النصّية، والتحقق بـ
`cloudflared --config <ملف> tunnel ingress validate` **قبل** نقل الملف مكان القديم.

### 3.7 قائمة المستخدمين لا يخدمها xray

**العرَض:** الرابط يبدو سليمًا وxray يرفضه:
`rejected proxy/vless/encoding: invalid request user id: …`

**السبب:** `links` يطبع من `state/users.tsv` بينما xray يصادق من
`xray/config.json`، ولا شيء يقارنهما.

**العلاج:** `users-apply` يعيد البناء، و`selftest` يقارن المعرّفات ويفشل عند
الاختلاف.

### 3.8 خدمة تعمل لكنها لا تبدأ بعد الإقلاع

تشغيل الخدمة الآن شيء، ورابط `/etc/rc.d/S*` شيء آخر. فشل `enable` صامت حتى أول
إعادة تشغيل. `enable_services` و`selftest` صارا يتحققان من الرابط صراحةً.

### 3.9 فرضيات جرّبناها وأثبت الدليل خطأها

لا تُضِع وقتك فيها: `iif lo lookup 16800` — كِل‑سويتش WireGuard (لا WireGuard
أصلًا، `wg show` فارغ) — `LOCAL_POLICY` (بريئة، قواعدنا تسبقها والعلامة تصمد) —
conntrack — تفريغ NAT في MediaTek (كان صفرًا أصلًا) — TCP Fast Open — dnsmasq.

---

## 4. درس متكرر: لا تُعلن نجاحًا بلا تحقق

أكثر ما أضاع الوقت لم يكن الأعطال بل **إعلان النجاح وهو لم يحدث**:

- `users_apply` يقول «طُبّقت» والكتابة فشلت.
- `vpn-bypass on` يقول «مفعّل» ولم يُكتب ملف أصلًا (المجلّد غير موجود).
- `vpn-bypass auto` يقول «مفعّل» ومصدر قراره غير متاح.
- `repair-ui` يتخطى كتابة الملفات إن وُجد المجلّد.
- تعطيل حماية اللوحة يحذف الملف ويترك خيار `uci` مشيرًا إليه.

**القاعدة المطبّقة الآن:** كل أمر يقرأ النتيجة من مصدرها بعد التنفيذ — عدد القواعد
من `iptables -C`، والوصلات من `/ready`، ورابط الإقلاع من `/etc/rc.d`، وتطابق
المعرّفات من الملفين. وإن تعذّر القياس، يرفض الأمر ويُبقي النظام عاملًا بدل التخمين.

---

## 5. التثبيت من الصفر

### قبل كل شيء — تأكد أن الراوتر يخرج

```sh
ping -c2 1.1.1.1
nslookup api.cloudflare.com
```

فشل الثاني مع نجاح الأول ⇦ العطل 3.2. طبّق القواعد يدويًا أولًا:

```sh
for p in "udp 53" "tcp 53" "tcp 443" "tcp 80" "tcp 7844" "udp 7844"; do
  set -- $p
  iptables -w -t mangle -C OUTPUT -p $1 --dport $2 -m mark --mark 0x0/0xf000 \
    -j MARK --set-xmark 0x8000/0xf000 2>/dev/null ||
  iptables -w -t mangle -I OUTPUT -p $1 --dport $2 -m mark --mark 0x0/0xf000 \
    -j MARK --set-xmark 0x8000/0xf000
done
nslookup api.cloudflare.com
```

### التنزيل

```sh
cd /root
wget -O xe3000autouiinput.sh \
  https://raw.githubusercontent.com/eprofdev/sub/main/xe3000/xe3000autouiinput.sh
wget -O check-cloudflare.sh \
  https://raw.githubusercontent.com/eprofdev/sub/main/xe3000/check-cloudflare.sh
chmod +x xe3000autouiinput.sh check-cloudflare.sh
sha256sum xe3000autouiinput.sh     # قارنه بـ SHA256SUMS في المستودع
```

لا تمرّره عبر أنبوب، واحفظه في `/root` لا `/tmp`.

### البيانات الأربع

توكن من My Profile ← API Tokens ← Create Token بصلاحيتين **فقط**:

- `Account` · `Cloudflare Tunnel` · **Edit**
- `Zone` · `DNS` · **Edit**

```sh
cat > /root/xe3000-fulltunnel-auto.env <<'EOF'
FULLTUNNEL_HOSTNAME=cdn.example.com
FULLTUNNEL_ACCOUNT_ID=...
FULLTUNNEL_ZONE_ID=...
FULLTUNNEL_API_TOKEN=...
EOF
chmod 600 /root/xe3000-fulltunnel-auto.env
sed -n l /root/xe3000-fulltunnel-auto.env    # كل سطر ينتهي بـ $ بلا \r
sh /root/xe3000autouiinput.sh auto
```

يُحذف الملف تلقائيًا بعد النجاح. أو `sh /root/xe3000autouiinput.sh` للتثبيت
التفاعلي.

### بعد التثبيت

```sh
sh /root/xe3000autouiinput.sh vpn-bypass auto   # أو on إن كان الـ VPN يقطع 7844
sh /root/xe3000autouiinput.sh watchdog on 5
sh /root/xe3000autouiinput.sh selftest
sh /root/xe3000autouiinput.sh links
```

---

## 6. مرجع الأوامر

| الأمر | ماذا يفعل |
|---|---|
| `install` / `auto [ملف]` | تثبيت كامل |
| `selftest` | فحص ست حلقات: xray ← cloudflared ← Cloudflare ← DNS ← الطلب العام |
| `status` / `diagnose` | الحالة، وفحص uhttpd والمنفذ 9000 |
| `links` / `user-list` | الروابط والمستخدمون |
| `user-add [اسم]` / `user-del <اسم>` | إضافة وحذف |
| `users-apply` | إعادة بناء إعداد xray من القائمة |
| `set-hostname <اسم>` | تبديل المضيف داخل نطاقك |
| `set-transport ws\|xhttp` | الناقل |
| `set-protocol vless\|trojan` | البروتوكول |
| `set-port <رقم>` / `set-listen <عنوان\|unix>` | المنفذ المحلي وعنوان الاستماع |
| `set-edge-protocol http2\|quic\|auto` | بروتوكول وصلة الحافة |
| `vpn-bypass auto\|on\|off\|status` | سياسة الخروج |
| `watchdog on [د]\|off\|test` | المراقبة الدورية |
| `auth on\|off\|status` | حماية اللوحة (معطّلة افتراضيًا) |
| `reinstall-services` | إعادة كتابة الإعداد وملفي الخدمة |
| `set-token` | تبديل التوكن وحده |
| `reset` / `remove` / `forget-creds` | تنظيف وإزالة |
| `menu` | قائمة تفاعلية عبر SSH |

---

## 7. التحقق من الخارج

الأقوى، لأنه لا يعتمد على شيء داخل الراوتر.

### ترقية WebSocket

```sh
curl -sS -m 20 --http1.1 -D - -o /dev/null \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  "https://المضيف/المسار"
```

**`--http1.1` ضروري** — ترقية WebSocket لا تعمل عبر HTTP/2 بآلية `Upgrade:`،
وبدونه ستحصل على `400` وتظنه عطلًا في الخادم.

| الردّ | معناه |
|---|---|
| `101 Switching Protocols` | السلسلة كاملة تعمل |
| `530` + `error code 1033` | لا وصلة نشطة من cloudflared |
| `404` على المسار الصحيح | xray يعمل لكن المسار مختلف |
| `502` | النفق متصل والأصل لا يجيب |

### اختبار VLESS كامل (مصادقة + تمرير بيانات)

`scripts/vless-probe.py` في هذا المجلد. يفتح WebSocket عبر Cloudflare، يرسل رأس
VLESS بمعرّفك، يطلب موقعًا، ويطبع ردّه. نجاحه يعني أن كل شيء يعمل بما فيه
المصادقة والتمرير — لا المصافحة وحدها.

```sh
python3 scripts/vless-probe.py <المضيف> <المسار> <UUID>
```

---

## 8. الخطوة التالية: عدة نطاقات

الهدف: تشغيل البوابة على أكثر من نطاق (`a.com` و`b.net` …) لتوزيع الخطر ومقاومة
الحجب.

### ما يعمل اليوم

`set-hostname` يبدّل المضيف **داخل نطاق واحد**، وسجل CNAME واحد يشير إلى النفق.

### ما ينقص

`write_cfd_config` يكتب قاعدة `ingress` واحدة لمضيف واحد. تعدد النطاقات يحتاج:

1. **قواعد ingress متعددة** — cloudflared يدعمها أصلًا:
   ```yaml
   ingress:
     - hostname: cdn.a.com
       service: http://127.0.0.1:18443
     - hostname: static.b.net
       service: http://127.0.0.1:18443
     - service: http_status:404
   ```
2. **سجل CNAME في كل نطاق** يشير إلى `<TUNNEL_ID>.cfargotunnel.com`.
3. **معرّف Zone لكل نطاق**، وتوكن له `Zone · DNS · Edit` على النطاقات كلها
   (أو توكن لكل نطاق). `FULLTUNNEL_ZONE_ID` الحالي مفرد — يحتاج تحويله إلى قائمة
   أو خريطة `مضيف → zone id`.
4. **الروابط**: رابط لكل مضيف، فيختار العميل ما يعمل في شبكته.

### أسئلة تحسم التصميم

- نفق واحد لكل النطاقات، أم نفق لكل نطاق؟ **نفق واحد أبسط** ويكفي: القيد على
  عدد المضيفين في الـ ingress سخيّ. نفق لكل نطاق يعزلها إن حُجب أحدها عند Cloudflare.
- توكن واحد بصلاحية على كل النطاقات، أم توكن لكل نطاق؟ الثاني أضيق صلاحية وأأمن.
- هل تُولَّد أسماء المضيفين تلقائيًا (`cdn`، `static`، `api`) أم تختارها؟

### حدّ الشهادة — مهم

على إعداد full تغطي شهادة Universal SSL المجانية النطاق والمستوى الأول فقط.
`cdn.example.com` مغطّى، و`youtube.com.example.com` **مستوى ثانٍ وغير مغطّى**
فتفشل مصافحة TLS بخطأ شهادة. يحتاج Advanced Certificate Manager أو Total TLS
(مدفوعان)، أو إعداد partial (CNAME) حيث تُصدر شهادة لكل مضيف مهما كان عمقه.

---

## 9. أعمال معلّقة

1. **تعدد النطاقات** — القسم 8.
2. **عدة بروتوكولات معًا باستقلال:** اليوم `set-protocol` يبدّل بين `vless`
   و`trojan`. المطلوب تفعيلها معًا مع تشغيل/إيقاف كل واحد دون أن يتأثر
   المستخدمون ما لم يُحذفوا.
3. **معرّف وكلمة مرور لكل مستخدم بلا تكرار:** `users.tsv` اليوم
   `uuid<TAB>اسم`. المطلوب إضافة كلمة مرور Trojan مستقلة لكل مستخدم — يحتاج
   تغيير المخطّط مع ترحيل الملفات القائمة.
4. **REALITY / XTLS:** **غير ممكن خلف Cloudflare Tunnel** — الحافة تنهي TLS
   وcloudflared يتكلم HTTP عاديًا مع الأصل. والراوتر خلف مودم 4G بلا عنوان عام
   فلا بديل مباشر. لا تُضِع وقتًا فيه.
5. **`xhttp` مع العملاء القدامى:** نواة v2ray 5.0.17 لا تدعمه — `ws` هو المتوافق.
6. **cloudflared لا يمرّر ترقية WebSocket إلى أصل `unix:`** (يردّ 502،
   `http: no Host in request URL`). مع `unix` استعمل `xhttp` لا `ws`.

---

## 10. تحذيرات عملية

- **تحقق من البصمة قبل كل تشغيل.** ثلاث مرات شُغّلت نسخة أقدم مما قُصد.
- **إعادة التثبيت من الصفر تنشئ نفقًا ومسارًا ومعرّفات جديدة** فتبطل روابط
  العملاء. لتغيير المضيف وحده استعمل `set-hostname`.
- **`reboot` ثم أمر فورًا** يعمل أثناء الإطفاء لا بعد الإقلاع، فيعطي نتيجة
  مضلّلة. انتظر واتصل من جديد.
- **بعد الإقلاع يحتاج النظام دقيقتين** حتى يسجّل cloudflared وصلاته.
- **اللوحة مفتوحة بلا كلمة مرور افتراضيًا** على `http://192.168.8.1:9000`
  و`https://192.168.8.1:9443`. أي جهاز على شبكتك يراها ويديرها. للحماية:
  `auth on`.
- **إن كان هاتفك على واي‑فاي الراوتر** فمروره يخرج عبر الـ VPN ويعود إلى
  الراوتر، ويمرّ بالقاعدة `9920: from all iif br-lan blackhole`. اختبر على بيانات
  الجوّال.

---

## 11. أوامر التشخيص السريع

```sh
sh /root/xe3000autouiinput.sh selftest            # ابدأ دائمًا من هنا
logread -e cloudflared | tail -20                 # أخطاء النفق وسبب القطع
logread -e xray | tail -20                        # رفض المعرّفات وأخطاء الإعداد
logread -e xe3000 | grep vpn-bypass               # قرارات تبديل المسار
curl -sS http://127.0.0.1:20241/ready             # عدد وصلات cloudflared
ip rule ; ip route show table all | head -30      # سياسة التوجيه
iptables -t mangle -L OUTPUT -n -v --line-numbers # قواعد التجاوز وعدّاداتها
ls -l /etc/rc.d/ | grep xe3000                    # روابط الإقلاع
sh /root/check-cloudflare.sh                      # فحوص Cloudflare الأربعة
```

**اقرأ عدّادات `iptables`:** عدّاد كبير يعني أن القاعدة تعمل فعلًا، وصفر يعني أن
المرور لا يمرّ بها أصلًا.
