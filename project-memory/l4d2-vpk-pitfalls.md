---
name: l4d2-vpk-pitfalls
description: VPK 三方图挂载失败的两个致命坑 + 修复方法，以及切回官图后特感插件需重载
metadata:
  type: reference
  tags:
    - l4d2
    - vpk
    - thirdparty-maps
    - pitfall
    - si-plugins
  originSessionId: 87f7d123-529c-4361-9c50-7bc8461e0 |
  modified: 2026-08-01T12:17:45.140Z
---

# L4D2 VPK 三方图挂载坑

## 坑 #1：ZIP 伪装的 VPK

**症状**：`sm_map <map>` 返回 `Map not found`，但 VPK 文件在 addons/ 里。

**检测**：
```bash
file /path/to/addons/xxx.vpk
# 输出: "Zip archive data" → 这是 ZIP 伪装的！
# 正确应是: "Valve Pak file, version 1, N entries"
```

**修复**：
```bash
unzip xxx.vpk -d /tmp/fix/
# 里面会有真正的 xxx.vpk
cp /tmp/fix/xxx.vpk /opt/gameservers/l4d2/data/addons/
docker restart l4d2-server
```

**来源**：gamemaps.com 部分下载的 ZIP 包把 VPK 再包了一层 ZIP。

**实际案例**：deadcity2.vpk（死城2）— ZIP 包，内藏 67K 条目的真 VPK。

---

## 坑 #2：巨型 VPK（255K+ 条目）服务器静默挂载失败

**症状**：VPK 有效（`file` 输出 `Valve Pak file`），`strings xxx.vpk | grep '.bsp$'` 能看见 BSP 路径，但 `sm_map` 返回 `Map not found`。服务器日志无任何错误。**完全静默，极难排查。**

**检测**：
```bash
# 检查 VPK 条目数
file /path/to/addons/xxx.vpk
# 输出: "Valve Pak file, version 1, 255583 entries"  ← 超过 220K 即高危

# 验证是否挂载成功
python3 -c "
from rcon.source import Client
with Client('127.0.0.1', 27015, passwd='PASSWORD') as c:
    print(c.run('maps <expected_map_name>'))
"
# 输出空 = 未挂载；输出 "PENDING: (fs) xxx.bsp" = 已挂载
```

**根因**：SRCDS 挂载 VPK 时需解析目录树到内存。条目数过大（如 255K）时静默失败，不报任何错误。经测试边界约在 220K 条目附近（darkwood 195K ✅, dearesther 219K ✅, yama 225108 ✅, gzzc 255K ❌）。

**⚠️ 重要**：不能只提取 BSP！必须完整提取 VPK 内所有内容。广州增城有 7929 个文件：models/ 3658 个、materials/ 4191 个、sound/ 31 个、scripts/ 31 个。缺任意一个 → 物理墙/贴图/音效丢失。

**完整修复流程**：
```bash
# 1. 完整提取 VPK
python3 /home/ubuntu/l4d2-server/scripts/extract_vpk.py <vpk路径>

# 2. 创建宿主机目录并复制文件
mkdir -p /opt/gameservers/l4d2/data/{models,materials,sound}
cp -r /tmp/vpk_extract/maps/*     /opt/gameservers/l4d2/data/maps/maps/
cp -r /tmp/vpk_extract/missions/* /opt/gameservers/l4d2/data/maps/missions/
cp -r /tmp/vpk_extract/scripts/*  /opt/gameservers/l4d2/data/maps/scripts/
cp -r /tmp/vpk_extract/models/*   /opt/gameservers/l4d2/data/models/
cp -r /tmp/vpk_extract/materials/* /opt/gameservers/l4d2/data/materials/
cp -r /tmp/vpk_extract/sound/*    /opt/gameservers/l4d2/data/sound/

# 3. docker-compose.yml 需挂载（一次性操作，已添加）
#    - ./data/models:/home/louis/l4d2/left4dead2/models
#    - ./data/materials:/home/louis/l4d2/left4dead2/materials
#    - ./data/sound:/home/louis/l4d2/left4dead2/sound

# 4. 重建容器
docker compose -f /opt/gameservers/l4d2/docker-compose.yml up -d l4d2
```

**一键脚本**：`python3 /home/ubuntu/l4d2-server/scripts/extract_vpk.py <vpk路径> --deploy` 自动完成检测+提取+部署+验证。

**实际案例**：gzzc7.9.vpk（广州增城 Lv7.9）— 834MB, 255K 条目，7929 个实际文件。所有其他 VPK（darkwood 195K, dearesther 219K）正常挂载，仅此 VPK 失败。

**docker-compose 新增挂载**（2026-07-22）：
```yaml
- ./data/models:/home/louis/l4d2/left4dead2/models
- ./data/materials:/home/louis/l4d2/left4dead2/materials
- ./data/sound:/home/louis/l4d2/left4dead2/sound
```
这些挂载不仅用于巨型 VPK 的提取文件，也可用于未来任何需要自定义模型/材质的模组。

---

## 坑 #3：VPK Python 库的中文编码

**症状**：`vpk` 命令行工具或 `vpk.open()` 报 `'utf-8' codec can't decode byte 0xb8`。

**根因**：`vpk` Python 库默认用 UTF-8 解码 VPK 内部路径名。中文地图制的 VPK 含有 GBK 编码文件名。

**修复**：
```python
# 用 latin-1 打开（接受任意字节，不解码失败）
with vpk.open(vpk_path, path_enc='latin-1') as pak:
    ...
```

---

## 坑 #4：切离 tumtara 后特感插件永久卸载

**症状**：切到 tumtara → 三个多特感插件被卸载（`AI_HardSI`, `specialspawner`, `spawn_infected_nolimit`）→ 切回官图或其他三方图时插件**未重载** → 从此零特感。

**根因**：`app.py` 和 `switch_map.py` 只有"切到 tumtara 时卸载"的逻辑，没有"切离 tumtara 时重载"的逻辑。

**修复**：已在 2026-07-22 修复 — 检测 `current_map in tumtara_maps` 且 `target not in tumtara_maps` 时，在 `sm_map` 后执行 `sm plugins load`。

**关联**：[[l4d2-tumtara-pitfalls]]

---

## 快速诊断命令

```bash
# 检查服务器能看到的自定义地图
python3 -c "
from rcon.source import Client
with Client('127.0.0.1', 27015, passwd='PASSWORD') as c:
    for m in ['zc1_m1','dc2m1_riverside','dw_woods','atr01_trailer_park',
              'de_donnelley_m1','re1m1','ddg1_tower_v2_1',
              'l4d2_lab024_01','l4d2_tanksplayground']:
        r = c.run(f'maps {m}')
        print(f'{m:30s} {\"FOUND\" if \"PENDING\" in r else \"NOT FOUND\"}')"

# 检查所有 addons VPK 是否真实（非 ZIP）
for vpk in /opt/gameservers/l4d2/data/addons/*.vpk; do
  type=$(file "$vpk" | grep -o 'Valve Pak\|Zip archive')
  echo "$(basename $vpk): $type"
done
```

## 关联

- [[l4d2-howto-thirdparty-maps]] — 三方地图操作总览
- [[l4d2-tumtara-pitfalls]] — tumtara 专属坑
- [[l4d2-map-switch-pitfalls]] — 切图系统性缺陷
- [[l4d2-deployment-rules]] — 部署铁律
- [[l4d2-admin-map-management]] — Admin Panel 地图管理
