// ============================================================================
// bt_smoker.inc — Smoker Behavior Tree (v3.2)
// ============================================================================
// v3.1: Mixed target selection — 60% farthest (back-line pull), 40% closest
//       (front-line disruption). Strafe approach avoids running straight.
// v3.2:
//   - FIXED: Removed tongue_release suicide — Smoker now re-engages after grab
//   - Ledge priority: when ledge is between SI and survivor → 90% farthest (pull for fall damage)
//   - Narrow corridor: pull survivor through chokepoint into infected pack
//   - Open area: standard mixed target (back-line + front-line disruption)
// Key behaviors:
//   - Mixed target: farthest (traditional) + closest (front-line)
//   - Strafe approach to avoid being an easy snipe target
//   - Retarget every 2 seconds
//   - Tongue break damage tracking
// ============================================================================

#if defined _bt_smoker_included
  #endinput
#endif
#define _bt_smoker_included

// ---------------------------------------------------------------------------
// Smoker target acquisition: mix farthest (back-line) + closest (front-line)
// ---------------------------------------------------------------------------

BT_Status SmokerAct_AcquireTarget(int client) {
    int target = -1;

    // 40% chance: front-line pull (closest survivor)
    // 60% chance: traditional back-line pull (farthest survivor)
    if (GetRandomFloat(0.0, 1.0) < 0.4) {
        float pos[3];
        GetClientAbsOrigin(client, pos);
        target = GetClosestSurvivor(pos);
    } else {
        // Farthest survivor via coordination system (ZC_SMOKER=1)
        target = SI_GetCoordinatedTarget(client, 1);
    }

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

    // Fallback: any survivor
    float pos[3];
    GetClientAbsOrigin(client, pos);
    int fallback = GetClosestSurvivor(pos);
    if (fallback > 0) {
        BB_SetInt(client, "target", fallback);
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}

// ============================================================================
// v3.2: Terrain-aware target acquisition
// ============================================================================

BT_Status SmokerAct_AcquireLedgeTarget(int client) {
    // When near a ledge: 90% farthest (pull for fall damage), 10% closest
    int target = -1;
    if (GetRandomFloat(0.0, 1.0) < 0.9) {
        target = SI_GetCoordinatedTarget(client, 1);  // farthest
    } else {
        float pos[3];
        GetClientAbsOrigin(client, pos);
        target = GetClosestSurvivor(pos);
    }

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

BT_Status SmokerAct_AcquireNarrowTarget(int client) {
    // Narrow: 50% farthest (pull through corridor), 50% closest (chokepoint)
    int target = -1;
    if (GetRandomFloat(0.0, 1.0) < 0.5) {
        target = SI_GetCoordinatedTarget(client, 1);
    } else {
        float pos[3];
        GetClientAbsOrigin(client, pos);
        target = GetClosestSurvivor(pos);
    }

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

// ============================================================================
// Tree builder
// ============================================================================

stock int BT_CreateSmokerTree() {
    // --- v3.2: Terrain-aware pull strategies ---
    // Ledge: 90% farthest target → pull for fall damage
    int ledgeTargetAcquire = BT_CreateAction(SmokerAct_AcquireLedgeTarget);
    // v3.2 FIX: ledgePullSeq now uses SmokerAct_AcquireLedgeTarget (90% farthest)
    // before snapping aim, instead of relying on the engine's default target.
    int ledgePullSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsLedgeBetweenTarget),
        BT_CreateAction(SmokerAct_AcquireLedgeTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateAction(ACT_SnapAimToTarget),
        BT_CreateAction(ACT_Attack)
    );

    // Narrow: 50/50 target mix → pull through chokepoint
    int narrowPullSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateAction(SmokerAct_AcquireNarrowTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateAction(ACT_SnapAimToTarget),
        BT_CreateAction(ACT_Attack)
    );

    // Standard: pull (mixed targeting), check LOS, aim, attack
    int acquireTarget = BT_CreateAction(SmokerAct_AcquireTarget);
    int pullSeq = BT_CreateSequence(3,
        BT_CreateCondition(CND_HasLOS),
        BT_CreateAction(ACT_SnapAimToTarget),
        BT_CreateAction(ACT_Attack)
    );

    // Retarget every 2s — mixes farthest and closest each cycle
    int retargetCooldown = BT_CreateCooldown(2.0, acquireTarget);

    // Ledge retarget (override: 90% farthest)
    int ledgeRetarget = BT_CreateCooldown(2.0, ledgeTargetAcquire);

    // Approach: strafe while moving
    int approachAct = BT_CreateAction(ACT_StrafeMoveToTarget);

    // Root selector — terrain branches (2-3) fail when disabled/unknown
    // → falls through to standard pull (4) and retarget (6).
    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, BT_CreateCondition(CND_IsPinningSurvivor));
    BT_AddChild(root, ledgePullSeq);          // 2. v3.2: ledge → pull for fall damage
    BT_AddChild(root, narrowPullSeq);         // 3. v3.2: narrow → pull through corridor
    BT_AddChild(root, pullSeq);               // 4. ← FALLBACK: standard pull
    BT_AddChild(root, ledgeRetarget);         // 5. v3.2: ledge → retarget farthest
    BT_AddChild(root, retargetCooldown);      // 6. ← FALLBACK: standard retarget
    BT_AddChild(root, approachAct);
    BT_AddChild(root, BT_CreateAction(ACT_Wander));

    return root;
}

public Smoker_OnModuleStart() {
    SetConVarFloat(FindConVar("smoker_tongue_delay"), 1.0);
}
