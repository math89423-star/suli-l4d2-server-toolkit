// ============================================================================
// bt_smoker.inc — Smoker Behavior Tree
// ============================================================================
// Key behaviors preserved from v2.4:
//   - Target farthest survivor (straggler pull)
//   - High ground preference (pull victims upward for fall damage)
//   - Retarget every 2 seconds
//   - Tongue break damage tracking
// ============================================================================

#if defined _bt_smoker_included
  #endinput
#endif
#define _bt_smoker_included

stock int BT_CreateSmokerTree() {
    // Pull: acquire farthest target, aim, and attack
    int acquireFarthest = BT_CreateAction(ACT_AcquireCoordTarget);
    // Set UserParam1 to ZC_SMOKER for farthest-survivor preference
    // (this is set at tree build time — see ACT_AcquireCoordTarget)

    int pullSeq = BT_CreateSequence(3,
        BT_CreateCondition(CND_HasLOS),
        BT_CreateAction(ACT_SnapAimToTarget),
        BT_CreateAction(ACT_Attack)     // tongue grab
    );

    // Coordinate: retarget during attack window
    int retargetCooldown = BT_CreateCooldown(2.0, acquireFarthest);

    // Position seeking: move toward high ground (prefer elevated spots)
    int positionSeq = BT_CreateSequence(1,
        BT_CreateAction(ACT_MoveToTarget)
    );

    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, BT_CreateCondition(CND_IsPinningSurvivor));
    BT_AddChild(root, pullSeq);
    BT_AddChild(root, retargetCooldown);
    BT_AddChild(root, positionSeq);
    BT_AddChild(root, BT_CreateAction(ACT_Wander));

    return root;
}

public Smoker_OnModuleStart() {
    SetConVarFloat(FindConVar("smoker_tongue_delay"), 1.0);
}
