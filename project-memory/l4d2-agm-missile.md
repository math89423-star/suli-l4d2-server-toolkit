---
name: l4d2-agm-missile
description: 火力支援IV-AGM导弹（artillery6/kind6，v1.8.0 新增 2026-08-15，18000 分定稿）——仿 BF5 V1 单发俯冲瞬爆，独立 V1_Launch 路径；三层圆柱伤害 + 震屏 + 推力 + 爆炸后暂停刷新 20s；v1.8.0-v1.8.25 全版本史
metadata:
  node_type: memory
  type: project
  originSessionId: session-current
  modified: 2026-08-16T14:20:00.000Z
---

# 火力支援IV-AGM导弹（artillery6 / kind 6）

**当前版本 v1.9.1（2026-08-16，1/2 圈层统一 99999 定稿）**。商店火力支援类第 4 档，
**18000 分**（v1.8.4 定稿价）。与 I/II/III「持续 N 秒落罐」机制根本不同：
**单发导弹俯冲 + 落点一次瞬爆清场**，走独立 `V1_Launch` 路径（完全不进
`Art_LaunchBarrage` 按秒排队）。代码全在 `l4d2_shop.sp`（3947-4608 行）。

## v1.9.0 攻击走廊（2026-08-16，commit 10e4d52）

AGM 投送判定从"正上方开放"改为 **Attack Corridor（8 方向斜向俯冲走廊）**：
- `Art_FindAGMCorridor`：0°/45°.../315° 采样，起点 = 落点 + dir×1200u 水平 +
  diveHeight 高，trace 起点→落点；**末端 300u 容差**内命中（接近地面斜插段）不算阻挡
- `Art_TraceFilterCorridor`：忽略玩家/特感/武器/弹丸/prop_physics（可动物理件），
  世界几何 + func_* + prop_static + prop_dynamic（门/集装箱）当阻挡——宁保守拒绝
- 任一方向 clear → 可投送（C5 窄街/桥下/雨棚可呼叫）；8 方向全 blocked →
  `ART_FAIL_NO_ATTACK_CORRIDOR` 明确拒绝（密闭室内/隧道），玩家提示
  "建筑完全遮挡，无法建立攻击走廊"
- `V1_Launch` 从选中的走廊起点发射（不再是固定 900u 偏移）；走廊信息进
  `ArtTargetInfo.corridorIndex/corridorStart`
- debug level 3 逐方向日志 + level 2 白 beam 可视化走廊
- ⚠ 已知限制：动态门（func_door/prop_dynamic 门）关着时算阻挡（保守）；
  头顶隐形实体（c4m2 防飞顶类）可能挡部分方向——8 方向只要 1 条 clear 即可

## 素材（全原版，零客户端分发，实证见 [[l4d2-c1m2-missile-asset]]）

- **模型** `models/missiles/f18_agm65maverick.mdl`（AGM-65 小牛，c1m2 那发导弹）
  - ⚠ **无 .phy 碰撞模型** → 不能用 prop_physics 自由坠落 → 必须
    `prop_dynamic_override`（solid 0）+ 每 tick `TeleportEntity` 手推轨迹
- **粒子** `explosion_huge_e/b/c/h/flames/burning_chunks/smoking_chunks` 7 个
  （v1.8.4 从 missile_hit_* 换 explosion_silo 干净版，剔除缺材质的 _d/_g；
  全在全局 particles_manifest.txt，客户端启动即加载）
  - ⚠ **必须 `AddToStringTable("ParticleEffectNames")` 注册**，否则 idx=-1 静默不生成
  - ⚠ 不用带火球的 missile_hit1_f / tanker_fireball / gen_dest_fireball（油罐车
    着火效果会留持续火焰；BF5 的 V1 只要浮尘烟云）
- **音效**（三轨分阶段，落地前必须掐飞行轨否则叠响）：
  - 发射 `animation/overpass_jets.wav`（T-3 秒，远处发射）
  - 飞行 `ambient/atmosphere/terrain_rumble1.wav`（T-0 俯冲低频轰鸣，绑导弹实体）
  - 爆炸 `animation/Tanker_Explosion.wav`（v1.8.25：前 0.4s 是呼啸，
    音效延迟 = diveTime − 0.4，动态跟随 cvar 不失同步）

## 机制（三层圆柱伤害，v1.8.16 定稿 / v1.9.1 修正）

圆柱判定：水平距离（X/Y）+ 垂直 ±1500u 独立判定。默认半径 600/450/350
（露天/中层≥900/矮房 600-900，cvar 可热调）。

| 区域 | 范围 | 幸存者 | 小僵尸 | 特感 | Tank | Witch |
|---|---|---|---|---|---|---|
| 核心区 | ≤ radius×1.38 | 内圈 80u 秒杀倒地，外圈线性衰减 dmgIn 100→dmgOut 15（友伤开关 si_hud_art6_friendly_fire 默认 1 开） | 秒杀 | **99999** | **99999** | **99999** |
| 冲击波区 | 1.38r – 2000u | 震屏无伤 | 秒杀 | **99999** | **99999** | **99999** |
| 余波区 | 2000 – 3000u | 无影响 | 100 伤 | 100 伤 | 6000 伤 | 800 伤 |

- **v1.9.1（2026-08-16 用户定稿：清场彻底化）**：1/2 圈层（核心区+冲击波区）
  特感/Tank/Witch 统一 **99999** 秒杀——原核心区 900000、冲击波区分层
  （特感500/Tank10000/Witch1200）全部归一；余波区分层保留
  （特感100/Tank6000/Witch800）。`si_hud_art6_tank_kill / si_hud_art6_tank_damage`
  cvar 随定稿删除（统一后成死声明，遵循残留 cvar 误判教训
  [[l4d2-rest-tier-override-bug]]）

- 核心圈内掉落物品/投掷物/物理道具被冲击波吹飞（V1_PushItem：径向+上抛，VPhysics
  native 优先；正落点给随机方向防除零）
- 屏幕震动用 **Shake 用户消息**（v1.8.15；原 World Decal 是贴花特效，m_Amplitude
  等字段不存在，震动从未生效）；推力随距离衰减
- 击杀归属铁律（沿用 artillery 全系）：attacker/inflictor = 召唤者，击杀记买家头上；
  召唤者失效（断线/换图）退回 worldspawn
- **爆炸后暂停特感+小僵尸刷新**（v1.8.24，si_hud_art6_pause_spawn 默认 20s）：
  特感走 specialspawner `SS_PauseSpawning`、小僵尸走 l4d2_max_common
  `MC_PauseCommon`——两个 native 都是**可选绑定**（AskPluginLoad2 MarkNativeAsOptional，
  对应插件未加载静默跳过）。不直接改 z_common_limit（max_common 每秒重算会覆盖回去）
- 播报：聊天击杀统计（小僵尸/特感/女巫/坦克）+ v1.8.25 si_hud v1.13.3
  `SH_ShowMissileBanner` 聚合击杀横幅（纯显示 native）

## 交互（与 I/II/III 同框架，细节差异）

购买 → 瞄准圈（紫，只显示**核心区** radius×1.38，不加落罐效果半径）→ 任意开火确认
→ 预警 **8s**（si_hud_art6_warn，比其它档长给逃跑时间；T-3 播发射音效+提示
"导弹已发射，正在接近目标！"；每秒倒计时）→ `V1_Launch`：导弹在落点上方
dive_height（默认 2600u）、水平偏移 900u 处生成，ease-in（匀加速 prog²，v1.8.10）
插值俯冲（160 步）→ 落地掐飞行音轨 → `V1_Detonate`。每图全服限购计数
g_iArt6MapUses（确认发射才计数，取消退款不算，OnMapStart 重置）。

## cvar 全表（si_hud_art6_*，2026-08-16 RCON 实况）

| cvar | 代码默认 | 当前实况 | 说明 |
|---|---|---|---|
| si_hud_art6_radius_out/mid/small | 600/450/350 | 同默认 | 三层半径（露天/中层/矮房） |
| si_hud_art6_dive_time | 1.6 | **5.0** ⚠ | 俯冲时长 s；**用户调过 5s 并实测**（09:45 日志 dive=5.0s） |
| si_hud_art6_dive_height | 2600 | — | 俯冲起始高度 |
| ~~si_hud_art6_tank_kill~~ | — | — | **v1.9.1 已删**（1/2 圈层统一 99999 后成死声明） |

> ⚠ **2026-08-16 v1.9.1 热加载实况**：reload 后 RCON 仍能查到
> `si_hud_art6_tank_kill=1 / si_hud_art6_tank_damage=3000`——旧版 cvar 的
> **引擎层残留**（卸载未清，长会话已知行为；全库 sp/smx/cfg 已确认无任何
> 引用，新代码不读，功能零影响）。SourceMod 无 cvar 删除 API，**等服务器
> 重启自然消失**，勿误判为代码没生效。
| si_hud_art6_friendly_fire | 1 | 1 | 幸存者友伤（BF5 原味） |
| si_hud_art6_surv_inner_radius | 80 | — | 幸存者内圈秒杀半径（硬编码兜底 80） |
| si_hud_art6_surv_damage_inner/outer | 100/15 | — | 核心区外圈线性衰减两端 |
| si_hud_art6_shake_amp/freq/duration | 16/150/3 | — | 屏幕震动 |
| si_hud_art6_push_force | 600 | — | 物理推力（0=关） |
| si_hud_art6_fx_rings/per_ring/spread/wave | 0/6/0.75/0.09 | 0 | 特效环（0=只放中心；**当前关着**） |
| si_hud_art6_max_per_map | **0** | **0** | ⚠ **代码注释写"默认 1 次/图"但默认值=0 不限购——注释与实现矛盾，升级时需确认** |
| si_hud_art6_warn | 8 | 8 | 预警秒数 |
| si_hud_art6_pause_spawn | 20 | 20 | 爆炸后暂停刷新秒数 |

## 版本史（v1.8.0-v1.9.1，2026-08-15 起）

- **v1.9.1**：**1/2 圈层统一 99999（用户定稿：清场彻底化）**——核心区+冲击波区
  特感/Tank/Witch 全 99999 秒杀（原核心 900000 / 冲击波分层 特感500 Tank10000
  Witch1200）；余波区分层保留（特感100/Tank6000/Witch800）；删
  si_hud_art6_tank_kill/tank_damage 死 cvar；commit `e22a18a`（未部署，待空服）
- **v1.8.0**：新增 AGM（15000 分）；SHOP_SLOTS 24→25；V1_Launch 独立路径；
  素材 precache + ParticleEffectNames 注册；Tank 秒杀/友伤开/限购三开关
- **v1.8.1**：特效铺开——粒子环形补放（fx_rings/per_ring/spread/wave）。
  ⚠ 边界：单个 info_particle_system 占一个 edict（上限 2048）+ 客户端同帧渲染
  全部实例——曾用 1200/4 环/12 点×6 粒子 = **294 实例一帧生成 → 客户端闪退**。
  硬封顶 `V1_FX_MAX_PARTICLES 60` + 逐环延迟摊帧
- **v1.8.2**：幸存者分圈伤害（用户定稿：内圈秒杀倒地太无脑，只有贴脸才倒地）
- **v1.8.3**：屏幕震动 + 物理推力
- **v1.8.4**：粒子换 explosion_huge_* 干净版；**定稿价 18000**
- **v1.8.5**：三档火力全面调整（见 [[l4d2-artillery-strike]]）；AGM 不动
- **v1.8.6**：电锯降价/透视涨价/弹药补充调整（商店非火力）
- **v1.8.7**：地狱烈火再收紧/区域轰炸放大+加快/幸存者 80u 秒杀区硬编码
- **v1.8.8**：绿色雨幕双路径（胆汁瓶+罐子）
- **v1.8.10**：俯冲 ease-in（prog²；不用 smoothstep——末段减速 5s 长动画会"飘"着落地）
- **v1.8.11**：倒计时播报导弹发射；导弹生成点加水平偏移 900u 制造斜向倾角
- **v1.8.12/13**：T-3 发射音效；音效三轨定稿（发射/飞行/爆炸分离，落地前 StopSound 掐飞行轨）
- **v1.8.14**：爆炸音效延迟播放对准落地（前 0.4s 是呼啸）
- **v1.8.15**：震屏改 Shake 用户消息（World Decal 字段不存在从未生效）；圆柱形判定
- **v1.8.16**：**三层分区伤害系统定稿**（±1500u 圆柱）；紫圈
- **v1.8.17**：掉落物品冲击波吹飞
- **v1.8.18**：Witch/Tank 分层伤害（用户定稿）；圈只显示核心区；粒子清理 8s→6s
- **v1.8.19**：Art_FindCeiling 起点 60→200u（起伏地形误判修复，commit c5b0c30）
- **v1.8.20**：Art_FindCeiling 穿透上限 4→16（狭窄长巷误拒，见 [[l4d2-artillery-strike]]）
- **v1.8.21-22**：弹药动态定价/菜单实时刷新（商店通用，见 [[l4d2-shop-decoupled]]）
- **v1.8.23**：购买后自动关闭商店 + 6s 无操作超时
- **v1.8.24**：爆炸后暂停刷新 20s（SS_PauseSpawning/MC_PauseCommon 可选绑定；
  commit 0609310 连带 specialspawner 冷静期 20-30→25-35s、清缴阈值 40%→30%）
- **v1.8.25**：爆炸音效前摇对齐（延迟=diveTime−0.4）；SH_ShowMissileBanner 横幅
  （si_hud v1.13.3 新增 native）

## 实机验证（2026-08-16 日志）

- 09:45 粟藜实测：dive=5.0s（cvar 已调）、r=450（室内中层档）、detonate 清
  common=8 si=4 witch=0 tank=0 surv=0，暂停刷新 20s 生效（SS+MC 双日志）
- 12:58 粟藜购买地狱烈火（10000）后取消退款（designate cancelled refund=10000）
- 全天多次换图 assets ready 7/7 粒子全注册成功（mdl idx 585-688 不等）

相关：[[l4d2-artillery-strike]] [[l4d2-c1m2-missile-asset]] [[l4d2-shop-decoupled]]
[[l4d2-shop-default-prices]]
