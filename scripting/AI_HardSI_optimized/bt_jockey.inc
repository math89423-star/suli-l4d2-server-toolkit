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

    // --- v3.2 FIX: Terrain-aware leap strategies ---
    // Each terrain type is split into TWO branches:
    //   Approach (far):  terrain match + onGround + HasLOS + NOT inRange → move
    //   Attack  (close): terrain match + onGround + HasLOS + inRange → AlternatingHop
    // Previously these branches ended with RUNNING-type movement actions
    // (HugWall/FlankApproach), which blocked the hopSeq fallback forever.
    // Now the approach runs when far; when close, it fails (Inverter trips)
    // and the selector moves to the attack branch.

    // Ledge: approach (far) → flank
    int ledgeApproach = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsNearLedge),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateInverter(BT_CreateIsInRange(400.0)),   // still far
        BT_CreateAction(ACT_FlankApproach)
    );
    int ledgeLeap = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsNearLedge),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(400.0),                       // close enough
        BT_CreateCooldown(2.0, BT_CreateAction(JockeyAct_AlternatingHop))
    );

    // Narrow: approach (far) → hug wall
    int narrowApproach = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateInverter(BT_CreateIsInRange(350.0)),
        BT_CreateAction(ACT_HugWall)
    );
    int narrowLeap = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(350.0),
        BT_CreateCooldown(2.0, BT_CreateAction(JockeyAct_AlternatingHop))
    );

    // Open: approach (far) → flank
    int openApproach = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateInverter(BT_CreateIsInRange(400.0)),
        BT_CreateAction(ACT_FlankApproach)
    );
    int openLeap = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(400.0),
        BT_CreateCooldown(2.0, BT_CreateAction(JockeyAct_AlternatingHop))
    );

    // --- Standard hop attack ---
    int hopPreCond = BT_CreateSequence(3,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(700.0)
    );

    int hopAcquireTarget = BT_CreateAction(JockeyAct_AlternatingHop);
    int hopWithCooldown = BT_CreateCooldown(2.0, hopAcquireTarget);

    int hopSeq = BT_CreateSequence(2,
        hopPreCond,
        hopWithCooldown
    );

    // Approach: always strafe while closing in
    int strafeApproach = BT_CreateSequence(2,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(ACT_StrafeMoveToTarget)
    );

    // Root selector — terrain branches come in approach/attack pairs.
    // When disabled (ai_terrain_enable=0): all terrain conditions return FAIL
    // → falls through to standard hop (8) and approach (9-10).
    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, rideSeq);
    BT_AddChild(root, ledgeLeap);           // 2. v3.2: ledge → close → leap
    BT_AddChild(root, ledgeApproach);       // 3. v3.2: ledge → far → flank
    BT_AddChild(root, narrowLeap);          // 4. v3.2: narrow → close → leap
    BT_AddChild(root, narrowApproach);      // 5. v3.2: narrow → far → hug wall
    BT_AddChild(root, openLeap);            // 6. v3.2: open → close → leap
    BT_AddChild(root, openApproach);        // 7. v3.2: open → far → flank
    BT_AddChild(root, hopSeq);              // 8. ← FALLBACK: standard hop
    BT_AddChild(root, strafeApproach);      // 9. ← FALLBACK: approach
    BT_AddChild(root, BT_CreateAction(ACT_Wander));

    return root;
}

public Jockey_OnModuleStart() {
    SetConVarInt(FindConVar("z_jockey_leap_range"), 1000);
}
