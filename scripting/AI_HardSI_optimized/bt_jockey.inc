// ============================================================================
// bt_jockey.inc — Jockey Behavior Tree (v3.2)
// ============================================================================
// Key behaviors preserved from v2.4:
//   - Alternating jump/leap cycle
//   - High-arc jumps (pitch up before jumping)
//   - Irregular cooldown (+-35% jitter)
//   - Lateral strafing during approach
//   - Target lowest-HP survivor during coordination
//   - Stumble bystanders (via jockey_ride event hook, unchanged)
// v3.2 terrain-aware additions:
//   - Narrow corridor: approach along wall → leap from cover
//   - Open area: flank leap → ride survivor away from team
//   - Near ledge: ride survivor toward cliff/ledge
// ============================================================================

#if defined _bt_jockey_included
  #endinput
#endif
#define _bt_jockey_included



// Alternating hop: normal jump ↔ leap attack
BT_Status JockeyAct_AlternatingHop(int client) {
    // Choose between normal jump and leap attack
    // Blackboard tracks: "jockey_next_is_jump" (bool toggle)
    bool doJump = BB_GetBool(client, "jockey_next_is_jump", false);

    // 15% chance: double leap (skip normal jump)
    bool doubleLeap = (GetRandomFloat(0.0, 1.0) < 0.15);

    if (doJump && !doubleLeap) {
        // High arc normal jump
        float eyeAng[3];
        GetClientEyeAngles(client, eyeAng);
        eyeAng[0] = -1.0 * GetRandomFloat(15.0, 30.0);  // pitch up
        BT_SetAimAngles(client, eyeAng[0], eyeAng[1], eyeAng[2]);
        BT_AddButton(client, IN_JUMP);
        BB_SetBool(client, "jockey_next_is_jump", false);
    } else {
        // Leap attack
        BT_AddButton(client, IN_ATTACK);
        BB_SetBool(client, "jockey_next_is_jump", !doubleLeap);
        SI_SignalAttack(client);
    }
    return BT_SUCCESS;
}
stock int BT_CreateJockeyTree() {
    // Riding — just maintain
    int rideSeq = BT_CreateSequence(2,
        BT_CreateCondition(CND_IsPinningSurvivor),
        BT_CreateAction(ACT_HoldVictim)
    );

    // --- v3.2: Terrain-aware leap strategies ---
    // Narrow: hug wall approach → leap from cover
    int narrowLeapSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(600.0),
        BT_CreateAction(ACT_HugWall)
    );

    // Open area: flank approach → leap from unexpected angle
    int openFlankSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(800.0),
        BT_CreateAction(ACT_FlankApproach)
    );

    // Ledge: approach survivor who is near edge → ride them off
    int ledgeRideSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsNearLedge),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(500.0),
        BT_CreateAction(ACT_FlankApproach)
    );

    // --- Standard hop attack ---
    int hopPreCond = BT_CreateSequence(3,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(700.0)
    );

    int hopAcquireTarget = BT_CreateAction(JockeyAct_AlternatingHop);
    int hopWithCooldown = BT_CreateCooldown(2.0, hopAcquireTarget);

    // v3.2 FIX: StrafeRandom RUNNING blocked hopWithCooldown (same bug as Hunter)
    // Strafe is now handled by strafeApproach, not inside the hop attack sequence.
    int hopSeq = BT_CreateSequence(2,
        hopPreCond,
        hopWithCooldown
    );

    // Approach: always strafe while closing in
    int strafeApproach = BT_CreateSequence(2,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(ACT_StrafeMoveToTarget)
    );

    // Root selector — terrain branches (2-4) fail when disabled/unknown
    // → falls through to standard hop (5) and approach (6-7).
    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, rideSeq);
    BT_AddChild(root, ledgeRideSeq);        // 2. v3.2: ledge → flank + leap
    BT_AddChild(root, narrowLeapSeq);       // 3. v3.2: narrow → hug wall
    BT_AddChild(root, openFlankSeq);        // 4. v3.2: open → flank
    BT_AddChild(root, hopSeq);              // 5. ← FALLBACK: standard hop
    BT_AddChild(root, strafeApproach);      // 6. ← FALLBACK: approach
    BT_AddChild(root, BT_CreateAction(ACT_Wander));

    return root;
}

public Jockey_OnModuleStart() {
    SetConVarInt(FindConVar("z_jockey_leap_range"), 1000);
}
