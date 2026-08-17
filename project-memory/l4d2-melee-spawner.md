---
name: l4d2-melee-spawner
description: 关卡开始时在安全屋刷新全部 13 种近战武器各一把，螺旋散布防堆叠
metadata: 
  node_type: memory
  type: project
  tags: 
    - l4d2
    - plugin
    - melee
  originSessionId: 1962b2f3-bd59-4a3f-8694-26aff5a76ffc
---

# L4D2 近战武器全刷新插件

## 文件位置

- 源码: `l4d2-server/sourcemod/scripting/l4d2_melee_spawner.sp`
- 编译: `l4d2-server/sourcemod/scripting/compiled/l4d2_melee_spawner.smx`
- 部署: `/opt/gameservers/l4d2/data/addons/sourcemod/plugins/l4d2_melee_spawner.smx`

## 功能

- 每关 `round_start` 触发（含团灭重来）
- 延迟 2 秒后找到安全屋复活点（`info_survivor_position` → `info_player_start` → 幸存者位置）
- 刷新全部 **13 种** 近战武器各一把：fireaxe, baseball_bat, cricket_bat, crowbar, electric_guitar, frying_pan, katana, machete, tonfa, golfclub, knife, shovel, pitchfork
- 使用黄金角螺旋散布（~137.5°），配合 `TR_TraceRay` 找地面，确保不掉落堆叠、不浮空
- 武器均匀分布到所有复活点（每个复活点承担 ceil(13/spawnCount) 把）

## 防堆叠机制

1. **黄金角螺旋**: 每增加一把武器旋转 137.5°，间距 55 units + 递增半径，天然避免重叠
2. **地面 Trace**: 从上方 trace 到下方 500 units，穿透武器/玩家实体，只碰世界几何体，找到真实地面后 +6 unit 放置
3. **多复活点分散**: 13 把武器分摊到 4 个 info_survivor_position，每个点最多 4 把

## ConVar

| ConVar | 默认值 | 说明 |
|--------|--------|------|
| `sm_melee_spawner_enable` | 1 | 开关 (0=关, 1=开) |
| `sm_melee_spawner_spacing` | 55.0 | 武器最小间距 (units, 40-100) |

## 加载/卸载

- 加载: `sm plugins load l4d2_melee_spawner`
- 卸载: `sm plugins unload l4d2_melee_spawner`
- 卸载后删除 smx，否则换图时自动重新加载
- 配置文件: `cfg/sourcemod/l4d2_melee_spawner.cfg`

## 关联

- [[l4d2-plugin-inventory]] — 插件清单
- [[l4d2-server-quick-reference]] — 管理速查
- [[l4d2-howto-plugins]] — 插件管理
