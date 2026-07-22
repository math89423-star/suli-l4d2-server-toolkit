#!/usr/bin/env python3
"""
switch_map.py — L4D2 命令行换图工具（替换 l4d2-switch-map.sh）。

用法:
  python3 switch_map.py <地图名|别名|首关>
  python3 switch_map.py --list         列出所有已安装地图及服务器状态
  python3 switch_map.py --help

别名: dw dc2 de zc atr re3 re1 ddg tank lab hls tumtara c1m1_hotel ...
"""

import json, os, sys
from rcon.source import Client as RCONClient

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(BASE_DIR, "config.json")
MAPS_FILE = os.path.join(BASE_DIR, "maps.json")

# ── 加载配置 ──────────────────────────────────────────────

def load_config():
    with open(CONFIG_FILE) as f:
        return json.load(f)

def load_aliases():
    """从 maps.json 加载别名 → 首关映射。"""
    if os.path.exists(MAPS_FILE):
        with open(MAPS_FILE) as f:
            return json.load(f).get("aliases", {})
    return {}

def load_addons_dir(cfg):
    """从 config.json 读取 addons_dir。"""
    # ★ 部署时修改: 默认值
    return cfg.get("addons_dir", "/opt/gameservers/l4d2/data/addons")

def rcon(cfg, cmd):
    with RCONClient(cfg["rcon_host"], cfg["rcon_port"], passwd=cfg["rcon_password"]) as c:
        return c.run(cmd).strip()

# ── --list ─────────────────────────────────────────────────

def cmd_list(cfg):
    """列出所有已安装地图和当前服务器状态。"""
    aliases = load_aliases()
    addons_dir = load_addons_dir(cfg)

    # 从 switch_map 的 VPK 定义
    # (vpk_name, first_map, label, size)
    vpk_catalog = [
        ("darkwood_extended_19",       "dw_woods",              "Dark Wood (Extended)", "940M"),
        ("gzzc7.9",                    "zc1_m1",                "广州增城",              "834M"),
        ("amidtheruins",               "atr01_trailer_park",    "Amid the Ruins",       "537M"),
        ("resident_evil3_10sep2025",   "re3m1",                 "生化危机3",            "463M"),
        ("dearesther",                 "de_donnelley_m1",       "Dear Esther",          "432M"),
        ("resident_evil1_19junio2024", "re1m1",                 "生化危机1",            "350M"),
        ("ddg_v2_1",                   "ddg1_tower_v2_1",       "Drop Dead Gorges",     "282M"),
        ("deadcity2",                  "dc2m1_riverside",       "Dead City 2",          "190M"),
        ("l4d2_tanksplayground",       "l4d2_tanksplayground",  "Tanks Playground",     "108M"),
        ("lab024_l4d2",                "l4d2_lab024_01",        "Lab 024",              "97M"),
    ]

    print("已安装的三方图:")
    print()
    print("非工坊（VPK 在 addons）:")
    for vpk_name, first_map, label, size in vpk_catalog:
        vpk_path = os.path.join(addons_dir, vpk_name + ".vpk")
        status = "✓" if os.path.exists(vpk_path) else "✗"
        print(f"  {status} {label:<28} {size:>6}  → {first_map}")
    print()
    print("工坊图（客户端订阅，服务端无 VPK）:")
    print("  ✓ 天梯1               工坊3703865650  → hls_05")
    print("  ✓ 天梯2               工坊3731244861  → hls_10")
    print("  ✓ TUMTaRA             工坊469986973   → tumtara")
    print()
    print("别名: " + " ".join(sorted(aliases.keys())))
    print()

    # 当前状态
    try:
        raw = rcon(cfg, "status")
        hn = mp = pl = ""
        for line in raw.split("\n"):
            line = line.strip()
            if line.startswith("hostname:"):
                hn = line.split(":", 1)[1].strip()
            elif line.startswith("map"):
                ps = line.split()
                if len(ps) >= 2:
                    mp = ps[2].strip()
            elif line.startswith("players"):
                import re as _re
                m = _re.match(r"players\s*:\s*(\d+)\s*humans.*\((\d+)\s*max\)", line)
                if m:
                    pl = f"{m.group(1)}/{m.group(2)}"
        print(f"当前: {mp}  |  玩家: {pl}  |  主机: {hn}")
    except Exception as e:
        print(f"(无法连接服务器: {e})")

# ── switch ─────────────────────────────────────────────────

def cmd_switch(cfg, target):
    """切换到指定地图。"""
    aliases = load_aliases()
    target = aliases.get(target, target)

    # tumtara 特殊处理：先卸载冲突插件
    tumtara_maps = cfg.get("tumtara_maps", [])
    if target in tumtara_maps:
        for plg in cfg.get("tumtara_unload_plugins", []):
            try:
                rcon(cfg, f"sm plugins unload {plg}")
                print(f"  已卸载: {plg}")
            except Exception:
                pass

    result = rcon(cfg, f"sm_map {target}")
    print(f"✓ 已切换到 {target}")
    if result:
        print(f"  {result}")

# ── main ───────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("--help", "-h"):
        print(__doc__)
        sys.exit(0)

    cfg = load_config()
    cmd = sys.argv[1]

    if cmd in ("--list", "-l"):
        cmd_list(cfg)
    else:
        cmd_switch(cfg, cmd)


if __name__ == "__main__":
    main()
