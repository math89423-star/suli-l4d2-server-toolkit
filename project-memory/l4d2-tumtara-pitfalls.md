---
name: l4d2-tumtara-pitfalls
description: tumtara (Workshop 469986973) 测试图专属坑，每次涉及 tumtara 时必须对照检查
metadata: 
  node_type: memory
  type: reference
  tags: 
    - l4d2
    - tumtara
    - thirdparty-maps
    - pitfall
  modified: 2026-07-28T09:09:13.352Z
  originSessionId: 3baba4d6-bc5e-4746-b270-85d13bf2008e
---

# tumtara (469986973) 踩坑清单

## 致命坑（会导致崩溃/不可连接）

| # | 坑 | 检查方法 | 修复 |
|---|-----|---------|------|
| 1 | VPK 放 addons/ | `ls data/addons/*.vpk` | 删掉 VPK，只留提取出的 BSP |
| 2 | 14 子图只提了 2 个 BSP | `ls data/maps/maps/tumtara*.bsp \| wc -l` | 从 Steam 工坊重下 VPK，提取全部 13 个 BSP（主图 + 12 子图）。缺失子图→切图 Host_Error |
| 3 | 无 nav mesh | `ls data/maps/maps/tumtara*.nav` | 不可修复（测试图不包含 nav），但 **specialspawner 等特感插件现已兼容无 nav 地图**（2026-07-28 验证） |
| 4 | start-l4d2.sh 默认 tumtara | 检查脚本 | 默认地图改为 c1m1_hotel，tumtara 只做按需手动切换 |
| 8 | VPK 残留毒害客户端 | 切图后检查 | 换回官图后确保 VPK 不在 addons/，否则推送 982 resources 踢所有玩家 |
| 10 | heapsize 不够 | docker-compose.yml | 207MB VPK + 982 resources → 至少 1.5GB heapsize（当前已设置） |

## 功能性坑

| # | 坑 | 影响 |
|---|-----|------|
| 5 | Invalid counterterrorist spawnpoint 刷屏 | CS:S 出生点 warning（cosmetic） |
| 6 | custom tank finale phase 失败 | 测试图无 Tank 终局实体 |
| 7 | outro_camera 父实体缺失 | 终局过场镜头异常 |
| 11 | l4d1 版本 BSP 残留 | tumtara_l4d1.bsp 对 L4D2 无用，占 33MB，可能干扰 mission 解析 |

## 技术坑

| # | 坑 | 说明 |
|---|-----|------|
| 9 | VPK 是 cooked 格式 | gamemaps.com 用 CRC32 哈希存目录树，用 `pip install vpk` 或 unzip（ZIP 伪装） |
| 12 | 24 个 VScript 拖慢启动 | 启动时解析所有 .nuc/.nut，即使子地图 BSP 缺失 |

## 切 tumtara 标准流程

**2026-07-28 更新：四个特感插件（AI_HardSI、specialspawner、spawn_infected_nolimit、si_composition_manager）现已兼容 tumtara，无需卸载。直接切图即可。**

## ⚠ 坑 13：武器按钮失灵（WeaponNames 表缺失）——2026-08-16 已修复

**症状**：地图上的 M60/榴弹"捡不了"——实为 **func_button + RunScriptCode
`self.GiveItem(WeaponNames.m60/grenadelauncher)`** 发放武器，但 `WeaponNames` 表
未定义 → 日志刷 `the index 'WeaponNames' does not exist` → 按钮只报错不发枪。
地面上挂榴弹模型的实体其实是 `weapon_ammo_spawn`（弹药堆），不是武器本身。

**根因**：
1. VPK 早已删除（只留 BSP）→ tumtara 的 vscripts 全部缺失（BSP 引用的
   tumtara_common/special_toggle_functions/tumtara_infotext 等）
2. 即使重新下载工坊 VPK（`steamcmd +workshop_download_item 550 469986973`，
   文件在 `/root/.local/share/Steam/steamapps/workshop/content/550/469986973/
   16039962154341904021_legacy.bin`，216MB，Valve VPK v1 格式，`pip install vpk`
   可解析），**当前版本的 tumtara_common.nuc（加密字节码）里也没有 WeaponNames 定义**——
   地图作者漏了/版本差异，全 VPK + BSP 均无定义

**修复（已在服务器生效）**：
1. 从 VPK 提取全部 tumtara_* 脚本（22 个 .nut/.nuc）+ special_toggle_functions.nut
   装到 `/opt/gameservers/l4d2/data/maps/scripts/vscripts/`（真实挂载目录！
   docker-compose 挂的是 `./data/maps/scripts`，不是 `./data/scripts`）
2. **给 special_toggle_functions.nut 追加 `::WeaponNames <- {...}` 全局表**
   （cola/fireworks/gas/gnome/grenadelauncher/Hands/m60/oxygen/propane →
   L4D2 classname），按钮即恢复发枪
3. 验证：WeaponNames 报错 0，用户实测按钮正常发 M60/榴弹

**遗留（cosmetic）**：地图启动时 `tankrumble_off`/`glow_far_off` 报 2 个错
（地图作者触发顺序问题：OnMapSpawn 早于脚本加载），不影响功能，未修。

**提取脚本命令备忘**：
```python
import vpk
v = vpk.open('/tmp/tumtara.vpk')   # 或直接指向 workshop 的 legacy.bin
for item in v.items():
    if 'vscripts' in item[0] and item[0].endswith(('.nut','.nuc')):
        open('/opt/gameservers/l4d2/data/maps/scripts/vscripts/'+os.path.basename(item[0]),'wb').write(v.get_file(item[0]).read())
```

## 切 tumtara 标准流程（原）

**2026-07-28 更新：四个特感插件（AI_HardSI、specialspawner、spawn_infected_nolimit、si_composition_manager）现已兼容 tumtara，无需卸载。直接切图即可。**

```python
python3 -c "
from rcon.source import Client
with Client('127.0.0.1', 27015, passwd='Nxp4HJ1xE2Jtzjng') as client:
    client.run('sm_map tumtara')
"
```

## 切回官图标准流程

```python
python3 -c "
from rcon.source import Client
with Client('127.0.0.1', 27015, passwd='Nxp4HJ1xE2Jtzjng') as client:
    client.run('sm_map c1m1_hotel')
"
```

## 关联

- [[l4d2-deployment-rules]] — 铁律 #12 已废除（多特感插件兼容 tumtara）
- [[l4d2-howto-thirdparty-maps]] — 三方图安装/切换指南
