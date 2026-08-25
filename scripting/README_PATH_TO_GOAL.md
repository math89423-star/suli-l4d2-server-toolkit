# l4d_path_to_goal — flow 梯度下降导航插件

> 版本: 5.0.4 (2026-08-25) | 作者: server
> 前身: PTG v4.8.3 / A* 引擎 v1.55（11k 行自建管线，已弃用）

## 概述

为 Survivor 实时绘制通往章节出口的引导线。核心思路：**引擎 flow 场本身就是导航答案**——
flow = 从地图出生点沿 nav 的弧长，递增方向即出口方向。从玩家所在 nav area 沿
4 向邻接做 flow 严格递增的梯度上升即可到达终点，无需自建搜索。

`!ptg` / `!guide` / `!wheretogo` 等命令单击开、再击关。

---

## 算法

```
起点 = 玩家所在 nav area（同层逐级放大 500→2000u 搜索；
        孤岛 area 跳过；跨层兜底 anyZ）
目标 = 出口实体 area（script_changelevel > trigger_changelevel > trigger_finale）
       找不到实体 → 出生点基准欧氏最远的同层 area

主循环（≤2000 步）:
  ① 到达判定: RESCUE_VEHICLE 属性 / goalArea / flow ≥ 地图上限×95%
  ② 梯度步: 4 向邻接中选 flow 严格递增者（见下方安全守卫）
  ③ 梯度卡住 → 一次 BFS 全图桥接后结束:
     BFS 覆盖 4 向 + 虚拟边，目标优先级:
       goal 直达 > 同层 flow 最大可达（跨层需 +500u 显著更优）
       > fallback 模式下可达集欧氏最远点
     正常无解再降级一次 fallback（部分导航: 画到可达集最深处 + 红 beacon）
```

### 安全守卫（v5.0.4）

| 守卫 | 规则 | 防的事故 |
|------|------|---------|
| Z 过滤 | 梯度 Δz>120u / BFS Δz>150u 的邻居跳过 | 悬崖边误连导致"跳楼线" |
| 攀爬守卫 | 向上 Δz∈(66,120] 须过 WalkableBetween 中点地面采样 | 66u=生还者跳跃上限；垂直墙/悬崖中点地面在低处被拒，坡道/楼梯/跳台放行 |
| 实体桥阻挡证明 | 门/炸墙配对前 trace 两 area 连线(+36u)，须命中该实体本身 | 电梯井两侧楼板、壁橱门被误配成通道 |
| 虚拟边门槛 | LOS(+30u) + WalkableBetween 三点采样 ±40u + dz≤60 + dist<400 | 细射线飞过墙顶、跳楼边中间悬空的假连接 |

### 虚拟边（补 nav 缺失连接）

三方图大量存在"玩家能走但 nav 没连"的孤岛。跨 4 向连通组件的近邻 area 对，
通过上述门槛后双向注册虚拟边，BFS 与 4 向一并搜索。
网格桶预筛（128u），**扫描半径 ±3 桶**——中心距 400u 的配对最坏相隔 4 桶，
±1 会系统性漏配（v5.0.4 FIX3，c2m1 实测合法连接 28→100 条）。

### 实体桥（门/可炸墙）

nav 作者故意不连的交互通道（prop_door_rotating / func_door* / func_breakable）：
实体中心沿门面法向 ±70u 各取最近同层 area 配对注册。v5.0.4 起必须通过阻挡证明
（c2m1 实测 30 个候选中 22 个是井道/空穿假配对，8 个真门全部保留）。

---

## 渲染

- **琥珀色线** = 正常路径；**红色线** = 该段 LOS 异常或断链终点
- 画法: nav center 连线（+10u）；穿墙时用共享边中点 A→M→B 中转；仍失败标红
- 近段 6 段全量、远段抽样（客户端 TE 缓冲上限 `l4d_path_to_goal_max`=32）
- 终点竖线 beacon: 绿=到达出口，红=死路/机关断链
- 衔接段无条件从玩家脚底画起（防止"线停留在原地"）

## 性能设计

- **预构建表**（首次 !ptg 懒初始化）: area→index、邻居 index、flow、center，
  BFS 运行时零 StringMap/native（死亡厕所迷宫全图 BFS 卡顿的根治）
- **路径缓存**: 移动 <128u 或 <0.5s 内复用（重算节流），快跑不逐帧算
- **每客户端独立重画定时器**（0.3s）：修复多玩家 TE buffer 竞争（v5.0.2）
- 虚拟边/实体桥每图构建一次（c2m1 6520 areas ≈ 200ms，一次性）

## 特殊地图策略

flow 覆盖率 <20% 判定为谜题/陷阱图：
- 有实体桥 → 桥接模式放行（线引导至机关/炸墙点，按逻辑推进）
- 无实体桥 → 数据层无解，提示后禁用

---

## ConVar

| Cvar | 默认 | 说明 |
|------|------|------|
| `l4d_path_to_goal_enable` | 1 | 总开关 |
| `l4d_path_to_goal_duration` | 0.5 | 光束寿命秒数（须 > 重画间隔 0.3s，防闪烁；过长会残留旧位置）|
| `l4d_path_to_goal_max` | 32 | 单次最大光束段数（客户端缓冲上限）|

## 命令

| 命令 | 权限 | 说明 |
|------|------|------|
| `ptg` / `guide` / `wheretogo` / `imlost` / `pathtogoal` / `path_to_goal` | 玩家 | 单击开/关导航线 |
| `ptg_recalc` | ROOT | 重建导航表并打印诊断: 边数/实体桥明细（OK/REJECT 逐条坐标）/ 各幸存者路径摘要 |

## 文件清单

| 文件 | 状态 |
|------|------|
| `scripting/l4d_path_to_goal.sp` | **全部逻辑在此单文件** |
| `scripting/include/l4d_path_to_goal.inc` | 遗留（A* 版核心，未被引用）|
| `scripting/include/gvazdas_navmesh_utils.inc` | 遗留（同上）|
| `gamedata/l4d_path_to_goal.txt` | 遗留（A* 版 dhooks 签名，未使用）|
| `translations/l4d_path_to_goal.phrases.txt` | 未使用 |

依赖仅 `sourcemod` + `left4dhooks`（nav 邻接/flow/navarea 系列 native）。

---

## 版本历史要点（教训库）

- **v5.0.1**: 换图清 toggle 标志与路径缓存（残留导致首按无效/脏数据画线）；
  定时器句柄管理改为"回调自然结束"（悬垂句柄空转翻倍画线速率）
- **v5.0.2**: 多玩家 TE buffer 竞争 → 每客户端独立定时器
- **v5.0.3**: timer 不强制 delete（正在执行的 Handle 强删崩溃），只清标志
- **v5.0.4**: 三处纯拒绝/同门槛扩召回——实体桥阻挡证明、攀爬守卫、
  虚拟边扫描 ±3 桶；新增 `ptg_recalc` 诊断。验证: c2m1 两点位路径与
  v5.0.3 逐位一致（主线零回归），详见 git 提交 95083ed
- 更早教训已内化为代码注释（起点跨层捞取、flow 孤岛 fallback、
  缓存句柄悬垂连环崩等，见源码各节注释）
