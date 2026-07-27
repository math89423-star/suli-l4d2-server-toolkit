// ============================================================================
// bt_spitter.inc — Spitter Behavior Tree
// ============================================================================
// Key behaviors preserved from v2.4:
//   - Combo targeting: pinned survivors > boomed survivors
//   - Snap aim to best target
//   - Velocity-based prediction (future enhancement)
// ============================================================================

#if defined _bt_spitter_included
  #endinput
#endif
#define _bt_spitter_included



// Find closest pinned survivor and set as target
BT_Status SpitterAct_FindPinnedTarget(int client) {
    float spitterPos[3];
    GetClientAbsOrigin(client, spitterPos);
    int bestTarget = -1;
    float bestDist = -1.0;

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsSurvivor(i) || !IsPlayerAlive(i)) continue;
        if (!IsPinned(i)) continue;
        float survPos[3];
        GetClientAbsOrigin(i, survPos);
        float dist = GetVectorDistance(spitterPos, survPos);
        if (bestDist < 0.0 || dist < bestDist) {
            bestDist = dist;
            bestTarget = i;
        }
    }

    if (bestTarget > 0) {
        BB_SetInt(client, "target", bestTarget);
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}

// Find closest boomed survivor and set as target
BT_Status SpitterAct_FindBoomedTarget(int client) {
    if (!SI_IsBoomerActive()) return BT_FAILURE;

    float spitterPos[3];
    GetClientAbsOrigin(client, spitterPos);
    int bestTarget = -1;
    float bestDist = -1.0;

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsSurvivor(i) || !IsPlayerAlive(i)) continue;
        if (GetEntProp(i, Prop_Data, "m_hasBeenBoomed") <= 0) continue;
        float survPos[3];
        GetClientAbsOrigin(i, survPos);
        float dist = GetVectorDistance(spitterPos, survPos);
        if (bestDist < 0.0 || dist < bestDist) {
            bestDist = dist;
            bestTarget = i;
        }
    }

    if (bestTarget > 0) {
        BB_SetInt(client, "target", bestTarget);
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}

// Snap aim to target and press ATTACK (spit)
BT_Status SpitterAct_Spit(int client) {
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    BT_AddButton(client, IN_ATTACK);
    return BT_SUCCESS;
}
stock int BT_CreateSpitterTree() {
    // Priority 1: Spit on pinned survivors (combo damage)
    int spitOnPinned = BT_CreateSequence(3,
        BT_CreateCondition(CND_AnySurvivorPinned),
        BT_CreateAction(SpitterAct_FindPinnedTarget),
        BT_CreateAction(SpitterAct_Spit)
    );

    // Priority 2: Spit on boomed survivors
    int spitOnBoomed = BT_CreateSequence(3,
        BT_CreateCondition(CND_IsBoomerActive),
        BT_CreateAction(SpitterAct_FindBoomedTarget),
        BT_CreateAction(SpitterAct_Spit)
    );

    // Default: find any target and spit
    int defaultSpit = BT_CreateSequence(2,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(SpitterAct_Spit)
    );

    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, spitOnPinned);
    BT_AddChild(root, spitOnBoomed);
    BT_AddChild(root, defaultSpit);
    BT_AddChild(root, BT_CreateAction(ACT_Wander));

    return root;
}

public Spitter_OnModuleStart() {
    SetConVarInt(FindConVar("z_spit_damage_interrupt"), 200);
}
