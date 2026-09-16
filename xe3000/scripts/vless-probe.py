#!/usr/bin/env python3
"""اختبار VLESS كامل عبر Cloudflare: ترقية WebSocket، مصادقة، وتمرير بيانات.

    python3 vless-probe.py <host> <path> <uuid> [target-host]

نجاحه يثبت السلسلة كلها من الإنترنت العام: الحافة ← cloudflared ← xray ←
الوجهة ← ورجوعًا. وهو أقوى من اختبار الترقية وحده، الذي ينجح حتى لو كان
المعرّف مرفوضًا.

لا يحفظ شيئًا ولا يطبع المعرّف — مرّره كوسيط ولا تودعه في ملف مشترك.
"""
import base64, hashlib, os, socket, ssl, struct, sys, uuid as _uuid

if len(sys.argv) < 4:
    sys.exit(__doc__)
HOST, PATH, UID = sys.argv[1], sys.argv[2], _uuid.UUID(sys.argv[3])
TARGET = sys.argv[4] if len(sys.argv) > 4 else "cp.cloudflare.com"
TARGET_PORT = 80


def ws_connect():
    raw = socket.create_connection((HOST, 443), timeout=20)
    s = ssl.create_default_context().wrap_socket(raw, server_hostname=HOST)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(
        f"GET {PATH} HTTP/1.1\r\nHost: {HOST}\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n\r\n".encode()
    )
    buf = b""
    while b"\r\n\r\n" not in buf:
        d = s.recv(4096)
        if not d:
            sys.exit("الاتصال أُغلق أثناء المصافحة")
        buf += d
    head = buf.split(b"\r\n\r\n")[0].decode(errors="replace")
    if "101" not in head.split("\r\n")[0]:
        sys.exit("فشل الترقية:\n" + head)
    acc = hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
    if base64.b64encode(acc).decode().lower() not in head.lower():
        sys.exit("Sec-WebSocket-Accept غير مطابق — وسيط يتدخل في المسار")
    print("1) ترقية WebSocket : 101 والمفتاح مطابق")
    return s


def ws_send(s, data):
    h = bytearray([0x82])
    n = len(data)
    if n < 126:
        h.append(0x80 | n)
    elif n < 65536:
        h.append(0x80 | 126); h += struct.pack(">H", n)
    else:
        h.append(0x80 | 127); h += struct.pack(">Q", n)
    m = os.urandom(4)
    h += m
    s.sendall(bytes(h) + bytes(b ^ m[i % 4] for i, b in enumerate(data)))


def ws_recv(s, timeout=30):
    s.settimeout(timeout)
    out = b""
    try:
        while True:
            hdr = s.recv(2)
            if len(hdr) < 2:
                break
            ln = hdr[1] & 0x7F
            if ln == 126:
                ln = struct.unpack(">H", s.recv(2))[0]
            elif ln == 127:
                ln = struct.unpack(">Q", s.recv(8))[0]
            pay = b""
            while len(pay) < ln:
                c = s.recv(ln - len(pay))
                if not c:
                    break
                pay += c
            out += pay
            if b"\r\n\r\n" in out or len(out) > 400:
                break
    except socket.timeout:
        pass
    return out


s = ws_connect()
req = f"GET / HTTP/1.1\r\nHost: {TARGET}\r\nConnection: close\r\n\r\n".encode()
hdr = bytearray([0])                      # الإصدار
hdr += UID.bytes                          # المعرّف
hdr.append(0)                             # طول الإضافات
hdr.append(1)                             # الأمر: TCP
hdr += struct.pack(">H", TARGET_PORT)
hdr.append(2)                             # نوع العنوان: اسم نطاق
hdr.append(len(TARGET)); hdr += TARGET.encode()
ws_send(s, bytes(hdr) + req)

r = ws_recv(s)
if len(r) <= 2:
    print("2) مصادقة VLESS    : فشلت — المعرّف مرفوض أو أُغلق الاتصال")
    print("   راجع على الراوتر: logread -e xray | tail -5")
    sys.exit(1)
print(f"2) مصادقة VLESS    : قُبِل المعرّف ({len(r)} بايت)")
print("3) تمرير البيانات  :", r[2:60].decode(errors="replace").splitlines()[0])
