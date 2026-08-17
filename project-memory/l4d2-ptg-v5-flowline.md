---
name: l4d2-ptg-v5-flowline
description: PTG v5.0.0 正式版（flow 梯度 + 全图一次 BFS）部署状态：卡顿根治 ✓ 线消失修复 ✓；v5.0.1 幽灵定时器+换图残留修复已装盘待 reload
metadata: 
  node_type: memory
  type: project
  originSessionId: 3b815306-9932-46c4-a273-89e0ccf4f19a
  modified: 2026-08-12T15:17:24.898Z
---

# PTG v5.0.0 正式版状态（2026-08-04）

替代弃用的 A* v4.8.3（[[l4d2-ptg-disabled]]），架构 = 引擎 flow 梯度 + 一次全图 BFS 桥接。部署在 `l4d_path_to_goal.sp`（正式版，非实验插件）。

## 已修根因（v5.0 迭代）

1. **reload 后 OnMapStart 不触发 → 表空全灭**（c5m3 01:50 len=2 刷屏）：`EnsureInitForCurrentMap()` 懒初始化——每次 !ptg/画线前比对当前地图名与建表地图，不一致或表空则全量重建（ResetMapState 先清旧表防跨图残留）。reload/换图/首次调用三场景覆盖。
2. **碎步 BFS → 卡顿**（c5m3 366 次碎步桥接 + guard=2000 撞顶，len=3464 绕圈路径，每帧全图级计算）：根治 = **BFS 一次全图直达**——深限 = 全节点数（无 2000 硬限）、目标优先级 goalArea → flow 最大可达（同层 ±150u 优先，跨层需 +500 flow 防爬楼）→ fallback 欧氏最远；**gradient 卡住后 BFS 补全程即 break（每次路径 ≤1 次 BFS）**。c5m3 实测 len=173 bridges=1 guard=172（vs 旧 3464/366/2000），**不卡了**。
3. 重算节流：移动 <128u 用缓存 + 重算间隔 ≥0.5s（大图 BFS 成本线性，快跑不逐帧算）。

## 未解决 → ✅ 已修复并部署验证（2026-08-04 09:51 reload,09:58 实测通过）

- **根因（error 日志实锤）**：DrawPathList 结尾 `delete path;`（旧 874 行）与 790 注释"本函数不 delete"矛盾 → 双重释放
  - 重算分支：770 DrawPathList 删掉 path → 771 `delete path` 二次释放崩（error 3, Handle invalid）
  - 缓存分支：745 DrawPathList 传入 `g_hPathCache[i]` 被删 → 下次 cache-hit 判定 `!= null` 照过（悬垂）→ 788 读 Length 崩 → 每 0.3s 崩一次,draw 日志消失,线消失
  - 现象吻合：draw ×2 出现 0.9s → 全灭；diag cache-hit 照打（在 788 崩之前）造成"重算正常"假象；同 bug 凌晨 01:42 旧版行号也崩过
- **修复**：① 删除 DrawPathList 的 `delete path;` ② 缓存分支判定加 `g_fPathCacheTime[i] > 0.0` 双保险（防悬垂句柄非 null 回归）
- **验证（09:58）**：draw 每 0.3s 持续输出 + 重算分支（len 284→87 移动重算）无错 + errors log 零新记录。✅
- 顺带：draw 日志每 0.3s 无条件打,刷屏量大,可后续加限频（诊断期保留）

## 验证数据

- c5m3_cemetery：5084 areas、虚拟边 83（LOS 74 + 实体桥 9）、初始化 84ms；路径 len=173（出生 → 教堂出口）
- silenthill（l4d_sh04_church）：6377 areas、4 向梯度 73.0%、BFS 桥 91.7% 总覆盖
- 死亡厕所迷宫（troll 图）：nav 无解（正确路径需炸墙+交叉密码，实体交互不在 nav 数据），实体桥模式放行

## 新方向（用户构想，未实现）

**VPK 解包预处理烘焙**：任何上传地图都持有 VPK，可解包提取 BSP 实体链（明文 keyvalues）+ VScript 源码（.nut 明文）+ 字幕 → 烘焙出"正确流程导航/攻略"。RE1 实证：codigo1-4.nut 密码 0815/5172/4392/1746 + codigo_pc.nut 91969 + agarrar_cosas.nut 可拿道具（caja_1-3/libro/vjolt）；BSP 实体 lump 在 VBSP 魔数后 offset 12 起（lump 表）、实体纯文本。见 [[l4d2-vpk-unpack-guide]]（待写）。谜题图破局点：交互实体全在实体数据里。

## v5.0.1（2026-08-12，已装盘待 reload，commit 71a998b）

三个修复（用户触发：查"第二个玩家开启 PTG 没反应"时发现）：

1. **幽灵定时器泄漏**：Timer_ToggleRedraw 旧写法"回调开头排下一轮 + !anyOn 置 null return" → 置空后无人杀刚排的定时器，累积并发幽灵定时器。改"干活干完再排"。详见 [[l4d2-ptg-timer-bug]]
2. **换图 toggle 状态残留**：ResetMapState 不清 g_bGuideToggled/g_hPathCache → 换图后第一次 !ptg 报"已关闭"假象。现逐客户端清理
3. **draw 日志降频**：0.3s/条 → 10s/客户端（g_fLastDrawLog 节流）

**多玩家调查结论**：v5.0.0 本就支持多人（8-04 双玩家叠加实测）；今日"第二人没反应"日志显示命令从未到达插件（无 toggle 行/无 error/无命令冲突）——玩家端问题（没打 ! 前缀/命令名错/没进游戏），待复测确认。

**v5.0.1 已热更新（2026-08-12 23:16 RCON `sm plugins reload l4d_path_to_goal`）**：日志确认 running，errors 干净。重载丢在线玩家 toggle 状态（需重新 !ptg），懒初始化自动建表。

相关：[[l4d2-flow-path-validation]] [[l4d2-ptg-disabled]] [[l4d2-dont-touch-server]] [[l4d2-ptg-timer-bug]]
