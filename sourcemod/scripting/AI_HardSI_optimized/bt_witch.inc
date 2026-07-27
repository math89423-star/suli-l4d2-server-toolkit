// ============================================================================
// bt_witch.inc — Witch Behavior Tree (v3.2)
// ============================================================================
// The Witch previously had empty stubs in AI_HardSI v2.4.
// v3.0: First implementation of Witch AI. Behaviors:
//   - Enraged: chase and claw the survivor who startled her
//   - Idle: sit in place (default behavior)
//   - Retreat: move away from survivors who get too close (pre-startle)
// v3.2 terrain-aware additions:
//   - Narrow space: no retreat possible → become more aggressive (lower startle threshold)
//   - Open area: standard retreat behavior
//   - When blocked: fight instead of trying to retreat into walls
// ============================================================================

#if defined _bt_witch_included
  #endinput
#endif
#define _bt_witch_included



// ---------------------------------------------------------------------------
// Witch-specific callbacks
// ---------------------------------------------------------------------------

// Check if the Witch has been startled (enraged state)
BT_Status WitchCond_IsEnraged(int client) {
    // m_mobRush is set when the Witch is angered
    if (GetEntProp(client, Prop_Send, "m_mobRush") > 0) return BT_SUCCESS;
    // Alternative: check if Witch is chasing (has a target)
    int target = GetClientAimTarget(client);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        // Witch only targets survivors when enraged
        float witchPos[3], survPos[3];
        GetClientAbsOrigin(client, witchPos);
        GetClientAbsOrigin(target, survPos);
        // If Witch is actively facing and close to a survivor, she's likely enraged
        if (GetVectorDistance(witchPos, survPos) < 200.0) return BT_SUCCESS;
    }
    return BT_FAILURE;
}

// Check if survivors are dangerously close (but Witch isn't startled yet)
BT_Status WitchCond_SurvivorsTooClose(int client) {
    float witchPos[3];
    GetClientAbsOrigin(client, witchPos);

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsSurvivor(i) || !IsPlayerAlive(i)) continue;
        float survPos[3];
        GetClientAbsOrigin(i, survPos);
        // 300 units is the "danger zone" where survivors might startle the Witch
        if (GetVectorDistance(witchPos, survPos) < 300.0) {
            return BT_SUCCESS;
        }
    }
    return BT_FAILURE;
}

// Chase the survivor who startled the Witch
BT_Status WitchAct_ChaseTarget(int client) {
    int target = GetClientAimTarget(client);
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) {
        // Find closest survivor if no engine target
        float witchPos[3];
        GetClientAbsOrigin(client, witchPos);
        target = GetClosestSurvivor(witchPos);
    }
    if (target > 0) {
        float wPos[3], sPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, wPos);
        GetClientAbsOrigin(target, sPos);
        MakeVectorFromPoints(wPos, sPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        BT_AddButton(client, IN_FORWARD);
    }
    return BT_RUNNING;
}

// Melee claw attack
BT_Status WitchAct_MeleeAttack(int client) {
    BT_AddButton(client, IN_ATTACK);
    return BT_SUCCESS;
}

// Move away from nearby survivors
BT_Status WitchAct_Retreat(int client) {
    float witchPos[3];
    GetClientAbsOrigin(client, witchPos);

    // Find average position of nearby survivors and move away from it
    float avgSurvPos[3];
    int count = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsSurvivor(i) || !IsPlayerAlive(i)) continue;
        float survPos[3];
        GetClientAbsOrigin(i, survPos);
        if (GetVectorDistance(witchPos, survPos) < 500.0) {
            avgSurvPos[0] += survPos[0];
            avgSurvPos[1] += survPos[1];
            avgSurvPos[2] += survPos[2];
            count++;
        }
    }

    if (count > 0) {
        avgSurvPos[0] /= float(count);
        avgSurvPos[1] /= float(count);
        avgSurvPos[2] /= float(count);

        // Face away from survivors and move
        float dir[3], ang[3];
        MakeVectorFromPoints(avgSurvPos, witchPos, dir);  // away from survivors
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        BT_AddButton(client, IN_FORWARD);
    }
    return BT_RUNNING;
}

// Default idle: sit still
BT_Status WitchAct_Idle(int client) {
    // Just sit there — don't move, don't attack
    // The Witch's default idle animation handles the rest
    return BT_SUCCESS;
}
stock int BT_CreateWitchTree() {
    // Branch 1: Enraged → chase and attack
    int enragedSeq = BT_CreateSequence(2,
        BT_CreateCondition(WitchCond_IsEnraged),
        BT_CreateSequence(2,
            BT_CreateAction(WitchAct_ChaseTarget),
            BT_CreateAction(WitchAct_MeleeAttack)
        )
    );

    // --- v3.2: Terrain-aware retreat ---
    // Narrow space: survivors too close → can't retreat, become aggressive
    int narrowThreatened = BT_CreateSequence(4,
        BT_CreateInverter(BT_CreateCondition(WitchCond_IsEnraged)),
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateCondition(WitchCond_SurvivorsTooClose),
        BT_CreateAction(WitchAct_ChaseTarget)   // move toward, not away
    );

    // Open/semi: survivors too close → retreat normally
    int openRetreatSeq = BT_CreateSequence(4,
        BT_CreateInverter(BT_CreateCondition(WitchCond_IsEnraged)),
        BT_CreateInverter(BT_CreateCondition(CND_IsNarrowSpace)),
        BT_CreateCondition(WitchCond_SurvivorsTooClose),
        BT_CreateAction(WitchAct_Retreat)
    );

    // Branch 3: Default idle (sit in place)
    int idleSeq = BT_CreateAction(WitchAct_Idle);

    // Root selector — when terrain=UNKNOWN:
    //   narrowThreatened fails (not narrow) → openRetreatSeq matches
    //   (NOT narrow = true) → if SurvivorsTooClose → retreat.
    //   If not too close → idle. Same as pre-v3.2 behavior (safe fallback).
    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, enragedSeq);
    BT_AddChild(root, narrowThreatened);   // 2. v3.2: narrow → aggressive
    BT_AddChild(root, openRetreatSeq);     // 3. ← FALLBACK (when not narrow, incl UNKNOWN)
    BT_AddChild(root, idleSeq);            // 4. ← FALLBACK: idle

    return root;
}

public Witch_OnModuleStart() {}
