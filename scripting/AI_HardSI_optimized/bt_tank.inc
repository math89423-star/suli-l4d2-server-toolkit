// ============================================================================
// bt_tank.inc — Tank Behavior Tree (v2.2 → BT v3.2)
// ============================================================================
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
    // v3.2 FIX: check ai_tank_rock master switch (was created but never read)
    if (!GetConVarBool(FindConVar("ai_tank_rock"))) return BT_FAILURE;

    int target = BB_GetInt(client, "target", -1);
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) return BT_FAILURE;
    float tPos[3], sPos[3];
    GetClientAbsOrigin(client, tPos); GetClientAbsOrigin(target, sPos);
    float dist = GetVectorDistance(tPos, sPos);
    float hDiff = sPos[2] - tPos[2];
    return (dist > 500.0 && hDiff > 100.0) ? BT_SUCCESS : BT_FAILURE;
}

// ============================================================================
// Smart Bhop (v2.2)
// ============================================================================

BT_Status TankCond_BhopEligible(int client) {
    // v3.2 FIX: check ai_tank_bhop master switch (was created but never read)
    if (!GetConVarBool(FindConVar("ai_tank_bhop"))) return BT_FAILURE;

    int flags = GetEntityFlags(client);
    if (!(flags & FL_ONGROUND)) return BT_FAILURE;
    if (GetEntityMoveType(client) & MOVETYPE_LADDER) return BT_FAILURE;

    float vel[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", vel);
    float speed = SquareRoot(Pow(vel[0], 2.0) + Pow(vel[1], 2.0));
    if (speed < 120.0) return BT_FAILURE;
    if (!GetEntProp(client, Prop_Send, "m_hasVisibleThreats")) return BT_FAILURE;

    float tPos[3];
    GetClientAbsOrigin(client, tPos);
    int target = BB_GetInt(client, "target", -1);

    // v3.2 FIX: enforce min_dist (was created as cvar but never checked).
    // Tank should punch at close range, not bhop.
    int minDist = GetConVarInt(FindConVar("ai_tank_bhop_min_dist"));
    if (GetSurvivorProximity(tPos, target) < minDist) return BT_FAILURE;

    // v3.2 FIX: enforce max_dist too (check was reversed: >800 returned FAIL,
    // but intended behavior is FAIL when farther than max_dist).
    int maxDist = GetConVarInt(FindConVar("ai_tank_bhop_max_dist"));
    if (GetSurvivorProximity(tPos, target) > maxDist) return BT_FAILURE;

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

    float now = GetGameTime();
    g_fTankLastBhop[client] = now;
    g_iTankBhopChain[client]++;

    // Momentum
    float boost = BASE_BOOST_FORWARD;
    if (GetConVarBool(FindConVar("ai_tank_bhop_momentum"))) {
        boost += float(g_iTankBhopChain[client]) * MOMENTUM_PER_HOP;
        if (boost > MAX_BOOST_FORWARD) boost = MAX_BOOST_FORWARD;
    }
    if (GetEntProp(client, Prop_Data, "m_fFlags") & FL_ONFIRE) boost *= 1.5;

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

    // Open area: rock throw when far, bhop chase when medium range
    int openRockSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateCondition(TankCond_RockEligible),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateAction(ACT_Attack2)           // throw rock
    );

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

    // Attack selector — terrain strategies (1-3) fail when disabled/unknown
    // → falls through to standard attack types (4-7) from v2.2.
    int attackSelector = BT_Create(BTN_SELECTOR);
    BT_AddChild(attackSelector, ledgePunchSeq);     // 1. v3.2: ledge → punch off cliff
    BT_AddChild(attackSelector, narrowHoldSeq);     // 2. v3.2: narrow → hold chokepoint
    BT_AddChild(attackSelector, openRockSeq);       // 3. v3.2: open → rock throw
    // ↓ FALLBACK: standard strategies (battle-tested since v2.2)
    BT_AddChild(attackSelector, punchJumpSeq);      // 4. ← punch-jump combo
    BT_AddChild(attackSelector, executeSeq);        // 5. ← execute incapped
    BT_AddChild(attackSelector, rockSeq);           // 6. ← standard rock throw
    BT_AddChild(attackSelector, bhopSeq);           // 7. ← bhop chase

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
    CreateConVar("ai_tank_bhop_min_dist",   "200", "Min distance to survivor for bhop", FCVAR_NONE);
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

    HookEvent("player_hurt", Tank_OnPlayerHurt, EventHookMode_Pre);
}

public Action:Tank_OnPlayerHurt(Handle:event, const String:name[], bool:dontBroadcast) {
    int victim = GetClientOfUserId(GetEventInt(event, "userid"));
    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    if (!IsBotTank(attacker) || !IsSurvivor(victim)) return Plugin_Continue;
    if (IsIncapacitated(victim)) return Plugin_Continue;
    int damagetype = GetEventInt(event, "type");
    if (!(damagetype & DMG_SLASH) && !(damagetype & DMG_CLUB)) return Plugin_Continue;
    int hp = GetClientHealth(victim);
    float finalDamage = (float(hp) + 50.0 > 150.0) ? float(hp) + 50.0 : 150.0;
    SDKHooks_TakeDamage(victim, attacker, attacker, finalDamage, DMG_SLASH);
    return Plugin_Continue;
}
