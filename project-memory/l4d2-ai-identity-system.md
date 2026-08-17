---
name: l4d2-ai-identity-system
description: AI_HardSI_bt v5.0 身份定位体系 —— 每特感明确进攻身份（Charger突破手/Spitter区域毒压/Jockey拖酸/Boomer补刀/Hunter打枪线/Smoker控制链/Tank开团）+ 战场感知基础设施 API
metadata: 
  node_type: memory
  type: project
  originSessionId: 6689aa9e-9eea-4bc8-8924-625741cf7fa7
  modified: 2026-08-04T16:23:45.105Z
---

# L4D2 AI_HardSI_bt v5.0 身份定位体系（2026-08-04 部署）

**背景**：用户拍板"每特感明确进攻身份，行为树承担压力调节，替代波次数量操作"。
v1.7.0 的分批释放（ss_wave_split）拆散 si_comp 组合、倒地补偿缩减组合——量层操作与
组合策略冲突，回滚（wave_split→1、incap_compensation→0.0，cvar 保留可随时调回）。
**2026-08-05 恢复分批**：玩家反馈"感觉一次全出"，用户拍板 ss_wave_split 1→2
（compensation 仍 0.0，见 [[l4d2-specialspawner-config]]）。
源码：`scripting/AI_HardSI_optimized/`（11 文件 5900+ 行），编译后部署名 **AI_HardSI_bt.smx**
（源码名 AI_HardSI.sp 不一致，勿混）。版本 5.0.0，备份 /tmp/AI_HardSI_bt.smx.bak.v4.1.2。

## 战场感知基础设施（hardcoop_util.sp，v5.0 新增）

| API | 功能 |
|---|---|
| `SI_GetNearestAcid(pos, acidPos, maxRange)` | 酸液锚点：扫描 spit_acid 实体（存在=有效），全插件统一酸液感知 |
| `SI_UpdatePinMap()` / `g_iPinOwnerOf` / `SI_GetPinOwner(s)` / `SI_GetPinDuration(s)` | 谁控谁映射（每 tick 更新，Boomer 补刀/Hunter 补压用） |
| `SI_GetNearestPinnedSurvivor(pos, maxDist)` | 最近的被控者 |
| `SI_GetDenseCluster(radius, minCount, center)` | 密集区分析：簇心成员 + 簇中心（O(n²)，n≤24） |
| `SI_GetSurvivorSpread()` | 队伍散布度（两两平均距离） |
| `SI_GetLoneliestSurvivor(minIsolation)` | 孤立度公共化（原 Smoker 私有 bt_smoker.inc:38 提出） |
| `SI_GetWeaponThreat(s)` / `SI_GetHighestThreatSurvivor(pos, maxDist)` | 火力威胁：榴弹3.0>狙击2.5>霰弹2.0>冲锋1.5>步枪1.2>手枪0.5>近战0.3，含距离衰减 |

## 公共节点（bt_common.inc，v5.0）

CND_HasNearbyAcid / CND_SurvivorsClustered(minCount, radius) / ACT_AcquirePinnedTarget /
ACT_AcquireLonelyTarget / ACT_AcquireThreatTarget / ACT_AcquireClusterTarget /
**ACT_SnapAimToBlackboardTarget**（瞄黑板 target——现有 ACT_SnapAimToTarget 瞄引擎
GetClientAimTarget，与身份选人结果不一致，必须用新的）。

## 7 特感身份分支（各 bt_*.inc）

| 特感 | 身份 | 改动 |
|---|---|---|
| Charger | 突破手 | chargeCluster 加 breakthroughCharge（密集区≥3人/500u→AcquireClusterTarget→冲）；root 加 breakthroughApproach（12s 冲锋冷却期 CircleFlank 绕侧后接近，冷却好即冲） |
| Spitter | 区域毒压 | spitCluster 分支（密集区→吐中心）；吐后行为三分 `_spitter_post_mode`：0=贴脸25%/1=撤退35%/2=据守40%（原 80% 贴脸送死，血 100 白送）；据守用 ACT_HoldPosition 等 8s 冷却重新吐 |
| Jockey | 毒压搬运 | SteerRide 骑乘航向优先级：最近酸液池（80-900u）> 远离队伍中心（原有）；骑上人后把人拖进酸 |
| Boomer | 补刀者 | 启用从未被引用的 CND_AnySurvivorPinned：被控者≤600u → 专程逼近（FlankApproach）→ 300u 内喷；任何模式生效（mode1Vomit 只在窗口+pin 广播 3s） |
| Hunter | 枪线扰乱 | disruptionSeq 分支（mode4/6 分散扑之后）：ducking+LOS+inRange → AcquireThreatTarget → 扑火力输出者（打枪手） |
| Smoker | 控制链 | pinSeq 替代裸 IsPinningSurvivor：拉中 → **SI_SignalAttack 开窗**（原从不发信号，控制链断裂）+ SteerPinToAcid 拖向酸液（无酸引擎托管） |
| Tank | 开团者 | targetSelector 加 selectCluster（damager 防风筝之后：密集区≤1200u 冲阵型）；投石两路径末尾 ACT_SignalAttack（石头压制=开团）；TankAct_Bhop 接近预告 SI_SignalAttack（mode6 除外，同出拳信号逻辑） |

## 关键设计决策

- **防 dogpile 保留**：Hunter 的 Inverter(IsTargetPinned) 未动——Boomer 补刀不受影响
  （补刀判定用 SI_GetNearestPinnedSurvivor 实时映射，不是防 dogpile 的目标选择）
- **引擎数值铁律不变**：所有距离对齐 ENGINE_CVARS.md（冲锋 750/呕吐 300/酸 900/舌头 850 保守）
- **密集区阈值**：3 人/500u 半径（Charger/Spitter/Tank 共用）；孤立度 350u（公共化后默认）
- **酸液锚点零发布代码**：spit_acid 实体天然准确（被删=失效），Charger acidCharge 早如此用

## 验证状态

v5.0.0 空服热重载通过（0 error 编译、errors 零新异常、si_comp 轮换照常）。
**待玩家实测**：突破冲锋体感、Jockey 拖酸、Boomer 补刀时机、Hunter 打枪手、Smoker 开窗配合。

## 相关

- [[l4d2-ai-hardsi-engine-tuning]] — v4.0.3→v4.1 引擎数值校准
- [[l4d2-hardsi-boomedprop-crash]] — v4.1.2 胆汁事件跟踪（v5.0 沿用）
- [[l4d2-si-tactical-v4]] — si_comp_active_mode 模式下发
- [[l4d2-specialspawner-config]] — v1.7.0 三段定向（本轮保留）+ 量层回滚
