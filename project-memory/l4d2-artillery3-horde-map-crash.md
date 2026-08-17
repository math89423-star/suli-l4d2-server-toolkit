---
name: l4d2-artillery3-horde-map-crash
description: 火炮III touch-miss 罐子 L4D_DetonateProjectile 在无限尸潮图（dearesther m2 onslaught）引擎段错误；v1.7.2 改手动碎裂（粒子+info_goal_infected_chase）；粒子名待客户端确认
metadata: 
  node_type: memory
  type: project
  originSessionId: 97820438-7362-47f9-a35c-c5e76627a5c2
  modified: 2026-08-05T06:05:26.198Z
---

# 火炮 III 无限尸潮图崩溃（2026-08-05 13:53 ✅ v1.7.2 已修复部署）

**现象**：dearesther m2 游玩中段错误崩溃（srcds segfault signal 11，core 被 apport 拦截无落盘），srcds_run 自动拉起（自愈三件套生效），崩溃时 2 名玩家被踢。

**根因链（用户猜测"地图无限尸潮+火力支援3"验证成立）**：
1. `de_m2_onslaught.nut`（dearesther VPK 内嵌脚本）：`MobSpawnMinTime=1/MaxTime=3`（**每 1-3 秒一波**）、`MobMinSize=15/MaxSize=20`、`MobMaxPending=10`、开局 `PlayMegaMobWarningSounds` = 无限 MegaMob 尸潮（解包 `vpk -x` 见证据）
2. 火炮 III 绿色雨幕（kind=3）：工厂 `CVomitJarProjectile::Create` 生成胆汁罐；罐子触地**未触发引擎 Touch**（touch-miss）→ 0.15s 后 fallback 强拆 `L4D_DetonateProjectile(ent)`（引擎 `CBaseGrenade::Detonate`）
3. 崩溃帧：`VomitJar_Detonate pre` 已打日志、`bile applied` 未打 = **崩在引擎 detonate 喷胆汁阶段**（SM 日志权威，docker logs 的 stderr 行序不可靠）
4. 对照组：官图同路径 touch-miss 强拆 19 次全平安（今天 c14m2×3 / 昨天×16 / 前天×6）→ **僵尸压力是决定变量**（官方帖：ExplodeVomit = trace + 粒子 + sphere check + puke + info_goal_infected_chase）

**修复 v1.7.2**：touch-miss 不再调 `L4D_DetonateProjectile`，改**手动碎裂**（复刻 ExplodeVomit 结构）：`Kill` 罐子 + `info_particle_system` 碎裂粒子（`ART3_BREAK_PARTICLE`）+ `info_goal_infected_chase` 吸引 8s（控场本体，社区插件 SI Command Chase Common 同款用法，不依赖被淋状态）。

**⏳ 待办**：粒子名客户端验证——L4D2 粒子客户端渲染、服务端不验证（无效名静默）→ 已加 `sm_art3_pfx <effect_name> [x y z]` 测试命令，5 候选：weapon_vomitjar_break / vomitjar_break / vomitjar_impact / **boomer_explosion（当前默认）** / weapon_vomitjar_impact；用户上线看哪个有绿色液体飞溅后定稿替换 + 删除测试命令。

**排查要点**：left4dhooks 无手动上胆汁 native（全是 forwards）→ 被淋状态（m_hasBeenBoomed）本版本不可靠（见 [[l4d2-hardsi-boomedprop-crash]]），手动上胆汁路线不可行；相关历史：v1.7.85 修过另一个第三方图火炮 segfault（瞄准心跳空模型索引）。

相关：[[l4d2-artillery-strike]] [[l4d2-shop-decoupled]] [[l4d2-long-session-steam-crash-loop]] [[l4d2-vpk-pitfalls]]
