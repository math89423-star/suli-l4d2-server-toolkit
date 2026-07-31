// ============================================================================
// bt_boomer.inc — Boomer Behavior Tree (v3.2)
// ============================================================================
// v3.1: Post-vomit behavior — 80% approach survivors (body-block, death-splode),
//       20% retreat. Fixed broken tree where ACT_AcquireClosestTarget always
//       succeeded and blocked vomitSeq from ever executing.
// Key behaviors preserved from v2.4:
//   - Flank approach (strafe when survivor is watching)
//   - Direct approach (charge straight when not watched)
//   - Vomit triggers coordination attack window
// v3.2 terrain-aware additions:
//   - Narrow corridor: hold chokepoint → vomit covers entire passage
//   - Open area: flank behind cover → vomit from unexpected angle
//   - Semi-open: hug wall → use corner for ambush vomit
// ============================================================================

#if defined _bt_boomer_included
  #endinput
#endif
#define _bt_boomer_included


// ---------------------------------------------------------------------------
// Post-vomit state conditions
// ---------------------------------------------------------------------------

BT_Status BoomerCnd_HasVomited(int client) {
    // v3.2 FIX: use timestamp so Boomer can re-vomit after cooldown (10s).
    // Previously _boomer_vomited was a permanent flag that never reset,
    // turning the Boomer into a melee-only bot after its first vomit.
    float vomitTime = BB_GetFloat(client, "_boomer_vomit_time", 0.0);
    if (vomitTime <= 0.0) return BT_FAILURE;
    if (GetGameTime() - vomitTime > 10.0) {
        BB_SetFloat(client, "_boomer_vomit_time", 0.0);
        BB_SetBool(client, "_boomer_approach", false);
        return BT_FAILURE;
    }
    return BT_SUCCESS;
}

BT_Status BoomerCnd_PostVomitApproach(int client) {
    return BB_GetBool(client, "_boomer_approach", false) ? BT_SUCCESS : BT_FAILURE;
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

// Flank or direct approach based on whether survivor is watching.
// Faces the blackboard "target" while approaching.
BT_Status BoomerAct_FlankApproach(int client) {
    // Face target
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }

    bool watched = IsTargetWatchingAttacker(client, 60);
    if (watched) {
        // Strafe to flank — harder to hit
        float now = GetGameTime();
        float nextSwitch = BB_GetFloat(client, "_boomer_flank_next");
        if (nextSwitch <= 0.0 || now >= nextSwitch) {
            BB_SetBool(client, "_boomer_flank_left",
                !BB_GetBool(client, "_boomer_flank_left", false));
            BB_SetFloat(client, "_boomer_flank_next",
                now + GetRandomFloat(0.4, 0.7));
        }
        if (BB_GetBool(client, "_boomer_flank_left", false)) {
            BT_AddButton(client, IN_MOVELEFT);
            BT_RemoveButton(client, IN_MOVERIGHT);
        } else {
            BT_AddButton(client, IN_MOVERIGHT);
            BT_RemoveButton(client, IN_MOVELEFT);
        }
    } else {
        // Direct approach — clear flank state
        BB_SetFloat(client, "_boomer_flank_next", 0.0);
    }
    BT_AddButton(client, IN_FORWARD);
    return BT_RUNNING;
}

// Vomit on target + decide post-vomit behavior (80% approach / 20% retreat)
BT_Status BoomerAct_Vomit(int client) {
    // Aim at target
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }

    BT_AddButton(client, IN_ATTACK);  // vomit
    // v3.2 FIX: removed SI_SignalBoomerHit() from here — the OnPlayerBoomed
    // event hook already fires when vomit actually hits a survivor, so calling
    // it here caused double coordination triggers (on-press + on-hit).

    // Decide post-vomit behavior once
    bool approach = (GetRandomFloat(0.0, 1.0) < 0.8);
    BB_SetBool(client, "_boomer_approach", approach);
    BB_SetFloat(client, "_boomer_vomit_time", GetGameTime());  // v3.2 FIX: timestamp, not permanent flag

    return BT_SUCCESS;
}

// ============================================================================
// Tree builder
// ============================================================================

stock int BT_CreateBoomerTree() {
    // ==========================================
    // v4.0: 伏击等待 —— narrow 地形不冲脸，原地隐藏等目标进 300u 再吐。
    // 真人 Boomer 会提前预判队伍行进路线，藏在必经之路上。
    // 目标 < 300u 时本分支 FAIL → 落到 narrowHoldVomit/vomitSeq 吐。
    // ==========================================
    int ambushSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateIsNotInRange(300.0),
        BT_CreateAction(ACT_AmbushHold)
    );

    // ==========================================
    // v4.0: 暗影锁链 (mode 1) —— 吐被拉的人（解救时全家被喷）
    // Smoker 拉中 → 窗口 → Boomer 吐被拉者：救他的人挤成一团全被喷
    // ==========================================
    int mode1Vomit = BT_CreateSequence(5,
        BT_CreateIsMode(1),
        BT_CreateCondition(CND_IsAttackWindow),
        BT_CreateAction(ACT_AcquirePinTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(350.0),
        BT_CreateAction(BoomerAct_Vomit)
    );

    // --- v3.2: Terrain-aware vomit strategies ---
    // Narrow corridor: hold chokepoint → vomit to cover entire passage
    int narrowHoldVomit = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(350.0),
        BT_CreateAction(ACT_HoldChokepoint),
        BT_CreateAction(BoomerAct_Vomit)
    );

    // v3.2 FIX: Split into approach + vomit branches.
    // Previously FlankApproach(RUNNING) blocked BoomerAct_Vomit in the sequence.
    // ==========================================
    // v3.5: Open terrain — 2-way random + extended range (550u)
    // ==========================================
    int openStrategyRoll = BT_CreateSequence(2,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateRollStrategy(2)
    );
    // Strat 0: Flank vomit — circle around → vomit from side
    int openS0_Approach = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(0),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateIsNotInRange(550.0),
        BT_CreateAction(ACT_FlankApproach)
    );
    int openS0_Vomit = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(0),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(550.0),
        BT_CreateAction(BoomerAct_Vomit)
    );
    // Strat 1: Erratic vomit — zigzag approach → vomit from varied angle
    int openS1_Approach = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(1),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateIsNotInRange(500.0),
        BT_CreateAction(ACT_ErraticApproach)
    );
    int openS1_Vomit = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(1),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(500.0),
        BT_CreateAction(BoomerAct_Vomit)
    );

    // v3.2 FIX: Split into approach + vomit branches.
    // Previously HugWall(RUNNING) blocked BoomerAct_Vomit in the sequence.
    // Semi-open: hug wall approach while far from target
    int semiHugApproach = BT_CreateSequence(4,
        BT_CreateCondition(CND_IsSemiOpen),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateInverter(BT_CreateIsInRange(350.0)),
        BT_CreateAction(ACT_HugWall)
    );
    // Semi-open: vomit from cover when in range
    int semiHugVomit = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsSemiOpen),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(350.0),
        BT_CreateAction(BoomerAct_Vomit)
    );

    // --- Post-vomit behavior: 80% approach / 20% retreat ---
    int postVomitApproach = BT_CreateSequence(3,
        BT_CreateCondition(BoomerCnd_PostVomitApproach),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(ACT_StrafeMoveToTarget)
    );

    int postVomitRetreat = BT_CreateAction(ACT_Retreat);

    int postVomitSelector = BT_Create(BTN_SELECTOR);
    BT_AddChild(postVomitSelector, postVomitApproach);
    BT_AddChild(postVomitSelector, postVomitRetreat);

    int postVomitSeq = BT_CreateSequence(2,
        BT_CreateCondition(BoomerCnd_HasVomited),
        postVomitSelector
    );

    // --- Vomit attack: in range + LOS → vomit ---
    int vomitSeq = BT_CreateSequence(4,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(300.0),
        BT_CreateAction(BoomerAct_Vomit)
    );

    // --- Approach: get in range for vomit ---
    int approachSeq = BT_CreateSequence(2,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(BoomerAct_FlankApproach)
    );

    // Root selector — terrain branches fail when disabled → fallback to standard.
    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, postVomitSeq);
    BT_AddChild(root, ambushSeq);          // 1.5. v4.0: narrow → 伏击等待
    BT_AddChild(root, mode1Vomit);         // 1.5. v4.0: mode 1 → 吐被拉者
    BT_AddChild(root, narrowHoldVomit);    // 2. v3.2: narrow → block + vomit
    BT_AddChild(root, openStrategyRoll);   // 3a. v3.5: open → roll token
    BT_AddChild(root, openS0_Vomit);       // 3b. v3.5: open strat0 → flank vomit
    BT_AddChild(root, openS0_Approach);    // 3c. v3.5: open strat0 → flank approach
    BT_AddChild(root, openS1_Vomit);       // 4a. v3.5: open strat1 → erratic vomit
    BT_AddChild(root, openS1_Approach);    // 4b. v3.5: open strat1 → erratic approach
    BT_AddChild(root, semiHugVomit);       // 5. v3.2: semi → vomit
    BT_AddChild(root, semiHugApproach);    // 5b. v3.2: semi → hug wall
    BT_AddChild(root, vomitSeq);           // 6. ← FALLBACK: standard vomit
    BT_AddChild(root, approachSeq);        // 7. ← FALLBACK: approach
    BT_AddChild(root, BT_CreateAction(ACT_Wander));

    return root;
}

public Boomer_OnModuleStart() {
    SetConVarFloat(FindConVar("boomer_exposed_time_tolerance"), 10000.0);
    SetConVarFloat(FindConVar("boomer_vomit_delay"), 0.1);
    HookEvent("player_now_it", OnPlayerBoomed, EventHookMode_Post);
}

public OnPlayerBoomed(Handle:event, const String:name[], bool:dontBroadcast) {
    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    if (attacker > 0 && IsBotInfected(attacker) && GetInfectedClass(attacker) == L4D2Infected_Boomer) {
        SI_SignalBoomerHit();
    }
}
