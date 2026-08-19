#!/usr/bin/env python3
import sys
from rcon.source import Client as R

HOST = "127.0.0.1"
PORT = 27015
PASS = "Nxp4HJ1xE2Jtzjng"

cmd = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "status"
with R(HOST, PORT, passwd=PASS) as rcon:
    print(rcon.run(cmd))
