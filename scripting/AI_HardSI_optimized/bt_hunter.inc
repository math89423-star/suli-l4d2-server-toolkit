// ============================================================================
// bt_hunter.inc — Hunter Behavior Tree (v3.3)
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
// v3.3 sprint-pounce flow (2026-07-28):
//   - FIX: Hunter no longer crouches at long range → runs full speed instead
//   - FIX: crouchApproachSeq now includes FORWARD movement (was only lateral strafe)
//   - ADDED: Sprint approach — RUNNING (no crouch) toward target when > pounce range
//   - ADDED: Transition crouch — enter pounce range → duck immediately
//   - ADDED: Direct close-range pounce (≤ straight_pounce_proximity, no Gauss offset)
//   - CHANGED: pounce ranges now read ai_fast_pounce_proximity / ai_straight_pounce_proximity
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

// ============================================================================
// v3.3 NEW ACTIONS: sprint approach + crouch approach
// ============================================================================

// Action: Sprint toward target at FULL speed (NO crouch) with erratic zigzag.
// Unlike ACT_ErraticApproach, this REMOVES IN_DUCK to guarantee running speed.
// Used when Hunter is beyond pounce range and needs to close distance fast.
BT_Status HunterAct_SprintApproach(int client) {
    // Strafe component — change direction every 0.3-0.8s
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

    // Forward movement at ±30° random offset from target direction
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        ang[1] += GetRandomFloat(-30.0, 30.0);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    BT_AddButton(client, IN_FORWARD);

    // CRITICAL: Ensure NOT ducking — sprint at full running speed.
    // The old approachFull forced crouch BEFORE approach, causing slow crawl.
    BT_RemoveButton(client, IN_DUCK);

    return BT_RUNNING;
}

// Action: Crouched approach with forward movement toward target + lateral strafe.
// Fixes the old crouchApproachSeq bug: it used ACT_StrafeRandom which only
// pressed IN_MOVELEFT/IN_MOVERIGHT with NO forward movement at all.
// The Hunter was literally strafing in place without closing distance.
BT_Status HunterAct_CrouchApproach(int client) {
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }

    // Lateral strafe — change direction every 0.5-1.2s
    float now = GetGameTime();
    float nextSwitch = BB_GetFloat(client, "_strafe_next");
    if (nextSwitch <= 0.0 || now >= nextSwitch) {
        bool goLeft = (GetRandomInt(0, 1) == 0);
        BB_SetBool(client, "_strafe_left", goLeft);
        BB_SetFloat(client, "_strafe_next", now + GetRandomFloat(0.5, 1.2));
    }
    if (BB_GetBool(client, "_strafe_left", false)) {
        BT_AddButton(client, IN_MOVELEFT);
    } else {
        BT_AddButton(client, IN_MOVERIGHT);
    }

    // Move forward toward target (crouched) + stay ducked
    BT_AddButton(client, IN_FORWARD);
    BT_AddButton(client, IN_DUCK);

    return BT_RUNNING;
}

// ============================================================================
// Tree builder
// ============================================================================

stock int BT_CreateHunterTree() {
    // --- Read pounce-range cvars (fall back to safe defaults) ---
    float fPounceRange = 1000.0;
    float fStraightRange = 200.0;
    ConVar hCvar = FindConVar("ai_fast_pounce_proximity");
    if (hCvar != null) fPounceRange = GetConVarFloat(hCvar);
    hCvar = FindConVar("ai_straight_pounce_proximity");
    if (hCvar != null) fStraightRange = GetConVarFloat(hCvar);

    // --- Leaf nodes ---
    int missEscSeq = BT_CreateSequence(2,
        BT_CreateCondition(HunterCond_JustMissed),
        BT_CreateAction(HunterAct_EscapeJump)
    );

    // v3.2: HasHighGround check so Hunter only climbs when there is
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

    // --- Standard fast pounce ---
    int fastPounceSeq = BT_CreateSequence(2,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking)
    );

    int pounceInnerSeq = BT_CreateSequence(3,
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(fPounceRange),
        BT_CreateInverter(BT_CreateCondition(CND_IsTargetPinned))
    );

    // v3.2: GaussianAimOffset for unpredictable pounce angles.
    // Sum-of-3-uniforms approximates Gaussian with ~15° std dev spread.
    int attackActionSeq = BT_CreateSequence(3,
        BT_CreateAction(ACT_SnapAimToTarget),
        BT_CreateAction(ACT_GaussianAimOffset),
        BT_CreateAction(ACT_QueueLunge)
    );

    int cooldownAttack = BT_CreateCooldown(1.0, attackActionSeq);
    int signalCoord = BT_CreateAction(ACT_SignalAttack);

    // --- v3.3: Close-range direct pounce (no Gauss offset, faster reaction) ---
    int closePounceSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(fStraightRange),
        BT_CreateInverter(BT_CreateCondition(CND_IsTargetPinned))
    );
    int closeAttackSeq = BT_CreateSequence(2,
        BT_CreateAction(ACT_SnapAimToTarget),
        BT_CreateAction(ACT_QueueLunge)
    );
    BT_AddChild(closePounceSeq, closeAttackSeq);

    // --- v3.3: Sprint approach — RUN full speed when far from target ---
    // Replaces the old approachFull which forced crouch BEFORE running.
    // Crouching cuts movement speed by ~50%, making Hunter crawl slowly.
    // This branch only fires when: OnGround + NOT ducking + > pounce range.
    int sprintApproachSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_OnGround),
        BT_CreateInverter(BT_CreateCondition(CND_IsDucking)),
        BT_CreateInverter(BT_CreateIsInRange(fPounceRange)),
        BT_CreateSequence(2,
            BT_CreateAction(ACT_AcquireClosestTarget),
            BT_CreateAction(HunterAct_SprintApproach)
        )
    );

    // --- v3.3: Transition crouch — enter pounce range → crouch immediately ---
    // When the sprint approach brings Hunter within pounce range, this branch
    // fires on the next tick: crouch now. The tick after that, fastPounceSeq
    // triggers the actual pounce. Natural sprint→crouch→pounce flow.
    int crouchPrepSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_OnGround),
        BT_CreateInverter(BT_CreateCondition(CND_IsDucking)),
        BT_CreateIsInRange(fPounceRange),
        BT_CreateCondition(CND_HasLOS)
    );
    int crouchPrepAction = BT_CreateSequence(1,
        BT_CreateAction(ACT_Crouch)
    );
    BT_AddChild(crouchPrepSeq, crouchPrepAction);

    // --- v3.3: Fixed crouch approach (in range + ducking + no LOS) ---
    // Uses HunterAct_CrouchApproach which moves FORWARD while strafing.
    // Old version used ACT_StrafeRandom which only did lateral movement.
    int crouchApproachSeq = BT_CreateSequence(3,
        BT_CreateCondition(CND_OnGround),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(HunterAct_CrouchApproach)
    );

    int wander = BT_CreateAction(ACT_Wander);

    // --- Build main tree ---
    BT_AddChild(fastPounceSeq, pounceInnerSeq);
    BT_AddChild(fastPounceSeq, cooldownAttack);
    BT_AddChild(fastPounceSeq, signalCoord);

    // Root selector — priority order:
    //   1. Escape after miss (safety first)
    //   2. High-ground positioning (tactical advantage)
    //   3. Narrow corridor → straight pounce
    //   4. Open area → flank approach
    //   5. Semi open → hug wall approach
    //   6. Close range (≤200) → direct pounce (no Gauss, faster) [v3.3]
    //   7. Standard fast pounce (ducking + LOS + inRange → pounce with Gauss)
    //   8. In range + not ducking → crouch to prepare pounce [v3.3]
    //   9. Far away → SPRINT full speed toward target [v3.3]
    //   10. In range + ducking + no LOS → crouch approach with forward movement [v3.3]
    //   11. Last resort → wander
    //
    // The sprint→crouch→pounce flow (8→7 or 9→8→7):
    //   Tick N:   Hunter far away → branch 9 (sprint) activates, runs toward target
    //   Tick N+1: Entered pounce range → branch 8 (crouchPrep) fires, presses DUCK
    //   Tick N+2: FL_DUCKING set → branch 7 (fastPounce) fires, POUNCES!
    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, missEscSeq);         // 1. escape after miss
    BT_AddChild(root, highPounceSeq);      // 2. high-ground positioning
    BT_AddChild(root, narrowPounceSeq);    // 3. v3.2: narrow → straight pounce
    BT_AddChild(root, openApproachSeq);    // 4. v3.2: open → flank approach
    BT_AddChild(root, semiApproachSeq);    // 5. v3.2: semi → hug wall
    BT_AddChild(root, closePounceSeq);     // 6. v3.3: close-range direct pounce
    BT_AddChild(root, fastPounceSeq);      // 7. standard fast pounce (Gauss angle)
    BT_AddChild(root, crouchPrepSeq);      // 8. v3.3: inRange + noDuck → crouch
    BT_AddChild(root, sprintApproachSeq);   // 9. v3.3: far away → SPRINT full speed
    BT_AddChild(root, crouchApproachSeq);  // 10. v3.3: inRange + ducking + noLOS → strafe+forward
    BT_AddChild(root, wander);             // 11. last resort

    return root;
}

// Module init — register cvars
public Hunter_OnModuleStart() {
    SetConVarInt(FindConVar("hunter_committed_attack_range"), 10000);
    SetConVarInt(FindConVar("hunter_pounce_ready_range"), 500);
    SetConVarInt(FindConVar("hunter_leap_away_give_up_range"), 0);
    SetConVarInt(FindConVar("hunter_pounce_max_loft_angle"), 0);
}
