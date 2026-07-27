// ============================================================================
// bt_smoker.inc — Smoker Behavior Tree
// ============================================================================
// v3.1: Mixed target selection — 60% farthest (back-line pull), 40% closest
//       (front-line disruption). Strafe approach avoids running straight.
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
// Tree builder
// ============================================================================

stock int BT_CreateSmokerTree() {
    // Pull: acquire target (mixed), check LOS, aim, and attack
    int acquireTarget = BT_CreateAction(SmokerAct_AcquireTarget);

    int pullSeq = BT_CreateSequence(3,
        BT_CreateCondition(CND_HasLOS),
        BT_CreateAction(ACT_SnapAimToTarget),
        BT_CreateAction(ACT_Attack)     // tongue grab
    );

    // Retarget every 2s — mixes farthest and closest each cycle
    int retargetCooldown = BT_CreateCooldown(2.0, acquireTarget);

    // Approach: strafe while moving — avoids running straight at survivors
    int approachAct = BT_CreateAction(ACT_StrafeMoveToTarget);

    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, BT_CreateCondition(CND_IsPinningSurvivor));
    BT_AddChild(root, pullSeq);
    BT_AddChild(root, retargetCooldown);
    BT_AddChild(root, approachAct);
    BT_AddChild(root, BT_CreateAction(ACT_Wander));

    return root;
}

public Smoker_OnModuleStart() {
    SetConVarFloat(FindConVar("smoker_tongue_delay"), 1.0);
}
