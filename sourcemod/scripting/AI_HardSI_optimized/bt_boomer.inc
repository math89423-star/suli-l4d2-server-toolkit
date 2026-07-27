// ============================================================================
// bt_boomer.inc — Boomer Behavior Tree
// ============================================================================
// v3.1: Post-vomit behavior — 80% approach survivors (body-block, death-splode),
//       20% retreat. Fixed broken tree where ACT_AcquireClosestTarget always
//       succeeded and blocked vomitSeq from ever executing.
// Key behaviors preserved from v2.4:
//   - Flank approach (strafe when survivor is watching)
//   - Direct approach (charge straight when not watched)
//   - Vomit triggers coordination attack window
// ============================================================================

#if defined _bt_boomer_included
  #endinput
#endif
#define _bt_boomer_included


// ---------------------------------------------------------------------------
// Post-vomit state conditions
// ---------------------------------------------------------------------------

BT_Status BoomerCnd_HasVomited(int client) {
    return BB_GetBool(client, "_boomer_vomited", false) ? BT_SUCCESS : BT_FAILURE;
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
    SI_SignalBoomerHit();             // trigger coordination

    // Decide post-vomit behavior once
    bool approach = (GetRandomFloat(0.0, 1.0) < 0.8);
    BB_SetBool(client, "_boomer_approach", approach);
    BB_SetBool(client, "_boomer_vomited", true);

    return BT_SUCCESS;
}

// ============================================================================
// Tree builder
// ============================================================================

stock int BT_CreateBoomerTree() {
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

    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, postVomitSeq);
    BT_AddChild(root, vomitSeq);
    BT_AddChild(root, approachSeq);
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
