// ============================================================================
// bt_spitter.inc — Spitter Behavior Tree (v3.2)
// ============================================================================
// v3.1: Post-spit behavior — 80% approach survivors (body-block/distract),
//       20% retreat. No longer suicides after spitting.
// Key behaviors preserved from v2.4:
//   - Combo targeting: pinned survivors > boomed survivors
//   - Snap aim to best target
// v3.2 terrain-aware additions:
//   - Narrow corridor: spit to block passage (area denial — survivors must wait or take damage)
//   - Open area: prediction spit toward escape route (cut off retreat)
//   - Near ledge: spit toward safe side to push survivors toward edge
// ============================================================================

#if defined _bt_spitter_included
  #endinput
#endif
#define _bt_spitter_included


// ---------------------------------------------------------------------------
// Post-spit state conditions
// ---------------------------------------------------------------------------

BT_Status SpitterCnd_HasSpit(int client) {
    // v3.2 FIX: use timestamp so Spitter can re-spit after cooldown (8s).
    // Previously _spitter_spit was a permanent flag that never reset,
    // turning the Spitter into a melee-only bot after its first spit.
    float spitTime = BB_GetFloat(client, "_spitter_spit_time", 0.0);
    if (spitTime <= 0.0) return BT_FAILURE;
    if (GetGameTime() - spitTime > 8.0) {
        BB_SetFloat(client, "_spitter_spit_time", 0.0);
        BB_SetBool(client, "_spitter_approach", false);
        return BT_FAILURE;
    }
    return BT_SUCCESS;
}

BT_Status SpitterCnd_PostSpitApproach(int client) {
    return BB_GetBool(client, "_spitter_approach", false) ? BT_SUCCESS : BT_FAILURE;
}

// ---------------------------------------------------------------------------
// Target acquisition
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Spit action — also decides post-spit behavior (80% approach / 20% retreat)
// ---------------------------------------------------------------------------

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

    // Decide post-spit behavior once at spit time
    // 80% approach (body-block/distract), 20% retreat
    bool approach = (GetRandomFloat(0.0, 1.0) < 0.8);
    BB_SetBool(client, "_spitter_approach", approach);
    BB_SetFloat(client, "_spitter_spit_time", GetGameTime());  // v3.2 FIX: timestamp, not permanent flag

    return BT_SUCCESS;
}

// ============================================================================
// Tree builder
// ============================================================================

stock int BT_CreateSpitterTree() {
    // --- v3.2: Terrain-aware spit strategies ---
    // Narrow corridor: spit toward center to block passage entirely
    int narrowBlockSpit = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(900.0),              // long-range area denial
        BT_CreateAction(SpitterAct_Spit)
    );

    // Open area: spit toward escape route (predict survivor movement)
    int openPredictSpit = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(800.0),
        BT_CreateAction(SpitterAct_Spit)
    );

    // --- Post-spit behavior: approach (80%) or retreat (20%) ---
    int postSpitApproach = BT_CreateSequence(3,
        BT_CreateCondition(SpitterCnd_PostSpitApproach),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(ACT_StrafeMoveToTarget)
    );

    int postSpitRetreat = BT_CreateAction(ACT_Retreat);

    int postSpitSelector = BT_Create(BTN_SELECTOR);
    BT_AddChild(postSpitSelector, postSpitApproach);
    BT_AddChild(postSpitSelector, postSpitRetreat);

    int postSpitSeq = BT_CreateSequence(2,
        BT_CreateCondition(SpitterCnd_HasSpit),
        postSpitSelector
    );

    // --- Spit on pinned survivors (combo damage) ---
    // v3.4 FIX: added CND_HasLOS + IsInRange — without these, Spitter would
    // spit toward pinned survivors through walls from across the map.
    int spitOnPinned = BT_CreateSequence(5,
        BT_CreateCondition(CND_AnySurvivorPinned),
        BT_CreateAction(SpitterAct_FindPinnedTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(900.0),
        BT_CreateAction(SpitterAct_Spit)
    );

    // --- Spit on boomed survivors ---
    // v3.4 FIX: added CND_HasLOS + IsInRange (same rationale as spitOnPinned).
    int spitOnBoomed = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsBoomerActive),
        BT_CreateAction(SpitterAct_FindBoomedTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(900.0),
        BT_CreateAction(SpitterAct_Spit)
    );

    // --- Default: find any target, check LOS, then spit ---
    // v3.2 FIX: added CND_HasLOS — without it, Spitter would spit toward the
    // closest survivor even when a wall was in the way, wasting the ability.
    int defaultSpit = BT_CreateSequence(3,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateAction(SpitterAct_Spit)
    );

    // Root selector — terrain branches (3-4) fail when disabled/unknown
    // → falls through to default spit (5).
    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, postSpitSeq);
    BT_AddChild(root, spitOnPinned);           // 1. combo: spit on pinned
    BT_AddChild(root, spitOnBoomed);           // 2. combo: spit on boomed
    BT_AddChild(root, narrowBlockSpit);        // 3. v3.2: narrow → area denial
    BT_AddChild(root, openPredictSpit);        // 4. v3.2: open → prediction
    BT_AddChild(root, defaultSpit);            // 5. ← FALLBACK: default spit
    BT_AddChild(root, BT_CreateAction(ACT_Wander));

    return root;
}

public Spitter_OnModuleStart() {
    // No game cvar tuning needed for Spitter.
    // (z_spit_damage_interrupt does not exist in L4D2 — removed)
}
