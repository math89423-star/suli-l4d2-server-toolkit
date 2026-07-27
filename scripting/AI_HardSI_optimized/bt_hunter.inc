// ============================================================================
// bt_hunter.inc — Hunter Behavior Tree (v3.2)
// ============================================================================
// Replaces the old AI_Hunter.sp flat logic with a BT-driven decision tree.
// Key behaviors preserved from v2.4:
//   - Zigzag strafe while crouched
//   - High-pounce positioning (climb to elevated ledges)
//   - Fast pouncing with cooldown
//   - Avoid dogpiling pinned survivors
//   - Missed-pounce escape jump
//   - Gaussian-angle pounce (via ability_use event hook, unchanged)
//   - Fake direction (via ability_use event hook, unchanged)
//   - Wall detection (via ability_use event hook, unchanged)
// v3.2 terrain-aware additions:
//   - Narrow corridor: wall-bounce pounce (un-dodgeable in tight spaces)
//   - Open area: flank approach → pounce from unexpected angles
//   - Semi-open (one wall): hug wall approach → use cover
// ============================================================================

#if defined _bt_hunter_included
  #endinput
#endif
#define _bt_hunter_included

// ---------------------------------------------------------------------------
// Hunter-specific state (shared with main plugin via extern)
// ---------------------------------------------------------------------------

bool g_bHunterJustLunged[MAXPLAYERS + 1];
float g_fHunterMissEscapeCooldown[MAXPLAYERS + 1];

// Forward declarations for tree builder

// ---------------------------------------------------------------------------
// Hunter tree builder — called once in OnPluginStart
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// Hunter-specific callbacks
// ---------------------------------------------------------------------------

// Condition: Hunter just missed a pounce and is on the ground
BT_Status HunterCond_JustMissed(int client) {
    if (!g_bHunterJustLunged[client]) return BT_FAILURE;
    if (!(GetEntityFlags(client) & FL_ONGROUND)) return BT_FAILURE;

    // Check if there's a pounce victim (successful pounce)
    int victim = GetEntPropEnt(client, Prop_Send, "m_pounceVictim");
    if (victim > 0) {
        g_bHunterJustLunged[client] = false;  // clear flag on success
        return BT_FAILURE;
    }

    // Check cooldown on escape (don't spam escape jumps)
    float now = GetGameTime();
    if (g_fHunterMissEscapeCooldown[client] > now) return BT_FAILURE;

    return BT_SUCCESS;
}

// Action: Jump away in random direction after missed pounce
BT_Status HunterAct_EscapeJump(int client) {
    float ang[3];
    GetClientEyeAngles(client, ang);
    ang[1] += GetRandomFloat(60.0, 120.0) * (GetRandomInt(0, 1) ? 1.0 : -1.0);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_JUMP);
    g_bHunterJustLunged[client] = false;
    g_fHunterMissEscapeCooldown[client] = GetGameTime() + 3.0;
    return BT_SUCCESS;
}

// Condition: Is there elevated ground within 120 units above the hunter?
BT_Status HunterCond_HasHighGround(int client) {
    float hunterPos[3];
    GetClientAbsOrigin(client, hunterPos);

    // Trace from 120 units above down to find ground
    float upCheck[3];
    upCheck[0] = hunterPos[0];
    upCheck[1] = hunterPos[1];
    upCheck[2] = hunterPos[2] + 120.0;

    float downCheck[3];
    downCheck[0] = upCheck[0];
    downCheck[1] = upCheck[1];
    downCheck[2] = upCheck[2] - 200.0;

    TR_TraceRayFilter(upCheck, downCheck, MASK_PLAYERSOLID, RayType_EndPoint, TracerayFilter, client);
    if (!TR_DidHit()) return BT_FAILURE;

    float groundPos[3];
    TR_GetEndPosition(groundPos);

    // Ground must be 40-200 units above hunter
    float dz = groundPos[2] - hunterPos[2];
    return (dz > 40.0 && dz < 200.0) ? BT_SUCCESS : BT_FAILURE;
}

// Action: Jump up to an elevated position
BT_Status HunterAct_ClimbHighGround(int client) {
    float hunterPos[3];
    GetClientAbsOrigin(client, hunterPos);

    // Find where the high ground is (re-trace)
    float upCheck[3];
    upCheck[0] = hunterPos[0];
    upCheck[1] = hunterPos[1];
    upCheck[2] = hunterPos[2] + 120.0;

    float downCheck[3];
    downCheck[0] = upCheck[0];
    downCheck[1] = upCheck[1];
    downCheck[2] = upCheck[2] - 200.0;

    TR_TraceRayFilter(upCheck, downCheck, MASK_PLAYERSOLID, RayType_EndPoint, TracerayFilter, client);
    if (!TR_DidHit()) return BT_FAILURE;

    float groundPos[3];
    TR_GetEndPosition(groundPos);

    // Face the elevated position and jump
    float dir[3], ang[3];
    MakeVectorFromPoints(hunterPos, groundPos, dir);
    GetVectorAngles(dir, ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_JUMP);
    return BT_SUCCESS;
}

// Condition: Is there a wall too close ahead?
BT_Status HunterCond_WallAhead(int client) {
    int wallDist = GetConVarInt(FindConVar("ai_wall_detection_distance"));
    if (wallDist <= 0) return BT_FAILURE;

    float hunterPos[3], hunterAng[3];
    GetClientAbsOrigin(client, hunterPos);
    GetClientEyeAngles(client, hunterAng);

    TR_TraceRayFilter(hunterPos, hunterAng, MASK_PLAYERSOLID, RayType_Infinite, TracerayFilter, client);
    float impactPos[3];
    TR_GetEndPosition(impactPos);

    return (GetVectorDistance(hunterPos, impactPos) < float(wallDist)) ? BT_SUCCESS : BT_FAILURE;
}

// Action: Briefly face away from target (fake direction)
BT_Status HunterAct_FakeDirection(int client) {
    float ang[3];
    GetClientEyeAngles(client, ang);
    ang[1] += GetRandomFloat(25.0, 40.0) * (GetRandomInt(0, 1) ? 1.0 : -1.0);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    return BT_SUCCESS;
}
stock int BT_CreateHunterTree() {
    // --- Leaf nodes ---
    int missEscSeq = BT_CreateSequence(2,
        BT_CreateCondition(HunterCond_JustMissed),
        BT_CreateAction(HunterAct_EscapeJump)
    );

    // v3.2 FIX: Added HasHighGround check so Hunter only climbs when there is
    // actually elevated ground above. Without it, 35% of crouched ticks trace-hit
    // the ground at Hunter's feet and jump uselessly (原地跳跃).
    int highPounceSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateCondition(HunterCond_HasHighGround),
        BT_CreateSequence(2,
            BT_CreateRandomChance(0.35),
            BT_CreateAction(HunterAct_ClimbHighGround)
        )
    );

    // --- v3.2: Terrain-aware pounce strategies ---
    // Narrow corridor: wall-bounce pounce — aim forward + ATTACK
    // In tight spaces, survivors can't dodge → just pounce straight
    int narrowPounceSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(800.0)  // longer range in corridors
    );
    int narrowAttackSeq = BT_CreateSequence(3,
        BT_CreateAction(ACT_SnapAimToTarget),
        BT_CreateAction(ACT_QueueLunge),
        BT_CreateAction(ACT_SignalAttack)
    );
    BT_AddChild(narrowPounceSeq, narrowAttackSeq);

    // Open area: flank approach → get off-angle for unpredictable pounce
    int openApproachSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateInverter(BT_CreateIsInRange(500.0))  // keep distance while flanking
    );
    int openFlankAction = BT_CreateSequence(3,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(ACT_Crouch),             // duck first (before RUNNING blocks it)
        BT_CreateAction(ACT_FlankApproach)       // 60° offset approach (RUNNING, last)
    );
    BT_AddChild(openApproachSeq, openFlankAction);

    // Semi-open / one wall: hug wall for cover while approaching
    int semiApproachSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateCondition(CND_IsSemiOpen),
        BT_CreateInverter(BT_CreateCondition(CND_HasLOS))
    );
    int semiHugAction = BT_CreateSequence(3,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(ACT_Crouch),             // duck first (before RUNNING blocks it)
        BT_CreateAction(ACT_HugWall)             // move along wall (RUNNING, last)
    );
    BT_AddChild(semiApproachSeq, semiHugAction);

    // --- Standard fast pounce (unchanged from v2.4) ---
    int fastPounceSeq = BT_CreateSequence(2,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking)
    );

    int pounceInnerSeq = BT_CreateSequence(3,
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(1000.0),
        BT_CreateInverter(BT_CreateCondition(CND_IsTargetPinned))
    );

    // v3.2 FIX: StrafeRandom returns BT_RUNNING and blocked SnapAim+QueueLunge
    // in the sequence, so Hunter never pressed IN_ATTACK (只会原地横移不扑).
    // Strafe happens during approach phases, not inside the attack execution.
    // v3.2 FIX: Added GaussianAimOffset for unpredictable pounce angles.
    // Without it, SnapAimToTarget always aims directly at target (只会往前扑).
    // Sum-of-3-uniforms approximates Gaussian with ~15° std dev spread.
    int attackActionSeq = BT_CreateSequence(3,
        BT_CreateAction(ACT_SnapAimToTarget),
        BT_CreateAction(ACT_GaussianAimOffset),
        BT_CreateAction(ACT_QueueLunge)
    );

    int cooldownAttack = BT_CreateCooldown(1.0, attackActionSeq);
    int signalCoord = BT_CreateAction(ACT_SignalAttack);

    // Approach: erratic zigzag + forward movement at ±30° random offset.
    // ErraticApproach replaces StrafeMoveToTarget — the straight-line approach
    // looked like "缓慢爬行" (slow crawling) and was too predictable.
    int approachSeq = BT_CreateSequence(2,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(ACT_ErraticApproach)
    );

    int crouchSeq = BT_CreateSequence(1,
        BT_CreateAction(ACT_Crouch)
    );

    // Crouch approach (when in range but no LOS yet)
    // v3.2 FIX: Acquire target first, then strafe (StrafeRandom RUNNING no longer blocks)
    int crouchApproachSeq = BT_CreateSequence(3,
        BT_CreateCondition(CND_OnGround),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(ACT_StrafeRandom)
    );

    int wander = BT_CreateAction(ACT_Wander);

    // --- Build main tree ---
    BT_AddChild(fastPounceSeq, pounceInnerSeq);
    BT_AddChild(fastPounceSeq, cooldownAttack);
    BT_AddChild(fastPounceSeq, signalCoord);

    // v3.2 FIX: Crouch BEFORE approach so FL_DUCKING is set for pounce check.
    // Previously approachSeq (StrafeMoveToTarget=RUNNING) blocked crouchSeq.
    int approachFull = BT_Create(BTN_SEQUENCE);
    BT_AddChild(approachFull, crouchSeq);
    BT_AddChild(approachFull, approachSeq);

    // Root selector — terrain-aware branches take priority over generic fallbacks.
    // FALLBACK: when ai_terrain_enable=0 or terrain=UNKNOWN, all v3.2 branches
    // (3/4/5) return FAIL → selector falls through to standard behavior (6-9).
    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, missEscSeq);         // 1. escape after miss
    BT_AddChild(root, highPounceSeq);      // 2. high-ground positioning
    BT_AddChild(root, narrowPounceSeq);    // 3. v3.2: narrow → straight pounce
    BT_AddChild(root, openApproachSeq);    // 4. v3.2: open → flank approach
    BT_AddChild(root, semiApproachSeq);    // 5. v3.2: semi → hug wall
    BT_AddChild(root, fastPounceSeq);      // 6. ← FALLBACK: standard fast pounce
    BT_AddChild(root, approachFull);       // 7. ← FALLBACK: approach → crouch
    BT_AddChild(root, crouchApproachSeq);  // 8. ← FALLBACK: crouch approach
    BT_AddChild(root, wander);             // 9. ← FALLBACK: wander

    return root;
}

// Module init — register cvars
public Hunter_OnModuleStart() {
    SetConVarInt(FindConVar("hunter_committed_attack_range"), 10000);
    SetConVarInt(FindConVar("hunter_pounce_ready_range"), 500);
    SetConVarInt(FindConVar("hunter_leap_away_give_up_range"), 0);
    SetConVarInt(FindConVar("hunter_pounce_max_loft_angle"), 0);
}
