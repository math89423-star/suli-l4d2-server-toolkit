// ============================================================================
// AI_HardSI.sp — L4D2 Special Infected AI (Behavior Tree v3.7)
// ============================================================================
// Original v2.4 by Breezy — flat if-then-else per-SI logic.
// v3.0 refactored with composable Behavior Tree framework for hierarchical,
// reactive, and maintainable AI decision-making.
// v3.5: Randomized open-terrain strategies per SI type
// v3.6: Anti-melee for control SI — ability-first, melee as valid fallback
// v3.7: Audit fixes — RandomChance thrashing, dead code, missing range checks
// v4.1.2: m_hasBeenBoomed 在此游戏版本（2.2.4.3）网络数据表不存在（netprops dump
//         实测全表无此属性）——v4.0.2 的 Prop_Data→Prop_Send 只换了失败方式，
//         GetEntProp 依旧每晚数万异常（BT tick 中止，协同瘫痪）。
//         改用 L4D_OnVomitedUpon_Post 事件跟踪胆汁状态（≈10s 失效，重生清零），
//         替换 4 处 GetEntProp 调用点（hardcoop_util 747/808 + spitter 84 + smoker 221）。
// v4.0.1: Charger 出生保护（unghost 后 2s 禁冲）+ coordSeq 补距离/LOS；
//         Hunter 出生蠕动修复（sprint 死区消除 + crouchApproach 站立快跑化）
// v4.0.2: P0 修复 hardcoop_util m_hasBeenBoomed Prop_Data→Prop_Send（每日 4 万异常，
//         Boomer 窗口期 BT tick 全中止 → 协同进攻瘫痪）；
//         Charger 出生保护加 freshSpawn 兜底（未观察到 ghost 阶段也保护 2s）；
//         走廊窄巷 Charger 直接 750u 冲（移除 HoldChokepoint 站桩分支）；
//         TICK_INTERVAL 4→2（BT 帧率翻倍，原版 AI 主导帧减半）
// v4.0.3: 实战弱化审计修复（三个根因类别 + 引擎数值实测校准）——
//         引擎数值实测（空服 rcon，2026-08-03，见 ENGINE_CVARS.md）：
//           z_charge_interval=12s（冲锋冷却）、覆盖 ≈940~1190u → 750 打得到；
//           z_spit_interval=20s（喷吐冷却）；smoker_tongue_delay def=1.5；
//           ai_fast_pounce_proximity/ai_straight_pounce_proximity 从未创建
//           （Hunter 一直用 fallback 1000/200，v3.3 注释为虚假记录）；
//           ai_ChargerChargeDistance 不存在（竞争配置自创，引擎无此限制）
//         [类型1] 装载链验证：运行版 = v4.0.2，无装载断链；
//         [类型2] Smoker ledgeRetarget 加 CND_IsNearLedge 门控（原版无条件
//                 每 2s 用"90% 拉最远"覆盖目标选择，孤立度选人窗口减半）；
//         [类型3] 攻击分支冷却簇 —— Smoker 6 个拉人分支包 Cooldown(1.8)、
//                 Charger 11 个冲锋分支包 Cooldown(12.0)（对齐引擎冲锋冷却；
//                 舌头/冲锋与近战共享 IN_ATTACK，无冷却 = 能力冷却期每 tick
//                 挠击/拳击，观感最蠢）；Spitter z_spit_interval 20→8 对齐
//                 post-spit 自锁（消除 8-20s 无效按键）；
//                 ai_charge_proximity 默认 500→750（冲锋覆盖 ~940-1190u 实测
//                 依据；服务器内存值本就是 750，防重启掉值）；
//                 Hunter highPounceSeq 加 1000-1600u 距离门控（消除跳-蹲抖动）
//                 + 5 个攻击序列补 Cooldown(1.0)（narrow/close/coord/openStrat）
// v4.0.4: Boomer 呕吐射程对齐引擎实测 z_vomit_range=300（第二轮 rcon 补测）：
//         v3.5 的 open 分支 550/500 为自创值，超过引擎射程 —— approach 在
//         550u 就停 → 永远进不了 300u 射程，站桩无限按无效呕吐键；
//         8 处 350/500/550 → 300（mode1/narrow/openS0/openS1/semi/approach 全系）；
//         z_spit_range=900 实测 → Spitter 800/900 全部对齐无需改动（已验证）；
//         z_jockey_ride_damage=4（骑乘 DPS）、z_tank_attack_interval=1.5 入库
// v4.0.5: Witch 死树移除 + Tank cvar 接入审计——
//         [Witch] bt_witch.inc 整文件删除：Witch 是实体非客户端，无
//         OnPlayerRunCmd 入口、无 player_spawn 绑定（BT_Bind 永不执行）、
//         节点全为客户端 API（GetClientAimTarget/m_mobRush 误用），纯死代码；
//         [Tank] 13 个 ai_tank_* cvar 审计：punch_jump/instakill/punch_damage/
//         rage_multiplier/wall_dist/adaptive/evade/aggro 创建了但未接入或丢失——
//         修复 punch_jump（=0 仍触发近身跳拳）、instakill/damage（hook 无条件
//         秒杀）、rage_multiplier（硬编码 1.5）；恢复 bhop 冷却（g_fTankLastBhop
//         只写不读 = 无冷却连跳）+ chain 重置 + wall trace/evade（v3.2 重构丢失）；
//         aggro 由 BhopEligible 消费（max_dist 翻倍 + 冷却缩短）；
//         近战攻击簇 Cooldown(1.5) 对齐引擎 z_tank_attack_interval=1.5
//         （冷却期按键 = 无效挥拳，与 Smoker/Charger 同模式）
// v4.1: Tank 高级玩法四件套（用户设计方向：无脑连跳贴脸一拳 = 低级做法）——
//         [协同配合] Tank 消费协同窗口：coordPinSeq（窗口+pin → 锁定被 pin
//         者）+ coordPunchSeq（窗口内 ≤300u 直测 pin 出拳必杀）；mode 6
//         巨兽协同保持小队分散（不命令集火）；Tank 出拳在非 mode6 下
//         SI_SignalAttack 开团（CommandABot 小队跟进）
//         [追击优化] damager 距离门控 ai_tank_damager_max_dist=800
//         （风筝手不再把 Tank 拖离战场）；窗口期由 coordPinSeq 自然无视风筝手
//         [地形秒杀] 设计实现后经用户拍板整体移除（2026-08-03）—— Tank 拳
//         只作用于汽车/树干等物理实体、不作用于爆炸物，罐类爆炸链路不可靠，
//         "不确定宁愿用原版"。保持原版行为（propKillSeq 已删，cvar 3 个已删）
//         [飞石精准+预判] TankAct_AimRock 提前量瞄准（lead=vel×dist/800，
//         clamp 400u）+ L4D_TankRock_OnRelease 释放校正（真实 |vecVel|
//         自修正 bhop 自身速度 + 动画期视角漂移；原版 AI 投石同享校正）
//         新 cvar 8 个：ai_tank_coord / rock_predict / rock_lead_max /
//         rock_pitch_offset / prop_kill / prop_punch_damage /
//         prop_blast_radius / damager_max_dist
// v4.1.1: Boomer 伏击站桩修复 —— ambushSeq（narrow + 目标>300u →
//         AmbushHold）无距离上限 + 无超时 = 出生远的 Boomer 无限站桩
//         被电脑处死。修复：目标 >1500u 不伏击直接接近（approach 分支
//         先拉近距离）+ 伏击超时 8s 转主动接近（ACT_AmbushHold 加
//         UserParam1 超时参数，≤0 = 不超时保持原行为，仅 Boomer 使用）
// v5.0: 身份定位全面修正（用户拍板：每特感明确进攻身份，行为树承担
//       压力调节，替代波次数量操作）——
//       [基础设施] hardcoop_util.sp 新增战场感知层：
//         酸液锚点 SI_GetNearestAcid（spit_acid 实体扫描，全插件统一）、
//         谁控谁映射 SI_UpdatePinMap/g_iPinOwnerOf（谁控谁+控了多久）、
//         阵型分析 SI_GetDenseCluster/SI_GetSurvivorSpread（密集区/散布）、
//         孤立度公共化 SI_GetLoneliestSurvivor、火力威胁评估
//         SI_GetWeaponThreat/SI_GetHighestThreatSurvivor（输出核心识别）；
//       [公共节点] bt_common.inc：CND_HasNearbyAcid/CND_SurvivorsClustered/
//         ACT_AcquirePinnedTarget/ACT_AcquireLonelyTarget/
//         ACT_AcquireThreatTarget/ACT_AcquireClusterTarget/
//         ACT_SnapAimToBlackboardTarget
//       [身份分支] 各树 root 加身份行为（详细注释在各 bt_*.inc）：
//         Charger 突破手 —— 密集区(≥3人/500u) → 绕侧后 CircleFlank → 冲
//         Spitter 区域毒压 —— 吐密集区中心；吐后 40% 据守/35% 撤退/25% 贴脸
//         Jockey 毒压搬运 —— SteerRide 骑乘航向优先拖向酸液池
//         Boomer 补刀者 —— CND_AnySurvivorPinned(启用) + 逼近被控者 600u 喷
//         Hunter 枪线扰乱 —— 优先扑高火力威胁者（打枪手）
//         Smoker 控制链 —— 拉中 SI_SignalAttack 开窗 + 拖向酸液
//         Tank 开团者 —— 密集区目标分支 + 投石/bhop 开团信号
//       部署名 AI_HardSI_bt.smx（源码 AI_HardSI.sp，编译后改名）。
// v5.1: 站桩修复 + 诊断（2026-08-04，用户报告"特感有时候原地傻站"）——
//       [Charger] 根 child9 BlockCharge 兜底 = 站桩 + 推后引擎 m_timestamp
//         （引擎冲锋永久不就绪 → 站 12s → 挠一下 → 再站 12s）。改为冷却期
//         走位逼近（AcquireClosestTarget + StrafeMoveToTarget，不按 ATTACK）；
//         m_timestamp 推后仅保留出生保护分支（2s 有界）。
//       [Tank] 根 SEQUENCE(目标选择,攻击选择)：melee/rock/bhop 全冷却或门控
//         不满足 → 攻击选择器全 FAIL → 整树 FAIL 无任何输出。attackSelector
//         补 ACT_MoveToTarget 兜底（不重新选人，沿用黑板 target）。
//       [Spitter] 吐后 40% 据守分支 HoldPosition → StrafeRandom（守位语义
//         保留、横向移动消除静止观感）。
//       [Tank instakill] player_hurt Pre hook 内 SDKHooks_TakeDamage 递归触发
//         player_hurt → 栈溢出（当天 5 次）。0.2s 同受害者时间戳防护。
//       [诊断] ai_debug cvar（默认 0）：每 2s 打印各特感根 selector 当前命中
//         分支序号 + 地形分类 + 目标距离到 SM 日志，定位傻站分支。
// v5.2: 站桩/原地跳第二波修复（2026-08-04，用户报告"Smoker/Jockey 站桩 +
//       Hunter 原地跳跃"）——
//       [通用] ACT_StrafeApproach（横移+前进，替换 closeRangeStrafe 的
//         ACT_StrafeRandom —— 原只横移不前进 = 原地左右晃，观感站桩）；
//         BT_StuckDetour 顶墙绕行（全插件无寻路 = 隔墙/高差顶墙站桩主因：
//         每 0.75s 位移 <20u 判停滞 → W+横移斜插沿墙滑动 1.5-2.5s，
//         接入 MoveToTarget/StrafeMoveToTarget/ErraticApproach/Wander/
//         Retreat/FlankApproach/HugWall/CircleFlank/SprintApproach/
//         CrouchApproach/ApproachOutside/StrafeApproach）
//       [Jockey] AlternatingHop 跳模式瞄准黑板 target + IN_FORWARD
//         （原 yaw 不变 + 无前进 = 350-700u 有 LOS 时 hopSeq 原地跳）
//       [Hunter] HasHighGround 高台上限 200→85（>85u 必跳失败 = 高台/房檐下
//         35% 概率每 tick 原地反复跳）；ClimbHighGround 加 2s 跳跃冷却
//         （跳后走位拉近，2s 后才再评估爬高）
// v5.3: 放完技能傻站 + Hunter 扑空循环（2026-08-05，v5.2 实战反馈）——
//       [Smoker] 拉中后无酸时后退拖拽（原 SteerPinToAcid 无酸返回 SUCCESS =
//         引擎钉住不动 = "放完技能原地傻站"；现背对目标后退拉扯，目标被拖离
//         队伍；距目标 ≥850u 停止后退防断舌）
//       [Hunter] 扑击距离对齐引擎：创建 ai_fast_pounce_proximity cvar=500
//         （对齐模块自设 hunter_pounce_ready_range=500；原 fallback 1000 =
//         600-1000u 按 ATTACK 引擎扑不出 → 扑空 → missEsc 逃跳 → 再扑 =
//         "跳一下扑一下"循环）
//       [通用] BT_StuckDetour 绕行增强：朝向偏转 ±90° 沿墙走（原只加横移
//         键 = 横移方向也贴墙时死锁，如 Spitter 守位横移贴墙）；StrafeRandom
//         接入绕行
//
// Include order is critical:
//   1. Core SM/left4dhooks SDK
//   2. hardcoop_util (shared utilities, coordination system)
//   3. bt_core       (BT node framework)
//   4. bt_common     (shared game-specific condition/action nodes)
//   5. bt_*          (per-SI behavior trees)
// ============================================================================

#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

// Shared utilities + coordination system (preserved from v2.4)
#include "hardcoop_util.sp"

// BT framework + shared nodes
#include "bt_core.inc"
#include "bt_common.inc"

// v5.22: Charger 真实冲锋确认标记 —— ability_charge 事件置位
// （云端审查任务书 §8：按 ATTACK ≠ 冲锋成功，只有事件到达才确认）。
// 必须声明在 bt_charger.inc 之前（bt_charger.inc 的 ChargerAct_TryCharge 消费它，
// SourcePawn 单遍编译按 include 展开顺序解析符号）。
float g_fChargerChargeConfirmed[MAXPLAYERS + 1];

// Per-SI behavior trees
#include "bt_hunter.inc"
#include "bt_charger.inc"
#include "bt_jockey.inc"
#include "bt_smoker.inc"
#include "bt_boomer.inc"
#include "bt_spitter.inc"
#include "bt_tank.inc"
// v4.0.5: bt_witch.inc 已删除 —— Witch 是实体不是客户端，整棵树从未被 bind/tick
// （无 OnPlayerRunCmd 入口、无 player_spawn 绑定、节点全为客户端 API），纯死代码

// ============================================================================
// Plugin Info
// ============================================================================

public Plugin:myinfo = {
    name = "AI: Hard SI (Behavior Tree v3.5)",
    author = "Breezy, refactored by Claude",
    description = "Improves the AI of special infected — BT-driven terrain-aware decision engine",
    version = "5.24.0",
    url = "github.com/breezyplease"
};

// ============================================================================
// Global State
// ============================================================================

// Tick throttling — evaluate AI every N frames
// v4.0.2: 4→2 —— 原 75% 帧由引擎原版 AI（官方故意保守）主导，插件行为被稀释。
// BT 帧率翻倍（25%→50%），terrain 分类已 0.5s 限频，CPU 代价可忽略。
int   g_iTickCounter[MAXPLAYERS + 1];
#define TICK_INTERVAL 2

// Shove tracking
bool  g_bHasBeenShoved[MAXPLAYERS + 1];

// BT root node IDs (built once in OnPluginStart, shared across clients)
int   g_iBTHunterRoot   = -1;
int   g_iBTChargerRoot  = -1;
int   g_iBTJockeyRoot   = -1;
int   g_iBTSmokerRoot   = -1;
int   g_iBTBoomerRoot   = -1;
int   g_iBTSpitterRoot  = -1;
int   g_iBTTankRoot     = -1;

// Cached ConVar handles (avoid FindConVar per-tick)
ConVar g_hCvarTankAggroBhop = null;

// v5.1: 诊断输出（ai_debug）
ConVar g_hCvarDebug = null;

// v5.18 功能 3：同步齐射 cvar（状态机实现见文件下方 Wave_EvaluateSync）
ConVar g_hCvarWaveSync        = null;  // 0=关（纯接力）1=开（接力+齐射）
ConVar g_hCvarWaveSyncRatio   = null;
ConVar g_hCvarWaveSyncTimeout = null;
ConVar g_hCvarWaveSyncRange   = null;  // 判定"就位"的距离

// ============================================================================
// OnPluginStart
// ============================================================================

public OnPluginStart() {
    // --- Event hooks (preserved from v2.4) ---
    HookEvent("player_spawn",      Event_PlayerSpawn,      EventHookMode_Pre);
    HookEvent("ability_use",       Event_AbilityUse,       EventHookMode_Pre);
    HookEvent("player_shoved",     Event_PlayerShoved,     EventHookMode_Pre);
    HookEvent("player_jump",       Event_PlayerJump,       EventHookMode_Pre);
    // v3.2: tongue_release suicide REMOVED — Smoker BT now handles re-engagement naturally

    // --- v3.2: Terrain detection cvar ---
    g_hCvarTerrainEnable = CreateConVar("ai_terrain_enable", "1",
        "Enable terrain-aware AI strategies (narrow/open/ledge detection): 0=OFF, 1=ON",
        FCVAR_NONE, true, 0.0, true, 1.0);

    // --- Coordination cvars ---
    g_hCvarCoordEnable = CreateConVar("ai_coordination_enable", "1",
        "Enable SI coordination system: 0=OFF, 1=ON",
        FCVAR_NONE, true, 0.0, true, 1.0);
    g_hCvarCoordWindow = CreateConVar("ai_coordination_window", "5.5",
        "Duration (seconds) of the coordination attack window",
        FCVAR_NONE, true, 0.5, true, 10.0);

    // --- v5.1: 诊断输出 ---
    // 每 2s 打印各特感根 selector 当前命中分支到 SM 日志。分支序号对应
    // 各 bt_*.inc 树构建器的注释优先级（如 bt_charger.inc: 0=出生保护 2=冲锋簇
    // 9=冷却走位 10=Wander）。傻站报告可直接对照日志定位卡在哪个分支。
    g_hCvarDebug = CreateConVar("ai_debug", "0",
        "Print per-SI root branch index + terrain + target distance to SM log every 2s: 0=OFF, 1=ON",
        FCVAR_NONE, true, 0.0, true, 1.0);

    // --- v5.18 功能 3：同步齐射 ---
    g_hCvarWaveSync = CreateConVar("ai_wave_sync", "1",
        "Synchronized alpha strike: harassers stage then strike together. 0=OFF (relay only), 1=ON",
        FCVAR_NONE, true, 0.0, true, 1.0);
    g_hCvarWaveSyncRatio = CreateConVar("ai_wave_sync_ratio", "0.6",
        "Fraction of harassers in position required to order the alpha strike",
        FCVAR_NONE, true, 0.1, true, 1.0);
    g_hCvarWaveSyncTimeout = CreateConVar("ai_wave_sync_timeout", "12.0",
        "Max seconds to stage before striking anyway (prevents stuck SI stalling the wave)",
        FCVAR_NONE, true, 3.0, true, 60.0);
    g_hCvarWaveSyncRange = CreateConVar("ai_wave_sync_range", "900.0",
        "Distance to nearest survivor counted as 'in position' for wave sync",
        FCVAR_NONE, true, 300.0, true, 2000.0);

    // v5.19: 骚扰态硬超时 —— 没有 Boomer/Smoker 发起者的波次里，骚扰者
    // 曾会无限期保持距离（观感"傻站着不打"）。超过此秒数强制放行开打。
    CreateConVar("ai_harass_max_hold", "5.0",
        "Max seconds a harasser holds off before attacking regardless of initiator",
        FCVAR_NONE, true, 0.0, true, 30.0);

    // --- Per-SI module initialization (cvars + game tuning) ---
    Smoker_OnModuleStart();
    Hunter_OnModuleStart();
    Spitter_OnModuleStart();
    Boomer_OnModuleStart();
    Charger_OnModuleStart();
    Jockey_OnModuleStart();
    Tank_OnModuleStart();

    // Cache frequently-read cvars (avoid FindConVar per tick)
    g_hCvarTankAggroBhop = FindConVar("ai_tank_aggro_bhop");

    // v4.0: 战术模式 cvar（由 si_composition_manager 写入；未安装时保持 -1，模式分支全部走默认行为）
    g_hCvarActiveMode = FindConVar("si_comp_active_mode");

    // --- Build all Behavior Trees ---
    g_iBTHunterRoot  = BT_CreateHunterTree();
    g_iBTChargerRoot = BT_CreateChargerTree();
    g_iBTJockeyRoot  = BT_CreateJockeyTree();
    g_iBTSmokerRoot  = BT_CreateSmokerTree();
    g_iBTBoomerRoot  = BT_CreateBoomerTree();
    g_iBTSpitterRoot = BT_CreateSpitterTree();
    g_iBTTankRoot    = BT_CreateTankTree();

    // --- Coordination timer ---
    CreateTimer(1.0, Timer_UpdateCoordination, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    // --- v5.1: 诊断定时器（ai_debug=1 时才输出） ---
    CreateTimer(2.0, Timer_DebugReport, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

// ============================================================================
// v5.16: Tank 物体投掷瞄准
// ============================================================================

// 监听物理道具被创建
public void OnEntityCreated(int entity, const char[] classname) {
    if (entity <= 0 || entity > 2048) return;

    // 监听物理道具（车辆、桌子等）
    if (StrEqual(classname, "prop_physics") ||
        StrEqual(classname, "prop_car_alarm") ||
        StrEqual(classname, "prop_physics_multiplayer")) {

        // 延迟 0.1 秒后检查是否被 Tank 击打
        CreateTimer(0.1, Timer_CheckPropVelocity, entity, TIMER_FLAG_NO_MAPCHANGE);
    }
}

// 检查物理道具是否被 Tank 击打并修改其飞行轨迹
Action Timer_CheckPropVelocity(Handle timer, int entity) {
    if (!IsValidEntity(entity)) return Plugin_Stop;

    // 获取物体速度
    float vel[3];
    GetEntPropVector(entity, Prop_Data, "m_vecVelocity", vel);
    float speed = SquareRoot(vel[0]*vel[0] + vel[1]*vel[1] + vel[2]*vel[2]);

    // 如果物体正在高速移动（>400 u/s），可能是被 Tank 击打
    if (speed > 400.0) {
        // 查找最近的 Tank
        int tank = -1;
        float propPos[3];
        GetEntPropVector(entity, Prop_Data, "m_vecOrigin", propPos);

        for (int i = 1; i <= MaxClients; i++) {
            if (!IsClientInGame(i) || !IsPlayerAlive(i)) continue;
            if (GetClientTeam(i) != 3) continue;
            if (GetEntProp(i, Prop_Send, "m_zombieClass") != ZC_TANK) continue;

            float tankPos[3];
            GetClientAbsOrigin(i, tankPos);
            float dist = GetVectorDistance(tankPos, propPos);

            // Tank 在附近（<300u）
            if (dist < 300.0) {
                tank = i;
                break;
            }
        }

        if (tank > 0) {
            // 找到最近的幸存者
            int target = -1;
            float minDist = 999999.0;

            for (int i = 1; i <= MaxClients; i++) {
                if (!IsClientInGame(i) || !IsPlayerAlive(i)) continue;
                if (GetClientTeam(i) != 2) continue;

                float sPos[3];
                GetClientAbsOrigin(i, sPos);
                float dist = GetVectorDistance(propPos, sPos);

                if (dist < minDist && dist < 1500.0) {
                    minDist = dist;
                    target = i;
                }
            }

            // 如果找到目标，修改物体飞行方向
            if (target > 0) {
                float targetPos[3];
                GetClientAbsOrigin(target, targetPos);

                // 计算从物体到目标的方向
                float dir[3];
                MakeVectorFromPoints(propPos, targetPos, dir);
                NormalizeVector(dir, dir);

                // 保持原速度大小，但改变方向朝向幸存者
                float newVel[3];
                newVel[0] = dir[0] * speed * 0.8;  // 0.8 系数避免过于精准
                newVel[1] = dir[1] * speed * 0.8;
                newVel[2] = dir[2] * speed * 0.5 + vel[2] * 0.5;  // 保留部分原有垂直速度

                // 设置新速度
                TeleportEntity(entity, NULL_VECTOR, NULL_VECTOR, newVel);
            }
        }
    }

    return Plugin_Stop;
}

// ============================================================================
// Per-SI Module Start/End functions are defined in their respective bt_*.inc files.
// These register custom cvars and modify vanilla game cvars.
// The BT framework replaces only the decision logic, not the game tuning.

public OnPluginEnd() {
    // Cleanup (if needed)
}

// ============================================================================
// Player Spawn: bind BT tree to SI bot
// ============================================================================

public Action:Event_PlayerSpawn(Handle:event, String:name[], bool:dontBroadcast) {
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    // v4.1.2: 幸存者重生清胆汁状态（死亡/复活 = 胆汁覆盖结束，事件跟踪归零）
    if (client > 0 && client <= MaxClients && !IsBotInfected(client)) {
        g_fSurvivorBoomedUntil[client] = 0.0;
        return Plugin_Handled;
    }

    g_bHasBeenShoved[client] = false;
    g_iTickCounter[client] = 0;

    // Bind the appropriate behavior tree
    int rootId = -1;
    switch (L4D2_Infected:GetInfectedClass(client)) {
        case L4D2Infected_Hunter:  rootId = g_iBTHunterRoot;
        case L4D2Infected_Charger: rootId = g_iBTChargerRoot;
        case L4D2Infected_Jockey:  rootId = g_iBTJockeyRoot;
        case L4D2Infected_Smoker:  rootId = g_iBTSmokerRoot;
        case L4D2Infected_Boomer:  rootId = g_iBTBoomerRoot;
        case L4D2Infected_Spitter: rootId = g_iBTSpitterRoot;
        case L4D2Infected_Tank:    rootId = g_iBTTankRoot;
        default:                   rootId = -1;
    }

    if (rootId >= 0) {
        BT_Bind(client, rootId);

        // v5.13: 攻击发起者机制 —— 分配角色（发起者 or 骚扰者）
        AssignWaveRole(client);
        Harass_ResetHold(client);   // v5.19: 新生成 SI 重置骚扰超时计时
    }

    // Per-SI spawn initialization (reset per-SI state)
    switch (L4D2_Infected:GetInfectedClass(client)) {
        case L4D2Infected_Charger: {
            // v4.0.2: 记录出生时刻 —— CND_ChargerSpawnProtect 的 freshSpawn 兜底用。
            // 覆盖"出生即实体（运出复活）未观察到 ghost 阶段"和
            // "player_spawn 在 unghost 时重发导致黑板重置"两种情况。
            BB_SetFloat(client, "_charger_spawn_at", GetGameTime());
        }
        case L4D2Infected_Hunter: {
            g_bHunterJustLunged[client] = false;
            g_fHunterMissEscapeCooldown[client] = 0.0;
        }
        case L4D2Infected_Spitter: {
            // v5.7: 清除发射标记残留（跨命黑板共享，防旧标记被新命消费）
            g_bSpitterSpitFired[client] = false;
            BB_SetBool(client, "_spitter_waiting_spit", false);
        }
        case L4D2Infected_Tank: {
            g_fTankLastBhop[client] = 0.0;
            g_iTankBhopChain[client] = 0;
            g_fTankLastGround[client] = 0.0;
            g_fTankLastPunchJump[client] = 0.0;
            // v5.35: 记录出生时刻 —— TankCond_SpawnPush 用它强制出生推进
            // （用户："一刷新出来就要主动贴近生还者队伍"）
            BB_SetFloat(client, "_tank_spawn_at", GetGameTime());
        }
    }

    return Plugin_Handled;
}

// ============================================================================
// OnPlayerRunCmd — main AI tick entry point
// ============================================================================

public Action:OnPlayerRunCmd(int client, int &buttons, int &impulse,
    float vel[3], float angles[3], int &weapon) {

    if (!IsBotInfected(client) || !IsPlayerAlive(client)) {
        return Plugin_Continue;
    }

    // --- v3.2 FIX: per-frame Tank jump/duck suppression (v2.2 first-layer defense) ---
    // The vanilla Tank AI presses IN_JUMP on its own. Without per-frame clearing,
    // TICK_INTERVAL=4 means 75% of frames pass through unmodified, letting the
    // vanilla AI jump freely at close range. This runs BEFORE the tick throttle.
    if (GetInfectedClass(client) == L4D2Infected_Tank) {
        buttons &= ~IN_JUMP;
        buttons &= ~IN_DUCK;
    }

    // --- v5.23.2: 帧策略回退（实机决定性结论）---
    // 实机对照：v5.23.1 非决策帧持续注入 BT 上次按键（IN_ATTACK 恒 1）时
    // Hunter 扑击失效（贴近 80u 走位不扑、267u 攻击序列在按但引擎不发起）。
    // L4D2 引擎 bot 的技能（扑击/冲锋）由引擎 AI 在自己的按键序列帧里发起，
    // 持续注入破坏该链路。回退为 v5.22 语义：决策帧 BT 输出、非决策帧完全
    // 交还引擎（Valve AI 原样执行），保留 v5.23 的掩码清理（ATTACK 不清理）、
    // 树修复与技能状态机。"控制输出每帧应用"在 L4D2 引擎 bot 上不可行。
    g_iTickCounter[client]++;
    if (g_iTickCounter[client] < TICK_INTERVAL) {
        // 非决策帧：完全交还引擎（Tank 的 jump/duck 抑制已在函数开头每帧做）
        if (GetInfectedClass(client) == L4D2Infected_Tank) {
            return Plugin_Changed;
        }
        return Plugin_Continue;
    }
    g_iTickCounter[client] = 0;

    // Skip if not bound to a BT
    if (!BT_IsBound(client)) {
        return Plugin_Continue;
    }

    // Reset BT movement accumulators (含 v5.22 控制掩码)
    BT_ResetMovement(client);

    // v5.18: 齐射状态机（内部 0.5s 节流，每 SI 调用无妨）
    Wave_EvaluateSync();

    // Set tank aggression mode on blackboard (cached handle, no FindConVar per tick)
    BB_SetBool(client, "tank_aggro", g_hCvarTankAggroBhop != null && GetConVarBool(g_hCvarTankAggroBhop));

    // Execute Behavior Tree
    // The BT modifies buttons/angles via BT_AddButton/BT_RemoveButton/BT_SetAimAngles.
    BT_Tick(client);

    // 决策帧：应用掩码清理（MOVE/DUCK/JUMP；ATTACK 不清理）+ Add/Remove + 视角
    BT_ApplyControlFrame(client, buttons);
    BT_ApplyAngles(client, angles);

    // Handle teleport (used by Tank bhop for velocity override)
    if (g_bBT_Teleport[client]) {
        TeleportEntity(client, NULL_VECTOR, g_fBT_Angles[client], NULL_VECTOR);
    }

    return Plugin_Changed;
}

// ============================================================================
// Event Hooks (preserved from v2.4 — game events, not BT logic)
// ============================================================================

// On ability use: handle pounce angle modification, coordination signals
// v3.2: removed suicide logic — all SI now have BT post-ability behaviors
public Action:Event_AbilityUse(Handle:event, String:name[], bool:dontBroadcast) {
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (!IsBotInfected(client)) return Plugin_Handled;

    g_bHasBeenShoved[client] = false;

    char abilityName[32];
    GetEventString(event, "ability", abilityName, sizeof(abilityName));

    if (StrEqual(abilityName, "ability_lunge")) {
        // Hunter pounce: mark for missed-pounce detection, signal coordination
        g_bHunterJustLunged[client] = true;
        g_fHunterMissEscapeCooldown[client] = GetGameTime() + 0.3;
        SI_SignalAttack(client);
        return Plugin_Handled;

    } else if (StrEqual(abilityName, "ability_charge")) {
        // Charger charge: signal coordination
        // v5.22: 真实冲锋确认标记 —— 引擎实际发起冲锋的事件（按 ATTACK ≠ 成功）。
        // bt_charger.inc 读它才锁 12s 正式冷却（云端审查任务书 §8）。
        g_fChargerChargeConfirmed[client] = GetGameTime();
        SI_SignalAttack(client);
        return Plugin_Handled;

    } else if (StrEqual(abilityName, "ability_spit")) {
        // Spitter post-spit behavior handled by BT (approach/retreat).
        // No suicide — Spitter re-engages after spit cooldown.
        // v5.7: 真实发射标记 —— SpitterAct_* 按住 IN_ATTACK 直到本事件才
        // 锁 8s（原按压时刻锁 = 引擎风阻吞按键时白锁一个冷却窗口）
        g_bSpitterSpitFired[client] = true;
        return Plugin_Handled;
    }
    return Plugin_Handled;
}

public Action:Event_PlayerShoved(Handle:event, String:name[], bool:dontBroadcast) {
    int shovedPlayer = GetClientOfUserId(GetEventInt(event, "userid"));
    if (IsBotInfected(shovedPlayer)) {
        g_bHasBeenShoved[shovedPlayer] = true;
    }
    return Plugin_Continue;
}

public Action:Event_PlayerJump(Handle:event, String:name[], bool:dontBroadcast) {
    int jumpingPlayer = GetClientOfUserId(GetEventInt(event, "userid"));
    if (IsBotInfected(jumpingPlayer)) {
        g_bHasBeenShoved[jumpingPlayer] = false;
    }
    return Plugin_Continue;
}

// ============================================================================
// Coordination timer callback
// ============================================================================

public Action:Timer_UpdateCoordination(Handle:timer) {
    SI_UpdateCoordination();
    return Plugin_Continue;
}

// ============================================================================
// v5.1: 诊断报告 —— 每 2s 打印各特感根 selector 当前命中的分支
// ============================================================================
// 输出到 SM 日志（addons/sourcemod/logs/L20xxxxxx.log）：
//   [AI_HardSI] Tank(8) rootBranch 6 terrain OPEN dist 412
// rootBranch = 根 selector 的子序号（对应各 bt_*.inc 树构建器注释优先级），
// terrain = 地形分类（UNKNOWN/NARROW/OPEN/LEDGE/SEMI），dist = 距黑板目标
// 水平距离（-1 = 无有效目标）。
// 用法：sm_cvar ai_debug 1 → 复现傻站 → 看日志里那个分支号 → 对照对应
// bt_*.inc 的注释找到分支 → 定位卡住的原因。用完记得关（ai_debug 0）。

stock void Debug_SIClassName(int client, char[] cls, int maxlen) {
    switch (L4D2_Infected:GetInfectedClass(client)) {
        case L4D2Infected_Hunter:  strcopy(cls, maxlen, "Hunter");
        case L4D2Infected_Charger: strcopy(cls, maxlen, "Charger");
        case L4D2Infected_Jockey:  strcopy(cls, maxlen, "Jockey");
        case L4D2Infected_Smoker:  strcopy(cls, maxlen, "Smoker");
        case L4D2Infected_Boomer:  strcopy(cls, maxlen, "Boomer");
        case L4D2Infected_Spitter: strcopy(cls, maxlen, "Spitter");
        case L4D2Infected_Tank:    strcopy(cls, maxlen, "Tank");
        default:                   strcopy(cls, maxlen, "?");
    }
}

stock void Debug_TerrainName(int terrain, char[] out, int maxlen) {
    switch (terrain) {
        case TERRAIN_UNKNOWN: strcopy(out, maxlen, "UNKNOWN");
        case TERRAIN_NARROW:  strcopy(out, maxlen, "NARROW");
        case TERRAIN_OPEN:    strcopy(out, maxlen, "OPEN");
        case TERRAIN_LEDGE:   strcopy(out, maxlen, "LEDGE");
        case TERRAIN_SEMI:    strcopy(out, maxlen, "SEMI");
        default:              strcopy(out, maxlen, "?");
    }
}

public Action:Timer_DebugReport(Handle:timer) {
    if (g_hCvarDebug == null || !GetConVarBool(g_hCvarDebug)) {
        return Plugin_Continue;
    }
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsBotInfected(i) || !IsPlayerAlive(i)) continue;
        if (!BT_IsBound(i)) continue;

        int root = g_iBTRoot[i];
        // v5.6: 改读 LastWinningChild —— 原版读 RunningChild：SUCCESS 分支
        // （呕吐/拉人/吐酸等 1-tick 攻击）命中时被清 -1，采样永远看不到
        // 攻击分支，统计失真（"从不攻击"实为观测盲区）
        int branch = g_iBTLastWinningChild[i][root];
        if (branch < 0) branch = -1;

        char cls[16], terr[16];
        Debug_SIClassName(i, cls, sizeof(cls));
        Debug_TerrainName(BB_GetInt(i, "_terrain", TERRAIN_UNKNOWN), terr, sizeof(terr));

        // 距黑板目标距离（-1 = 无有效目标）
        int dist = -1;
        int target = BB_GetInt(i, "target", -1);
        if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
            float myPos[3], tPos[3];
            GetClientAbsOrigin(i, myPos);
            GetClientAbsOrigin(target, tPos);
            dist = RoundToNearest(GetVectorDistance(myPos, tPos));
        }

        LogMessage("[AI_HardSI] %s(%d) rootBranch %d terrain %s dist %d",
            cls, i, branch, terr, dist);
    }
    return Plugin_Continue;
}

// ============================================================================
// v5.13: 攻击发起者机制（Attack Initiator Role）
// ============================================================================
// 每波攻击指定一个"发起者"（Boomer 或 Smoker），其他特感作为"骚扰者"
// 来源：Legend of Dragon 战术原则
//
// 角色定义：
//   ROLE_INITIATOR (1) - 发起者：优先攻击，全力进攻
//   ROLE_HARASSER (2)  - 骚扰者：保持距离，等待发起者成功后再全力进攻
//
// 分配规则：
//   - 每波首个生成的 Boomer 或 Smoker 自动成为发起者
//   - 其他所有特感（包括后续的 Boomer/Smoker）为骚扰者
//   - Tank 不参与角色系统（独立行为）
// ============================================================================

// 全局变量：记录当前波是否已有发起者
bool g_bWaveHasInitiator = false;
float g_fWaveStartTime = 0.0;

// ---------------------------------------------------------------------------
// v5.18 功能 3：同步齐射（Synchronized Alpha Strike）
// ---------------------------------------------------------------------------
// 既有的发起者/骚扰者是"接力式"：骚扰者等发起者得手才转全力（CND_InitiatorEngaged）。
// 齐射是另一条路：全体就位后同时发动。两者压力曲线不同，这里做成并存 ——
// 骚扰者转全力的闸门 = 发起者得手 OR 齐射令下。
//
// 状态机：
//   STAGE_NONE(0)    无波次在待命
//   STAGE_STAGING(1) 待命中：骚扰者到位但按住不打
//   STAGE_STRIKE(2)  齐射令已下：全体全力进攻（持续到本波结束）
//
// 触发齐射的两个条件（任一）：
//   a) 就位比例 ≥ ai_wave_sync_ratio（默认 0.6）
//   b) 待命超时 ai_wave_sync_timeout（默认 12s）—— 防卡死，避免有特感
//      卡在远处导致整波永不发动
// ---------------------------------------------------------------------------
#define STAGE_NONE      0
#define STAGE_STAGING   1
#define STAGE_STRIKE    2

int   g_iWaveStage       = STAGE_NONE;
float g_fWaveStageStart  = 0.0;
float g_fWaveNextEval    = 0.0;

// cvar 句柄声明见文件上方（SourcePawn 全局变量须先声明后用，
// OnPluginStart 的 CreateConVar 在本段之前）

// 波次重置（在新波开始时调用，可由 specialspawner 或其他插件触发）
public void ResetWaveRoles() {
    g_bWaveHasInitiator = false;
    g_fWaveStartTime = GetGameTime();
    g_iWaveStage = STAGE_NONE;
    g_fWaveStageStart = 0.0;
}

// 齐射令是否已下（供 bt_common 的 CND_WaveStrikeOrdered 读取）
stock bool Wave_IsStrikeOrdered() {
    if (g_hCvarWaveSync == null || !g_hCvarWaveSync.BoolValue) return false;
    return (g_iWaveStage == STAGE_STRIKE);
}

// 是否处于待命阶段（骚扰者应按住不打）
stock bool Wave_IsStaging() {
    if (g_hCvarWaveSync == null || !g_hCvarWaveSync.BoolValue) return false;
    return (g_iWaveStage == STAGE_STAGING);
}

// 齐射状态机评估：每 0.5s 一次，在主 tick 里调用
void Wave_EvaluateSync() {
    if (g_hCvarWaveSync == null || !g_hCvarWaveSync.BoolValue) {
        g_iWaveStage = STAGE_NONE;
        return;
    }

    float now = GetGameTime();
    if (now < g_fWaveNextEval) return;
    g_fWaveNextEval = now + 0.5;

    // 统计活着的骚扰者 / 其中已就位的
    int total = 0, ready = 0;
    float readyRange = g_hCvarWaveSyncRange.FloatValue;

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || !IsPlayerAlive(i)) continue;
        if (GetClientTeam(i) != 3) continue;
        int class = GetEntProp(i, Prop_Send, "m_zombieClass");
        if (class == 8) continue;                       // Tank 不参与
        if (BB_GetInt(i, "wave_role", 0) != 2) continue; // 只算骚扰者

        total++;

        // 就位判定：距最近幸存者 ≤ readyRange 且有 LOS
        // v5.22 FIX: 注释承诺 LOS，实际只查距离 —— 隔墙/楼上/门后无射线通路
        // 也被计入 ready，齐射提前发动（云端审查任务书 §12）。补 trace 视线。
        float pos[3];
        GetClientAbsOrigin(i, pos);
        int prox = GetSurvivorProximity(pos);
        if (prox <= 0 || float(prox) > readyRange) continue;

        int near = GetClosestSurvivor(pos);
        if (near <= 0 || !IsSurvivor(near) || !IsPlayerAlive(near)) continue;

        float tPos[3];
        GetClientAbsOrigin(near, tPos);
        TR_TraceRayFilter(pos, tPos, MASK_SHOT, RayType_EndPoint, TracerayFilter, i);
        if (TR_GetFraction() > 0.9) {   // 视线通畅才计就位
            ready++;
        }
    }

    // 没有骚扰者 → 回到无波次状态
    if (total == 0) {
        if (g_iWaveStage != STAGE_NONE) {
            g_iWaveStage = STAGE_NONE;
        }
        return;
    }

    // 齐射已下令：保持到本波打完（骚扰者全死或换波由 ResetWaveRoles 重置）
    if (g_iWaveStage == STAGE_STRIKE) return;

    // 进入待命
    if (g_iWaveStage == STAGE_NONE) {
        g_iWaveStage = STAGE_STAGING;
        g_fWaveStageStart = now;
        if (g_hCvarDebug != null && g_hCvarDebug.BoolValue) {
            LogMessage("[AI_HardSI] Wave sync: STAGING (%d harassers)", total);
        }
        return;
    }

    // 待命中：检查两个发动条件
    float ratio = float(ready) / float(total);
    float wantRatio = g_hCvarWaveSyncRatio.FloatValue;
    float timeout = g_hCvarWaveSyncTimeout.FloatValue;
    bool byRatio = (ratio >= wantRatio);
    bool byTimeout = (now - g_fWaveStageStart >= timeout);

    if (byRatio || byTimeout) {
        g_iWaveStage = STAGE_STRIKE;
        if (g_hCvarDebug != null && g_hCvarDebug.BoolValue) {
            LogMessage("[AI_HardSI] Wave sync: STRIKE (%d/%d ready, %.0f%%, by=%s)",
                ready, total, ratio * 100.0, byTimeout ? "timeout" : "ratio");
        }
    }
}

// 为新生成的特感分配角色
stock void AssignWaveRole(int client) {
    if (!IsClientInGame(client) || !IsPlayerAlive(client)) {
        return;
    }

    int class = GetEntProp(client, Prop_Send, "m_zombieClass");

    // Tank 不参与角色系统
    if (class == 8) {
        BB_SetInt(client, "wave_role", 0);  // ROLE_NONE
        return;
    }

    // v5.26/v5.30: 角色分配（用户拍板）：
    //   原：只有首个 Boomer/Smoker 当发起者 → Hunter/Jockey 100% 骚扰者
    //   v5.26: 每只非 Tank 特感独立 50/50 掷骰
    //   v5.30: 用户调整为 6:4 —— 进攻者 60% / 骚扰者 40%
    //   INITIATOR（进攻者）：直接全力进攻（不游走）
    //   HARASSER（骚扰者）：游走一会（≤ ai_harass_max_hold 硬超时）再进攻
    // 无发起者时由 CND_HarasserReleased 的 5s 硬超时/到嘴边兜底（v5.19）。
    if (GetRandomFloat(0.0, 1.0) < 0.6) {
        BB_SetInt(client, "wave_role", 1);  // ROLE_INITIATOR（60%）
        g_bWaveHasInitiator = true;
        g_fWaveStartTime = GetGameTime();
        LogMessage("[AI_HardSI] SI(%d class=%d) assigned as INITIATOR (60%)", client, class);
    } else {
        BB_SetInt(client, "wave_role", 2);  // ROLE_HARASSER（40%）
    }
}
