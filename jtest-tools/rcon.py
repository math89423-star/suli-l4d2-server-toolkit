#!/usr/bin/env python3
# rcon.py — L4D2 服务器裸包 RCON 客户端（python rcon 库在本机会 BrokenPipe，必须用这个）
# 用法: python3 rcon.py "cmd1" "cmd2" ...
import socket, struct, sys

HOST, PORT = '127.0.0.1', 27015
PASSWD = 'Nxp4HJ1xE2Jtzjng'   # 与 cfg/server.cfg rcon_password 一致

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
        chunk = s.recv(ln - len(buf))
        if not chunk:
            break
        buf += chunk
    return buf[8:-2].decode(errors='replace').strip()

def rcon(*cmds):
    """顺序执行命令；注意 printl/PrintToServer 的输出会随响应返回"""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect((HOST, PORT))
    s.sendall(pkt(1, 3, PASSWD))
    read_pkt(s)   # 空响应
    read_pkt(s)   # AUTH_RESPONSE
    for cmd in cmds:
        s.sendall(pkt(2, 2, cmd))
        out = read_pkt(s)
        print(f">>> {cmd}\n{out}\n")
    s.close()

if __name__ == '__main__':
    rcon(*sys.argv[1:])
