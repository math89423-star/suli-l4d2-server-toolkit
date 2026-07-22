#!/usr/bin/env python3
"""
extract_vpk.py — L4D2 VPK 一键诊断 + 提取 + 部署 + 验证

用法:
  python3 extract_vpk.py <vpk路径>               # 诊断 VPK，输出报告
  python3 extract_vpk.py <vpk路径> --extract     # 提取到 /tmp/vpk_extract/
  python3 extract_vpk.py <vpk路径> --deploy      # 一键提取 + 部署 + 验证（需要 root）

坑位覆盖:
  1. ZIP 伪装的 VPK → 自动检测，自动解压取内层真 VPK
  2. 巨型 VPK (220K+ 条目) → 自动检测，建议完整提取
  3. 中文文件名 VPK → 使用 latin-1 编码提取
  4. 提取后验证 → RCON 检查 maps 命令确认可用

依赖: pip install vpk (已安装), rcon (已安装)
"""

import argparse, json, os, shutil, subprocess, sys, tempfile, zipfile

# ── 配置 ─────────────────────────────────────────────────
CONFIG_FILE = "/opt/gameservers/l4d2/admin-panel/config.json"
DATA_DIR = "/opt/gameservers/l4d2/data"
ADDONS_DIR = f"{DATA_DIR}/addons"
MAPS_DIR = f"{DATA_DIR}/maps/maps"
MISSIONS_DIR = f"{DATA_DIR}/maps/missions"
SCRIPTS_DIR = f"{DATA_DIR}/maps/scripts"
MODELS_DIR = f"{DATA_DIR}/models"
MATERIALS_DIR = f"{DATA_DIR}/materials"
SOUND_DIR = f"{DATA_DIR}/sound"
COMPOSE_FILE = "/opt/gameservers/l4d2/docker-compose.yml"

ENTRY_WARN_THRESHOLD = 220000  # 超过此条目数建议提取
ENTRY_DANGER_THRESHOLD = 240000  # 超过此条目数几乎必定挂载失败

# ── 工具函数 ─────────────────────────────────────────────

def log(msg, level="INFO"):
    prefix = {"INFO": "  ✓", "WARN": "  ⚠", "ERROR": "  ✗", "STEP": "  →"}.get(level, "  -")
    print(f"{prefix} {msg}")

def get_entry_count(vpk_path):
    """从 file 命令输出提取 VPK 条目数"""
    try:
        result = subprocess.run(["file", vpk_path], capture_output=True, text=True)
        import re
        m = re.search(r'(\d+)\s+entries', result.stdout)
        return int(m.group(1)) if m else 0
    except:
        return 0

def get_vpk_file_list(vpk_path):
    """列出 VPK 内所有文件路径（使用 vpk Python 库，支持中文）"""
    try:
        import vpk
        with vpk.open(vpk_path, path_enc='latin-1') as pak:
            return list(pak)
    except Exception:
        return []

def extract_vpk_full(vpk_path, out_dir):
    """完整提取 VPK（使用 latin-1 处理中文文件名）"""
    import vpk
    os.makedirs(out_dir, exist_ok=True)
    count = 0
    failed = 0
    with vpk.open(vpk_path, path_enc='latin-1') as pak:
        for entry in pak:
            try:
                data = pak[entry].read()
                dst = os.path.join(out_dir, entry)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                with open(dst, 'wb') as f:
                    f.write(data)
                count += 1
            except Exception as e:
                failed += 1
                if failed <= 5:
                    log(f"提取失败: {entry} — {e}", "WARN")
    return count, failed

def rcon(cmd):
    """执行 RCON 命令"""
    with open(CONFIG_FILE) as f:
        cfg = json.load(f)
    from rcon.source import Client
    with Client(cfg["rcon_host"], cfg["rcon_port"], passwd=cfg["rcon_password"]) as c:
        return c.run(cmd).strip()

def verify_map(map_name):
    """验证服务器能否识别地图"""
    try:
        result = rcon(f"maps {map_name}")
        return "PENDING" in result
    except:
        return False

def restart_server():
    """重建 L4D2 容器"""
    subprocess.run(
        ["docker", "compose", "-f", COMPOSE_FILE, "up", "-d", "l4d2"],
        capture_output=True, check=True
    )

# ── 命令实现 ──────────────────────────────────────────────

def cmd_diagnose(vpk_path):
    """诊断 VPK 并输出报告"""
    if not os.path.exists(vpk_path):
        log(f"文件不存在: {vpk_path}", "ERROR")
        return 1

    log(f"诊断: {vpk_path}", "STEP")

    # 检测 1: 是否是 ZIP 伪装
    result = subprocess.run(["file", vpk_path], capture_output=True, text=True)
    file_type = result.stdout.strip()
    is_zip = "Zip archive" in file_type
    is_vpk = "Valve Pak" in file_type

    print(f"  文件类型: {file_type}")
    if is_zip:
        log("发现 ZIP 伪装的 VPK！需解压取出内层真 VPK", "WARN")
        # 检查 ZIP 内部
        try:
            with zipfile.ZipFile(vpk_path, 'r') as zf:
                names = zf.namelist()
                vpk_inside = [n for n in names if n.lower().endswith('.vpk')]
                print(f"  ZIP 内含 {len(names)} 个文件")
                for n in names[:10]:
                    print(f"    - {n}")
                if len(names) == 1 and vpk_inside:
                    log(f"修复: unzip {vpk_path} → 取出 {vpk_inside[0]} 放到 addons/", "STEP")
        except Exception as e:
            log(f"ZIP 读取失败: {e}", "ERROR")
    elif is_vpk:
        entry_count = get_entry_count(vpk_path)
        size_mb = os.path.getsize(vpk_path) / 1024 / 1024

        # 尝试列出实际文件数
        file_list = get_vpk_file_list(vpk_path)
        actual_files = len(file_list)
        has_models = any(f.startswith("models/") for f in file_list)
        has_materials = any(f.startswith("materials/") for f in file_list)
        has_sound = any(f.startswith("sound/") for f in file_list)
        has_scripts = any(f.startswith("scripts/") for f in file_list)
        bsp_count = sum(1 for f in file_list if f.endswith('.bsp'))
        mission_count = sum(1 for f in file_list if f.startswith('missions/'))

        print(f"  大小: {size_mb:.0f} MB")
        print(f"  条目: {entry_count} (实际文件: {actual_files})")
        print(f"  地图: {bsp_count} BSP, {mission_count} mission")
        print(f"  资源: models={'✓' if has_models else '✗'}, materials={'✓' if has_materials else '✗'}, "
              f"sound={'✓' if has_sound else '✗'}, scripts={'✓' if has_scripts else '✗'}")

        if entry_count >= ENTRY_DANGER_THRESHOLD:
            log(f"条目数 {entry_count} >= {ENTRY_DANGER_THRESHOLD}，服务器必定无法挂载！", "ERROR")
            log("建议: python3 extract_vpk.py <vpk> --deploy", "STEP")
        elif entry_count >= ENTRY_WARN_THRESHOLD:
            log(f"条目数 {entry_count} >= {ENTRY_WARN_THRESHOLD}，挂载可能失败", "WARN")
        else:
            log(f"条目数 {entry_count} < {ENTRY_WARN_THRESHOLD}，挂载大概率正常", "INFO")

        if has_models or has_materials:
            log("此 VPK 含自定义资源（模型/材质/音效），若需提取必须完整提取！", "WARN")
    else:
        log("无法识别的文件格式", "ERROR")
        return 1

    return 0


def cmd_extract(vpk_path, out_dir="/tmp/vpk_extract"):
    """提取 VPK 全部内容"""
    # 先判断是否 ZIP 伪装
    result = subprocess.run(["file", vpk_path], capture_output=True, text=True)
    file_type = result.stdout.strip()

    if "Zip archive" in file_type:
        log("检测到 ZIP 伪装，先解压...", "STEP")
        tmp_zip = tempfile.mkdtemp(prefix="vpk_unzip_")
        with zipfile.ZipFile(vpk_path, 'r') as zf:
            zf.extractall(tmp_zip)
        vpk_files = []
        for root, dirs, files in os.walk(tmp_zip):
            for fn in files:
                if fn.lower().endswith('.vpk'):
                    vpk_files.append(os.path.join(root, fn))
        if not vpk_files:
            log("ZIP 内未找到 VPK 文件", "ERROR")
            return 1
        vpk_path = vpk_files[0]
        log(f"内层 VPK: {vpk_path}", "INFO")

    if "Valve Pak" not in subprocess.run(["file", vpk_path], capture_output=True, text=True).stdout:
        log("不是有效的 VPK 文件", "ERROR")
        return 1

    log(f"提取到: {out_dir}", "STEP")
    count, failed = extract_vpk_full(vpk_path, out_dir)
    log(f"提取完成: {count} 个文件" + (f", {failed} 个失败" if failed else ""), "INFO")

    # 输出目录结构
    for category in ['maps', 'missions', 'models', 'materials', 'sound', 'scripts']:
        cat_dir = os.path.join(out_dir, category)
        if os.path.exists(cat_dir):
            file_count = sum(1 for _ in os.walk(cat_dir) for f in _[2])
            if file_count > 0:
                log(f"  {category}/ {file_count} 个文件")

    return 0


def cmd_deploy(vpk_path):
    """一键提取 + 部署 + 验证"""
    log("开始一键部署...", "STEP")

    # Step 1: 提取
    out_dir = "/tmp/vpk_extract"
    if os.path.exists(out_dir):
        shutil.rmtree(out_dir)
    ret = cmd_extract(vpk_path, out_dir)
    if ret != 0:
        return ret

    # Step 2: 部署到服务器目录
    log("部署文件到服务器目录...", "STEP")

    mappings = [
        ("maps", MAPS_DIR),
        ("missions", MISSIONS_DIR),
        ("scripts", SCRIPTS_DIR),
        ("models", MODELS_DIR),
        ("materials", MATERIALS_DIR),
        ("sound", SOUND_DIR),
    ]

    total_deployed = 0
    for src_name, dst_dir in mappings:
        src_dir = os.path.join(out_dir, src_name)
        if not os.path.exists(src_dir):
            continue
        os.makedirs(dst_dir, exist_ok=True)
        file_count = 0
        for root, dirs, files in os.walk(src_dir):
            for fn in files:
                src_path = os.path.join(root, fn)
                rel_path = os.path.relpath(src_path, src_dir)
                dst_path = os.path.join(dst_dir, rel_path)
                os.makedirs(os.path.dirname(dst_path), exist_ok=True)
                shutil.copy2(src_path, dst_path)
                file_count += 1
        if file_count > 0:
            log(f"  {src_name}/ → {dst_dir} ({file_count} 个文件)")
            total_deployed += file_count

    log(f"共部署 {total_deployed} 个文件")

    # Step 3: 提取地图名并验证
    log("提取地图名...", "STEP")
    bsp_files = []
    for root, dirs, files in os.walk(os.path.join(out_dir, "maps")):
        for fn in files:
            if fn.lower().endswith('.bsp'):
                bsp_files.append(fn[:-4])  # 去掉 .bsp

    if bsp_files:
        log(f"发现地图: {', '.join(bsp_files)}")

    # Step 4: 确认重启
    print()
    log("需要重建容器以使新文件生效", "WARN")
    resp = input("  是否立即重建 l4d2-server 容器？[y/N] ").strip().lower()
    if resp == 'y':
        log("重建容器...", "STEP")
        try:
            restart_server()
            log("容器已重建", "INFO")
        except Exception as e:
            log(f"重建失败: {e}", "ERROR")
            return 1

    # Step 5: 验证
    log("等待服务器启动...", "STEP")
    import time
    time.sleep(8)

    log("验证地图...", "STEP")
    all_ok = True
    for map_name in bsp_files[:3]:  # 验证前 3 个
        ok = verify_map(map_name)
        status = "✓ 可用" if ok else "✗ 未找到"
        if not ok:
            all_ok = False
        log(f"  {map_name}: {status}")

    if all_ok:
        log("全部验证通过！", "INFO")
    else:
        log("部分地图未找到，请检查服务器日志", "WARN")

    # Step 6: 清理
    shutil.rmtree(out_dir, ignore_errors=True)
    log(f"临时文件已清理: {out_dir}")

    return 0


# ── Main ──────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="L4D2 VPK 诊断/提取/部署工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  %(prog)s map.vpk                诊断 VPK
  %(prog)s map.vpk --extract      提取到 /tmp/vpk_extract/
  %(prog)s map.vpk --deploy       一键提取+部署+重启+验证
        """
    )
    parser.add_argument("vpk", help="VPK 文件路径")
    parser.add_argument("--extract", "-x", action="store_true", help="完整提取 VPK")
    parser.add_argument("--deploy", "-d", action="store_true", help="一键提取+部署+验证")
    parser.add_argument("--output", "-o", default="/tmp/vpk_extract", help="提取输出目录")
    args = parser.parse_args()

    if not os.path.exists(args.vpk):
        log(f"文件不存在: {args.vpk}", "ERROR")
        return 1

    if args.deploy:
        return cmd_deploy(args.vpk)
    elif args.extract:
        return cmd_extract(args.vpk, args.output)
    else:
        return cmd_diagnose(args.vpk)


if __name__ == "__main__":
    sys.exit(main())
