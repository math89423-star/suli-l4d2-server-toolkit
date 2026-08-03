// ============================================================================
// bt_tank.inc — Tank Behavior Tree (v2.2 → BT v3.2 → v4.0.5)
// ============================================================================
// v4.0.5 cvar 接入审计（13 个 ai_tank_* 只建不接的修正）：
//   - punch_jump / instakill / punch_damage / rage_multiplier 接入生效
//   - bhop 冷却恢复（g_fTankLastBhop 只写不读 = 无冷却连跳）+ chain 重置
//   - wall trace / evade 恢复（v3.2 重构丢失 ai_tank_bhop_wall_dist/evade）
//   - aggro（ai_tank_aggro_bhop）由 BhopEligible 消费：max_dist 翻倍 + 冷却缩短
//   - 近战攻击簇 Cooldown(1.5) 对齐引擎 z_tank_attack_interval=1.5
// Preserved v2.2 features:
//   - Smart bhop (adaptive cooldown, momentum, obstacle evasion, terrain sense)
//   - Punch-jump combo (50% at <300u)
//   - Instakill (via player_hurt event hook, unchanged)
//   - Smart rock blocking (via L4D2_OnSelectTankAttack, unchanged)
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
    for (int s = 1; s <= MaxClients; s++) {
        if (!IsSurvivor(s) || !IsPlayerAlive(s)) continue;
        if (IsPinned(s)) continue;
        if (IsValidClient(s) && GetClientAimTarget(s) == client) {
            float pos[3];
            GetClientAbsOrigin(s, pos);
            int d = RoundToNearest(GetVectorDistance(tankPos, pos));
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

    int targetSelector = BT_Create(BTN_SELECTOR);
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
    int openStrat0_Rock = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateStrategyIs(0),
        BT_CreateCondition(TankCond_RockEligible),
        BT_CreateCondition(CND_HasLOS),
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
    int rockSeq = BT_CreateSequence(2,
        BT_CreateCondition(TankCond_RockEligible),
        BT_CreateAction(ACT_Attack2)
    );
    int bhopSeq = BT_CreateSequence(2,
        BT_CreateCondition(TankCond_BhopEligible),
        BT_CreateAction(TankAct_Bhop)
    );

    // ==========================================
    // v4.0.5: 近战攻击簇 —— Cooldown(1.5) 对齐引擎 z_tank_attack_interval=1.5
    // 引擎爪击间隔 1.5s，冷却期内按住 IN_ATTACK = 无效挥拳（与 Smoker/Charger
    // 共享 IN_ATTACK 的同款模式）。簇内 selector：ledge punch / open charge。
    int meleeSelector = BT_Create(BTN_SELECTOR);
    BT_AddChild(meleeSelector, ledgePunchSeq);        // 1a. ledge → punch off cliff
    BT_AddChild(meleeSelector, openStrat1_Charge);    // 1b. open → charge punch
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
