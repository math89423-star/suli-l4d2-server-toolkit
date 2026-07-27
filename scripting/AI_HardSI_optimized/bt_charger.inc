// ============================================================================
// bt_charger.inc — Charger Behavior Tree (v3.2)
// ============================================================================
// Key behaviors preserved from v2.4:
//   - Charge proximity blocking (wait until in range)
//   - Velocity-based prediction (via ability_use event hook)
//   - Wall-slam detection (via ability_use event hook)
//   - Off-angle sweep charge (via ability_use event hook)
//   - Low-health desperation charge
//   - Coordination target switching
// v3.2 terrain-aware additions:
//   - Narrow corridor: hold chokepoint → charge down center (survivor can't dodge)
//   - Open area: flank approach → charge from side (survivor facing elsewhere)
//   - Near ledge: charge to punch survivors off cliffs
// ============================================================================

#if defined _bt_charger_included
  #endinput
#endif
#define _bt_charger_included



// Block charge ability — keep extending cooldown
BT_Status ChargerAct_BlockCharge(int client) {
    int chargeEntity = GetEntPropEnt(client, Prop_Send, "m_customAbility");
    if (chargeEntity > 0) {
        SetEntPropFloat(chargeEntity, Prop_Send, "m_timestamp", GetGameTime() + 0.1);
    }
    return BT_RUNNING;
}

// Execute charge — press ATTACK after aiming
BT_Status ChargerAct_Charge(int client) {
    BT_AddButton(client, IN_ATTACK);
    BT_AddButton(client, IN_FORWARD);
    SI_SignalAttack(client);
    return BT_SUCCESS;
}
stock int BT_CreateChargerTree() {
    // --- v3.2: Terrain-aware charge strategies ---
    // Narrow corridor: hold chokepoint → charge when survivor is close
    // Blocking the corridor prevents survivors from advancing
    int narrowHoldSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateIsInRange(600.0),             // survivor in corridor
        BT_CreateAction(ACT_HoldChokepoint)    // face them, block passage
    );
    int narrowChargeSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(400.0),             // close enough to charge
        BT_CreateAction(ChargerAct_Charge)
    );

    // Open area: flank approach → charge from unexpected angle
    int openFlankSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateInverter(BT_CreateIsInRange(600.0)),  // still far
        BT_CreateAction(ACT_FlankApproach)     // circle around
    );
    int openChargeSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(500.0),
        BT_CreateAction(ChargerAct_Charge)
    );

    // Ledge nearby: charge toward survivors near the edge
    int ledgeChargeSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsNearLedge),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(450.0),
        BT_CreateAction(ChargerAct_Charge)
    );

    // Low-health desperation charge
    int lowHpSeq = BT_CreateSequence(3,
        BT_CreateHealthBelow(200.0),
        BT_CreateIsInRange(500.0),
        BT_CreateAction(ChargerAct_Charge)
    );

    // Coordination attack
    int coordSeq = BT_CreateSequence(3,
        BT_CreateCondition(CND_IsAttackWindow),
        BT_CreateAction(ACT_SnapAimToCoordTarget),
        BT_CreateAction(ChargerAct_Charge)
    );

    // Default charge: in range + LOS → charge (v3.2 fix: was missing)
    int defaultChargeSeq = BT_CreateSequence(4,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(500.0),
        BT_CreateAction(ChargerAct_Charge)
    );

    // Standard approach: strafe toward target when too far to charge
    int approachSeq = BT_CreateSequence(3,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateInverter(BT_CreateIsInRange(500.0)),
        BT_CreateAction(ACT_StrafeMoveToTarget)
    );

    // Root selector — terrain branches (2-6) fail when ai_terrain_enable=0 or
    // terrain=UNKNOWN → falls through to standard behavior (7-12).
    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, BT_CreateCondition(CND_IsPinningSurvivor));
    BT_AddChild(root, ledgeChargeSeq);          // 2. v3.2: ledge → charge
    BT_AddChild(root, narrowChargeSeq);         // 3. v3.2: narrow → charge
    BT_AddChild(root, narrowHoldSeq);           // 4. v3.2: narrow → hold
    BT_AddChild(root, openChargeSeq);           // 5. v3.2: open → flank charge
    BT_AddChild(root, openFlankSeq);            // 6. v3.2: open → approach
    BT_AddChild(root, lowHpSeq);                // 7. ← FALLBACK: low HP charge
    BT_AddChild(root, coordSeq);                // 8. ← FALLBACK: coordination
    BT_AddChild(root, defaultChargeSeq);        // 9. ← FALLBACK: default charge (v3.3)
    BT_AddChild(root, approachSeq);             // 10.← FALLBACK: approach with strafe
    BT_AddChild(root, BT_CreateAction(ChargerAct_BlockCharge)); // 11. ← FALLBACK
    BT_AddChild(root, BT_CreateAction(ACT_Wander));             // 12. ← FALLBACK

    return root;
}

public Charger_OnModuleStart() {
    CreateConVar("ai_charge_proximity", "500", "Charger charge proximity");
    CreateConVar("ai_health_threshold_charger", "200", "Low HP charge threshold");
}
