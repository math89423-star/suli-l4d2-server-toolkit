// ============================================================================
// bt_jockey.inc — Jockey Behavior Tree
// ============================================================================
// Key behaviors preserved from v2.4:
//   - Alternating jump/leap cycle
//   - High-arc jumps (pitch up before jumping)
//   - Irregular cooldown (+-35% jitter)
//   - Lateral strafing during approach
//   - Target lowest-HP survivor during coordination
//   - Stumble bystanders (via jockey_ride event hook, unchanged)
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

    // Hop attack subtree
    int hopPreCond = BT_CreateSequence(3,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(700.0)
    );

    int hopAcquireTarget = BT_CreateAction(JockeyAct_AlternatingHop);  // handles the jump/leap cycle

    int hopWithCooldown = BT_CreateCooldown(2.0, hopAcquireTarget);

    int hopSeq = BT_CreateSequence(3,
        hopPreCond,
        BT_CreateAction(ACT_StrafeRandom),
        hopWithCooldown
    );

    // Approach: always strafe while closing in (avoids being headshot while running straight)
    int strafeApproach = BT_CreateSequence(2,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(ACT_StrafeMoveToTarget)
    );

    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, rideSeq);
    BT_AddChild(root, hopSeq);
    BT_AddChild(root, strafeApproach);
    BT_AddChild(root, BT_CreateAction(ACT_Wander));

    return root;
}

public Jockey_OnModuleStart() {
    SetConVarInt(FindConVar("z_jockey_leap_range"), 1000);
}
