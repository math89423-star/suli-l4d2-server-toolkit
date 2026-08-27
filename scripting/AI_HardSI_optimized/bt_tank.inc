// ============================================================================
// bt_tank.inc — Tank Behavior Tree (v2.2 → BT v3.2 → v4.0.5 → v4.1)
// ============================================================================
// v4.0.5 cvar 接入审计（13 个 ai_tank_* 只建不接的修正）：
//   - punch_jump / instakill / punch_damage / rage_multiplier 接入生效
//   - bhop 冷却恢复（g_fTankLastBhop 只写不读 = 无冷却连跳）+ chain 重置
//   - wall trace / evade 恢复（v3.2 重构丢失 ai_tank_bhop_wall_dist/evade）
//   - aggro（ai_tank_aggro_bhop）由 BhopEligible 消费：max_dist 翻倍 + 冷却缩短
//   - 近战攻击簇 Cooldown(1.5) 对齐引擎 z_tank_attack_interval=1.5
// v4.1 Tank 高级玩法四件套（用户设计方向：无脑连跳贴脸一拳 = 低级做法，
// 强调协同配合 + 战术）：
//   - 协同配合：Tank 消费协同窗口 —— coordPinSeq 窗口内锁被 pin 目标
//     （C/H/Sp/J 任一 pin 住人 → Tank 冲过去一拳必杀）+ coordPunchSeq
//     窗口内 ≤300u 直测 pin 出拳；mode 6 巨兽协同保持小队分散（不集火命令）
//   - 追击优化：damager 距离门控 800u（风筝手不再把 Tank 拖离战场）
//   - 地形秒杀：设计实现后经用户拍板整体移除（2026-08-03）—— Tank 拳
//     只作用于汽车/树干等物理实体、不作用于爆炸物，罐类爆炸链路不可靠，
//     "不确定宁愿用原版"。保持原版行为，不主动打车（propKillSeq 已删）
//   - 飞石精准 + 移动靶预判：TankAct_AimRock 提前量瞄准（lead = vel × dist/800）
//     + L4D_TankRock_OnRelease 释放校正（真实 |vecVel| 自修正 bhop 自身速度）
// Preserved v2.2 features:
//   - Smart bhop (adaptive cooldown, momentum, obstacle evasion, terrain sense)
//   - Punch-jump combo (50% at <300u)
//   - Instakill (via player_hurt event hook, unchanged)
//   - (v4.1: "Smart rock blocking via L4D2_OnSelectTankAttack" 从未实现 ——
//     历史注释。石头行为由 v4.1 的 AimRock + OnRelease 校正层接管)
//   - Target selection (damager > low HP > incapped execute > default)
//   - Rage multiplier (on fire: faster/stronger bhops)
// v3.2 terrain-aware additions:
//   - Narrow corridor: body-block chokepoint + melee punch (survivors trapped)
//   - Open area: prefer rock throw + bhop chase (maximum reach)
//   - Near ledge: punch survivors off cliffs (aim toward edge)
// ============================================================================

#if defined _bt_tank_included
  #endinput
#endif
#define _bt_tank_included

#include <sdktools>

// Tank bhop constants (from v2.2)
#define BASE_BOOST_FORWARD  60.0
#define MOMENTUM_PER_HOP    10.0
#define MAX_BOOST_FORWARD   150.0

// Per-tank state
float g_fTankLastBhop[MAXPLAYERS + 1];
int   g_iTankBhopChain[MAXPLAYERS + 1];
float g_fTankLastGround[MAXPLAYERS + 1];
float g_fTankLastPunchJump[MAXPLAYERS + 1];
// v5.1: instakill 递归防护 —— SDKHooks_TakeDamage 注入的伤害再次触发
// player_hurt（Pre hook 在事件链内递归），2026-08-04 曾 5 次栈溢出
// （"Not enough space on the stack"）。0.2s 内同一受害者不重复注入。
float g_fTankLastInstakillAt[MAXPLAYERS + 1];

// Forward declarations

// v3.4: cached ConVar handles (initialized in Tank_OnModuleStart after CreateConVar)
ConVar g_hCvarTankBhop_cached = null;
ConVar g_hCvarTankRock_cached = null;
ConVar g_hCvarTankBhopMinDist_cached = null;
ConVar g_hCvarTankBhopMaxDist_cached = null;
ConVar g_hCvarTankBhopMomentum_cached = null;
// v4.0.5: 审计补全 —— 以下 cvar 此前创建了但从未被读取（= 无效配置）
ConVar g_hCvarTankBhopAdaptive_cached = null;
ConVar g_hCvarTankBhopWall_cached = null;
ConVar g_hCvarTankBhopEvade_cached = null;
ConVar g_hCvarTankPunchJump_cached = null;
ConVar g_hCvarTankRage_cached = null;
ConVar g_hCvarTankInstakill_cached = null;
ConVar g_hCvarTankPunchDamage_cached = null;
// v4.1: 四件套 cvar（协同 / 飞石预判 / 追击门控；地形秒杀已移除）
ConVar g_hCvarTankCoord_cached = null;
ConVar g_hCvarTankRockPredict_cached = null;
ConVar g_hCvarTankRockLeadMax_cached = null;
ConVar g_hCvarTankRockPitch_cached = null;
ConVar g_hCvarTankDamagerMaxDist_cached = null;


// ============================================================================
// Target Selection
// ============================================================================

BT_Status TankCond_HasDamager(int client) {
    for (int s = 1; s <= MaxClients; s++) {
        if (!IsSurvivor(s) || !IsPlayerAlive(s)) continue;
        if (IsPinned(s)) continue;
        if (IsValidClient(s) && GetClientAimTarget(s) == client) {
            return BT_SUCCESS;
        }
    }
    return BT_FAILURE;
}

BT_Status TankAct_SelectDamager(int client) {
    float tankPos[3];
    GetClientAbsOrigin(client, tankPos);
    int bestTarget = -1;
    int bestDist = 999999;
    // v4.1: 追击距离门控 —— 风筝手（远处射击者）不再把 Tank 拖离战场。
    // 只有门控距离内（默认 800u）的射手才值得追；远距离射手由
    // 低 HP / 最近目标选择接管（体验参数，玩家可调）
    int maxDist = (g_hCvarTankDamagerMaxDist_cached != null) ? GetConVarInt(g_hCvarTankDamagerMaxDist_cached) : 800;
    for (int s = 1; s <= MaxClients; s++) {
        if (!IsSurvivor(s) || !IsPlayerAlive(s)) continue;
        if (IsPinned(s)) continue;
        if (IsValidClient(s) && GetClientAimTarget(s) == client) {
            float pos[3];
            GetClientAbsOrigin(s, pos);
            int d = RoundToNearest(GetVectorDistance(tankPos, pos));
            if (d > maxDist) continue;   // v4.1: 门控外射手忽略
            if (bestTarget < 0 || d < bestDist) { bestTarget = s; bestDist = d; }
        }
    }
    if (bestTarget > 0) { BB_SetInt(client, "target", bestTarget); return BT_SUCCESS; }
    return BT_FAILURE;
}

BT_Status TankAct_SelectLowestHP(int client) {
    int best = -1, lowestHP = 999;
    for (int s = 1; s <= MaxClients; s++) {
        if (!IsSurvivor(s) || !IsPlayerAlive(s)) continue;
        if (IsIncapacitated(s) || IsPinned(s)) continue;
        int hp = GetClientHealth(s);
        if (hp < lowestHP) { lowestHP = hp; best = s; }
    }
    if (best > 0) { BB_SetInt(client, "target", best); return BT_SUCCESS; }
    return BT_FAILURE;
}

BT_Status TankAct_SelectDefault(int client) {
    int t = GetClientAimTarget(client);
    if (t > 0 && IsSurvivor(t)) { BB_SetInt(client, "target", t); return BT_SUCCESS; }
    float pos[3]; GetClientAbsOrigin(client, pos);
    int c = GetClosestSurvivor(pos);
    if (c > 0) { BB_SetInt(client, "target", c); return BT_SUCCESS; }
    return BT_FAILURE;
}

// ============================================================================
// v5.0: 开团者 —— 不被风筝手牵制时主动冲幸存者密集区（撕开阵型）。
// Tank 是特感阵营的坦克：冲散站位 = 为 C/H/J/Sp 创造进攻窗口。
// 条件：密集区存在（≥3 人 500u 内）且距 Tank ≤1200u —— 远时仍优先追
// 射手防风筝（damager 分支在前）；近时从"追单兵"切换为"冲整片火力网"。
// ============================================================================

BT_Status TankCond_ClusterReady(int client) {
    float myPos[3];
    GetClientAbsOrigin(client, myPos);
    float center[3];
    int member = SI_GetDenseCluster(500.0, 3, center);
    if (member <= 0) return BT_FAILURE;
    float cPos[3];
    GetClientAbsOrigin(member, cPos);
    return (GetVectorDistance(myPos, cPos) <= 1200.0) ? BT_SUCCESS : BT_FAILURE;
}

BT_Status TankAct_SelectClusterMember(int client) {
    float center[3];
    int member = SI_GetDenseCluster(500.0, 3, center);
    if (member <= 0) return BT_FAILURE;
    BB_SetInt(client, "target", member);
    return BT_SUCCESS;
}

// ============================================================================
// Punch-Jump Combo
// ============================================================================

BT_Status TankCond_PunchJumpReady(int client) {
    // v4.0.5 FIX: ai_tank_punch_jump 创建了但从未检查 —— 默认 0（禁用）时
    // 近身仍有 50% 概率跳拳，配置完全无效（历史教训：[[l4d2-tank-ai-fix]]）
    if (g_hCvarTankPunchJump_cached == null || !GetConVarBool(g_hCvarTankPunchJump_cached)) return BT_FAILURE;
    int target = BB_GetInt(client, "target", -1);
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) return BT_FAILURE;
    if (IsIncapacitated(target) || IsPinned(target)) return BT_FAILURE;
    float tPos[3], sPos[3];
    GetClientAbsOrigin(client, tPos); GetClientAbsOrigin(target, sPos);
    if (GetVectorDistance(tPos, sPos) > 300.0) return BT_FAILURE;
    if (GetRandomInt(0, 1) != 0) return BT_FAILURE;
    float now = GetGameTime();
    if (g_fTankLastPunchJump[client] > 0.0 && (now - g_fTankLastPunchJump[client]) < 2.0) return BT_FAILURE;
    return BT_SUCCESS;
}

BT_Status TankAct_PunchJump(int client) {
    float tPos[3];
    GetClientAbsOrigin(client, tPos);
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target)) {
        float sPos[3], dir[3], ang[3];
        GetClientAbsOrigin(target, sPos);
        MakeVectorFromPoints(tPos, sPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    BT_AddButton(client, IN_JUMP);
    BT_AddButton(client, IN_ATTACK);
    BT_RemoveButton(client, IN_ATTACK2);
    g_fTankLastPunchJump[client] = GetGameTime();
    return BT_SUCCESS;
}

// ============================================================================
// Execute Incapped
// ============================================================================

BT_Status TankCond_IncappedNearby(int client) {
    float tPos[3];
    GetClientAbsOrigin(client, tPos);
    // v4.0.5: 追杀未倒地 > 补刀 —— 追击圈(800u)内存在站立活人则优先追杀，
    // 不处决（处决 = 白赚击杀，只在活人全部跑出可及范围时执行）
    for (int s = 1; s <= MaxClients; s++) {
        if (!IsSurvivor(s) || !IsPlayerAlive(s) || IsIncapacitated(s)) continue;
        float sPos[3]; GetClientAbsOrigin(s, sPos);
        if (GetVectorDistance(tPos, sPos) < 800.0) return BT_FAILURE;
    }
    // v5.6: 处决掷骰 1.5s 节拍（对齐近战冷却）—— 原版每 tick 重掷 40%：
    // 40% 帧按拳、60% 帧走位 → 补刀不连贯，倒地者差一拳没死（+ 两个目标
    // 交替瞄准甩头）。
    float now = GetGameTime();
    float lastRoll = BB_GetFloat(client, "_tank_execute_roll", 0.0);
    bool doExecute;
    if (now - lastRoll >= 1.5) {
        doExecute = (GetRandomFloat(0.0, 1.0) < 0.40);
        BB_SetBool(client, "_tank_execute_do", doExecute);
        BB_SetFloat(client, "_tank_execute_roll", now);
    } else {
        doExecute = BB_GetBool(client, "_tank_execute_do", false);
    }
    for (int s = 1; s <= MaxClients; s++) {
        if (!IsSurvivor(s) || !IsPlayerAlive(s) || !IsIncapacitated(s)) continue;
        float sPos[3]; GetClientAbsOrigin(s, sPos);
        if (GetVectorDistance(tPos, sPos) < 120.0 && doExecute) {
            BB_SetInt(client, "target", s);
            return BT_SUCCESS;
        }
    }
    return BT_FAILURE;
}

BT_Status TankAct_ExecuteIncapped(int client) {
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target)) {
        float tPos[3], sPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, tPos);
        GetClientAbsOrigin(target, sPos);
        MakeVectorFromPoints(tPos, sPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    BT_AddButton(client, IN_ATTACK);
    BT_RemoveButton(client, IN_ATTACK2);
    return BT_SUCCESS;
}

// ============================================================================
// Rock Eligibility
// ============================================================================

BT_Status TankCond_RockEligible(int client) {
    // v3.4 FIX: use cached handle instead of FindConVar per tick
    if (g_hCvarTankRock_cached == null || !GetConVarBool(g_hCvarTankRock_cached)) return BT_FAILURE;

    int target = BB_GetInt(client, "target", -1);
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) return BT_FAILURE;
    float tPos[3], sPos[3];
    GetClientAbsOrigin(client, tPos); GetClientAbsOrigin(target, sPos);
    float dist = GetVectorDistance(tPos, sPos);
    // v3.5 FIX: removed hDiff > 100 requirement — on flat terrain (hDiff≈0)
    // the Tank would NEVER throw rocks. Distance alone is sufficient.
    return (dist > 500.0) ? BT_SUCCESS : BT_FAILURE;
}

// ============================================================================
// Smart Bhop (v2.2)
// ============================================================================

// v4.0.5: 墙检测 + 侧向绕墙辅助（恢复 v3.2 重构丢失的 wall/evade）
// 复用 TerrainTraceFilter：排除所有玩家实体，只算 world geometry ——
// 幸存者/特感站在前面不构成"墙"（Tank 应该穿过他们）

// 前方 wallDist 内是否有墙体（水平 trace，胸口高度）
stock bool Tank_IsWallAhead(int client, int dist) {
    float pos[3], ang[3], fwd[3], start[3], end[3];
    GetClientEyePosition(client, pos);
    GetClientEyeAngles(client, ang);
    ang[0] = 0.0;
    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(fwd, fwd);
    start[0] = pos[0]; start[1] = pos[1]; start[2] = pos[2] - 20.0;
    end[0] = pos[0] + fwd[0] * float(dist);
    end[1] = pos[1] + fwd[1] * float(dist);
    end[2] = start[2];
    TR_TraceRayFilter(start, end, MASK_PLAYERSOLID, RayType_EndPoint, TerrainTraceFilter, client);
    return TR_DidHit();
}

// 左右两侧找空档：+1（右）/ -1（左）/ 0（两边都堵）
stock int Tank_PickEvadeSide(int client, int dist) {
    float pos[3], ang[3], right[3], start[3], end[3];
    GetClientEyePosition(client, pos);
    GetClientEyeAngles(client, ang);
    ang[0] = 0.0;
    GetAngleVectors(ang, NULL_VECTOR, right, NULL_VECTOR);  // 第三参 = right
    NormalizeVector(right, right);
    float z = pos[2] - 20.0;
    start[0] = pos[0]; start[1] = pos[1]; start[2] = z;
    // 右侧
    end[0] = pos[0] + right[0] * float(dist);
    end[1] = pos[1] + right[1] * float(dist);
    end[2] = z;
    TR_TraceRayFilter(start, end, MASK_PLAYERSOLID, RayType_EndPoint, TerrainTraceFilter, client);
    bool rightBlocked = TR_DidHit();
    // 左侧
    end[0] = pos[0] - right[0] * float(dist);
    end[1] = pos[1] - right[1] * float(dist);
    end[2] = z;
    TR_TraceRayFilter(start, end, MASK_PLAYERSOLID, RayType_EndPoint, TerrainTraceFilter, client);
    bool leftBlocked = TR_DidHit();
    if (!rightBlocked && leftBlocked) return 1;    // 右空
    if (rightBlocked && !leftBlocked) return -1;   // 左空
    if (!rightBlocked && !leftBlocked) return 1;   // 都空 → 默认右
    return 0;                                       // 都堵
}

BT_Status TankCond_BhopEligible(int client) {
    // v3.4 FIX: use cached handle instead of FindConVar per tick
    if (g_hCvarTankBhop_cached == null || !GetConVarBool(g_hCvarTankBhop_cached)) return BT_FAILURE;

    int flags = GetEntityFlags(client);
    if (!(flags & FL_ONGROUND)) return BT_FAILURE;
    if (GetEntityMoveType(client) & MOVETYPE_LADDER) return BT_FAILURE;

    float vel[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", vel);
    float speed = SquareRoot(Pow(vel[0], 2.0) + Pow(vel[1], 2.0));
    if (speed < 120.0) return BT_FAILURE;
    // v5.7: 引擎标志 → trace 视线 —— 插件每 2 帧覆盖朝向/按键致
    // m_hasVisibleThreats 失真，Tank 连跳追人全程被禁用（呆站主因之一）
    if (CND_HasTargetLOS(client) != BT_SUCCESS) return BT_FAILURE;

    // v4.0.5 FIX: 恢复 bhop 冷却 —— g_fTankLastBhop 此前只写不读，
    // 每 2 tick（~33ms）无条件连跳，boost 永续叠加 + IN_JUMP 每帧按 =
    // 抽搐式连跳。adaptive=1：速度越快冷却越短（120→600 u/s 映射 0.6→0.25s）
    float now = GetGameTime();
    float cd = 0.6;
    if (g_hCvarTankBhopAdaptive_cached != null && GetConVarBool(g_hCvarTankBhopAdaptive_cached)) {
        cd = 0.6 - (speed - 120.0) / 1600.0;
        if (cd < 0.25) cd = 0.25;
    }
    if (g_fTankLastBhop[client] > 0.0 && (now - g_fTankLastBhop[client]) < cd) return BT_FAILURE;

    float tPos[3];
    GetClientAbsOrigin(client, tPos);
    int target = BB_GetInt(client, "target", -1);

    // v3.4 FIX: enforce min_dist using cached handle
    int minDist = (g_hCvarTankBhopMinDist_cached != null) ? GetConVarInt(g_hCvarTankBhopMinDist_cached) : 200;
    if (GetSurvivorProximity(tPos, target) < minDist) return BT_FAILURE;

    // v3.4 FIX: enforce max_dist using cached handle
    int maxDist = (g_hCvarTankBhopMaxDist_cached != null) ? GetConVarInt(g_hCvarTankBhopMaxDist_cached) : 800;
    // v4.0.5: aggro（ai_tank_aggro_bhop）真正消费 —— CND_IsAggressiveMode 有定义
    // 但无树引用，aggro 写进黑板后无人读取（纯死配置）。语义：max_dist 翻倍
    // 远程也追跳（"relentlessly bhops toward target"），min_dist 保持 ——
    // 近身不跳是历史铁律（[[l4d2-tank-ai-fix]]），aggro 不得覆盖
    if (BB_GetBool(client, "tank_aggro", false)) {
        maxDist *= 2;
    }
    if (GetSurvivorProximity(tPos, target) > maxDist) return BT_FAILURE;

    // v6.8.1: 墙检 200→120 收窄，减少窄巷误判“有墙”导致不开跳；Tank大体型在200内常误触侧墙
    int wallDist = (g_hCvarTankBhopWall_cached != null) ? GetConVarInt(g_hCvarTankBhopWall_cached) : 120;
    if (Tank_IsWallAhead(client, wallDist)) {
        bool evade = (g_hCvarTankBhopEvade_cached != null) ? GetConVarBool(g_hCvarTankBhopEvade_cached) : true;
        if (!evade) return BT_FAILURE;  // 不绕墙 → 不跳，fallback 地面走
        int side = Tank_PickEvadeSide(client, wallDist);
        if (side == 0) return BT_FAILURE;   // 左右都堵 → 不跳
        BB_SetInt(client, "tank_evade_dir", side);
    } else {
        BB_SetInt(client, "tank_evade_dir", 0);
    }

    return BT_SUCCESS;
}

BT_Status TankAct_Bhop(int client) {
    // v5.0: 开团预告 —— Tank 连跳逼近 = 队友跟进窗口（mode6 巨兽协同除外：
    // 该模式设计是"Tank 锁定、小队分散控制"，与 v4.1 出拳信号同逻辑）
    if (SI_GetActiveMode() != 6)
        SI_SignalAttack(client);

    float eyeAng[3];
    GetClientEyeAngles(client, eyeAng);

    // 80% snap toward target
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float tPos[3], sPos[3], dir[3], chaseAng[3];
        GetClientAbsOrigin(client, tPos);
        GetClientAbsOrigin(target, sPos);
        MakeVectorFromPoints(tPos, sPos, dir);
        GetVectorAngles(dir, chaseAng);
        eyeAng[1] = eyeAng[1] * 0.2 + chaseAng[1] * 0.8;
        eyeAng[0] = eyeAng[0] * 0.2 + chaseAng[0] * 0.8;
    }

    // v4.0.5: evade —— 有墙时侧向偏转 70°（BhopEligible 已标好方向）
    int evadeDir = BB_GetInt(client, "tank_evade_dir", 0);
    if (evadeDir != 0) {
        eyeAng[1] += 70.0 * float(evadeDir);
    }

    float now = GetGameTime();
    // v4.0.5 FIX: chain 重置 —— 非连续跳跃（距上次 >1s）清零，否则 chain
    // 永续增长到 cap，momentum 恒满（失去"连跳越跳越猛"的意义）
    if (g_fTankLastBhop[client] > 0.0 && (now - g_fTankLastBhop[client]) > 1.0) {
        g_iTankBhopChain[client] = 0;
    }
    g_fTankLastBhop[client] = now;
    g_iTankBhopChain[client]++;

    // Momentum
    float boost = BASE_BOOST_FORWARD;
    if (g_hCvarTankBhopMomentum_cached != null && GetConVarBool(g_hCvarTankBhopMomentum_cached)) {
        boost += float(g_iTankBhopChain[client]) * MOMENTUM_PER_HOP;
        if (boost > MAX_BOOST_FORWARD) boost = MAX_BOOST_FORWARD;
    }
    // v4.0.5 FIX: rage_multiplier 此前硬编码 1.5，cvar 无效
    if (GetEntProp(client, Prop_Data, "m_fFlags") & FL_ONFIRE) {
        float rage = (g_hCvarTankRage_cached != null) ? GetConVarFloat(g_hCvarTankRage_cached) : 1.5;
        boost *= rage;
    }

    BT_RemoveButton(client, IN_ATTACK2);
    BT_AddButton(client, IN_DUCK);
    BT_AddButton(client, IN_JUMP);
    BT_AddButton(client, IN_FORWARD);

    // Push velocity
    float fwd[3];
    GetAngleVectors(eyeAng, fwd, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(fwd, fwd);
    ScaleVector(fwd, boost);

    float newVel[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", newVel);
    newVel[0] += fwd[0];
    newVel[1] += fwd[1];
    newVel[2] += fwd[2];
    TeleportEntity(client, NULL_VECTOR, eyeAng, newVel);
    return BT_SUCCESS;
}

// ============================================================================
// v4.1: 飞石瞄准 + 移动靶预判（TankAct_AimRock）
// ============================================================================
// 现状缺口：两条投石路径（openStrat0_Rock / rockSeq）都只按 IN_ATTACK2，
// 石头沿残留视线方向飞出（继承自上次 bhop 的 80/20 混合角或引擎遗留角）——
// 连"瞄准目标"都没有。本 action 在投石前把视角对准提前点：
//   lead = 目标水平速度 × (距离 / 800)    （z_tank_throw_force=800 基线）
// 引擎按视线方向解算投掷弹道（vVel = forward×800 + 自身速度 + z+80），
// 瞄提前点即可命中移动目标；文件尾的 L4D_TankRock_OnRelease 校正层用
// 释放瞬间的真实 |vecVel| 重算，自修正 bhop 自身速度带来的误差。
BT_Status TankAct_AimRock(int client) {
    if (g_hCvarTankRockPredict_cached != null && GetConVarBool(g_hCvarTankRockPredict_cached)) {
        int target = BB_GetInt(client, "target", -1);
        if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
            float tPos[3], tVel[3], lead[3], tankPos[3], dir[3], ang[3];
            // v5.30: 瞄准点改用眼睛高度（原 GetClientAbsOrigin = 脚底 → 石头
            // 抛物线落点偏低/低抛，命中率差）。眼睛高度 ≈ 脚底+60u，
            // 石头弧线落点落在目标身体上而非地面。
            GetClientEyePosition(target, tPos);
            GetEntPropVector(target, Prop_Data, "m_vecVelocity", tVel);
            GetClientAbsOrigin(client, tankPos);
            float dist = GetVectorDistance(tankPos, tPos);
            // 水平向提前量（z 轴不预判 —— 高度由引擎弹道处理）
            float t = dist / 800.0;
            lead[0] = tVel[0] * t;
            lead[1] = tVel[1] * t;
            lead[2] = 0.0;
            float maxLead = (g_hCvarTankRockLeadMax_cached != null) ? GetConVarFloat(g_hCvarTankRockLeadMax_cached) : 400.0;
            float leadLen = GetVectorLength(lead);
            if (leadLen > maxLead) ScaleVector(lead, maxLead / leadLen);
            AddVectors(tPos, lead, tPos);
            MakeVectorFromPoints(tankPos, tPos, dir);
            GetVectorAngles(dir, ang);
            // 垂直补偿：石头弹道弧线的残余垂直误差，空服实测标定（默认 0）
            if (g_hCvarTankRockPitch_cached != null) {
                ang[0] += GetConVarFloat(g_hCvarTankRockPitch_cached);
            }
            // v6.8.1: 30% 高抛 — 低抛易被掩体挡，高抛越障；-18~-25° 抬头，存BB供OnRelease校正
            float highAdd = 0.0;
            if (dist > 600.0 && GetRandomFloat(0.0, 1.0) < 0.3) {
                highAdd = GetRandomFloat(-25.0, -18.0);
                ang[0] += highAdd;
            }
            BB_SetFloat(client, "_tank_rock_high_pitch", highAdd);
            BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        }
    }
    return BT_SUCCESS;
}

// ============================================================================
// v5.26: 投石确认状态机（P1-1 —— 审查发现"按 IN_ATTACK2 = 假成功"）
// 原 rockCluster Cooldown(5.0) 在按键时刻武装：投石动画 ~1s 期间引擎冷却内
// 提前按键被吞 → 实际投石频率约砍半。本动作按 ATTACK2 → TRYING →
// L4D_TankRock_OnRelease（真实释放事件，文件尾钩子置 _tank_rock_confirmed）
// → CONFIRMED（arm 外层 Cooldown(5.0)）；2s 未确认 → 退避重试（不锁冷却）。
// 只改本文件：标记由既有的 L4D_TankRock_OnRelease 钩子置位（新增一行）。
// ============================================================================
#define TANK_ROCK_TRY_TIMEOUT 2.0
#define TANK_ROCK_BACKOFF 0.6

BT_Status TankAct_TryThrowRock(int client) {
    float now = GetGameTime();

    // 退避中：不按 IN_ATTACK2（防每 tick 重探/白按），FAILURE → 落其它分支
    if (SI_AbilityBackoffActive(client, "_tank_rock")) {
        return BT_FAILURE;
    }

    // 真实确认：L4D_TankRock_OnRelease 已触发（石头真正投出）→ 清标记、
    // CONFIRMED + SUCCESS → 外层 rockCluster Cooldown(5.0) arm（唯一冷却源）
    if (BB_GetFloat(client, "_tank_rock_confirmed", 0.0) > 0.0) {
        BB_SetFloat(client, "_tank_rock_confirmed", 0.0);
        SI_AbilityMarkConfirmed(client, "_tank_rock", now);
        SI_AbilitySetState(client, "_tank_rock", ABILITY_CONFIRMED);
        return BT_SUCCESS;
    }

    // 进入尝试：仅【非 TRYING】时重置起点（v5.39 FIX：原条件含"已过期也
    // 重置"，到期 tick 刷新 tryAt → 底部超时分支永不可达 → 无限按 ATTACK2。
    // 现到期不重置，交底部超时分支退避回 IDLE；被抢占残留的陈旧 try_at
    // 首个 tick 即触发超时自愈）
    float tryAt = SI_AbilityGetTryAt(client, "_tank_rock");
    if (SI_AbilityGetState(client, "_tank_rock") != ABILITY_TRYING) {
        tryAt = now;
        SI_AbilityMarkTry(client, "_tank_rock", tryAt);
        SI_AbilitySetState(client, "_tank_rock", ABILITY_TRYING);
    }

    // 持续按住 ATTACK2（视角由前置 TankAct_AimRock 已对准提前点）
    BT_AddButton(client, IN_ATTACK2);

    // 超时未确认 = 引擎拒绝/吞键（几何/冷却）→ 短退避，不锁 5s 冷却
    if (now - tryAt > TANK_ROCK_TRY_TIMEOUT) {
        SI_AbilityBackoff(client, "_tank_rock", now, GetRandomFloat(0.4, 0.8));
        return BT_FAILURE;
    }

    return BT_RUNNING;
}

// ============================================================================
// v4.1: Tank × 协同特感配合（coordPinSeq / coordPunchSeq）
// ============================================================================
// 现状缺口：bt_tank.inc 无任何 SI_*/窗口引用 —— mode 6 巨兽协同的设计意图
// （hardcoop_util.sp SI_GetCoordinatedTarget 注释）是"Tank 锁定目标，
// C+H+Sp+J 分散控制更多生还者"，但 Tank 侧消费完全缺失。本版补上：
//   - targetSelector 顶部：窗口开启 + pin 目标有效 → Tank 锁定被 pin 者
//     （C/H/Sp/J 任一 pin 住人，Tank 冲过去一拳必杀 —— 被 pin 者无法躲避）
//   - meleeSelector 顶部：窗口内 ≤300u 直测 pin → 出拳
//     （共享近战簇 Cooldown(1.5)，双冷却节点轮流触发 = 没锁，铁律）
BT_Status TankCond_TankCoordEnabled(int client) {
    if (g_hCvarTankCoord_cached == null || !GetConVarBool(g_hCvarTankCoord_cached)) return BT_FAILURE;
    return BT_SUCCESS;
}

BT_Status TankCond_CoordPunchReady(int client) {
    if (g_hCvarTankCoord_cached == null || !GetConVarBool(g_hCvarTankCoord_cached)) return BT_FAILURE;
    if (!SI_IsAttackWindow()) return BT_FAILURE;
    int pin = SI_GetPinTarget();
    if (pin <= 0 || !IsSurvivor(pin) || !IsPlayerAlive(pin)) return BT_FAILURE;
    // 黑板对齐（coordPinSeq 被前面的分支抢跑时仍保持一致）
    if (BB_GetInt(client, "target", -1) != pin) BB_SetInt(client, "target", pin);
    float tPos[3], sPos[3];
    GetClientAbsOrigin(client, tPos);
    GetClientAbsOrigin(pin, sPos);
    // 直测 pin 距离 —— 不能用 CND_IsInRange（它量最近生还者，pin 在 400u
    // 而另一个生还者 200u 时会误触发打空气）
    if (GetVectorDistance(tPos, sPos) > 300.0) return BT_FAILURE;
    // v5.26: 替换已证伪的 m_hasVisibleThreats（P1-2 —— BT 接管视角/按键下
    // 引擎标志失真，协同"窗口出拳必杀"静默失效）→ 直测 pin 视线（trace）。
    float eye[3], pinEye[3];
    GetClientEyePosition(client, eye);
    GetClientEyePosition(pin, pinEye);
    TR_TraceRayFilter(eye, pinEye, MASK_PLAYERSOLID, RayType_EndPoint, LOS_TraceFilter, client);
    if (TR_DidHit() && TR_GetEntityIndex() != pin) return BT_FAILURE;
    return BT_SUCCESS;
}

BT_Status TankAct_CoordPunch(int client) {
    int pin = SI_GetPinTarget();
    if (pin > 0 && IsSurvivor(pin) && IsPlayerAlive(pin)) {
        float tPos[3], sPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, tPos);
        GetClientAbsOrigin(pin, sPos);
        MakeVectorFromPoints(tPos, sPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    BT_AddButton(client, IN_ATTACK);
    BT_RemoveButton(client, IN_ATTACK2);
    // mode 6（巨兽协同）：C+H+Sp+J 分散控制更多生还者、减轻 Tank 被集火
    // 压力 —— 不命令小队集火 Tank 的目标（与 SI_GetCoordinatedTarget
    // 的 mode-6 豁免同义）。其他模式：Tank 出拳 = 开团信号，附近未攻击
    // SI 收到 L4D2_CommandABot 跟进（SI_SignalAttack 语义）
    if (SI_GetActiveMode() != 6) SI_SignalAttack(client);
    return BT_SUCCESS;
}

stock int BT_CreateTankTree() {
    // ==========================================
    // Target selection subtree
    // ==========================================
    int selectDamager = BT_CreateSequence(2,
        BT_CreateCondition(TankCond_HasDamager),
        BT_CreateAction(TankAct_SelectDamager)
    );
    // v5.0: 开团者 —— 密集区近旁时冲密集区（撕阵型制造窗口）
    int selectCluster = BT_CreateSequence(2,
        BT_CreateCondition(TankCond_ClusterReady),
        BT_CreateAction(TankAct_SelectClusterMember)
    );
    int selectLowHP = BT_CreateAction(TankAct_SelectLowestHP);
    int selectDefault = BT_CreateAction(TankAct_SelectDefault);

    // v4.1: 协同窗口消费 —— 窗口开启 + pin 目标有效 → Tank 锁定被 pin 者。
    // ACT_AcquirePinTarget 自带有效性校验（过期/无效返回 FAILURE），失败
    // 自然落到原选择链（damager > lowHP > default）。全模式生效：
    // mode 6 巨兽协同的设计就是"Tank 锁定目标，小队分散控制"
    int coordPinSeq = BT_CreateSequence(3,
        BT_CreateCondition(TankCond_TankCoordEnabled),
        BT_CreateCondition(CND_IsAttackWindow),
        BT_CreateAction(ACT_AcquirePinTarget)
    );

    // v5.18 功能 2：挂边优先 —— 挂边者一拳打落即死，是 Tank 效率最高的目标。
    // 排在选人链最前（协同窗口之前）：挂边是限时机会，队友几秒就拉起来了，
    // 而协同 pin 目标随时都能打。400u 内才接管，不为一个挂边者横跨半张图。
    int selectHanging = BT_CreateAcquireHangingTarget(400.0);

    int targetSelector = BT_Create(BTN_SELECTOR);
    BT_AddChild(targetSelector, selectHanging);        // v5.18: 挂边者优先击落
    BT_AddChild(targetSelector, coordPinSeq);         // v4.1: 窗口内锁 pin 目标
    BT_AddChild(targetSelector, selectDamager);      // 防风筝：有人打 Tank 追射手
    BT_AddChild(targetSelector, selectCluster);      // v5.0: 开团 → 冲密集区
    BT_AddChild(targetSelector, selectLowHP);
    BT_AddChild(targetSelector, selectDefault);

    // ==========================================
    // v3.2: Terrain-aware attack types
    // ==========================================
    // Narrow corridor: hold chokepoint + melee (survivors can't run past)
    // v5.4.1 FIX: 守点距离 400→120 —— 原 400u 站桩死区：meleeCluster 的 3 个
    // 子分支（协同拳/悬崖拳/开阔冲锋）条件全不满足时，narrowHoldSeq 无条件
    // SUCCESS（400u 内 + LOS）→ Tank 在 120-400u 窄巷区间永久站桩（近战够
    // 不着、岩石/跳扑/走位兜底全被抢——v4.0.2 移过 Charger 同款分支，Tank
    // 漏了）。120u = 引擎近战距离，贴脸守点语义保留，区间外交 rock/bhop/
    // MoveToTarget 兜底。
    int narrowHoldSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsInRange(120.0),
        BT_CreateAction(ACT_HoldChokepoint)
    );

    // ==========================================
    // v3.5: Open terrain — 3-way random strategies
    // ==========================================
    // Strategy roll — fires once every STRATEGY_TOKEN_TTL seconds
    int openStrategyRoll = BT_CreateSequence(2,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateRollStrategy(3)
    );
    // Strategy 0: Rock throw at long range (suppress from distance)
    // v4.1: +TankAct_AimRock —— 投石前把视角对准提前点（移动靶预判）
    int openStrat0_Rock = BT_CreateSequence(7,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateStrategyIs(0),
        BT_CreateCondition(TankCond_RockEligible),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateAction(TankAct_AimRock),      // v4.1: 预判瞄准
        BT_CreateAction(TankAct_TryThrowRock), // v5.26: 确认状态机（真实释放才 arm 冷却）
        BT_CreateAction(ACT_SignalAttack)      // v5.0: 投石压制 = 开团信号（队友跟进）
    );
    // Strategy 1: Direct charge — rush up and punch (instakill threat)
    // v4.0.5: 已移入下方近战簇（meleeCluster）—— 与 ledge punch 共享
    // Cooldown(1.5) 对齐引擎 z_tank_attack_interval=1.5
    // v5.6: 700 → 150 —— 原版 150-700u 段对空气挥拳：引擎近战射程只有
    // ~110-150u，幽灵拳每次还启动 1.5s 近战冷却（贴脸第一拳被延迟）。
    int openStrat1_Charge = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateStrategyIs(1),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsInRange(150.0),
        BT_CreateAction(ACT_Attack)            // melee punch
    );
    // Strategy 2: Bhop chase — falls through to standard bhop below

    // Ledge: punch survivors off — charge at them near the edge
    // v5.6: 300 → 150（同幽灵拳修复）
    int ledgePunchSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_IsNearLedge),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsInRange(150.0),
        BT_CreateAction(ACT_Attack)            // melee toward ledge
    );

    // ==========================================
    int punchJumpSeq = BT_CreateSequence(2,
        BT_CreateCondition(TankCond_PunchJumpReady),
        BT_CreateAction(TankAct_PunchJump)
    );
    int executeSeq = BT_CreateSequence(2,
        BT_CreateCondition(TankCond_IncappedNearby),
        BT_CreateAction(TankAct_ExecuteIncapped)
    );
    // v5.6: 兜底路径补 HasTargetLOS —— 原版只有 openStrat0_Rock 有 LOS 门，
    // 兜底 rockSeq 漏掉：目标在墙后/建筑内 >500u 时每 5s 对墙按 IN_ATTACK2，
    // 石头砸墙 + 占用引擎 6s 扔石冷却（真需要远程压制时无石可用）。
    int rockSeq = BT_CreateSequence(5,
        BT_CreateCondition(TankCond_RockEligible),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateAction(TankAct_AimRock),      // v4.1: 预判瞄准（fallback 路径同样接管）
        BT_CreateAction(TankAct_TryThrowRock), // v5.26: 确认状态机
        BT_CreateAction(ACT_SignalAttack)      // v5.0: 投石开团信号
    );
    int bhopSeq = BT_CreateSequence(2,
        BT_CreateCondition(TankCond_BhopEligible),
        BT_CreateAction(TankAct_Bhop)
    );

    // ==========================================
    // v4.0.5: 近战攻击簇 —— Cooldown(1.5) 对齐引擎 z_tank_attack_interval=1.5
    // 引擎爪击间隔 1.5s，冷却期内按住 IN_ATTACK = 无效挥拳（与 Smoker/Charger
    // 共享 IN_ATTACK 的同款模式）。簇内 selector：coord punch / prop kill /
    // ledge punch / open charge —— 全部共享同一冷却包装（双冷却节点轮流
    // 触发 = 没锁，铁律）。
    // v4.1: 新增最高优先级分支 —— 协同窗口拳杀被 pin 者
    // （地形秒杀 propKillSeq 已按用户拍板整体移除，保持原版不打车不打罐）
    int coordPunchSeq = BT_CreateSequence(2,
        BT_CreateCondition(TankCond_CoordPunchReady),
        BT_CreateAction(TankAct_CoordPunch)
    );

    // v5.6: 窄巷贴脸拳 —— 原版 meleeSelector 三子分支（协同/悬崖/开阔）在
    // 窄巷全 FAIL → BT 近战在窄巷永不发（v5.4.1 只修了 120-400u 死区，
    // ≤120u 窄巷仍无 BT 输出，贴脸站桩全靠引擎帧兜底）
    int narrowMeleeSeq = BT_CreateSequence(3,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsInRange(150.0),
        BT_CreateAction(ACT_Attack)            // melee punch in corridor
    );

    int meleeSelector = BT_Create(BTN_SELECTOR);
    BT_AddChild(meleeSelector, coordPunchSeq);        // 1a. v4.1 协同窗口 → 拳杀被 pin 者
    BT_AddChild(meleeSelector, ledgePunchSeq);        // 1b. ledge → punch off cliff
    BT_AddChild(meleeSelector, openStrat1_Charge);    // 1c. open → charge punch
    BT_AddChild(meleeSelector, narrowMeleeSeq);       // 1d. v5.6: 窄巷贴脸拳
    int meleeCluster = BT_CreateCooldown(1.5, meleeSelector);

    // ==========================================
    // v4.0.5: 岩石簇 —— Cooldown(5.0) 对齐引擎 z_tank_throw_interval=5
    // （2026-08-03 空服 rcon 实测）。冷却期内按 IN_ATTACK2 = 引擎不理的
    // 无效按键。openStrat0 与 rockSeq 必须共享同一 Cooldown —— 两个独立
    // 冷却节点会各自计时、轮流触发，等于没锁。
    int rockSelector = BT_Create(BTN_SELECTOR);
    BT_AddChild(rockSelector, openStrat0_Rock);       // 1a. open strat0 → rock throw
    BT_AddChild(rockSelector, rockSeq);               // 1b. ← standard rock throw (fallback)
    int rockCluster = BT_CreateCooldown(5.0, rockSelector);

    // Attack selector — terrain strategies fail when disabled/unknown
    // → falls through to standard attack types from v2.2.
    int attackSelector = BT_Create(BTN_SELECTOR);
    BT_AddChild(attackSelector, meleeCluster);        // 1. v4.0.5 近战簇（Cooldown 1.5，对齐引擎爪击）
    BT_AddChild(attackSelector, executeSeq);          // 2. ← execute incapped —— 紧贴簇后：
                                                      //    近战冷却期恰是处决窗口（引擎补刀不慢）
    BT_AddChild(attackSelector, narrowHoldSeq);       // 3. v3.2: narrow → hold chokepoint
    BT_AddChild(attackSelector, openStrategyRoll);    // 4a. v3.5: open → roll token
    BT_AddChild(attackSelector, rockCluster);         // 4b. v4.0.5 岩石簇（Cooldown 5.0，对齐 throw_interval）
    // 4c: open strat2 → falls through to bhop below
    // ↓ FALLBACK: standard strategies (battle-tested since v2.2)
    BT_AddChild(attackSelector, punchJumpSeq);        // 5. ← punch-jump combo（自带 2s 冷却 + cvar 门控）
    BT_AddChild(attackSelector, bhopSeq);             // 6. ← bhop chase（v4.0.5 自带冷却）
    // ==========================================
    // v5.1: 站桩修复 —— 原树无"走向目标"兜底：melee/rock/bhop 全冷却或
    // 门控不满足（近身 <500u 禁跳、>1600u 禁跳、撞墙无侧路、速度 <120）时
    // attackSelector 全 FAIL → 根 SEQUENCE 整树 FAIL → Tank 无任何输出原地
    // 冻结（引擎跳也被 OnPlayerRunCmd 每帧清掉）。加走位兜底（不按 ATTACK，
    // 不重新选人 —— 沿用 targetSelector 刚选好的黑板 target），保证攻击
    // 冷却期持续逼近目标。
    // ==========================================
    BT_AddChild(attackSelector, BT_CreateAction(ACT_MoveToTarget)); // 7. v5.1: ← 冷却期走位逼近

    // ==========================================
    // v5.35: 出生推进（用户："Tank 刷新远一点，但一刷新就要主动贴近队伍"）
    // 生成后 3s 内强制向最近幸存者推进（AcquireClosestTarget + MoveToTarget，
    // MoveToTarget 走 v5.25 远近分流 → 远处 Valve 导航绕障碍逼近，不直线撞墙）。
    // 3s 后条件 FAIL → 正常走 targetSelector/attackSelector 战术。
    // ==========================================
    int spawnPushSeq = BT_CreateSequence(3,
        BT_CreateCondition(TankCond_SpawnPush),     // 出生 3s 内
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(ACT_MoveToTarget)            // RUNNING：持续推进
    );

    // ==========================================
    // Root — P0: Sequence(spawnPush, ...) 3s 后 FAIL 全树冻结，已改 Selector
    // ==========================================
    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, spawnPushSeq);
    int normalSeq = BT_Create(BTN_SEQUENCE);
    BT_AddChild(normalSeq, targetSelector);
    BT_AddChild(normalSeq, attackSelector);
    BT_AddChild(root, normalSeq);
    return root;
}

// v5.35: 出生推进条件 —— 距生成时刻 < 3s（生成时刻由 AI_HardSI.sp
// Event_PlayerSpawn 的 Tank case 写入黑板 _tank_spawn_at）
BT_Status TankCond_SpawnPush(int client) {
    float spawnAt = BB_GetFloat(client, "_tank_spawn_at", 0.0);
    if (spawnAt <= 0.0) return BT_FAILURE;
    return (GetGameTime() - spawnAt < 3.0) ? BT_SUCCESS : BT_FAILURE;
}

public Tank_OnModuleStart() {
    // --- Tank ConVars (v3.0 fix: re-create cvars lost during BT refactor) ---
    // v6.8.2: OnMapStart 重入守卫 — CreateConVar 二次创建抛 "already exists"
    if (FindConVar("ai_tank_bhop") == null) CreateConVar("ai_tank_bhop",            "1",   "Enable bhop facsimile on AI tanks", FCVAR_NONE);
    if (FindConVar("ai_tank_rock") == null) CreateConVar("ai_tank_rock",            "1",   "Enable rock throws on AI tanks (0=disable)", FCVAR_NONE);
    // v4.0.5: min_dist 200→400→500 —— 玩家反馈"连跳追击过于困难"。
    // 设计定位：bhop 是远程拉近距离的工具（>min_dist 才跳），进入威胁圈
    // 必须落地走过去 —— 200u 等于贴脸才停，一路蹦到脸上，失去游戏性。
    // 400 仍偏低（玩家反馈后上调），500u = 更早收跳，玩家有完整反应空间。
    // 体验参数可调（sourcemod.cfg 覆盖）。配合 min_dist 收紧，近身时
    // 原版 AI 的移动被每帧清跳约束 → 稳步走进去出拳。
    if (FindConVar("ai_tank_bhop_min_dist") == null) CreateConVar("ai_tank_bhop_min_dist",   "500", "Min distance to survivor for bhop (below this: walk, no bhop)", FCVAR_NONE);
    if (FindConVar("ai_tank_bhop_max_dist") == null) CreateConVar("ai_tank_bhop_max_dist",   "800", "Max distance to survivor for bhop", FCVAR_NONE);
    if (FindConVar("ai_tank_bhop_wall_dist") == null) CreateConVar("ai_tank_bhop_wall_dist",  "200", "Trace distance for wall/obstacle check", FCVAR_NONE);
    if (FindConVar("ai_tank_bhop_adaptive") == null) CreateConVar("ai_tank_bhop_adaptive",   "1",   "Adaptive bhop cooldown (0=fixed 0.6s)", FCVAR_NONE);
    if (FindConVar("ai_tank_bhop_momentum") == null) CreateConVar("ai_tank_bhop_momentum",   "1",   "Momentum building: consecutive bhops get stronger", FCVAR_NONE);
    if (FindConVar("ai_tank_bhop_evade") == null) CreateConVar("ai_tank_bhop_evade",      "1",   "Obstacle evasion: sideways bhop around walls", FCVAR_NONE);
    if (FindConVar("ai_tank_punch_jump") == null) CreateConVar("ai_tank_punch_jump",      "0",   "Punch-jump combo at close range", FCVAR_NONE);
    if (FindConVar("ai_tank_rage_multiplier") == null) CreateConVar("ai_tank_rage_multiplier", "1.5", "On-fire multiplier for cooldown + push force", FCVAR_NONE);
    if (FindConVar("ai_tank_punch_instakill") == null) CreateConVar("ai_tank_punch_instakill", "1",   "Instakill: melee punch incaps survivors", FCVAR_NONE);
    if (FindConVar("ai_tank_punch_damage") == null) CreateConVar("ai_tank_punch_damage",    "150", "Damage per punch when instakill enabled (>100=incap)", FCVAR_NONE);
    if (FindConVar("ai_tank_aggro_bhop") == null) CreateConVar("ai_tank_aggro_bhop",      "1",   "Aggressive bhop: Tank relentlessly bhops toward target", FCVAR_NONE);

    // --- v4.1: Tank 高级玩法 cvar（地形秒杀 3 个已按用户拍板移除）---
    if (FindConVar("ai_tank_coord") == null) CreateConVar("ai_tank_coord",              "1",   "Tank consumes coordination window (rush pinned survivor)", FCVAR_NONE);
    if (FindConVar("ai_tank_rock_predict") == null) CreateConVar("ai_tank_rock_predict",       "1",   "Predictive rock aiming (lead) + OnRelease correction", FCVAR_NONE);
    if (FindConVar("ai_tank_rock_lead_max") == null) CreateConVar("ai_tank_rock_lead_max",      "400", "Max lead distance (u) for rock prediction", FCVAR_NONE);
    if (FindConVar("ai_tank_rock_pitch_offset") == null) CreateConVar("ai_tank_rock_pitch_offset",  "0",   "Vertical aim compensation for rock arc (empirical)", FCVAR_NONE);
    if (FindConVar("ai_tank_damager_max_dist") == null) CreateConVar("ai_tank_damager_max_dist",   "800", "Damager-preference chase distance gate (kiter immunity)", FCVAR_NONE);

    // v3.4: cache handles to avoid per-tick FindConVar in BT callbacks
    g_hCvarTankBhop_cached = FindConVar("ai_tank_bhop");
    g_hCvarTankRock_cached = FindConVar("ai_tank_rock");
    g_hCvarTankBhopMinDist_cached = FindConVar("ai_tank_bhop_min_dist");
    g_hCvarTankBhopMaxDist_cached = FindConVar("ai_tank_bhop_max_dist");
    g_hCvarTankBhopMomentum_cached = FindConVar("ai_tank_bhop_momentum");
    // v4.0.5: 审计补全 cache（此前只 CreateConVar 不 FindConVar = 读取必然 null）
    g_hCvarTankBhopAdaptive_cached = FindConVar("ai_tank_bhop_adaptive");
    g_hCvarTankBhopWall_cached = FindConVar("ai_tank_bhop_wall_dist");
    g_hCvarTankBhopEvade_cached = FindConVar("ai_tank_bhop_evade");
    g_hCvarTankPunchJump_cached = FindConVar("ai_tank_punch_jump");
    g_hCvarTankRage_cached = FindConVar("ai_tank_rage_multiplier");
    g_hCvarTankInstakill_cached = FindConVar("ai_tank_punch_instakill");
    g_hCvarTankPunchDamage_cached = FindConVar("ai_tank_punch_damage");
    // v4.1: 四件套 cache（地形秒杀 3 个已移除）
    g_hCvarTankCoord_cached = FindConVar("ai_tank_coord");
    g_hCvarTankRockPredict_cached = FindConVar("ai_tank_rock_predict");
    g_hCvarTankRockLeadMax_cached = FindConVar("ai_tank_rock_lead_max");
    g_hCvarTankRockPitch_cached = FindConVar("ai_tank_rock_pitch_offset");
    g_hCvarTankDamagerMaxDist_cached = FindConVar("ai_tank_damager_max_dist");

    static bool s_bTankHooked = false;
    if (!s_bTankHooked) { HookEvent("player_hurt", Tank_OnPlayerHurt, EventHookMode_Pre); s_bTankHooked = true; }
}

public Action:Tank_OnPlayerHurt(Handle:event, const String:name[], bool:dontBroadcast) {
    int victim = GetClientOfUserId(GetEventInt(event, "userid"));
    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    if (!IsBotTank(attacker) || !IsSurvivor(victim)) return Plugin_Continue;
    if (IsIncapacitated(victim)) return Plugin_Continue;
    // v4.0.5 FIX: instakill/damage cvar 创建了但从未检查 —— hook 无条件秒杀
    if (g_hCvarTankInstakill_cached == null || !GetConVarBool(g_hCvarTankInstakill_cached)) return Plugin_Continue;
    int punchDamage = (g_hCvarTankPunchDamage_cached != null) ? GetConVarInt(g_hCvarTankPunchDamage_cached) : 150;
    int damagetype = GetEventInt(event, "type");
    if (!(damagetype & DMG_SLASH) && !(damagetype & DMG_CLUB)) return Plugin_Continue;
    // v5.1: 递归防护 —— TakeDamage 注入后再次触发 player_hurt（同 damage 类型）
    // 会重新进入本 hook → 无限递归栈溢出。0.2s 窗口内同一受害者跳过。
    float now = GetGameTime();
    if (g_fTankLastInstakillAt[victim] > 0.0 && now - g_fTankLastInstakillAt[victim] < 0.2) return Plugin_Continue;
    g_fTankLastInstakillAt[victim] = now;
    int hp = GetClientHealth(victim);
    // max(hp+50, punchDamage)：hp+50 保证一般血量一拳打进倒地，
    // punchDamage 兜底（残血时 hp+50 可能 <100 不够击倒）
    float finalDamage = (float(hp) + 50.0 > float(punchDamage)) ? float(hp) + 50.0 : float(punchDamage);
    SDKHooks_TakeDamage(victim, attacker, attacker, finalDamage, DMG_SLASH);
    return Plugin_Continue;
}

// ============================================================================
// v4.1: 飞石释放校正层（L4D_TankRock_OnRelease）
// ============================================================================
// left4dhooks GlobalForward（l4dd_setup.sp 注册），插件声明 public 函数即
// 自动接收。返回 Plugin_Changed + 改写 vecVel → detour MRES_ChangedHandled
// 写回引擎（l4dd_forwards.sp:2169-2187），石头按新速度发射。
// 作用：BT 瞄准（AimRock）与引擎实际释放间隔 ~1s（投石动画），期间 vanilla
// AI 可能漂视角；且引擎 vVel 含 Tank 自身速度（bhop 时 +400~500u/s）。
// 本层用释放瞬间的 vecPos / 真实 |vecVel| 重算提前量 —— 两层误差自修正。
// 附带收益：原版 AI 的 bot 投石也被校正（同门控，不区分 BT 是否在场）。
 public Action:L4D_TankRock_OnRelease(int tank, int rock, float vecPos[3], float vecAng[3], float vecVel[3], float vecRot[3]) {
    if (tank < 1 || !IsBotTank(tank)) return Plugin_Continue;
    // v5.26: 真实投石确认标记 —— 引擎真实释放石头的事件（按 IN_ATTACK2 ≠
    // 投出，动画 ~1s 期间按键可能被引擎吞/对墙白按）。TankAct_TryThrowRock
    // 消费本标记：收到才 CONFIRMED（arm rockCluster Cooldown(5.0)）。
    BB_SetFloat(tank, "_tank_rock_confirmed", GetGameTime());
    if (g_hCvarTankRockPredict_cached == null || !GetConVarBool(g_hCvarTankRockPredict_cached)) return Plugin_Continue;
    int target = BB_GetInt(tank, "target", -1);
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) return Plugin_Continue;
    float tPos[3], tVel[3], lead[3], dir[3], ang[3];
    // v5.30: 同 AimRock —— 瞄准眼睛高度（原脚底 → 低抛命中差）
    GetClientEyePosition(target, tPos);
    GetEntPropVector(target, Prop_Data, "m_vecVelocity", tVel);
    float speed = GetVectorLength(vecVel);
    if (speed < 1.0) return Plugin_Continue;
    // 飞行时间用释放瞬间的真实速度（含自身速度 + z+80），自修正 AimRock 的
    // dist/800 近似（bhop 时 Tank 自身速度显著抬升石头初速）
    float t = GetVectorDistance(vecPos, tPos) / speed;
    lead[0] = tVel[0] * t;
    lead[1] = tVel[1] * t;
    lead[2] = 0.0;
    float maxLead = (g_hCvarTankRockLeadMax_cached != null) ? GetConVarFloat(g_hCvarTankRockLeadMax_cached) : 400.0;
    float leadLen = GetVectorLength(lead);
    if (leadLen > maxLead) ScaleVector(lead, maxLead / leadLen);
    AddVectors(tPos, lead, tPos);
    MakeVectorFromPoints(vecPos, tPos, dir);
    GetVectorAngles(dir, ang);
    // v6.8.1: 高抛同步——AimRock存的高抬头在释放校正层重放，保持高弧
    float highAdd = BB_GetFloat(tank, "_tank_rock_high_pitch", 0.0);
    if (highAdd != 0.0) ang[0] += highAdd;
    if (g_hCvarTankRockPitch_cached != null) ang[0] += GetConVarFloat(g_hCvarTankRockPitch_cached);
    GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(dir, dir);
    ScaleVector(dir, speed);          // 保持引擎速度不变，只改方向
    vecVel[0] = dir[0];
    vecVel[1] = dir[1];
    vecVel[2] = dir[2];
    BB_SetFloat(tank, "_tank_rock_high_pitch", 0.0); // 消费后清零
    return Plugin_Changed;
}
