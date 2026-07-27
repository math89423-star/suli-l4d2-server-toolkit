// ============================================================================
// bt_charger.inc — Charger Behavior Tree
// ============================================================================
// Key behaviors preserved from v2.4:
//   - Charge proximity blocking (wait until in range)
//   - Velocity-based prediction (via ability_use event hook)
//   - Wall-slam detection (via ability_use event hook)
//   - Off-angle sweep charge (via ability_use event hook)
//   - Low-health desperation charge
//   - Coordination target switching
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

    // Standard approach: block charge until in range
    int approachSeq = BT_CreateSequence(2,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateInverter(BT_CreateIsInRange(500.0))
    );

    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, BT_CreateCondition(CND_IsPinningSurvivor));
    BT_AddChild(root, lowHpSeq);
    BT_AddChild(root, coordSeq);
    BT_AddChild(root, approachSeq);
    BT_AddChild(root, BT_CreateAction(ChargerAct_BlockCharge));
    BT_AddChild(root, BT_CreateAction(ACT_Wander));

    return root;
}

public Charger_OnModuleStart() {
    CreateConVar("ai_charge_proximity", "500", "Charger charge proximity");
    CreateConVar("ai_health_threshold_charger", "200", "Low HP charge threshold");
}
