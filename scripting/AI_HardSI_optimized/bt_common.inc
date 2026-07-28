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

// Random lateral strafe. UserParam1 = interval (seconds between direction changes).
BT_Status ACT_StrafeRandom(int client) {
    float now = GetGameTime();
    // Check if it's time to switch direction
    float nextSwitch = BB_GetFloat(client, "_strafe_next");
    if (nextSwitch <= 0.0 || now >= nextSwitch) {
        bool goLeft = (GetRandomInt(0, 1) == 0);
        BB_SetBool(client, "_strafe_left", goLeft);
        int nodeId = g_iBTCurrentTickNode;
        float interval = g_fBTNodeUserParam1[nodeId];
        if (interval <= 0.0) interval = 0.5;  // default 0.5s
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

// ---------------------------------------------------------------------------

