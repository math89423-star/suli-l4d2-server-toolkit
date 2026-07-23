#!/usr/bin/env python3
"""
scan_maps.py — 扫描 L4D2 addons 目录里的 VPK 文件，自动生成 maps.json。

用法:
  python3 scan_maps.py                # 扫描并写入 maps.json（保留已有 labels）
  python3 scan_maps.py --dry-run      # 只打印 JSON，不写入文件
  python3 scan_maps.py --addons DIR   # 指定 addons 目录

原理:
  - 从 VPK 文件中用 strings + grep 提取 .bsp 地图名
  - 支持普通 VPK 和 ZIP 封装的 VPK（如 deadcity2）
  - 工坊图（无 VPK）使用手动维护的列表
  - 官方战役列表硬编码（不变）
  - 已有 maps.json 中的 map_labels 会被保留
"""

import json, os, re, subprocess, sys, zipfile, tempfile, shutil

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ADDONS_DIR = "/opt/gameservers/l4d2/data/addons"
MAPS_FILE = os.path.join(BASE_DIR, "maps.json")

# ============================================================
# VPK 元数据覆盖（完全可选 — 留空也能自动发现所有 VPK）
#   如果某个 VPK 需要自定义中文名、别名、或分类(fun/custom)，
#   在这里添加一行即可。不在此表中的 VPK 全自动处理。
#   格式: "vpk文件名(不含.vpk)": (campaign_id, 显示名称, 别名, 分类)
# ============================================================
VPK_CATALOG = {}

# 自定义地图排序（完全可选）
#   仅当某个战役的自然排序不对时才需要手动指定。
#   键 = campaign_id，值 = 正确顺序的地图列表
MAP_ORDER = {}

# ============================================================
# 工坊图 / 无 VPK 的战役 — 地图列表手动维护
#   (campaign_id, campaign_name, alias, size_label, category, [maps])
# ============================================================
MANUAL_CAMPAIGNS = [
    ("hls",     "天梯1+2",  "hls",     "工坊", "custom",
     ["hls_05", "hls_06", "hls_07", "hls_09",
      "hls_10", "hls_11", "hls_12", "hls_13", "hls_14"]),
    ("tumtara", "TUMTaRA",  "tumtara", "工坊", "fun",
     ["tumtara", "tumtara_l4d1_playground"]),
]

# ============================================================
# 官方战役 — 永远不变
# ============================================================
OFFICIAL_CAMPAIGNS = [
    ("c1",  "死亡中心 (Dead Center)",     ["c1m1_hotel", "c1m2_streets", "c1m3_mall", "c1m4_atrium"]),
    ("c2",  "黑色狂欢节 (Dark Carnival)", ["c2m1_highway", "c2m2_fairgrounds", "c2m3_coaster", "c2m4_barns", "c2m5_concert"]),
    ("c3",  "沼泽激战 (Swamp Fever)",     ["c3m1_plankcountry", "c3m2_swamp", "c3m3_shantytown", "c3m4_plantation"]),
    ("c4",  "暴雨 (Hard Rain)",           ["c4m1_milltown_a", "c4m2_sugarmill_a", "c4m3_sugarmill_b", "c4m4_milltown_b", "c4m5_milltown_escape"]),
    ("c5",  "教区 (The Parish)",          ["c5m1_waterfront", "c5m2_park", "c5m3_cemetery", "c5m4_quarter", "c5m5_bridge"]),
    ("c6",  "短暂时刻 (The Passing)",     ["c6m1_riverbank", "c6m2_bedlam", "c6m3_port"]),
    ("c7",  "牺牲 (The Sacrifice)",       ["c7m1_docks", "c7m2_barge", "c7m3_port"]),
    ("c8",  "毫不留情 (No Mercy)",        ["c8m1_apartment", "c8m2_subway", "c8m3_sewers", "c8m4_interior", "c8m5_rooftop"]),
    ("c9",  "坠机险途 (Crash Course)",    ["c9m1_alleys", "c9m2_lots"]),
    ("c10", "死亡丧钟 (Death Toll)",      ["c10m1_caves", "c10m2_drainage", "c10m3_ranchhouse", "c10m4_mainstreet", "c10m5_cemetery"]),
    ("c11", "寂静时分 (Dead Air)",        ["c11m1_greenhouse", "c11m2_offices", "c11m3_garage", "c11m4_runway_terminal", "c11m5_runway"]),
    ("c12", "血腥收获 (Blood Harvest)",   ["c12m1_hilltop", "c12m2_traintunnel", "c12m3_bridge", "c12m4_barn", "c12m5_cornfield"]),
    ("c13", "刺骨寒溪 (Cold Stream)",     ["c13m1_alpinecreek", "c13m2_southpinestream", "c13m3_memorialbridge", "c13m4_cutthroatcreek"]),
    ("c14", "背水一战 (The Last Stand)",  ["c14m1_junkyard", "c14m2_lighthouse"]),
]


def _natural_key(name):
    """Natural sort: split on digits, compare as ints for correct map order."""
    return [int(p) if p.isdigit() else p.lower() for p in re.split(r'(\d+)', name)]


# ── helpers ────────────────────────────────────────────────

def extract_maps_from_vpk(vpk_path):
    """
    从 VPK 文件中提取 .bsp 地图名列表。
    返回去重、排序后的纯地图名列表，如 ['dw_woods', 'dw_complex']。
    """
    maps = set()
    vpk_path = os.path.realpath(vpk_path)

    # 方法1: 如果是 ZIP（如 deadcity2.vpk 外层是 ZIP），
    #         先解压内层 VPK 到临时目录再扫描
    if zipfile.is_zipfile(vpk_path):
        with zipfile.ZipFile(vpk_path, 'r') as zf:
            names = zf.namelist()
            # 如果 ZIP 里只有一个 .vpk 文件，提取它
            vpk_inside = [n for n in names if n.lower().endswith('.vpk')]
            other_files = [n for n in names if not n.lower().endswith('.vpk')]
            if vpk_inside and not other_files:
                tmpdir = tempfile.mkdtemp(prefix='l4d2scan_')
                try:
                    zf.extract(vpk_inside[0], tmpdir)
                    inner_path = os.path.join(tmpdir, vpk_inside[0])
                    maps |= set(extract_maps_from_vpk(inner_path))
                finally:
                    shutil.rmtree(tmpdir, ignore_errors=True)
                return sorted(maps, key=_natural_key)
            # 如果 ZIP 里有直接的 .bsp 文件
            for name in names:
                if name.lower().endswith('.bsp'):
                    m = _clean_map_name(name)
                    if m:
                        maps.add(m)

    # 方法2: strings + grep（对所有 VPK 都有效）
    try:
        result = subprocess.run(
            ['strings', vpk_path],
            capture_output=True, text=True, timeout=30
        )
        for line in result.stdout.split('\n'):
            line = line.strip()
            if not line.lower().endswith('.bsp'):
                continue
            m = _clean_map_name(line)
            if m:
                maps.add(m)
    except Exception as e:
        print(f"  ⚠ strings 失败: {e}", file=sys.stderr)

    return sorted(maps, key=_natural_key)


def _clean_map_name(raw):
    """
    从 VPK 内部的路径/字符串中提取干净的地图名。
    "maps/re3m1.bsp" → "re3m1"
    "maps/HLS 10.bsp" → "hls_10"  (空格→下划线，小写)
    """
    # 取文件名（去掉路径）
    name = os.path.basename(raw.strip())
    # 去掉 .bsp 后缀
    if name.lower().endswith('.bsp'):
        name = name[:-4]
    else:
        return None
    # 空格 → 下划线，统一小写
    name = name.replace(' ', '_').lower()
    # 过滤明显不是地图名的（太短、太长、含特殊字符、纯数字）
    if len(name) < 4 or len(name) > 48:
        return None
    if not re.match(r'^[a-z][a-z0-9_-]*[a-z0-9]$', name):
        return None
    # 过滤 Source 引擎内置/测试图
    if name in ('credits', '6', 'curling_stadium', 'motionprimingtest',
                'motionprimingtest_rev', 'navigationtest_a',
                'styleguide_semiurban_01', 'styleguide_swamp01',
                'styleguide_swamp_cheapwater01', 'styleguide_urban_01',
                'test_box2', 'test_macguffin', 'test_mall',
                'test_scavenge', 'tutorial_standards', 'tutorial_standards_vs',
                'zoo_carnivalgames', 'zoo_infected2', 'zoo_jukebox',
                'zoo_swamp_foliage_01', 'zoo_trafficsigns', 'zoo_urban_foliage_01'):
        return None
    return name


def load_existing_labels():
    """从已有 maps.json 加载已有 map_labels（保留人工翻译）。"""
    if os.path.exists(MAPS_FILE):
        try:
            with open(MAPS_FILE, 'r') as f:
                return json.load(f).get('map_labels', {})
        except Exception:
            pass
    return {}

def load_existing_metadata():
    """从已有 maps.json 加载各 campaign 的元数据。
       返回两个查询表：按首关名、按地图集合。"""
    by_first = {}
    by_maps = {}
    if os.path.exists(MAPS_FILE):
        try:
            with open(MAPS_FILE, 'r') as f:
                data = json.load(f)
                for cat in data.get('categories', []):
                    for camp in cat.get('campaigns', []):
                        maps = camp.get('maps', [])
                        cid = camp.get('id', '')
                        if not maps:
                            continue
                        meta = {
                            'id': cid,
                            'name': camp.get('name', ''),
                            'alias': camp.get('alias', ''),
                            'category': cat.get('id', 'custom'),
                        }
                        if maps[0] not in by_first:
                            by_first[maps[0]] = meta
                        # 用排序后的 maps 集合作为匹配键
                        key = '\n'.join(sorted(maps))
                        if key not in by_maps:
                            by_maps[key] = meta
        except Exception:
            pass
    return by_first, by_maps


def auto_label(campaign_name, map_name, index):
    """自动生成地图中文标签。"""
    # 官方图有固定命名规则
    m = re.match(r'^c(\d+)m(\d+)', map_name)
    if m:
        c, mnum = int(m.group(1)), int(m.group(2))
        # 用 campaign_name 的前几个字
        short = campaign_name.split('(')[0].strip()
        return f"{short}{mnum}"
    # 三方图: 用战役名 + 序号
    return f"{campaign_name}-{index + 1}"


def _auto_campaign_id(basename):
    """从 VPK 文件名自动生成 campaign ID。"""
    cid = basename.lower()
    # 去掉常见前缀
    for pf in ('l4d2_', 'l4d_', 'left4dead2_', 'left4dead_'):
        if cid.startswith(pf):
            cid = cid[len(pf):]
            break
    # 去掉版本号后缀（_v1, _19, _v2_1 等）
    cid = re.sub(r'_v?\d+(_\d+)*$', '', cid)
    cid = re.sub(r'[^a-z0-9_]', '', cid)[:16]
    if not cid or cid[0].isdigit():
        cid = 'm_' + cid
    return cid


def _auto_campaign_name(basename):
    """从 VPK 文件名自动生成可读的名称。"""
    name = basename
    # 去掉常见前缀
    for pf in ('l4d2_', 'l4d_', 'left4dead2_', 'left4dead_'):
        if name.lower().startswith(pf):
            name = name[len(pf):]
            break
    # 去掉版本号后缀
    name = re.sub(r'_v?\d+(_\d+)*$', '', name)
    # 下划线 → 空格，首字母大写
    name = name.replace('_', ' ').strip()
    name = ' '.join(w[0].upper() + w[1:] if w and w[0].islower() else w for w in name.split() if w)
    return name if name else basename.replace('_', ' ').title()


def build_maps_json(addons_dir=ADDONS_DIR):
    """扫描并构建完整的 maps.json 数据结构。"""
    existing_labels = load_existing_labels()

    categories = []

    # ── 官方战役 ──────────────────────────────────────────
    official_campaigns = []
    for cid, cname, maps in OFFICIAL_CAMPAIGNS:
        official_campaigns.append({
            "id": cid, "name": cname, "maps": maps
        })
    categories.append({
        "id": "official", "name": "官方战役", "campaigns": official_campaigns
    })

    # ── 三方战役 + 娱乐图 ──────────────────────────────────
    custom_campaigns = []
    fun_campaigns = []

    # 自动发现 addons 目录下所有 .vpk 文件
    vpk_files = []
    if os.path.isdir(addons_dir):
        for fn in sorted(os.listdir(addons_dir)):
            if fn.lower().endswith(".vpk"):
                vpk_files.append(fn)

    # 加载已有元数据，用于跨扫描保留人工编辑的名称/别名
    existing_by_first, existing_by_maps = load_existing_metadata()

    scanned_ids = set()

    for vpk_filename in vpk_files:
        vpk_basename = vpk_filename[:-4]  # strip .vpk
        vpk_path = os.path.join(addons_dir, vpk_filename)

        print(f"  扫描 {vpk_filename} ...", file=sys.stderr)
        maps = extract_maps_from_vpk(vpk_path)
        if not maps:
            print(f"    ⚠ 未提取到地图，跳过", file=sys.stderr)
            continue

        print(f"    → {len(maps)} 张地图: {', '.join(maps)}", file=sys.stderr)

        # 优先从 VPK_CATALOG → 已有 maps.json（首关/全集合匹配）→ 自动生成
        catalog_entry = VPK_CATALOG.get(vpk_basename)
        if catalog_entry:
            cid, cname, alias, cat = catalog_entry
        else:
            # 用首关地图名匹配已有 maps.json，保留人工编辑的名称/别名
            old = existing_by_first.get(maps[0])
            # 回退：用排序后的完整地图集合匹配（防止 MAP_ORDER 改变首关顺序）
            if not old:
                old = existing_by_maps.get('\n'.join(sorted(maps)))
            if old:
                cid = old['id']
                cname = old['name']
                alias = old.get('alias') or cid
                cat = old.get('category') or 'custom'
            else:
                # 全新地图：自动生成
                cid = _auto_campaign_id(vpk_basename)
                cname = _auto_campaign_name(vpk_basename)
                alias = cid
                cat = "custom"

        # 防重名 ID
        if cid in scanned_ids:
            cid = cid + "_2"
        scanned_ids.add(cid)

        # 应用自定义排序
        if cid in MAP_ORDER:
            ordered = MAP_ORDER[cid]
            existing = set(maps)
            maps = [m for m in ordered if m in existing] + [m for m in maps if m not in ordered]

        # 自动计算大小
        try:
            size_bytes = os.path.getsize(vpk_path)
            if size_bytes >= 1048576:
                size = f"{size_bytes // 1048576}M"
            elif size_bytes >= 1024:
                size = f"{size_bytes // 1024}K"
            else:
                size = f"{size_bytes}B"
        except:
            size = "?"

        campaign = {
            "id": cid, "name": cname, "alias": alias, "maps": maps, "size": size
        }
        if cat == "fun":
            fun_campaigns.append(campaign)
        else:
            custom_campaigns.append(campaign)

    # 工坊图（无 VPK — 手动维护）
    for cid, cname, alias, size, cat, maps in MANUAL_CAMPAIGNS:
        if cid in scanned_ids:
            continue  # 如果 addons 已有同名 VPK，跳过手动条目
        campaign = {
            "id": cid, "name": cname, "alias": alias, "maps": maps, "size": size
        }
        if cat == "fun":
            fun_campaigns.append(campaign)
        else:
            custom_campaigns.append(campaign)

    categories.append({
        "id": "custom", "name": "三方战役", "campaigns": custom_campaigns
    })
    categories.append({
        "id": "fun", "name": "娱乐 / 特感", "campaigns": fun_campaigns
    })

    # ── 构建 aliases ───────────────────────────────────────
    aliases = {}
    for cat in categories[1:]:  # 跳过 official
        for camp in cat["campaigns"]:
            if "alias" in camp:
                aliases[camp["alias"]] = camp["maps"][0]

    # ── 构建 map_labels（保留已有 + 自动生成新） ──────────
    map_labels = {}
    for cat in categories:
        for camp in cat["campaigns"]:
            for i, m in enumerate(camp["maps"]):
                if m in existing_labels:
                    map_labels[m] = existing_labels[m]
                else:
                    map_labels[m] = auto_label(camp["name"], m, i)

    return {
        "categories": categories,
        "aliases": aliases,
        "map_labels": map_labels,
    }


def main():
    dry_run = "--dry-run" in sys.argv
    addons_dir = ADDONS_DIR

    # 解析 --addons 参数
    for i, arg in enumerate(sys.argv):
        if arg == "--addons" and i + 1 < len(sys.argv):
            addons_dir = sys.argv[i + 1]

    if not os.path.isdir(addons_dir):
        print(f"错误: addons 目录不存在: {addons_dir}", file=sys.stderr)
        sys.exit(1)

    print(f"扫描目录: {addons_dir}", file=sys.stderr)
    print(f"已有 labels: {len(load_existing_labels())} 条", file=sys.stderr)
    print("", file=sys.stderr)

    data = build_maps_json(addons_dir)

    total_maps = sum(len(camp["maps"]) for cat in data["categories"] for camp in cat["campaigns"])
    print(f"\n共 {len(data['categories'])} 个分类, {total_maps} 张地图", file=sys.stderr)

    if dry_run:
        print(json.dumps(data, indent=2, ensure_ascii=False))
    else:
        with open(MAPS_FILE, 'w') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        print(f"已写入 {MAPS_FILE}", file=sys.stderr)


if __name__ == "__main__":
    main()
