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
//   - 地形秒杀：propKillSeq 打汽车（prop_car*，注入 500 拳伤确定性引爆，
//     爆炸半径内 350u 生还者被秒杀；用户拍板只打汽车不打爆炸物 ——
//     Tank 拳不作用于罐类，见 Tank_IsKillProp 注释）
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
// v4.1: 四件套 cvar（协同 / 飞石预判 / 地形秒杀 / 追击门控）
ConVar g_hCvarTankCoord_cached = null;
ConVar g_hCvarTankRockPredict_cached = null;
ConVar g_hCvarTankRockLeadMax_cached = null;
ConVar g_hCvarTankRockPitch_cached = null;
ConVar g_hCvarTankPropKill_cached = null;
ConVar g_hCvarTankPropPunchDamage_cached = null;
ConVar g_hCvarTankPropBlastRadius_cached = null;
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
    for (int s = 1; s <= MaxClients; s++) {
        if (!IsSurvivor(s) || !IsPlayerAlive(s) || !IsIncapacitated(s)) continue;
        float sPos[3]; GetClientAbsOrigin(s, sPos);
        if (GetVectorDistance(tPos, sPos) < 120.0 && GetRandomFloat(0.0, 1.0) < 0.40) {
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
    if (!GetEntProp(client, Prop_Send, "m_hasVisibleThreats")) return BT_FAILURE;

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

    // v4.0.5 FIX: 恢复前方墙检测（v3.2 重构丢失 ai_tank_bhop_wall_dist/evade）
    int wallDist = (g_hCvarTankBhopWall_cached != null) ? GetConVarInt(g_hCvarTankBhopWall_cached) : 200;
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
            GetClientAbsOrigin(target, tPos);
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
            BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        }
    }
    return BT_SUCCESS;
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
    return (GetEntProp(client, Prop_Send, "m_hasVisibleThreats") > 0) ? BT_SUCCESS : BT_FAILURE;
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

// ============================================================================
// v4.1: 地形秒杀 —— 打汽车击杀附近幸存者（用户拍板：只打汽车，不打爆炸物）
// ============================================================================
// 引擎机制（已核验）：prop_car* 损毁即爆炸（vanilla），爆炸范围伤害正常
// 作用于附近生还者，归属跟 inflictor。
// 2026-08-03 用户修正：Tank 拳击只作用于汽车/树干等物理实体，不作用于
// 爆炸物（丙烷/汽油/氧气罐等）—— 罐类爆炸链路（propdata onbreak:
// explode_fire）是 l4d2_shop 在"生成"场景验证的，对 Tank 拳击场景不可靠，
// 属"不确定"。按用户原则（不确定宁愿用原版）剔除 4 种爆炸罐 + 模型匹配，
// 只保留 prop_car*（Tank 拳能打汽车 = 用户确认的 vanilla 行为）。
// 注入 SDKHooks_TakeDamage 保证确定性破坏 + 归属（inflictor=tank）。
stock bool Tank_IsKillProp(int ent) {
    char cls[64];
    GetEntityClassname(ent, cls, sizeof(cls));
    if (StrContains(cls, "prop_car", false) != 0) return false;
    // prop_car / prop_car_alarm；prop_car_glass 只会碎不会爆
    if (StrEqual(cls, "prop_car_glass")) return false;
    return HasEntProp(ent, Prop_Data, "m_iHealth") && GetEntProp(ent, Prop_Data, "m_iHealth") > 0;
}

// LOS：eye→prop 射线，首个命中必须是该 prop（TerrainTraceFilter 只排除
// 玩家实体，prop 按世界实体命中 → 中间隔着别的物体时 TR_GetEntityIndex
// 不是该 prop，判失败）
stock bool Tank_PropLOS(int client, int prop, const float propPos[3]) {
    float eye[3];
    GetClientEyePosition(client, eye);
    TR_TraceRayFilter(eye, propPos, MASK_PLAYERSOLID, RayType_EndPoint, TerrainTraceFilter, client);
    return TR_DidHit() && TR_GetEntityIndex() == prop;
}

// 找可打爆 prop：生还者须在爆炸半径内（躲车后/贴罐），Tank 须在拳击范围内
stock int Tank_FindKillProp(int client, int targetSurvivor) {
    if (targetSurvivor < 1 || !IsSurvivor(targetSurvivor) || !IsPlayerAlive(targetSurvivor)) return -1;
    float tankPos[3], survPos[3];
    GetClientAbsOrigin(client, tankPos);
    GetClientAbsOrigin(targetSurvivor, survPos);
    float blast = (g_hCvarTankPropBlastRadius_cached != null) ? GetConVarFloat(g_hCvarTankPropBlastRadius_cached) : 350.0;
    float punchRange = 250.0;
    // 早退：Tank 距目标超 700u 时（拳距 250 + 爆距 350 + 余量）不可能同时满足
    if (GetVectorDistance(tankPos, survPos) > punchRange + blast + 100.0) return -1;
    for (int e = MaxClients + 1; e < GetMaxEntities(); e++) {
        if (!IsValidEntity(e) || !Tank_IsKillProp(e)) continue;
        float propPos[3];
        GetEntPropVector(e, Prop_Data, "m_vecAbsOrigin", propPos);
        if (GetVectorDistance(survPos, propPos) > blast) continue;      // 生还者不在爆圈内
        if (GetVectorDistance(tankPos, propPos) > punchRange) continue; // Tank 打不到
        if (!Tank_PropLOS(client, e, propPos)) continue;
        return e;
    }
    return -1;
}

BT_Status TankCond_PropKill(int client) {
    if (g_hCvarTankPropKill_cached == null || !GetConVarBool(g_hCvarTankPropKill_cached)) return BT_FAILURE;
    // 0.5s 节流（镜像 terrain classify 节流模式）：edict 扫描 ≤2048 实体，
    // 只在节流边界重扫；缓存实体每 tick 重验存活（中途被打爆自动弃置）
    float now = GetGameTime();
    if (now >= BB_GetFloat(client, "_tank_prop_next", 0.0)) {
        BB_SetFloat(client, "_tank_prop_next", now + 0.5);
        int target = BB_GetInt(client, "target", -1);
        if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) {
            float tPos[3];
            GetClientAbsOrigin(client, tPos);
            target = GetClosestSurvivor(tPos);
        }
        BB_SetInt(client, "_tank_prop_ent", Tank_FindKillProp(client, target));
    }
    int prop = BB_GetInt(client, "_tank_prop_ent", -1);
    if (prop <= MaxClients || !IsValidEntity(prop)) return BT_FAILURE;
    if (!HasEntProp(prop, Prop_Data, "m_iHealth") || GetEntProp(prop, Prop_Data, "m_iHealth") <= 0) return BT_FAILURE;
    return BT_SUCCESS;
}

BT_Status TankAct_PropKill(int client) {
    int prop = BB_GetInt(client, "_tank_prop_ent", -1);
    if (prop <= MaxClients || !IsValidEntity(prop)) return BT_FAILURE;
    float propPos[3], tPos[3], dir[3], ang[3];
    GetEntPropVector(prop, Prop_Data, "m_vecAbsOrigin", propPos);
    GetClientAbsOrigin(client, tPos);
    MakeVectorFromPoints(tPos, propPos, dir);
    GetVectorAngles(dir, ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_ATTACK);      // 拳动画（观感）
    BT_RemoveButton(client, IN_ATTACK2);
    // 确定性击杀：注入伤害（默认 500，2-3 拳内爆）。
    // damagePosition 必须传 prop 原点 —— 否则爆炸衰减从世界原点算（l4d2_shop 教训）
    if (HasEntProp(prop, Prop_Data, "m_iHealth") && GetEntProp(prop, Prop_Data, "m_iHealth") > 0) {
        int dmg = (g_hCvarTankPropPunchDamage_cached != null) ? GetConVarInt(g_hCvarTankPropPunchDamage_cached) : 500;
        SDKHooks_TakeDamage(prop, client, client, float(dmg), DMG_CLUB, -1, NULL_VECTOR, propPos, false);
    }
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

    int targetSelector = BT_Create(BTN_SELECTOR);
    BT_AddChild(targetSelector, coordPinSeq);         // v4.1: 窗口内锁 pin 目标
    BT_AddChild(targetSelector, selectDamager);
    BT_AddChild(targetSelector, selectLowHP);
    BT_AddChild(targetSelector, selectDefault);

    // ==========================================
    // v3.2: Terrain-aware attack types
    // ==========================================
    // Narrow corridor: hold chokepoint + melee (survivors can't run past)
    int narrowHoldSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(400.0),
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
    int openStrat0_Rock = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateStrategyIs(0),
        BT_CreateCondition(TankCond_RockEligible),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateAction(TankAct_AimRock),      // v4.1: 预判瞄准
        BT_CreateAction(ACT_Attack2)           // throw rock
    );
    // Strategy 1: Direct charge — rush up and punch (instakill threat)
    // v4.0.5: 已移入下方近战簇（meleeCluster）—— 与 ledge punch 共享
    // Cooldown(1.5) 对齐引擎 z_tank_attack_interval=1.5
    int openStrat1_Charge = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateStrategyIs(1),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(700.0),
        BT_CreateAction(ACT_Attack)            // melee punch
    );
    // Strategy 2: Bhop chase — falls through to standard bhop below

    // Ledge: punch survivors off — charge at them near the edge
    int ledgePunchSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_IsNearLedge),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(300.0),
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
    int rockSeq = BT_CreateSequence(3,
        BT_CreateCondition(TankCond_RockEligible),
        BT_CreateAction(TankAct_AimRock),      // v4.1: 预判瞄准（fallback 路径同样接管）
        BT_CreateAction(ACT_Attack2)
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
    // v4.1: 新增最高优先级两分支 —— 协同窗口拳杀被 pin 者 + 地形秒杀
    int coordPunchSeq = BT_CreateSequence(2,
        BT_CreateCondition(TankCond_CoordPunchReady),
        BT_CreateAction(TankAct_CoordPunch)
    );
    int propKillSeq = BT_CreateSequence(2,
        BT_CreateCondition(TankCond_PropKill),
        BT_CreateAction(TankAct_PropKill)
    );

    int meleeSelector = BT_Create(BTN_SELECTOR);
    BT_AddChild(meleeSelector, coordPunchSeq);        // 1a. v4.1 协同窗口 → 拳杀被 pin 者
    BT_AddChild(meleeSelector, propKillSeq);          // 1b. v4.1 打汽车（地形秒杀）
    BT_AddChild(meleeSelector, ledgePunchSeq);        // 1c. ledge → punch off cliff
    BT_AddChild(meleeSelector, openStrat1_Charge);    // 1d. open → charge punch
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
    // Root
    // ==========================================
    int root = BT_CreateSequence(2, targetSelector, attackSelector);
    return root;
}

public Tank_OnModuleStart() {
    // --- Tank ConVars (v3.0 fix: re-create cvars lost during BT refactor) ---
    CreateConVar("ai_tank_bhop",            "1",   "Enable bhop facsimile on AI tanks", FCVAR_NONE);
    CreateConVar("ai_tank_rock",            "1",   "Enable rock throws on AI tanks (0=disable)", FCVAR_NONE);
    // v4.0.5: min_dist 200→400→500 —— 玩家反馈"连跳追击过于困难"。
    // 设计定位：bhop 是远程拉近距离的工具（>min_dist 才跳），进入威胁圈
    // 必须落地走过去 —— 200u 等于贴脸才停，一路蹦到脸上，失去游戏性。
    // 400 仍偏低（玩家反馈后上调），500u = 更早收跳，玩家有完整反应空间。
    // 体验参数可调（sourcemod.cfg 覆盖）。配合 min_dist 收紧，近身时
    // 原版 AI 的移动被每帧清跳约束 → 稳步走进去出拳。
    CreateConVar("ai_tank_bhop_min_dist",   "500", "Min distance to survivor for bhop (below this: walk, no bhop)", FCVAR_NONE);
    CreateConVar("ai_tank_bhop_max_dist",   "800", "Max distance to survivor for bhop", FCVAR_NONE);
    CreateConVar("ai_tank_bhop_wall_dist",  "200", "Trace distance for wall/obstacle check", FCVAR_NONE);
    CreateConVar("ai_tank_bhop_adaptive",   "1",   "Adaptive bhop cooldown (0=fixed 0.6s)", FCVAR_NONE);
    CreateConVar("ai_tank_bhop_momentum",   "1",   "Momentum building: consecutive bhops get stronger", FCVAR_NONE);
    CreateConVar("ai_tank_bhop_evade",      "1",   "Obstacle evasion: sideways bhop around walls", FCVAR_NONE);
    CreateConVar("ai_tank_punch_jump",      "0",   "Punch-jump combo at close range", FCVAR_NONE);
    CreateConVar("ai_tank_rage_multiplier", "1.5", "On-fire multiplier for cooldown + push force", FCVAR_NONE);
    CreateConVar("ai_tank_punch_instakill", "1",   "Instakill: melee punch incaps survivors", FCVAR_NONE);
    CreateConVar("ai_tank_punch_damage",    "150", "Damage per punch when instakill enabled (>100=incap)", FCVAR_NONE);
    CreateConVar("ai_tank_aggro_bhop",      "1",   "Aggressive bhop: Tank relentlessly bhops toward target", FCVAR_NONE);

    // --- v4.1: Tank 高级玩法四件套 cvar ---
    CreateConVar("ai_tank_coord",              "1",   "Tank consumes coordination window (rush pinned survivor)", FCVAR_NONE);
    CreateConVar("ai_tank_rock_predict",       "1",   "Predictive rock aiming (lead) + OnRelease correction", FCVAR_NONE);
    CreateConVar("ai_tank_rock_lead_max",      "400", "Max lead distance (u) for rock prediction", FCVAR_NONE);
    CreateConVar("ai_tank_rock_pitch_offset",  "0",   "Vertical aim compensation for rock arc (empirical)", FCVAR_NONE);
    CreateConVar("ai_tank_prop_kill",          "1",   "Tank smashes cars (prop_car*) to kill nearby survivors", FCVAR_NONE);
    CreateConVar("ai_tank_prop_punch_damage",  "500", "Damage injected per prop punch", FCVAR_NONE);
    CreateConVar("ai_tank_prop_blast_radius",  "350", "Survivor must be within this radius of the prop", FCVAR_NONE);
    CreateConVar("ai_tank_damager_max_dist",   "800", "Damager-preference chase distance gate (kiter immunity)", FCVAR_NONE);

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
    // v4.1: 四件套 cache
    g_hCvarTankCoord_cached = FindConVar("ai_tank_coord");
    g_hCvarTankRockPredict_cached = FindConVar("ai_tank_rock_predict");
    g_hCvarTankRockLeadMax_cached = FindConVar("ai_tank_rock_lead_max");
    g_hCvarTankRockPitch_cached = FindConVar("ai_tank_rock_pitch_offset");
    g_hCvarTankPropKill_cached = FindConVar("ai_tank_prop_kill");
    g_hCvarTankPropPunchDamage_cached = FindConVar("ai_tank_prop_punch_damage");
    g_hCvarTankPropBlastRadius_cached = FindConVar("ai_tank_prop_blast_radius");
    g_hCvarTankDamagerMaxDist_cached = FindConVar("ai_tank_damager_max_dist");

    HookEvent("player_hurt", Tank_OnPlayerHurt, EventHookMode_Pre);
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
    if (g_hCvarTankRockPredict_cached == null || !GetConVarBool(g_hCvarTankRockPredict_cached)) return Plugin_Continue;
    int target = BB_GetInt(tank, "target", -1);
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) return Plugin_Continue;
    float tPos[3], tVel[3], lead[3], dir[3];
    GetClientAbsOrigin(target, tPos);
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
    NormalizeVector(dir, dir);
    ScaleVector(dir, speed);          // 保持引擎速度不变，只改方向
    vecVel[0] = dir[0];
    vecVel[1] = dir[1];
    vecVel[2] = dir[2];
    return Plugin_Changed;
}
