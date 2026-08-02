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

// v4.0.1: 出生保护 —— unghost 后 2s 内禁止释放 charge。
// 症状：Charger 出生（运出复活）后立刻对着空气冲一次。
// 根因：出生瞬间 charge 技能即 ready（m_timestamp 是过去时间），而 coordSeq
//       （攻击窗口分支）没有距离/LOS 限制 —— 窗口常被其他 SI 的攻击/pin 广播
//       打开，一出生就冲远处或隔墙的协同目标，观感就是"对空气冲"。
// 修法：ghost→unghost 边沿检测，unghost 后 2s 内本条件 SUCCESS → 根 selector
//       停在 BlockCharge 分支（持续推后 m_timestamp，引擎 AI 也释放不了），
//       2s 后 FAIL 恢复正常战术。
// v4.0.2: 加 freshSpawn 兜底 —— 未观察到 ghost 阶段（运出复活出生即实体、
//       或 player_spawn 在 unghost 时重发导致黑板被 BB_Init 重置）时，
//       从 Event_PlayerSpawn 记录的 _charger_spawn_at 起 2s 内同样保护。
//       ghost 期间引擎不会攻击，保护期对正常流程无害。
BT_Status CND_ChargerSpawnProtect(int client) {
    bool ghostNow = L4D_IsPlayerGhost(client);
    float ghostSince = BB_GetFloat(client, "_charger_ghost_since", 0.0);
    float unghostAt = BB_GetFloat(client, "_charger_unghost_at", 0.0);

    if (ghostNow) {
        if (ghostSince <= 0.0) {
            BB_SetFloat(client, "_charger_ghost_since", GetGameTime());
        }
        BB_SetFloat(client, "_charger_unghost_at", 0.0);
        return BT_FAILURE;  // ghost 期间引擎忽略攻击，无需保护
    }

    if (ghostSince > 0.0) {
        // 刚 unghost —— 记录时刻并立即进入保护
        unghostAt = GetGameTime();
        BB_SetFloat(client, "_charger_unghost_at", unghostAt);
        BB_SetFloat(client, "_charger_ghost_since", 0.0);
    }

    if (unghostAt > 0.0) {
        return (GetGameTime() - unghostAt < 2.0) ? BT_SUCCESS : BT_FAILURE;
    }

    // v4.0.2 freshSpawn 兜底（须在边沿检测之后，避免 long-ghost 场景双重保护）
    float spawnAt = BB_GetFloat(client, "_charger_spawn_at", 0.0);
    if (spawnAt > 0.0 && GetGameTime() - spawnAt < 2.0) {
        return BT_SUCCESS;
    }

    return BT_FAILURE;
}

// v4.0: 酸液配合 —— 找站在 Spitter 酸液里的生还者作为冲撞目标。
// Charger × Spitter 经典组合：把人撞倒在酸里 → 掉血 + 队友救人要趟酸 → 快速减员。
// 被撞中后 pin 广播会触发 Spitter 吐被撞者（spitOnPinned 分支），形成闭环。
BT_Status ChargerAct_AcquireAcidTarget(int client) {
    int acid = -1;
    float acidPos[3];
    while ((acid = FindEntityByClassname(acid, "spit_acid")) != INVALID_ENT_REFERENCE) {
        GetEntPropVector(acid, Prop_Send, "m_vecOrigin", acidPos);
        for (int i = 1; i <= MaxClients; i++) {
            if (!IsSurvivor(i) || !IsPlayerAlive(i)) continue;
            if (IsPinned(i) || IsIncapacitated(i)) continue;
            float p[3];
            GetClientAbsOrigin(i, p);
            if (GetVectorDistance(p, acidPos) < 200.0) {
                BB_SetInt(client, "target", i);
                return BT_SUCCESS;
            }
        }
    }
    return BT_FAILURE;
}

// v3.8: Aim at blackboard target before charging.
// Fixes "charging into empty walls" — previously ChargerAct_Charge fired
// IN_ATTACK+IN_FORWARD in whatever direction the previous BT branch left,
// which could be WANDER's random angle pointing at a wall.
BT_Status ChargerAct_AimAtTarget(int client) {
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    return BT_SUCCESS;
}

// Execute charge — press ATTACK after aiming
BT_Status ChargerAct_Charge(int client) {
    BT_AddButton(client, IN_ATTACK);
    BT_AddButton(client, IN_FORWARD);
    SI_SignalAttack(client);
    return BT_SUCCESS;
}

// v3.6: Blind charge — charge even without LOS (30% chance).
// Charger's charge has a wide hitbox that can clip survivors around corners.
// Sometimes a blind charge is better than circling forever.
BT_Status ChargerAct_BlindCharge(int client) {
    // Face the acquired target direction even without LOS
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    BT_AddButton(client, IN_ATTACK);
    BT_AddButton(client, IN_FORWARD);
    SI_SignalAttack(client);
    return BT_SUCCESS;
}

// v3.6: Step-back then charge — when too close (<200u), back up briefly
// to create optimal charge distance, then charge.
BT_Status ChargerAct_StepBackCharge(int client) {
    float now = GetGameTime();
    float backUntil = BB_GetFloat(client, "_charger_backup_until", 0.0);

    if (backUntil <= 0.0) {
        // Start backing up
        BB_SetFloat(client, "_charger_backup_until", now + 0.4);
    }

    if (now < backUntil) {
        // Backpedal: face target, move backward
        int target = BB_GetInt(client, "target", -1);
        if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
            float sPos[3], tPos[3], dir[3], ang[3];
            GetClientAbsOrigin(client, sPos);
            GetClientAbsOrigin(target, tPos);
            MakeVectorFromPoints(sPos, tPos, dir);
            GetVectorAngles(dir, ang);
            BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        }
        BT_AddButton(client, IN_BACK);
        return BT_RUNNING;
    }

    // v3.8 FIX: Re-check LOS before charging. During the 0.4s back-up,
    // the survivor may have moved behind cover. If LOS is lost, abort
    // and let the selector try another branch (approach/blind charge).
    if (GetEntProp(client, Prop_Send, "m_hasVisibleThreats") <= 0) {
        BB_SetFloat(client, "_charger_backup_until", 0.0);
        return BT_FAILURE;
    }

    // Back-up complete → charge now
    BB_SetFloat(client, "_charger_backup_until", 0.0);
    return ChargerAct_Charge(client);
}
stock int BT_CreateChargerTree() {
    // --- Read charge-range cvars (v3.4 FIX: were created but never read) ---
    float fChargeProx = 750.0;  // v3.6: increased from 500 for more aggressive charging
    int   iHpThreshold = 200;
    ConVar hCvar = FindConVar("ai_charge_proximity");
    if (hCvar != null) fChargeProx = GetConVarFloat(hCvar);
    hCvar = FindConVar("ai_health_threshold_charger");
    if (hCvar != null) iHpThreshold = GetConVarInt(hCvar);

    // --- v3.2 terrain strategies: narrow ---
    // v4.0.2: 移除 narrowHoldSeq（HoldChokepoint 站桩是 Tank/Boomer 卡点动作，
    // 对 Charger 是"原地不动看着生还者"）——窄巷本应无解直冲；
    // narrowChargeSeq 距离 400→fChargeProx(750)，与开阔地冲锋距离对齐。
    int narrowChargeSeq = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(fChargeProx),
        BT_CreateAction(ChargerAct_AimAtTarget),
        BT_CreateAction(ChargerAct_Charge)
    );

    // === v3.5: Open terrain — 3-way random strategies ===
    int openStrategyRoll = BT_CreateSequence(2,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateRollStrategy(3)
    );
    // Strat 0: Flank charge — circle around → charge from side
    // v4.0: 大弧线绕后（CircleFlank）—— 120° 大圈绕到队伍侧后方再冲
    int openS0_Approach = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(0),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateIsNotInRange(600.0),
        BT_CreateAction(ACT_CircleFlank)
    );
    int openS0_Charge = BT_CreateSequence(7,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(0),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(fChargeProx),
        BT_CreateAction(ChargerAct_AimAtTarget),
        BT_CreateAction(ChargerAct_Charge)
    );
    // Strat 1: Erratic charge — zigzag approach → charge
    int openS1_Approach = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(1),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateIsNotInRange(500.0),
        BT_CreateAction(ACT_ErraticApproach)
    );
    int openS1_Charge = BT_CreateSequence(7,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(1),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(fChargeProx),
        BT_CreateAction(ChargerAct_AimAtTarget),
        BT_CreateAction(ChargerAct_Charge)
    );
    // Strat 2: Standard — falls through to defaultChargeSeq below

    // Ledge nearby: charge toward survivors near the edge
    int ledgeChargeSeq = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsNearLedge),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(450.0),
        BT_CreateAction(ChargerAct_AimAtTarget),
        BT_CreateAction(ChargerAct_Charge)
    );

    // Low-health desperation charge (v3.8 FIX: added AcquireClosestTarget + HasLOS
    // + AimAtTarget — previously had none of these, would charge in whatever
    // direction the previous BT branch left, often straight into a wall)
    int lowHpSeq = BT_CreateSequence(6,
        BT_CreateHealthBelow(float(iHpThreshold)),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(fChargeProx),
        BT_CreateAction(ChargerAct_AimAtTarget),
        BT_CreateAction(ChargerAct_Charge)
    );

    // Coordination attack
    // v4.0: 目标由 SI_GetCoordinatedTarget 决定 ——
    //   集火模式（0/1/2/3/5）：窗口内优先冲被 pin 者（队友锁住的人必中）
    //   分散模式（4/6）：冲未受控目标（Tank 模式下冲别的目标减轻 Tank 压力）
    // v4.0.1 FIX: 补上 HasLOS + inRange —— 原版无任何距离/LOS 限制，
    //   攻击窗口（5.5s，常被其他 SI 攻击/pin 广播打开）一开，Charger 在
    //   2000u+ 外/隔墙也直接释放 charge，造成"出生对空气冲"与平时白冲。
    int coordSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsAttackWindow),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(fChargeProx),
        BT_CreateAction(ACT_SnapAimToCoordTarget),
        BT_CreateAction(ChargerAct_Charge)
    );

    // ==========================================
    // v4.0: 钢铁洪流 (mode 0) —— 正面直冲，更远距离开冲。
    // 洪流的战术 = 近战 SI 一波涌入：Charger 是开路先锋，
    // 900u 直接冲（比默认 750 更凶），冲散阵型后 Hunter/Jockey 跟进。
    // ==========================================
    int mode0Charge = BT_CreateSequence(6,
        BT_CreateIsMode(0),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(900.0),
        BT_CreateAction(ChargerAct_AimAtTarget),
        BT_CreateAction(ChargerAct_Charge)
    );

    // ==========================================
    // v4.0: 酸液配合 —— 冲站在 Spitter 酸液里的生还者（任何模式生效）
    // Charger × Spitter 经典组合：撞进酸里锁住 → 掉血 + 救人趟酸 → 快速减员
    // ==========================================
    int acidCharge = BT_CreateSequence(5,
        BT_CreateAction(ChargerAct_AcquireAcidTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(fChargeProx),
        BT_CreateAction(ChargerAct_AimAtTarget),
        BT_CreateAction(ChargerAct_Charge)
    );

    // Default charge: in range + LOS → charge (v3.2 fix: was missing)
    int defaultChargeSeq = BT_CreateSequence(5,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(fChargeProx),
        BT_CreateAction(ChargerAct_AimAtTarget),
        BT_CreateAction(ChargerAct_Charge)
    );

    // v3.2 FIX: approach when in range but no LOS (LOS blind-spot deadlock).
    // Previously: distance ≤500 + no LOS → neither charge nor approach fires
    // → falls to BlockCharge → Charger stands still extending cooldown forever.
    int noLosApproach = BT_CreateSequence(4,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateInverter(BT_CreateCondition(CND_HasLOS)),
        BT_CreateIsInRange(fChargeProx),
        BT_CreateAction(ACT_StrafeMoveToTarget)   // keep moving, may regain LOS
    );

    // Standard approach: strafe toward target when too far to charge
    int approachSeq = BT_CreateSequence(3,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateInverter(BT_CreateIsInRange(fChargeProx)),
        BT_CreateAction(ACT_StrafeMoveToTarget)
    );

    // ==========================================
    // v3.6: Aggressive charge — blind charge + step-back charge.
    // Charger's charge has a wide hitbox; a blind charge around corners
    // is often better than circling forever. When too close (<200u),
    // step back briefly to create optimal charge distance.
    // ==========================================
    // v3.7 FIX (P0): Removed RandomChance from stepBackCharge.
    // RandomChance re-evaluates every tick → step-back was being aborted mid-way
    // when the dice roll changed. Now always step back when too close.
    // Close range + HasLOS → step back 0.4s then charge. If charge is on
    // cooldown, IN_ATTACK becomes melee punch (valid fallback 贴脸近战).
    int stepBackCharge = BT_CreateSequence(4,
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(200.0),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(ChargerAct_StepBackCharge)
    );
    // v3.7 FIX (P0): Removed ForceSuccess wrapper from blindCharge.
    // ForceSuccess caused deadlock: when RandomChance failed, ForceSuccess
    // returned SUCCESS anyway → selector consumed → Charger did nothing
    // every tick. Now blindCharge fails naturally, selector moves to
    // next branch (noLosApproach / approachSeq / Wander).
    int blindCharge = BT_CreateSequence(5,
        BT_CreateInverter(BT_CreateCondition(CND_HasLOS)),
        BT_CreateIsInRange(400.0),
        BT_CreateRandomChance(0.30),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(ChargerAct_BlindCharge)
    );

    // Root selector — terrain branches fail when disabled → fallback to standard.
    int root = BT_Create(BTN_SELECTOR);
    // v4.0.1: 0. 出生保护 —— unghost 后 2s 内强制 BlockCharge（防出生对空气冲）
    int spawnProtect = BT_CreateSequence(2,
        BT_CreateCondition(CND_ChargerSpawnProtect),
        BT_CreateAction(ChargerAct_BlockCharge)
    );
    BT_AddChild(root, spawnProtect);                               // 0. v4.0.1
    BT_AddChild(root, BT_CreateCondition(CND_IsPinningSurvivor)); // 1
    BT_AddChild(root, stepBackCharge);         // 2. v3.7: too close → step back + charge
    BT_AddChild(root, blindCharge);            // 3. v3.7: no LOS + close → 30% blind charge
    BT_AddChild(root, mode0Charge);            // 3.5. v4.0: mode 0 → 900u 正面直冲
    // v4.0: coordSeq 从第 10 位前置到第 4 位 ——
    // 队友 pin 住人时立刻冲（窗口 = pin 广播），不再被地形分支挡住
    BT_AddChild(root, coordSeq);               // 4. ← v4.0 前置: coordination 冲被 pin 者
    BT_AddChild(root, acidCharge);             // 4.5. v4.0: 冲酸液里的人（Charger×Spitter 配合）
    BT_AddChild(root, ledgeChargeSeq);         // 5. v3.2: ledge → charge
    BT_AddChild(root, narrowChargeSeq);        // 6. v3.2/v4.0.2: narrow → charge (750u)
    BT_AddChild(root, openStrategyRoll);        // 7a. v3.5: open → roll token
    BT_AddChild(root, openS0_Charge);           // 8b. v3.5: open strat0 → flank charge
    BT_AddChild(root, openS0_Approach);         // 8c. v3.5: open strat0 → flank approach
    BT_AddChild(root, openS1_Charge);           // 9a. v3.5: open strat1 → erratic charge
    BT_AddChild(root, openS1_Approach);         // 9b. v3.5: open strat1 → erratic approach
    // 9c: open strat2 → falls through to defaultChargeSeq
    BT_AddChild(root, lowHpSeq);                // 10. ← FALLBACK: low HP charge
    BT_AddChild(root, defaultChargeSeq);        // 11. ← FALLBACK: default charge (prox=750)
    BT_AddChild(root, noLosApproach);           // 12. ← FALLBACK: in-range no-LOS approach
    BT_AddChild(root, approachSeq);             // 13. ← FALLBACK: approach from far
    BT_AddChild(root, BT_CreateAction(ChargerAct_BlockCharge)); // 14.
    BT_AddChild(root, BT_CreateAction(ACT_Wander));             // 15.

    return root;
}

public Charger_OnModuleStart() {
    CreateConVar("ai_charge_proximity", "500", "Charger charge proximity");
    CreateConVar("ai_health_threshold_charger", "200", "Low HP charge threshold");
}
