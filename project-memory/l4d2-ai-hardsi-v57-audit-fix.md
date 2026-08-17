---
name: l4d2-ai-hardsi-v57-audit-fix
description: AI_HardSI_bt v5.7.0 已部署（2026-08-13）——Hunter 站桩根因修复 + LOS 迁移补完，待玩家实测
metadata: 
  node_type: memory
  type: project
  originSessionId: 84e3242d-ad42-4f7c-b86b-9435fdc99ebc
  modified: 2026-08-13T08:19:12.391Z
---

# AI_HardSI_bt v5.7.0（2026-08-13 审计修复，已部署 reload，待玩家实测）

用户实测报告："Hunter 站桩"+"特感原地不动靠近才动"。4 agent 并行审计 + 逐条源码复核后修复，commit 3181240（AI 改动）+ bc8a678（存量同步），全部已推送 GitHub。

## 根因与修复

- **Hunter 是 v5.6 唯一漏迁移 LOS 的树**（9× CND_HasLOS 挂引擎 m_hasVisibleThreats，该标志被插件每 2 帧覆盖朝向/按键后失真）→ 8 个扑击分支全部不可达。v5.7 全部改 Acquire + CND_HasTargetLOS + IsTargetInRange。
- **crouchPrep 站桩**：ACT_Crouch 每 tick SUCCESS（零移动只按 DUCK），幸存者 ≤500u 时持续胜出。修复 = Crouch 包 Cooldown(2.5)。
- Spitter 吐锁改真实发射时刻（ability_spit 事件置 g_bSpitterSpitFired，按住 IN_ATTACK 至发射/1.5s 超时）——Boomer v5.6 同款修复 Spitter 漏跟进。
- ACT_CircleFlank 远距偏移 120°→55°：v5.6 横移键修复后净向量 75° 方向接近速率仅 cos75°≈26%（Charger 52s 绕路现场），55° 后 ~98%。
- Tank 4× LOS 迁移 + bhop 门控迁移；Charger coordSeq 补 AcquireCoordTarget；Jockey mode1 距离改 target 口径；CND_IsTargetPinned 优先黑板 target。

## 拍板跳过（设计如此/无实锤）

- **Smoker 850u 门不改**：代码库注释自证 tongue max ~850u（v5.6 已全树统一），审计声称 1100u 无实锤。
- **Jockey leap 无下界门不改**：<250u 引擎拒绝 leap → 挠击（有伤害），注释明示是设计兜底。
- Charger 12s 冷却漂移（按键≠真实 charge）挂起未修。
- 编译 13 warnings 全是存量未使用符号（ACT_SnapAimToTarget 现在零引用 = 迁移完成的反证）。

## 验证方法（等玩家上线）

ai_debug 开着时读 g_iBTLastWinningChild：Hunter crouchPrep=11 占比应大幅下降、扑击分支（0-10）应开始出现。**Tank 根是 SEQUENCE，ai_debug 对 Tank 盲区**（LastWinningChild 只在 SELECTOR 写入）。

## 工作流新规（用户拍板 2026-08-13）

**不留 smx 备份**（plugins/*.smx.bak.* 模式废除），Git 管理一切源码，smx 是 gitignore 的构建产物。历史 18 个 .bak 已按用户指示全部清除（2026-08-13）。相关：[[l4d2-si-ai-audit-v56]] [[l4d2-deployment-rules]] [[l4d2-git-repo]]
