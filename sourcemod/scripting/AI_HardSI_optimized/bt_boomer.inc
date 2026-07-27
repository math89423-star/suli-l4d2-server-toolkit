// ============================================================================
// bt_boomer.inc — Boomer Behavior Tree
// ============================================================================
// Key behaviors preserved from v2.4:
//   - Flank approach (strafe when survivor is watching)
//   - Direct approach (charge straight when not watched)
//   - Vomit triggers coordination attack window
// ============================================================================

#if defined _bt_boomer_included
  #endinput
#endif
#define _bt_boomer_included



// Flank or direct approach based on whether survivor is watching
BT_Status BoomerAct_FlankApproach(int client) {
    bool watched = IsTargetWatchingAttacker(client, 60);
    if (watched) {
        // Strafe to flank
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

BT_Status BoomerAct_Vomit(int client) {
    BT_AddButton(client, IN_ATTACK);  // vomit
    SI_SignalBoomerHit();             // trigger coordination
    return BT_SUCCESS;
}
stock int BT_CreateBoomerTree() {
    // Vomit attack: flank approach + vomit when in range
    int vomitSeq = BT_CreateSequence(3,
        BT_CreateAction(BoomerAct_FlankApproach),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateAction(BoomerAct_Vomit)
    );

    // Direct approach (not being watched)
    int directSeq = BT_CreateSequence(1,
        BT_CreateAction(ACT_MoveToTarget)
    );

    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, BT_CreateAction(ACT_AcquireClosestTarget));
    BT_AddChild(root, vomitSeq);
    BT_AddChild(root, directSeq);
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
