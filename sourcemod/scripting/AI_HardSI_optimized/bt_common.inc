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

stock int BT_CreateIsInRangeCoordTarget(float maxDist) {
    int id = BT_Create(BTN_CONDITION);
    g_hBTFunc[id] = CND_IsInRangeCoordTarget;
    g_fBTNodeUserParam1[id] = maxDist;
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

// Check distance to current coordination target
BT_Status CND_IsInRangeCoordTarget(int client) {
    int nodeId = g_iBTCurrentTickNode;
    float maxDist = g_fBTNodeUserParam1[nodeId];
    int target = SI_GetCoordinatedTarget(client);
    if (target <= 0 || !IsSurvivor(target)) return BT_FAILURE;
    float pos[3], tPos[3];
    GetClientAbsOrigin(client, pos);
    GetClientAbsOrigin(target, tPos);
    return (GetVectorDistance(pos, tPos) <= maxDist) ? BT_SUCCESS : BT_FAILURE;
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

// Face away from target briefly (fake direction — tricks survivors)
// UserParam1 = probability (0.0-1.0). Should be wrapped in CND_RandomChance.
BT_Status ACT_FakeDirection(int client) {
    float ang[3];
    GetClientEyeAngles(client, ang);
    ang[1] += GetRandomFloat(25.0, 40.0) * (GetRandomInt(0, 1) ? 1.0 : -1.0);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    return BT_SUCCESS;
}

// Snap aim to a specified survivor class target (for Smoker → farthest, Jockey → lowest HP)
// UserParam1 = target preference: 1=SMOKER(farthest), 2=JOCKEY(lowest HP), 0=default
BT_Status ACT_AcquireCoordTarget(int client) {
    int nodeId = g_iBTCurrentTickNode;
    int preferClass = RoundToNearest(g_fBTNodeUserParam1[nodeId]);
    int target = SI_GetCoordinatedTarget(client, preferClass);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        BB_SetInt(client, "target", target);
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

// ---------------------------------------------------------------------------
