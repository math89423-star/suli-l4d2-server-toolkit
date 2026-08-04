// ============================================================================
// bt_common.inc — Shared game-specific BT condition & action nodes
// ============================================================================
// Depends on: bt_core.inc, hardcoop_util.sp (via main plugin), left4dhooks
//
// Parameterized conditions use g_fBTNodeUserParam1[nodeId].

#if defined _bt_common_included
  #endinput
#endif
#define _bt_common_included

// ---------------------------------------------------------------------------
// Factory: parameterized condition creation
// ---------------------------------------------------------------------------

stock int BT_CreateIsInRange(float maxDist) {
    int id = BT_Create(BTN_CONDITION);
    g_hBTFunc[id] = CND_IsInRange;
    g_fBTNodeUserParam1[id] = maxDist;
    return id;
}

stock int BT_CreateIsTargetWatching(float aimThreshold) {
    int id = BT_Create(BTN_CONDITION);
    g_hBTFunc[id] = CND_IsTargetWatching;
    g_fBTNodeUserParam1[id] = aimThreshold;
    return id;
}

stock int BT_CreateHealthBelow(float hpThreshold) {
    int id = BT_Create(BTN_CONDITION);
    g_hBTFunc[id] = CND_HealthBelow;
    g_fBTNodeUserParam1[id] = hpThreshold;
    return id;
}

stock int BT_CreateRandomChance(float probability) {
    int id = BT_Create(BTN_CONDITION);
    g_hBTFunc[id] = CND_RandomChance;
    g_fBTNodeUserParam1[id] = probability;
    return id;
}

// ---------------------------------------------------------------------------
// Simple conditions (no params — use BT_CreateCondition directly)
// ---------------------------------------------------------------------------

// Check if bot has visible threats (m_hasVisibleThreats)
// Survivor aim tracking (moved from old AI_HardSI.sp)
// ---------------------------------------------------------------------------

stock bool IsTargetWatchingAttacker(int attacker, int offsetThreshold) {
    if (GetClientTeam(attacker) == 3 && IsPlayerAlive(attacker)) {
        int target = GetClientAimTarget(attacker);
        if (IsSurvivor(target)) {
            int aimOffset = RoundToNearest(GetPlayerAimOffset(target, attacker));
            return (aimOffset <= offsetThreshold);
        }
    }
    return true;
}

stock float GetPlayerAimOffset(int attacker, int target) {
    float attackerPos[3], targetPos[3], aimVector[3], directVector[3];
    GetClientEyeAngles(attacker, aimVector);
    aimVector[0] = aimVector[2] = 0.0;
    GetAngleVectors(aimVector, aimVector, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(aimVector, aimVector);
    GetClientAbsOrigin(target, targetPos);
    GetClientAbsOrigin(attacker, attackerPos);
    attackerPos[2] = targetPos[2] = 0.0;
    MakeVectorFromPoints(attackerPos, targetPos, directVector);
    NormalizeVector(directVector, directVector);
    return RadToDeg(ArcCosine(GetVectorDotProduct(aimVector, directVector)));
}
BT_Status CND_HasLOS(int client) {
    return (GetEntProp(client, Prop_Send, "m_hasVisibleThreats") > 0) ? BT_SUCCESS : BT_FAILURE;
}

// Check if we're within the coordination attack window
BT_Status CND_IsAttackWindow(int client) {
    return SI_IsAttackWindow() ? BT_SUCCESS : BT_FAILURE;
}

// Check if any survivor is currently boomed (bile-covered)
BT_Status CND_IsBoomerActive(int client) {
    return SI_IsBoomerActive() ? BT_SUCCESS : BT_FAILURE;
}

// Check if bot is on the ground
BT_Status CND_OnGround(int client) {
    return (GetEntityFlags(client) & FL_ONGROUND) ? BT_SUCCESS : BT_FAILURE;
}

// Check if bot is ducking (hunter crouch)
BT_Status CND_IsDucking(int client) {
    return (GetEntityFlags(client) & FL_DUCKING) ? BT_SUCCESS : BT_FAILURE;
}

// Check if bot is currently pinning a survivor (hunter/jockey/charger/smoker)
BT_Status CND_IsPinningSurvivor(int client) {
    return IsPinningASurvivor(client) ? BT_SUCCESS : BT_FAILURE;
}

// Check if there's a pinned survivor that could be combo'd (for spitter/charger)
BT_Status CND_AnySurvivorPinned(int client) {
    for (int i = 1; i <= MaxClients; i++) {
        if (IsSurvivor(i) && IsPlayerAlive(i) && IsPinned(i)) {
            return BT_SUCCESS;
        }
    }
    return BT_FAILURE;
}

// Check if the coordination system is enabled
BT_Status CND_IsCoordEnabled(int client) {
    return (g_hCvarCoordEnable != INVALID_HANDLE && GetConVarBool(g_hCvarCoordEnable))
        ? BT_SUCCESS : BT_FAILURE;
}

// Check if running as aggressive mode (for Tank)
BT_Status CND_IsAggressiveMode(int client) {
    // Read from blackboard; set by Tank module
    return BB_GetBool(client, "tank_aggro", false) ? BT_SUCCESS : BT_FAILURE;
}

// Check if the current target is pinned (avoid dogpiling)
BT_Status CND_IsTargetPinned(int client) {
    int target = GetClientAimTarget(client);
    if (target > 0 && IsSurvivor(target) && IsPinned(target)) {
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}

// ---------------------------------------------------------------------------
// Parameterized conditions
// ---------------------------------------------------------------------------

// Check distance to nearest survivor. Uses UserParam1 as max distance.
BT_Status CND_IsInRange(int client) {
    int nodeId = g_iBTCurrentTickNode;
    float maxDist = g_fBTNodeUserParam1[nodeId];
    float pos[3];
    GetClientAbsOrigin(client, pos);
    int dist = GetSurvivorProximity(pos);
    return (dist > 0 && float(dist) <= maxDist) ? BT_SUCCESS : BT_FAILURE;
}

// Check if the targeted survivor is watching this bot
BT_Status CND_IsTargetWatching(int client) {
    int nodeId = g_iBTCurrentTickNode;
    int threshold = RoundToNearest(g_fBTNodeUserParam1[nodeId]);
    return IsTargetWatchingAttacker(client, threshold) ? BT_SUCCESS : BT_FAILURE;
}

// Check if bot's health is below threshold
BT_Status CND_HealthBelow(int client) {
    int nodeId = g_iBTCurrentTickNode;
    int threshold = RoundToNearest(g_fBTNodeUserParam1[nodeId]);
    return (GetClientHealth(client) < threshold) ? BT_SUCCESS : BT_FAILURE;
}

// Random probability check (0.0-1.0)
BT_Status CND_RandomChance(int client) {
    int nodeId = g_iBTCurrentTickNode;
    float prob = g_fBTNodeUserParam1[nodeId];
    return (GetRandomFloat(0.0, 1.0) < prob) ? BT_SUCCESS : BT_FAILURE;
}

// ---------------------------------------------------------------------------
// Simple actions (no params)
// ---------------------------------------------------------------------------

// Snap aim to engine-selected target (GetClientAimTarget)
BT_Status ACT_SnapAimToTarget(int client) {
    int target = GetClientAimTarget(client);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    return BT_SUCCESS;
}

// Snap aim to the coordination-assigned target
BT_Status ACT_SnapAimToCoordTarget(int client) {
    int target = SI_GetCoordinatedTarget(client);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}

// Signal the coordination system that this SI has committed to an attack
BT_Status ACT_SignalAttack(int client) {
    SI_SignalAttack(client);
    return BT_SUCCESS;
}

// v5.0: 瞄准黑板 "target"（身份目标获取后使用——ACT_AcquireThreatTarget/
// AcquireClusterTarget 等写入的黑板目标；现有 ACT_SnapAimToTarget 瞄的是
// 引擎 GetClientAimTarget，与身份选人结果不一致）
BT_Status ACT_SnapAimToBlackboardTarget(int client) {
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}

// Block ATTACK2 (right-click / rock throw). Call this when Tank shouldn't throw.
BT_Status ACT_BlockAttack2(int client) {
    BT_RemoveButton(client, IN_ATTACK2);
    return BT_SUCCESS;
}

// Send JUMP button
BT_Status ACT_Jump(int client) {
    BT_AddButton(client, IN_JUMP);
    return BT_SUCCESS;
}

// Send ATTACK (left-click / primary attack)
BT_Status ACT_Attack(int client) {
    BT_AddButton(client, IN_ATTACK);
    return BT_SUCCESS;
}

// Send ATTACK2 (right-click / secondary attack / rock throw)
BT_Status ACT_Attack2(int client) {
    BT_AddButton(client, IN_ATTACK2);
    return BT_SUCCESS;
}

// Signal Boomer hit + trigger full assault coordination
BT_Status ACT_SignalBoomerHit(int client) {
    SI_SignalBoomerHit();
    return BT_SUCCESS;
}

// Hold victim — do nothing (pinning state handled by engine)
BT_Status ACT_HoldVictim(int client) {
    // Just succeeds; the pin is maintained by the engine
    return BT_SUCCESS;
}

// Acquire closest survivor as blackboard "target"
BT_Status ACT_AcquireClosestTarget(int client) {
    float pos[3];
    GetClientAbsOrigin(client, pos);
    int closest = GetClosestSurvivor(pos);
    if (closest > 0) {
        BB_SetInt(client, "target", closest);
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}

// ---------------------------------------------------------------------------
// Parameterized actions
// ---------------------------------------------------------------------------

// Random lateral strafe while facing the blackboard target.
// UserParam1 = interval (seconds between direction changes).
// v3.7 FIX: Now faces BB target — previously strafed blindly in whatever
// direction the SI was facing, often away from survivors.
BT_Status ACT_StrafeRandom(int client) {
    // Face the blackboard target while strafing
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }

    float now = GetGameTime();
    float nextSwitch = BB_GetFloat(client, "_strafe_next");
    if (nextSwitch <= 0.0 || now >= nextSwitch) {
        bool goLeft = (GetRandomInt(0, 1) == 0);
        BB_SetBool(client, "_strafe_left", goLeft);
        int nodeId = g_iBTCurrentTickNode;
        float interval = g_fBTNodeUserParam1[nodeId];
        if (interval <= 0.0) interval = 0.5;
        BB_SetFloat(client, "_strafe_next", now + GetRandomFloat(interval * 0.5, interval * 1.5));
    }
    if (BB_GetBool(client, "_strafe_left", false)) {
        BT_AddButton(client, IN_MOVELEFT);
        BT_RemoveButton(client, IN_MOVERIGHT);
    } else {
        BT_AddButton(client, IN_MOVERIGHT);
        BT_RemoveButton(client, IN_MOVELEFT);
    }
    return BT_RUNNING;
}

// Move toward blackboard "target". Returns RUNNING to keep moving.
BT_Status ACT_MoveToTarget(int client) {
    int target = BB_GetInt(client, "target", -1);
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) {
        return BT_FAILURE;
    }
    // Face the target
    float sPos[3], tPos[3], dir[3], ang[3];
    GetClientAbsOrigin(client, sPos);
    GetClientAbsOrigin(target, tPos);
    MakeVectorFromPoints(sPos, tPos, dir);
    GetVectorAngles(dir, ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    // Move forward
    BT_AddButton(client, IN_FORWARD);
    return BT_RUNNING;
}

// Wander in a random direction. Returns RUNNING to keep moving.
BT_Status ACT_Wander(int client) {
    // Pick a random direction every few seconds
    float now = GetGameTime();
    float nextWander = BB_GetFloat(client, "_wander_next");
    if (nextWander <= 0.0 || now >= nextWander) {
        float ang[3];
        ang[0] = 0.0;
        ang[1] = GetRandomFloat(0.0, 360.0);
        ang[2] = 0.0;
        BB_SetFloat(client, "_wander_yaw", ang[1]);
        BB_SetFloat(client, "_wander_next", now + GetRandomFloat(2.0, 5.0));
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    } else {
        float yaw = BB_GetFloat(client, "_wander_yaw", 0.0);
        BT_SetAimAngles(client, 0.0, yaw, 0.0);
    }
    BT_AddButton(client, IN_FORWARD);
    return BT_RUNNING;
}

// Crouch — for Hunter preparing to pounce
BT_Status ACT_Crouch(int client) {
    BT_AddButton(client, IN_DUCK);
    return BT_SUCCESS;
}

// Queue a lunge for Hunter (sets up the delayed pounce)
BT_Status ACT_QueueLunge(int client) {
    // The actual queueing is done via the lunge interval timer
    // This action just clears ATTACK to release any pending pounce,
    // then re-presses ATTACK after the cooldown.
    // The Cooldown decorator handles the timing.
    BT_AddButton(client, IN_ATTACK);
    return BT_SUCCESS;
}

// Strafe + move toward blackboard target (combined action for SI approach).
// Avoids running in a straight line — prevents survivors from easily headshotting.
BT_Status ACT_StrafeMoveToTarget(int client) {
    // ---- strafe component ----
    float now = GetGameTime();
    float nextSwitch = BB_GetFloat(client, "_strafe_next");
    if (nextSwitch <= 0.0 || now >= nextSwitch) {
        bool goLeft = (GetRandomInt(0, 1) == 0);
        BB_SetBool(client, "_strafe_left", goLeft);
        BB_SetFloat(client, "_strafe_next", now + GetRandomFloat(0.3, 0.8));
    }
    if (BB_GetBool(client, "_strafe_left", false)) {
        BT_AddButton(client, IN_MOVELEFT);
        BT_RemoveButton(client, IN_MOVERIGHT);
    } else {
        BT_AddButton(client, IN_MOVERIGHT);
        BT_RemoveButton(client, IN_MOVELEFT);
    }

    // ---- move component ----
    int target = BB_GetInt(client, "target", -1);
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) {
        return BT_RUNNING;  // keep strafing even without target
    }
    float sPos[3], tPos[3], dir[3], ang[3];
    GetClientAbsOrigin(client, sPos);
    GetClientAbsOrigin(target, tPos);
    MakeVectorFromPoints(sPos, tPos, dir);
    GetVectorAngles(dir, ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_FORWARD);

    return BT_RUNNING;
}

// Apply Gaussian-distributed random yaw offset before pouncing.
// Creates unpredictable pounce angles — survivors can't easily dodge.
// Uses sum-of-3-uniforms to approximate Gaussian with ~15° std dev.
BT_Status ACT_GaussianAimOffset(int client) {
    float ang[3];
    GetClientEyeAngles(client, ang);
    float offset = (GetRandomFloat(-1.0, 1.0) + GetRandomFloat(-1.0, 1.0) + GetRandomFloat(-1.0, 1.0)) * 15.0;
    ang[1] += offset;
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    return BT_SUCCESS;
}

// Erratic approach: zigzag strafe + forward movement at random offset angles.
// Unlike ACT_StrafeMoveToTarget which faces the target directly, this adds
// ±30° random yaw offset so the approach path is unpredictable and harder to track.
BT_Status ACT_ErraticApproach(int client) {
    // ---- strafe component ----
    float now = GetGameTime();
    float nextSwitch = BB_GetFloat(client, "_strafe_next");
    if (nextSwitch <= 0.0 || now >= nextSwitch) {
        bool goLeft = (GetRandomInt(0, 1) == 0);
        BB_SetBool(client, "_strafe_left", goLeft);
        BB_SetFloat(client, "_strafe_next", now + GetRandomFloat(0.3, 0.8));
    }
    if (BB_GetBool(client, "_strafe_left", false)) {
        BT_AddButton(client, IN_MOVELEFT);
        BT_RemoveButton(client, IN_MOVERIGHT);
    } else {
        BT_AddButton(client, IN_MOVERIGHT);
        BT_RemoveButton(client, IN_MOVELEFT);
    }

    // ---- forward movement at random offset from target direction (±30°) ----
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        ang[1] += GetRandomFloat(-30.0, 30.0);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    BT_AddButton(client, IN_FORWARD);

    return BT_RUNNING;
}


// Retreat: move away from the closest survivor.
// Used by Spitter/Boomer as low-probability post-ability flee behavior.
BT_Status ACT_Retreat(int client) {
    float myPos[3];
    GetClientAbsOrigin(client, myPos);
    int closest = GetClosestSurvivor(myPos);
    if (closest > 0) {
        float sPos[3], dir[3], ang[3];
        GetClientAbsOrigin(closest, sPos);
        MakeVectorFromPoints(sPos, myPos, dir);  // away from survivor
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    BT_AddButton(client, IN_FORWARD);
    return BT_RUNNING;
}

// ============================================================================
// v3.2: TERRAIN DETECTION FRAMEWORK
// ============================================================================
// Classifies SI's current position into terrain types to enable context-aware
// attack strategies. Results are cached in the blackboard for 0.5s intervals.
//
// Terrain types (stored in _terrain):
//   0 = unknown / unclassified
//   1 = narrow   (corridor, tunnel — both sides blocked)
//   2 = open     (3+ directions clear beyond 600u)
//   3 = ledge    (forward trace detects drop-off within 500u)
//   4 = semi     (one side blocked, mixed — wall/cover on one side)
//
// Detection runs in two passes:
//   Pass 1: horizontal traces (left/right for narrow, 4-way for open)
//   Pass 2: forward ledge trace (3 step-down checks)
// ============================================================================

#define TERRAIN_UNKNOWN 0
#define TERRAIN_NARROW  1
#define TERRAIN_OPEN    2
#define TERRAIN_LEDGE   3
#define TERRAIN_SEMI    4

#define TERRAIN_CHECK_INTERVAL 0.5
#define TERRAIN_NARROW_WIDTH   200.0   // left/right trace distance for narrow check
#define TERRAIN_OPEN_DIST      600.0   // 4-direction trace for open check
#define TERRAIN_LEDGE_FWD_MAX  500.0   // max forward distance for ledge check
#define TERRAIN_LEDGE_DOWN     400.0   // downward trace for ledge check

// ---------------------------------------------------------------------------
// Internal trace helpers — filter out the SI itself and other infected
// ---------------------------------------------------------------------------

public bool TerrainTraceFilter(int entity, int contentsMask, any data) {
    if (entity == data) return false;   // skip self
    if (entity < 1 || entity > MaxClients) return true;  // world geometry
    // Skip other infected bots (they're not terrain)
    if (IsClientInGame(entity) && GetClientTeam(entity) == 3) return false;
    // v3.2 FIX: skip survivors too (they're not terrain — standing next to a
    // survivor shouldn't make the area classify as "narrow").
    if (IsClientInGame(entity) && GetClientTeam(entity) == 2) return false;
    return true;
}

// Trace in a horizontal direction from SI's position.
// Returns true if trace hits something within maxDist.
stock bool Terrain_HorzTraceHit(int client, float angleOffset, float maxDist) {
    float pos[3], ang[3], fwd[3], end[3];
    GetClientAbsOrigin(client, pos);
    GetClientEyeAngles(client, ang);
    ang[1] += angleOffset;
    ang[0] = 0.0;  // horizontal only

    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(fwd, fwd);
    end[0] = pos[0] + fwd[0] * maxDist;
    end[1] = pos[1] + fwd[1] * maxDist;
    end[2] = pos[2];

    TR_TraceRayFilter(pos, end, MASK_PLAYERSOLID, RayType_EndPoint, TerrainTraceFilter, client);
    return TR_DidHit();
}

// Forward ledge check: trace down at forwardDist ahead, return drop height.
// Positive = ground is below. Negative = ground is above (ramp). 0 = no hit.
stock float Terrain_LedgeDropAt(int client, float forwardDist) {
    float pos[3], ang[3], fwd[3], start[3];
    GetClientAbsOrigin(client, pos);
    GetClientEyeAngles(client, ang);
    ang[0] = 0.0;

    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(fwd, fwd);

    start[0] = pos[0] + fwd[0] * forwardDist;
    start[1] = pos[1] + fwd[1] * forwardDist;
    start[2] = pos[2] + 50.0;  // start a bit above

    float end[3];
    end[0] = start[0];
    end[1] = start[1];
    end[2] = start[2] - TERRAIN_LEDGE_DOWN;

    TR_TraceRayFilter(start, end, MASK_PLAYERSOLID, RayType_EndPoint, TerrainTraceFilter, client);
    if (!TR_DidHit()) return -999.0;  // no ground at all (cliff!)

    float hitPos[3];
    TR_GetEndPosition(hitPos);
    return start[2] - hitPos[2];  // positive = ground is below start point
}

// Full terrain classification — runs once per interval, caches result.
// When ai_terrain_enable=0: skips all traces, sets terrain to UNKNOWN.
// This causes all terrain condition nodes to return FAIL, and the BT
// selector falls through to the standard (non-terrain) behavior — the
// default strategies that were battle-tested in v2.4/v3.0.
stock void Terrain_Classify(int client) {
    // -- v3.2: Check if terrain system is enabled --
    if (g_hCvarTerrainEnable == INVALID_HANDLE || !GetConVarBool(g_hCvarTerrainEnable)) {
        // Terrain detection disabled — force UNKNOWN.
        // All terrain conditions will fail → BT falls back to standard behavior.
        BB_SetInt(client, "_terrain", TERRAIN_UNKNOWN);
        BB_SetFloat(client, "_terrain_next", GetGameTime() + TERRAIN_CHECK_INTERVAL);
        return;
    }

    // Rate-limit: only reclassify every TERRAIN_CHECK_INTERVAL seconds
    float now = GetGameTime();
    float nextCheck = BB_GetFloat(client, "_terrain_next", 0.0);
    if (nextCheck > 0.0 && now < nextCheck) return;
    BB_SetFloat(client, "_terrain_next", now + TERRAIN_CHECK_INTERVAL);

    // Reset ledge priority flag (only set when terrain is TERRAIN_LEDGE)
    BB_SetBool(client, "_terrain_ledge_prio", false);

    // ---- Pass 1: horizontal traces ----
    bool leftBlocked  = Terrain_HorzTraceHit(client, -90.0, TERRAIN_NARROW_WIDTH);
    bool rightBlocked = Terrain_HorzTraceHit(client,  90.0, TERRAIN_NARROW_WIDTH);

    // Count clear directions for open-area detection (0°, 90°, 180°, 270°)
    int clearDirs = 0;
    float openAngles[4];
    openAngles[0] = 0.0;    // forward
    openAngles[1] = 90.0;   // right
    openAngles[2] = 180.0;  // backward
    openAngles[3] = 270.0;  // left
    for (int i = 0; i < 4; i++) {
        if (!Terrain_HorzTraceHit(client, openAngles[i], TERRAIN_OPEN_DIST)) {
            clearDirs++;
        }
    }

    // ---- Pass 2: ledge check ----
    float drop150 = Terrain_LedgeDropAt(client, 150.0);
    float drop350 = Terrain_LedgeDropAt(client, 350.0);
    float drop500 = Terrain_LedgeDropAt(client, 500.0);
    bool nearLedge = false;
    // Ledge: close ground is solid but farther is missing or steep drop
    if (drop150 > -900.0 && (drop350 < -800.0 || drop350 > 200.0 || drop500 < -800.0 || drop500 > 250.0)) {
        nearLedge = true;
    }
    // Also ledge if ground drops more than 150u between 150u and 350u ahead
    if (drop150 > -900.0 && drop350 > -900.0 && (drop350 - drop150) > 150.0) {
        nearLedge = true;
    }

    // ---- Classification ----
    int terrainType = TERRAIN_UNKNOWN;

    // Ledge takes priority (dangerous to move forward)
    if (nearLedge) {
        terrainType = TERRAIN_LEDGE;
        // Check if ledge is between SI and nearest survivor → useful for Smoker
        float myPos[3], ang[3], fwd[3];
        GetClientAbsOrigin(client, myPos);
        GetClientEyeAngles(client, ang);
        ang[0] = 0.0;
        GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
        NormalizeVector(fwd, fwd);

        int nearest = GetClosestSurvivor(myPos);
        if (nearest > 0) {
            float sPos[3], toSurv[3];
            GetClientAbsOrigin(nearest, sPos);
            MakeVectorFromPoints(myPos, sPos, toSurv);
            NormalizeVector(toSurv, toSurv);
            // If survivor is roughly in front (within 45°), ledge is between them
            if (GetVectorDotProduct(fwd, toSurv) > 0.7) {
                BB_SetBool(client, "_terrain_ledge_prio", true);
            }
        }
    } else if (leftBlocked && rightBlocked) {
        terrainType = TERRAIN_NARROW;
    } else if (clearDirs >= 3) {
        terrainType = TERRAIN_OPEN;
    } else {
        terrainType = TERRAIN_SEMI;  // one wall, partial cover
    }

    BB_SetInt(client, "_terrain", terrainType);

    // Store directional info for narrow spaces (which side is blocked)
    BB_SetBool(client, "_terrain_left_blocked", leftBlocked);
    BB_SetBool(client, "_terrain_right_blocked", rightBlocked);

    // Store open direction count for open areas
    BB_SetInt(client, "_terrain_clear_dirs", clearDirs);
}

// ============================================================================
// v3.2: Terrain condition nodes (use with BT_CreateCondition)
//
// All terrain conditions first check ai_terrain_enable cvar via Terrain_Classify.
// When disabled, terrain is set to UNKNOWN and ALL conditions return FAIL,
// causing BT selectors to fall through to standard (non-terrain) strategies.
// ============================================================================

// Master switch: returns SUCCESS only when terrain system is active
BT_Status CND_IsTerrainEnabled(int client) {
    if (g_hCvarTerrainEnable != INVALID_HANDLE && !GetConVarBool(g_hCvarTerrainEnable))
        return BT_FAILURE;
    return BT_SUCCESS;
}

// Returns SUCCESS when terrain is unclassified or classification failed.
// Useful as an explicit fallback guard in BT branches.
BT_Status CND_IsTerrainUnknown(int client) {
    Terrain_Classify(client);
    return (BB_GetInt(client, "_terrain", TERRAIN_UNKNOWN) == TERRAIN_UNKNOWN) ? BT_SUCCESS : BT_FAILURE;
}

BT_Status CND_IsNarrowSpace(int client) {
    Terrain_Classify(client);
    // cvar check: if disabled, Terrain_Classify forces UNKNOWN → condition fails
    return (BB_GetInt(client, "_terrain", 0) == TERRAIN_NARROW) ? BT_SUCCESS : BT_FAILURE;
}

BT_Status CND_IsOpenArea(int client) {
    Terrain_Classify(client);
    return (BB_GetInt(client, "_terrain", 0) == TERRAIN_OPEN) ? BT_SUCCESS : BT_FAILURE;
}

BT_Status CND_IsNearLedge(int client) {
    Terrain_Classify(client);
    return (BB_GetInt(client, "_terrain", 0) == TERRAIN_LEDGE) ? BT_SUCCESS : BT_FAILURE;
}

BT_Status CND_IsSemiOpen(int client) {
    Terrain_Classify(client);
    return (BB_GetInt(client, "_terrain", 0) == TERRAIN_SEMI) ? BT_SUCCESS : BT_FAILURE;
}

// Check if ledge is between SI and nearest survivor (for Smoker pull strategy)
BT_Status CND_IsLedgeBetweenTarget(int client) {
    Terrain_Classify(client);
    int terrain = BB_GetInt(client, "_terrain", 0);
    if (terrain != TERRAIN_LEDGE) return BT_FAILURE;
    return BB_GetBool(client, "_terrain_ledge_prio", false) ? BT_SUCCESS : BT_FAILURE;
}

// ============================================================================
// v3.2: Terrain-aware actions
// ============================================================================

// Move toward a flanking position (90° offset from direct approach)
// Used by Hunter/Charger in open areas to attack from the side
BT_Status ACT_FlankApproach(int client) {
    float now = GetGameTime();
    float nextSwitch = BB_GetFloat(client, "_flank_next", 0.0);
    bool flankRight = BB_GetBool(client, "_flank_right", false);

    if (nextSwitch <= 0.0 || now >= nextSwitch) {
        flankRight = (GetRandomInt(0, 1) == 0);
        BB_SetBool(client, "_flank_right", flankRight);
        BB_SetFloat(client, "_flank_next", now + GetRandomFloat(1.5, 3.0));
    }

    int target = BB_GetInt(client, "target", -1);
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) {
        return BT_RUNNING;
    }

    // Aim at target but offset by ±60° for flank approach
    float sPos[3], tPos[3], dir[3], ang[3];
    GetClientAbsOrigin(client, sPos);
    GetClientAbsOrigin(target, tPos);
    MakeVectorFromPoints(sPos, tPos, dir);
    GetVectorAngles(dir, ang);

    // Offset approach angle for flanking
    ang[1] += flankRight ? 60.0 : -60.0;
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);

    // Strafe toward flank direction while moving forward
    if (flankRight) {
        BT_AddButton(client, IN_MOVERIGHT);
    } else {
        BT_AddButton(client, IN_MOVELEFT);
    }
    BT_AddButton(client, IN_FORWARD);
    return BT_RUNNING;
}

// Move along a wall (perpendicular to facing, toward the unblocked side)
// Used in narrow/semi spaces to use walls for cover
BT_Status ACT_HugWall(int client) {
    bool leftBlocked  = BB_GetBool(client, "_terrain_left_blocked", false);
    bool rightBlocked = BB_GetBool(client, "_terrain_right_blocked", false);

    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }

    // Hug the wall: strafe toward the blocked side
    if (leftBlocked && !rightBlocked) {
        BT_AddButton(client, IN_MOVELEFT);   // move toward left wall
    } else if (rightBlocked && !leftBlocked) {
        BT_AddButton(client, IN_MOVERIGHT);  // move toward right wall
    } else {
        // Both blocked (narrow corridor) — move straight
    }
    BT_AddButton(client, IN_FORWARD);
    return BT_RUNNING;
}

// Block a choke point — stand ground in narrow space facing the survivor
// Used by Tank/Boomer to body-block corridors
BT_Status ACT_HoldChokepoint(int client) {
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    // Don't move forward — just face the target and hold position
    // (Tank will punch, Boomer will vomit, etc.)
    return BT_SUCCESS;
}

// ============================================================================
// v3.6: ANTI-MELEE INFRASTRUCTURE
// ============================================================================
// In L4D2, control abilities (tongue/charge/leap) and melee attacks share the
// same IN_ATTACK button. When the engine decides the ability isn't ready
// (cooldown, angle, range), pressing IN_ATTACK triggers a melee scratch instead.
// This is deadly for control SI — a Smoker scratching at close range is worse
// than a Smoker repositioning for a tongue grab.
//
// Fix: provide "hold and wait" behaviors that keep the BT selector occupied
// without pressing IN_ATTACK, preventing the engine default melee takeover.

// Hold position: face the blackboard target, don't move or attack.
// Keeps the selector occupied (returns RUNNING) so the engine default AI
// never takes over. Control SI use this as last resort instead of Wander.
BT_Status ACT_HoldPosition(int client) {
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    // NO movement buttons — just face target and wait for ability cooldown
    return BT_RUNNING;
}

// ============================================================================
// v3.5: STRATEGY TOKEN SYSTEM
// ============================================================================
// Enables random strategy selection within the same terrain type.
// A "strategy token" is a persistent random integer stored in the blackboard
// that determines which of N strategies the SI pursues. The token is re-rolled
// every 10 seconds, creating unpredictable behavior variety.
//
// Usage pattern in BT selectors:
//   Selector:
//     Sequence(IsOpenArea, RollStrategy(3))       // roll token (consumes 1 tick)
//     Sequence(IsOpenArea, StrategyIs(0), ...)    // token=0 → strategy A
//     Sequence(IsOpenArea, StrategyIs(1), ...)    // token=1 → strategy B
//     Sequence(IsOpenArea, StrategyIs(2), ...)    // token=2 → strategy C
//     ... fallback ...
// ============================================================================

#define STRATEGY_TOKEN_TTL 10.0   // seconds before re-roll

// Condition: check if the blackboard strategy token matches the expected index.
// UserParam1 = expected strategy index (0, 1, 2, ...)
BT_Status CND_StrategyIs(int client) {
    int nodeId = g_iBTCurrentTickNode;
    int expectedIdx = RoundToNearest(g_fBTNodeUserParam1[nodeId]);
    int currentIdx = BB_GetInt(client, "_strategy_idx", -1);
    return (currentIdx == expectedIdx) ? BT_SUCCESS : BT_FAILURE;
}

// Action: roll a new strategy token if stale or unset.
// UserParam1 = number of strategies to choose from.
// Returns SUCCESS on the tick the roll happens (so the selector is consumed
// for one tick), then FAIL on subsequent ticks (so selector moves past to
// the StrategyIs branches).
BT_Status ACT_RollStrategy(int client) {
    int nodeId = g_iBTCurrentTickNode;
    int numStrategies = RoundToNearest(g_fBTNodeUserParam1[nodeId]);
    if (numStrategies < 1) numStrategies = 1;

    float now = GetGameTime();
    float lastRoll = BB_GetFloat(client, "_strategy_time", 0.0);

    // Token still fresh — skip (return FAIL so selector moves on)
    if (lastRoll > 0.0 && (now - lastRoll) < STRATEGY_TOKEN_TTL) {
        return BT_FAILURE;
    }

    // Roll new strategy
    int roll = GetRandomInt(0, numStrategies - 1);
    BB_SetInt(client, "_strategy_idx", roll);
    BB_SetFloat(client, "_strategy_time", now);
    return BT_SUCCESS;
}

// Factory: create a StrategyIs condition node
stock int BT_CreateStrategyIs(int idx) {
    int id = BT_Create(BTN_CONDITION);
    g_hBTFunc[id] = CND_StrategyIs;
    g_fBTNodeUserParam1[id] = float(idx);
    return id;
}

// ============================================================================
// v4.0: TACTICAL MODE SYSTEM
// ============================================================================
// si_composition_manager 每波/每模式切换时写入 si_comp_active_mode。
// 行为树用 CND_IsMode(N) 感知当前战术模式，走对应配合分支。
// 模式编号：0-5 = 6 种普通模式, 6 = Tank 巨兽协同, -1 = 未激活 → 分支全 FAIL，落回默认行为。

// Condition: 当前战术模式 == expected (UserParam1)
BT_Status CND_IsMode(int client) {
    int nodeId = g_iBTCurrentTickNode;
    int expected = RoundToNearest(g_fBTNodeUserParam1[nodeId]);
    return (SI_GetActiveMode() == expected) ? BT_SUCCESS : BT_FAILURE;
}

// Factory: create an IsMode condition node
stock int BT_CreateIsMode(int mode) {
    int id = BT_Create(BTN_CONDITION);
    g_hBTFunc[id] = CND_IsMode;
    g_fBTNodeUserParam1[id] = float(mode);
    return id;
}

// Condition: 当前战术模式 ∈ {UserParam1, UserParam2} 之一（分散型模式共用分支）
BT_Status CND_IsModeAny(int client) {
    int nodeId = g_iBTCurrentTickNode;
    int modeA = RoundToNearest(g_fBTNodeUserParam1[nodeId]);
    int modeB = RoundToNearest(g_fBTNodeUserParam2[nodeId]);
    int cur = SI_GetActiveMode();
    return (cur == modeA || cur == modeB) ? BT_SUCCESS : BT_FAILURE;
}

// Factory: create an IsModeAny condition node
stock int BT_CreateIsModeAny(int modeA, int modeB) {
    int id = BT_Create(BTN_CONDITION);
    g_hBTFunc[id] = CND_IsModeAny;
    g_fBTNodeUserParam1[id] = float(modeA);
    g_fBTNodeUserParam2[id] = float(modeB);
    return id;
}

// Action: 把当前集火目标（被 pin 者）设为黑板 target
BT_Status ACT_AcquirePinTarget(int client) {
    int pin = SI_GetPinTarget();
    if (pin > 0 && IsSurvivor(pin) && IsPlayerAlive(pin)) {
        BB_SetInt(client, "target", pin);
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}

// Action: 把协同分配目标（分散/防 dogpile）设为黑板 target
BT_Status ACT_AcquireCoordTarget(int client) {
    int target = SI_GetCoordinatedTarget(client);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        BB_SetInt(client, "target", target);
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}

// ============================================================================
// v4.0: ACT_CircleFlank — 大弧线绕后包夹（开阔地）
// ============================================================================
// 与 ACT_FlankApproach（±60° 小幅侧移）不同，这是大弧线机动：
// 以目标为中心走 120° 偏移的大圈，从目标视线外绕到侧后方。
// 适用于开阔地 Hunter/Charger/Jockey 的包夹进攻 —— 生还者看到时已绕到位。
// 接近到 350u 内后自动转小偏移（防止绕过头）。
BT_Status ACT_CircleFlank(int client) {
    // 切换弧线方向：每 2-3.5s 反转一次绕行方向
    float now = GetGameTime();
    float nextSwitch = BB_GetFloat(client, "_circle_next", 0.0);
    bool circleRight = BB_GetBool(client, "_circle_right", false);
    if (nextSwitch <= 0.0 || now >= nextSwitch) {
        circleRight = !circleRight;
        BB_SetBool(client, "_circle_right", circleRight);
        BB_SetFloat(client, "_circle_next", now + GetRandomFloat(2.0, 3.5));
    }

    int target = BB_GetInt(client, "target", -1);
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) {
        return BT_RUNNING;
    }

    float sPos[3], tPos[3], dir[3], ang[3];
    GetClientAbsOrigin(client, sPos);
    GetClientAbsOrigin(target, tPos);
    MakeVectorFromPoints(sPos, tPos, dir);
    GetVectorAngles(dir, ang);

    // 距离远时大偏移绕后（120°），接近后收敛到 30° 直插
    float dist = GetVectorDistance(sPos, tPos);
    float offset = (dist > 600.0) ? 120.0 : 30.0;
    ang[1] += circleRight ? offset : -offset;
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);

    // 绕行时侧向移动强化弧线
    if (circleRight) {
        BT_AddButton(client, IN_MOVERIGHT);
        BT_RemoveButton(client, IN_MOVELEFT);
    } else {
        BT_AddButton(client, IN_MOVELEFT);
        BT_RemoveButton(client, IN_MOVERIGHT);
    }
    BT_AddButton(client, IN_FORWARD);
    return BT_RUNNING;
}

// ============================================================================
// v4.0: ACT_AmbushHold — 伏击等待（狭窄地/转角）
// ============================================================================
// 原地不动、面向目标方向，等待目标进入射程由上层 selector 切换到攻击分支。
// 返回 RUNNING 保持姿态。Boomer 门后伏击、Smoker 走廊尽头等人都用它。
BT_Status ACT_AmbushHold(int client) {
    // v4.1.1: 伏击超时 —— UserParam1（秒）内目标未进射程 → FAIL 放弃伏击，
    // 由上层 selector 落到 approach 主动接近（防"出生远 → 无限站桩 → 被处死"）。
    // 超时后 _ambush_start 刻意残留：本生命内该分支每 tick 立即 FAIL，
    // 行为 = 永久转为主动接近，直到重生（BB 重置）恢复伏击能力。
    // UserParam1 ≤ 0 = 不超时（保持原行为）。
    int nodeId = g_iBTCurrentTickNode;
    float timeout = g_fBTNodeUserParam1[nodeId];
    if (timeout > 0.0) {
        float now = GetGameTime();
        float start = BB_GetFloat(client, "_ambush_start", 0.0);
        if (start <= 0.0) {
            BB_SetFloat(client, "_ambush_start", now);
        } else if (now - start >= timeout) {
            return BT_FAILURE;
        }
    }

    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    // 不按任何移动键 —— 完全静止，保持伪装
    return BT_RUNNING;
}

// Factory: create a RollStrategy action node
stock int BT_CreateRollStrategy(int numStrategies) {
    int id = BT_Create(BTN_ACTION);
    g_hBTFunc[id] = ACT_RollStrategy;
    g_fBTNodeUserParam1[id] = float(numStrategies);
    return id;
}

// Factory: NOT in range — condition that succeeds when distance > minDist.
// Simpler than nesting Inverter+IsInRange for "not yet close enough" checks.
stock int BT_CreateIsNotInRange(float minDist) {
    int id = BT_Create(BTN_INVERTER);
    BT_AddChild(id, BT_CreateIsInRange(minDist));
    return id;
}

// ============================================================================
// v5.0: 身份定位系统公共节点（感知条件 + 身份目标获取）
// 基础设施在 hardcoop_util.sp（酸液锚点/谁控谁映射/阵型分析/孤立度/火力威胁）。
// 身份分支 = 用这些节点替换"最近者驱动"的目标选择 + 加入身份专属动作。
// ============================================================================

// 条件：附近有酸液池（UserParam1 = 最大距离，0 = 不限）
BT_Status CND_HasNearbyAcid(int client) {
    int nodeId = g_iBTCurrentTickNode;
    float maxRange = g_fBTNodeUserParam1[nodeId];
    float pos[3], acid[3];
    GetClientAbsOrigin(client, pos);
    return (SI_GetNearestAcid(pos, acid, maxRange) >= 0.0) ? BT_SUCCESS : BT_FAILURE;
}

stock int BT_CreateHasNearbyAcid(float maxRange) {
    int id = BT_Create(BTN_CONDITION);
    g_hBTFunc[id] = CND_HasNearbyAcid;
    g_fBTNodeUserParam1[id] = maxRange;
    return id;
}

// 条件：幸存者存在密集区（UserParam1 = 最少总人数, UserParam2 = 簇半径）
BT_Status CND_SurvivorsClustered(int client) {
    int nodeId = g_iBTCurrentTickNode;
    float radius = g_fBTNodeUserParam2[nodeId];
    int minCount = RoundToNearest(g_fBTNodeUserParam1[nodeId]);
    float center[3];
    return (SI_GetDenseCluster(radius, minCount, center) > 0) ? BT_SUCCESS : BT_FAILURE;
}

stock int BT_CreateSurvivorsClustered(int minCount, float radius) {
    int id = BT_Create(BTN_CONDITION);
    g_hBTFunc[id] = CND_SurvivorsClustered;
    g_fBTNodeUserParam1[id] = float(minCount);
    g_fBTNodeUserParam2[id] = radius;
    return id;
}

// 动作：把最近的被控者设为黑板 target（Boomer 补刀/Hunter 补压）
// UserParam1 = 最大距离（0 = 不限）
BT_Status ACT_AcquirePinnedTarget(int client) {
    int nodeId = g_iBTCurrentTickNode;
    float maxDist = g_fBTNodeUserParam1[nodeId];
    if (maxDist <= 0.0) maxDist = 99999.0;
    float pos[3];
    GetClientAbsOrigin(client, pos);
    int pinned = SI_GetNearestPinnedSurvivor(pos, maxDist);
    if (pinned > 0) {
        BB_SetInt(client, "target", pinned);
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}

stock int BT_CreateAcquirePinnedTarget(float maxDist) {
    int id = BT_Create(BTN_ACTION);
    g_hBTFunc[id] = ACT_AcquirePinnedTarget;
    g_fBTNodeUserParam1[id] = maxDist;
    return id;
}

// 动作：把孤立者设为黑板 target（Hunter 打枪线后排/Smoker 传统）
BT_Status ACT_AcquireLonelyTarget(int client) {
    int lonely = SI_GetLoneliestSurvivor(350.0);
    if (lonely > 0) {
        BB_SetInt(client, "target", lonely);
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}

// 动作：把高威胁输出核心设为黑板 target（Charger 突破撕火力网/Hunter 打枪手）
BT_Status ACT_AcquireThreatTarget(int client) {
    float pos[3];
    GetClientAbsOrigin(client, pos);
    int threat = SI_GetHighestThreatSurvivor(pos, 1200.0);
    if (threat > 0) {
        BB_SetInt(client, "target", threat);
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}

// 动作：把密集区中心成员设为黑板 target（Charger 冲密集区撕阵型）
BT_Status ACT_AcquireClusterTarget(int client) {
    float center[3];
    int member = SI_GetDenseCluster(500.0, 3, center);
    if (member > 0) {
        BB_SetInt(client, "target", member);
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}

// ---------------------------------------------------------------------------

