---
name: l4d2-gl-splash-fix
description: L4D2 榴弹爆炸伤害插件定稿 v2.1.24 — 引擎对幸存者后置扣血=m_flDamage×falloff×(1/15) 唯一杠杆；Witch DMG_GENERIC 注入；击杀卡英文根因
metadata:
  node_type: memory
  type: project
  originSessionId: 0deba71b-de56-41a6-baf3-b2147aae62c1
  modified: 2026-08-02T07:08:55.463Z
---

# L4D2 榴弹爆炸伤害（splash_fix v2.1.24 定稿，2026-08-02）

源码：`scripting/l4d2_gl_splash_fix.sp`（v2.1.24）；cfg：`cfg/sourcemod/l4d2_gl_splash_fix.cfg`。

## 伤害模型（用户逐项实测拍板）

| 目标 | 伤害 | 机制 |
|---|---|---|
| 队友直击/溅射 | ≈18 / ≈10（v2.1.25） | **引擎后置扣血 = m_flDamage×falloff×(1/15)**，唯一杠杆 = `sm_gl_engine_damage 270` |
| 自己（贴脸） | ≈14 | boom 注入 attacker=0（750×falloff×self_mult 0.02） |
| Witch | 750/发，两发必死 | boom 注入 **DMG_GENERIC**（非爆炸类型绕过重算），贴脸不秒杀 |
| 特感 | 750 无衰减 | OnTakeDamage 重写（client 生效） |
| Tank | 1875 | 同上 ×2.5 |
| 小僵尸 | 225×falloff | 引擎基准（与后置同源，清场变弱则调 sm_gl_engine_damage） |

## 核心知识：引擎三条"后置处理"（全绕过 hook，改 damage 无效）

1. **投掷者自伤 ~1/150 减伤**（TakeDamage 内部，hook 之后）：attacker=0（世界）注入绕过 → 已验证贴脸 722 落地
2. **幸存者爆炸后置扣血 = m_flDamage×falloff×(1/15)**（dmgType=DMG_BLAST|DMG_PLASMA 16777280，hook 里 engine=0）：
   - 改 damage / Plugin_Handled / 清 DMG_PLASMA 位 / 注入 DMG_BLAST 全无效（逐项实锤）
   - **唯一杠杆 = 弹头 m_flDamage prop**（FrameSetDamage 写 sm_gl_engine_damage=225）
   - 回补校准方案（下一帧/帧循环把多扣的加回）也不可靠：后置扣血时机不稳（14:48 测试 1 秒内根本没扣，TIMEOUT）
3. **Witch 爆炸伤害重算**（改 1125 实际几百；DMG_BLAST 注入 1125 被重算回 ~221）：**DMG_GENERIC + inflictor=投掷者 注入绕过** → 全额落地

## cvar 清单

| cvar | 值 | 语义 |
|---|---|---|
| sm_gl_splash_damage | 750 | 特感/Witch/自伤注入基准（cfg 固化） |
| **sm_gl_engine_damage** | 270 | v2.1.24+：弹头 m_flDamage（幸存者后置 18/10 + 小僵尸清场基准；225→270 v2.1.25） |
| sm_gl_witch_mult | 1.0 | 750/发（1.5 时贴脸 1125+补刀 441 秒杀满血，用户拍板降 1.0） |
| sm_gl_ff_factor | 0.25 | 队友/自伤系数（0.4→0.25；实际量由 engine_damage 决定，此值只影响注入部分） |
| sm_gl_self_mult | 0.0 | 自动继承 ff_factor × 引擎友伤难度（hard 0.08） |
| sm_gl_splash_range | 500 | 扩展溅射（180~500 特感/Tank 注入） |

## 版本教训链

- v2.1.11→14: Witch 改 damage 无效 → DMG_BLAST 注入无效 → DMG_GENERIC 注入生效（v2.1.14 实锤 hp 差精确 1125）
- v2.1.15: witch_mult 1.5→1.0（满血贴脸 1125+441 秒杀，用户拍板去倍率）
- v2.1.16→17: ff_factor 0.4→0.25；诊断实锤队友 hook engine=0
- v2.1.18: 队友注入（DMG_GENERIC 15/8）+ Handled —— 后置照扣叠加成 65/33，用户否决
- v2.1.19→20: 回补校准 + 帧循环 —— 后置时机不稳（14:48 TIMEOUT hp 纹丝不动）
- v2.1.21→22: 纯放行 RAW 日志实锤 dmgType=16777280（DMG_BLAST|DMG_PLASMA）；清 PLASMA 无效
- v2.1.23→24: **m_flDamage 750→225 实验成功（用户"预期了"）→ 固化 sm_gl_engine_damage** ✅
- v2.1.25: 225→270（线性 1.2 倍）→ 直击 18 / 溅射 10（用户拍板）

## 高爆弹友伤（挂起待调，2026-08-02 用户拍板暂缓）

- **现状**（诊断实锤 v2.1.26）：直射 = ff_fix TraceAttack × sm_ff_multiplier 0.30（M60 ≈7.5，可调）；
  溅射 = 引擎后置直接扣血（engine=0，dmgType 0x81800042 含 DMG_PLASMA，inflictor=player，
  与榴弹队友同款机制）→ 拦不住、无 m_flDamage 式杠杆（爆炸伤害引擎内置）
- **用户诉求**：溅射不应与直射相同（7-8 vs 7-8），按比例降低（不设固定值），比例未定
- **拟定方案**（未实施）：扣血前**预加血**（hook 里后置未扣时把血加到"扣完=目标"，防倒地）
  + **残差回补**帧循环兜底；**倒地后补血无效**（incap 状态机，补血破坏状态）
- **诊断日志已保留**：`GL blast non-proj`（v2.1.26 非 GL 弹头爆炸对队友）
- 用户决定：后续反馈要调整再说

## 其他知识

- 击杀卡英文根因：引擎 player_death 报 "grenadelauncher"（无下划线）= WeaponType 枚举，si_hud 翻译表加别名（v1.7.55）
- Witch 也发 infected_hurt 事件（NPC 归 infected）→ si_hud 需按 classname=="witch" 排除（v1.7.56 已修）
- 实体销毁时 GetEntityClassname 不可靠 → OnEntityCreated 时 entref 追踪表
- 本地 SDKHooks 旧版 include：无 SDKHook_OnEntityDestroyed；TakeDamage 签名 (entity, inflictor, attacker, ...)
- SM 日志只写文件不输出容器 stdout；AutoExecConfig 不覆盖现有 cfg（新 cvar 手动追加）
- 玩家在线禁止服务端操作（只读也不行），插件 reload 允许；编辑后同步 /opt/gameservers 再编译

## 关联

- [[l4d2-weapon-attributes]] — weapon_attributes 对 GL damage 无效（被 splash_fix FrameSetDamage 覆盖）
- [[l4d2-bf-kill-hud]] — si_hud v1.7.56
- [[l4d2-source-code-location-pitfall]] — 源码位置规则
