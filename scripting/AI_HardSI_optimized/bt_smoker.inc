// ============================================================================
// bt_smoker.inc — Smoker Behavior Tree (v3.2)
// ============================================================================
// v3.1: Mixed target selection — 60% farthest (back-line pull), 40% closest
//       (front-line disruption). Strafe approach avoids running straight.
// v3.2:
//   - FIXED: Removed tongue_release suicide — Smoker now re-engages after grab
//   - Ledge priority: when ledge is between SI and survivor → 90% farthest (pull for fall damage)
//   - Narrow corridor: pull survivor through chokepoint into infected pack
//   - Open area: standard mixed target (back-line + front-line disruption)
// Key behaviors:
//   - Mixed target: farthest (traditional) + closest (front-line)
//   - Strafe approach to avoid being an easy snipe target
//   - Retarget every 2 seconds
//   - Tongue break damage tracking
// ============================================================================

#if defined _bt_smoker_included
  #endinput
#endif
#define _bt_smoker_included

// ---------------------------------------------------------------------------
// Smoker target acquisition (v4.0): 孤立度优先 —— 拉落单的人
// 真正有进攻性的 Smoker 专挑与队伍分离的幸存者：
//   1. 掉队的人（落在队伍后面，脱离大部队）
//   2. 冲太快的人（跑在前头，与后方队伍分离）
// 判定方式：到最近队友的距离（孤立度）。> ISOLATION_THRESHOLD 即为落单，
// 拉孤立度最高的人 —— 两个场景被同一个度量覆盖。
// 无人明显落单时 fallback 到 60% 拉最远（后排）/ 40% 拉最近（前排干扰）。
// ---------------------------------------------------------------------------

#define SMOKER_ISOLATION_THRESHOLD 350.0

BT_Status SmokerAct_AcquireTarget(int client) {
    // --- 找孤立度最高的幸存者 ---
    int bestIsolated = -1;
    float bestIsolation = SMOKER_ISOLATION_THRESHOLD;  // 必须明显落单才算
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsSurvivor(i) || !IsPlayerAlive(i)) continue;
        if (IsPinned(i) || IsIncapacitated(i)) continue;
        float p[3];
        GetClientAbsOrigin(i, p);
        // 到最近队友的距离 = 孤立度
        float nearest = 999999.0;
        for (int j = 1; j <= MaxClients; j++) {
            if (j == i || !IsSurvivor(j) || !IsPlayerAlive(j)) continue;
            float q[3];
            GetClientAbsOrigin(j, q);
            float d = GetVectorDistance(p, q);
            if (d < nearest) nearest = d;
        }
        if (nearest > bestIsolation) {
            bestIsolation = nearest;
            bestIsolated = i;
        }
    }

    if (bestIsolated > 0) {
        BB_SetInt(client, "target", bestIsolated);
        return BT_SUCCESS;
    }

    // --- 无人明显落单：混合 fallback ---
    int target = -1;
    // 40% chance: front-line pull (closest survivor)
    // 60% chance: traditional back-line pull (farthest survivor)
    if (GetRandomFloat(0.0, 1.0) < 0.4) {
        float pos[3];
        GetClientAbsOrigin(client, pos);
        target = GetClosestSurvivor(pos);
    } else {
        // Farthest survivor via coordination system (ZC_SMOKER=1)
        target = SI_GetCoordinatedTarget(client, 1);
    }

    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        BB_SetInt(client, "target", target);
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        return BT_SUCCESS;
    }

    // Fallback: any survivor
    float pos[3];
    GetClientAbsOrigin(client, pos);
    int fallback = GetClosestSurvivor(pos);
    if (fallback > 0) {
        BB_SetInt(client, "target", fallback);
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}

// ============================================================================
// v4.0: 外侧走位 —— 站到目标远离队伍中心的一侧再拉。
// 舌头把人拉向 Smoker 自身，所以 Smoker 站在队伍外侧时，被拉的人
// 就会被拖离队伍（往特感堆/空旷处拉），而不是拉向队伍中心（队友秒救）。
// ============================================================================

BT_Status SmokerAct_ApproachOutside(int client) {
    int target = BB_GetInt(client, "target", -1);
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) {
        return BT_FAILURE;
    }

    // 队伍中心（其他幸存者平均位置）
    float center[3];
    int count = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsSurvivor(i) && IsPlayerAlive(i) && i != target) {
            float p[3];
            GetClientAbsOrigin(i, p);
            center[0] += p[0];
            center[1] += p[1];
            center[2] += p[2];
            count++;
        }
    }

    float tPos[3], myPos[3];
    GetClientAbsOrigin(target, tPos);
    GetClientAbsOrigin(client, myPos);

    float dir[3], ang[3];
    if (count > 0) {
        center[0] /= float(count);
        center[1] /= float(count);
        // 外侧方向 = 队伍中心 → 目标 的延长线（目标远离队伍的一侧）
        float outside[3];
        MakeVectorFromPoints(center, tPos, outside);
        outside[2] = 0.0;
        NormalizeVector(outside, outside);
        // 预站位 = 目标外侧 150u
        float standPos[3];
        standPos[0] = tPos[0] + outside[0] * 150.0;
        standPos[1] = tPos[1] + outside[1] * 150.0;
        standPos[2] = tPos[2];
        MakeVectorFromPoints(myPos, standPos, dir);
    } else {
        // 单人局无队伍中心：直接朝向目标
        MakeVectorFromPoints(myPos, tPos, dir);
    }
    GetVectorAngles(dir, ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_FORWARD);
    return BT_RUNNING;
}

// ============================================================================
// v3.2: Terrain-aware target acquisition
// ============================================================================

BT_Status SmokerAct_AcquireLedgeTarget(int client) {
    // When near a ledge: 90% farthest (pull for fall damage), 10% closest
    int target = -1;
    if (GetRandomFloat(0.0, 1.0) < 0.9) {
        target = SI_GetCoordinatedTarget(client, 1);  // farthest
    } else {
        float pos[3];
        GetClientAbsOrigin(client, pos);
        target = GetClosestSurvivor(pos);
    }

    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        BB_SetInt(client, "target", target);
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}

BT_Status SmokerAct_AcquireNarrowTarget(int client) {
    // Narrow: 50% farthest (pull through corridor), 50% closest (chokepoint)
    int target = -1;
    if (GetRandomFloat(0.0, 1.0) < 0.5) {
        target = SI_GetCoordinatedTarget(client, 1);
    } else {
        float pos[3];
        GetClientAbsOrigin(client, pos);
        target = GetClosestSurvivor(pos);
    }

    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        BB_SetInt(client, "target", target);
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}

// ============================================================================
// v4.0: 生化危机 (mode 3) —— 拉被 Boomer 喷过的人。
// 被喷者视野被糊，反应最差；拉他 = 在混乱中精准收割，配合毒区绞杀。
// ============================================================================

BT_Status SmokerAct_AcquireBoomedTarget(int client) {
    if (!SI_IsBoomerActive()) return BT_FAILURE;

    float pos[3];
    GetClientAbsOrigin(client, pos);
    int best = -1;
    float bestDist = -1.0;
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsSurvivor(i) || !IsPlayerAlive(i)) continue;
        if (IsPinned(i)) continue;
        if (GetEntProp(i, Prop_Data, "m_hasBeenBoomed") <= 0) continue;
        float p[3];
        GetClientAbsOrigin(i, p);
        float d = GetVectorDistance(pos, p);
        if (bestDist < 0.0 || d < bestDist) {
            bestDist = d;
            best = i;
        }
    }
    if (best > 0) {
        BB_SetInt(client, "target", best);
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(best, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}

// ============================================================================
// Tree builder
// ============================================================================

stock int BT_CreateSmokerTree() {
    // ==========================================
    // v3.5: Open terrain — 3-way random pull strategies
    // ==========================================
    int openStrategyRoll = BT_CreateSequence(2,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateRollStrategy(3)
    );
    // Strat 0: Flank pull — move to side → pull from unexpected angle
    int openS0_Approach = BT_CreateSequence(4,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(0),
        BT_CreateInverter(BT_CreateCondition(CND_HasLOS)),
        BT_CreateAction(ACT_FlankApproach)
    );
    int openS0_Pull = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(0),
        BT_CreateAction(SmokerAct_AcquireTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(850.0),     // v3.7: tongue max range ~850u
        BT_CreateAction(ACT_Attack)
    );
    // Strat 1: Erratic pull — zigzag approach → pull from varied angle
    // v3.7 FIX: was HasLOS (dead code — pull fires first when HasLOS=true).
    // Changed to Inverter(HasLOS): approach when no LOS to regain angle.
    int openS1_Approach = BT_CreateSequence(4,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(1),
        BT_CreateInverter(BT_CreateCondition(CND_HasLOS)),
        BT_CreateAction(ACT_ErraticApproach)
    );
    int openS1_Pull = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(1),
        BT_CreateAction(SmokerAct_AcquireTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(850.0),     // v3.7: tongue max range
        BT_CreateAction(ACT_Attack)
    );
    // Strat 2: Standard pull — falls through to pullSeq below

    // --- v3.2: Terrain-aware pull strategies ---
    // Ledge: 90% farthest target → pull for fall damage
    int ledgeTargetAcquire = BT_CreateAction(SmokerAct_AcquireLedgeTarget);
    // v3.2 FIX: ledgePullSeq now uses SmokerAct_AcquireLedgeTarget (90% farthest)
    // before snapping aim, instead of relying on the engine's default target.
    int ledgePullSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsLedgeBetweenTarget),
        BT_CreateAction(SmokerAct_AcquireLedgeTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateAction(ACT_SnapAimToTarget),
        BT_CreateAction(ACT_Attack)
    );

    // Narrow: 50/50 target mix → pull through chokepoint
    int narrowPullSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateAction(SmokerAct_AcquireNarrowTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateAction(ACT_SnapAimToTarget),
        BT_CreateAction(ACT_Attack)
    );

    // Standard: pull (mixed targeting), check LOS, aim, attack
    int acquireTarget = BT_CreateAction(SmokerAct_AcquireTarget);
    int pullSeq = BT_CreateSequence(3,
        BT_CreateCondition(CND_HasLOS),
        BT_CreateAction(ACT_SnapAimToTarget),
        BT_CreateAction(ACT_Attack)
    );

    // Retarget every 2s — 孤立度动态变化，持续重新评估最佳目标
    int retargetCooldown = BT_CreateCooldown(2.0, acquireTarget);

    // Ledge retarget (override: 90% farthest)
    int ledgeRetarget = BT_CreateCooldown(2.0, ledgeTargetAcquire);

    // Approach: 外侧走位 —— 绕到目标远离队伍的一侧再拉（把人拉离队伍）
    int approachAct = BT_CreateAction(SmokerAct_ApproachOutside);

    // ==========================================
    // v4.0: 生化危机 (mode 3) —— 拉被喷者
    // ==========================================
    int mode3Pull = BT_CreateSequence(5,
        BT_CreateIsMode(3),
        BT_CreateAction(SmokerAct_AcquireBoomedTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(850.0),
        BT_CreateAction(ACT_Attack)
    );
    int mode3Approach = BT_CreateSequence(4,
        BT_CreateIsMode(3),
        BT_CreateAction(SmokerAct_AcquireBoomedTarget),
        BT_CreateInverter(BT_CreateCondition(CND_HasLOS)),
        BT_CreateAction(SmokerAct_ApproachOutside)
    );

    // ==========================================
    // v3.6: Anti-melee — prevent ATTACK spam between tongue attempts.
    // Smoker's tongue shares IN_ATTACK with melee scratch. Without a cooldown,
    // pullSeq presses ATTACK every tick. When the tongue is on its engine
    // cooldown (~1-2s), every ATTACK press becomes a melee scratch.
    // Fix: Cooldown(1.8) on the pull action — only press ATTACK when the
    // tongue is likely ready. Between attempts, strafe (not scratch).
    //
    // Close range + no LOS → still strafe for angle (don't approach blindly).
    // Close range + HasLOS → pull with cooldown (tongue, not scratch).
    // Last resort → Wander (melee is valid when nothing else works).
    // ==========================================
    int closeRangeStrafe = BT_CreateSequence(4,
        BT_CreateIsInRange(350.0),
        BT_CreateInverter(BT_CreateCondition(CND_HasLOS)),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(ACT_StrafeRandom)
    );

    // Root selector — v3.6: pull with cooldown prevents melee spam.
    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, BT_CreateCondition(CND_IsPinningSurvivor)); // 1
    BT_AddChild(root, ledgePullSeq);          // 2. ledge → pull
    BT_AddChild(root, narrowPullSeq);         // 3. narrow → pull
    BT_AddChild(root, mode3Pull);             // 3.5. v4.0: mode 3 → 拉被喷者
    BT_AddChild(root, mode3Approach);         // 3.5. v4.0: mode 3 → 外侧走位接近
    BT_AddChild(root, openStrategyRoll);      // 4a. open → roll token
    BT_AddChild(root, openS0_Pull);           // 4b. open strat0 → flank pull
    BT_AddChild(root, openS0_Approach);       // 4c. open strat0 → flank approach
    BT_AddChild(root, openS1_Pull);           // 5a. open strat1 → erratic pull
    BT_AddChild(root, openS1_Approach);       // 5b. open strat1 → erratic approach
    BT_AddChild(root, pullSeq);               // 6. standard pull (any range + LOS)
    BT_AddChild(root, closeRangeStrafe);      // 7. v3.6: close + noLOS → strafe, don't approach
    BT_AddChild(root, ledgeRetarget);         // 8. ledge → retarget
    BT_AddChild(root, retargetCooldown);      // 9. standard retarget
    BT_AddChild(root, approachAct);           // 10. approach (only when far)
    BT_AddChild(root, BT_CreateAction(ACT_Wander)); // 11. last resort — melee IS valid here

    return root;
}

public Smoker_OnModuleStart() {
    SetConVarFloat(FindConVar("smoker_tongue_delay"), 1.0);
}
