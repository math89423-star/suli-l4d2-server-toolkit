#!/usr/bin/env python3
# jsweep.py — 骑跃射程扫描驱动
# 用法: python3 jsweep.py 250 300 350 ...   （距离列表）
# 前置: rcon.py 同目录；服务器已按 AGENTS.md 配方进入实测态
import socket, struct, time, sys

HOST, PORT = '127.0.0.1', 27015
PASSWD = 'Nxp4HJ1xE2Jtzjng'

def pkt(rid, typ, body):
    data = struct.pack('<ii', rid, typ) + body.encode() + b'\x00\x00'
    return struct.pack('<i', len(data)) + data

def read_pkt(s):
    raw = s.recv(4)
    if len(raw) < 4:
        return None
    ln = struct.unpack('<i', raw)[0]
    buf = b''
    while len(buf) < ln:
        c = s.recv(ln - len(buf))
        if not c:
            break
        buf += c
    return buf[8:-2].decode(errors='replace').strip()

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(10)
s.connect((HOST, PORT))
s.sendall(pkt(1, 3, PASSWD))
read_pkt(s); read_pkt(s)

def rc(cmd):
    s.sendall(pkt(2, 2, cmd))
    return read_pkt(s)

def trial_once(D, pitch=None):
    setup = rc(f'sm_jt_run {D}')
    if 'ok' not in (setup or ''):
        return None, (setup or '').strip()[:50]
    time.sleep(0.25)
    if pitch is None:
        rc('sm_jt_press')
    else:
        rc(f'sm_jt_press {pitch}')
    time.sleep(0.35)
    rc('sm_jt_sample')
    time.sleep(1.9)
    ev = rc(f'sm_jt_eval {D}')
    line = [l for l in ev.split('\n') if l.startswith('JTEST_RESULT')]
    return (line[0] if line else None), None

def trial(D, pitch=None, tries=3):
    for _ in range(tries):
        r, err = trial_once(D, pitch)
        if r:
            suffix = f' pitch={pitch}' if pitch is not None else ''
            print(r + suffix)
            time.sleep(0.6)
            return
        time.sleep(1.0)
    print(f'D={D}: FAILED_AFTER_RETRIES ({err})')

args = sys.argv[1:]
pitch = None
if args and args[0].startswith('-'):
    pitch = float(args[0])
    args = args[1:]
for D in ([int(x) for x in args] or [250]):
    trial(D, pitch)
s.close()
