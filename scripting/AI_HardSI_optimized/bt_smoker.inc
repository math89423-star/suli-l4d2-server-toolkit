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
    // v5.6: 选人时效 —— 4s 内刚选过就不重选（原版每次调用重掷 40% 最近/
    // 60% 最远 → 每 2s 目标跳变，Smoker 在"追最近/追最远"之间折返，
    // ai_debug 386→4800u 反复 = "接近-后退"循环主因）
    float now = GetGameTime();
    float lastPick = BB_GetFloat(client, "_smoker_target_time", 0.0);
    int cur = BB_GetInt(client, "target", -1);
    if (cur > 0 && lastPick > 0.0 && now - lastPick < 4.0) {
        if (IsSurvivor(cur) && IsPlayerAlive(cur)) return BT_SUCCESS;
    }
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
        BB_SetFloat(client, "_smoker_target_time", now);
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
        BB_SetFloat(client, "_smoker_target_time", now);
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
    BT_StuckDetour(client);   // v5.2: 顶墙绕行（隔墙站桩主因）
    return BT_RUNNING;
}

// ============================================================================
// v5.0: 控制链核心 —— 拉中人后的拖拽 steering。
// 舌头把人拉向 Smoker 自身：Smoker 朝酸液池方向移动 = 被拉者被拖向酸液
// （拖进酸 = 酸伤 + 队友救人必须趟酸）。无酸液时保持原地引擎托管拉。
// ============================================================================

BT_Status SmokerAct_SteerPinToAcid(int client) {
    float myPos[3];
    GetClientAbsOrigin(client, myPos);
    float acidPos[3];
    float acidDist = SI_GetNearestAcid(myPos, acidPos, 900.0);
    if (acidDist >= 100.0) {
        float dir[3], ang[3];
        MakeVectorFromPoints(myPos, acidPos, dir);
        dir[2] = 0.0;
        if (GetVectorLength(dir) > 10.0) {
            GetVectorAngles(dir, ang);
            BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
            BT_AddButton(client, IN_FORWARD);
            return BT_RUNNING;
        }
    }

    // v5.3: 无酸时后退拖拽 —— 原版引擎拉中后钉住不动（观感"放完技能原地
    // 傻站"）。真人 Smoker 拉中会后退拉扯：背对目标走 = 舌头把目标拖向自己
    // （目标被拖离队伍/拖进特感堆）。后退受限：目标距 Smoker ≥850u 停止
    // （防拉断舌头），退到 850u 后引擎托管拉，断舌/松开后回正常分支。
    int victim = GetEntPropEnt(client, Prop_Send, "m_tongueVictim");
    if (victim > 0 && IsSurvivor(victim) && IsPlayerAlive(victim)) {
        float vPos[3];
        GetClientAbsOrigin(victim, vPos);
        float dist = GetVectorDistance(myPos, vPos);
        if (dist < 850.0) {
            float dir[3], ang[3];
            MakeVectorFromPoints(vPos, myPos, dir);   // 目标→我 = 背对目标方向
            dir[2] = 0.0;
            if (GetVectorLength(dir) > 10.0) {
                GetVectorAngles(dir, ang);
                BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
                BT_AddButton(client, IN_FORWARD);
                return BT_RUNNING;
            }
        }
    }
    return BT_SUCCESS;  // 无酸液/距离危险：引擎托管拉
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
        if (!SI_IsSurvivorBoomed(i)) continue;   // v4.1.2: prop 不存在，事件跟踪替代
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
        BT_CreateInverter(BT_CreateCondition(CND_HasTargetLOS)),  // v5.22: HasLOS → HasTargetLOS（引擎标志失真）
        BT_CreateAction(ACT_FlankApproach)
    );
    // v5.6: 移除序列内 AcquireTarget（选人只归 branch 8，2s 一次 + 4s 时效；
    // 原版每 tick 重评时重选 → 目标每 tick 跳变）+ HasLOS → HasTargetLOS
    // （引擎 m_hasVisibleThreats 在 Smoker 路径实测几乎恒 0 → 拉人分支全灭）
    // + IsInRange → IsTargetInRange（距离量黑板 target 而非最近者）
    int openS0_Pull = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(0),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange_Scaled(850.0),  // v5.8: pressure-scaled range
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(ACT_Attack)
    );
    // Strat 1: Erratic pull — zigzag approach → pull from varied angle
    // v3.7 FIX: was HasLOS (dead code — pull fires first when HasLOS=true).
    // Changed to Inverter(HasLOS): approach when no LOS to regain angle.
    // v5.22: HasLOS → HasTargetLOS（引擎标志失真，与拉人分支口径统一）
    int openS1_Approach = BT_CreateSequence(4,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(1),
        BT_CreateInverter(BT_CreateCondition(CND_HasTargetLOS)),
        BT_CreateAction(ACT_ErraticApproach)
    );
    // v5.6: 同 openS0_Pull
    int openS1_Pull = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(1),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange_Scaled(850.0),  // v5.8: pressure-scaled range
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(ACT_Attack)
    );
    // Strat 2: Standard pull — falls through to pullSeq below

    // --- v3.2: Terrain-aware pull strategies ---
    // Ledge: 90% farthest target → pull for fall damage
    int ledgeTargetAcquire = BT_CreateAction(SmokerAct_AcquireLedgeTarget);
    // v3.2 FIX: ledgePullSeq now uses SmokerAct_AcquireLedgeTarget (90% farthest)
    // before snapping aim, instead of relying on the engine's default target.
    // v5.6: 补 IsTargetInRange(850)（原版缺距离门：ledge 地形命中时 2000u 外
    // 也按 ATTACK）+ HasTargetLOS + SnapAimToBlackboardTarget
    int ledgePullSeq = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsLedgeBetweenTarget),
        BT_CreateAction(SmokerAct_AcquireLedgeTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange_Scaled(850.0),  // v5.8: pressure-scaled range
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(ACT_Attack)
    );

    // Narrow: 50/50 target mix → pull through chokepoint
    // v5.6: 同 ledgePullSeq
    int narrowPullSeq = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateAction(SmokerAct_AcquireNarrowTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange_Scaled(850.0),  // v5.8: pressure-scaled range
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(ACT_Attack)
    );

    // Standard: pull (mixed targeting), check LOS, aim, attack
    // v4.0.3: 加 IsInRange(850) —— 原版无距离限制，2000u 外有 LOS 也每 tick 按
    // ATTACK（舌头够不着，纯浪费按键；与 openS0/S1 pull 的距离口径对齐）。
    // v5.6: HasLOS → HasTargetLOS（Smoker 拉人全灭根因）+ target 口径 + 黑板瞄准
    int acquireTarget = BT_CreateAction(SmokerAct_AcquireTarget);
    int pullSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange_Scaled(850.0),  // v5.8: pressure-scaled range
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(ACT_Attack)
    );

    // Retarget every 2s — 孤立度动态变化，持续重新评估最佳目标
    int retargetCooldown = BT_CreateCooldown(2.0, acquireTarget);

    // Ledge retarget (override: 90% farthest)
    int ledgeRetarget = BT_CreateCooldown(2.0, ledgeTargetAcquire);

    // v4.0.3: ledgeRetarget 加地形门控 —— 原版无条件每 2s 用"90% 拉最远"覆盖
    // 目标选择，把 v4.0 孤立度选人（retargetCooldown）的生效窗口砍掉一半。
    // 现在只有真正站在 ledge 附近才走"90% 拉最远"（v3.2 设计意图）；
    // 不在 ledge 时完全交给 retargetCooldown 的孤立度逻辑。
    int ledgeRetargetGated = BT_CreateSequence(2,
        BT_CreateCondition(CND_IsNearLedge),
        ledgeRetarget
    );

    // Approach: 外侧走位 —— 绕到目标远离队伍的一侧再拉（把人拉离队伍）
    // v5.6: 加距离门控（IsNotInRange(850)）—— 原版注释声称 "only when far"
    // 但无任何距离条件：850u 内（舌头射程内）拉人分支全 FAIL 时也落此分支
    // 盲走（386-800u 反复"拱人+侧滑"现场）。射程内走位 = closeRangeStrafe
    // 的职责，approachAct 只负责射程外绕位。
    int approachAct = BT_CreateSequence(2,
        BT_CreateIsNotInRange(850.0),
        BT_CreateAction(SmokerAct_ApproachOutside)
    );

    // ==========================================
    // v4.0: 生化危机 (mode 3) —— 拉被喷者
    // ==========================================
    // v5.6: 同 pullSeq 口径（trace LOS + target 距离）
    int mode3Pull = BT_CreateSequence(5,
        BT_CreateIsMode(3),
        BT_CreateAction(SmokerAct_AcquireBoomedTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange_Scaled(850.0),  // v5.8: pressure-scaled range
        BT_CreateAction(ACT_Attack)
    );
    int mode3Approach = BT_CreateSequence(4,
        BT_CreateIsMode(3),
        BT_CreateAction(SmokerAct_AcquireBoomedTarget),
        BT_CreateInverter(BT_CreateCondition(CND_HasTargetLOS)),  // v5.22: 序列内已获取 boomed target，改口径
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
    // v5.2: 横移 + 前进（原 ACT_StrafeRandom 只横移不前进 —— ≤350u 无 LOS 时
    // 原地左右晃，观感"站桩"；StrafeApproach 绕圈接近）
    // v5.6 FIX: 350 → 850 —— 原版 350-850u 无 LOS 区间无任何分支（拉人分支
    // 要 LOS、approachAct 要 LOS 外？实测兜底 approachAct 直接拱到 ≤150u 贴脸
    // 顶身循环）→ 无 LOS 时整段舌头射程内只能盲走。850u 全射程内无 LOS 都
    // 横移找角度，拉人分支才有机会触发。
    int closeRangeStrafe = BT_CreateSequence(4,
        BT_CreateIsInRange(850.0),
        BT_CreateInverter(BT_CreateCondition(CND_HasTargetLOS)),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(ACT_StrafeApproach)
    );

    // ==========================================
    // v4.0.3: 拉人冷却簇 —— 舌头与近战共享 IN_ATTACK。
    // 引擎舌头冷却 (smoker_tongue_delay=1.0) 期间按 ATTACK = 近战挠击，
    // 原版 6 个拉人分支全部无冷却：只要 LOS+射程内就每 tick 按 →
    // 舌头冷却期贴脸挠击（v3.6 注释声称的 Cooldown(1.8) 从未落地）。
    // 现在所有拉人分支包进一个 Cooldown(1.8)：冷却窗口内整个簇 FAIL，
    // 树落到走位/重新选人分支（v3.6 设计意图原样落地），
    // ATTACK 频率从每 tick → 每 1.8s。
    // ==========================================
    int pullCluster = BT_Create(BTN_SELECTOR);
    BT_AddChild(pullCluster, ledgePullSeq);       // ledge → pull
    BT_AddChild(pullCluster, narrowPullSeq);      // narrow → pull
    BT_AddChild(pullCluster, mode3Pull);          // v4.0: mode 3 → 拉被喷者
    BT_AddChild(pullCluster, openS0_Pull);        // open strat0 → flank pull
    BT_AddChild(pullCluster, openS1_Pull);        // open strat1 → erratic pull
    BT_AddChild(pullCluster, pullSeq);            // standard pull (fallback)
    int cooldownPull = BT_CreateCooldown(1.8, pullCluster);

    // ==========================================
    // v5.18 功能 1：flow 前置埋伏
    // ------------------------------------------
    // Smoker 是唯一的纯远程控制位，最怕的就是主动接近后被集火。
    // 出生点若已在队伍推进方向的前方（flow 领先），最优解是原地蹲守
    // 等玩家走进舌头射程 —— 而不是拱过去暴露。
    //
    // 排在拉人簇之后：有 LOS + 射程内时拉人优先（branch 2 先命中），
    // 只有"够不到人"时才转埋伏，不会压制既有攻击行为。
    // flow 不可用（无 nav / 三方图）时 CND_IsAheadOnRoute 返回 FAILURE，
    // 整支退化为不存在，行为与 v5.17 完全一致。
    // ==========================================
    int routeAmbushSeq = BT_CreateSequence(4,
        BT_CreateIsAheadOnRoute(600.0),                        // 领先队伍 600 flow
        BT_CreateInverter(BT_CreateCondition(CND_HasTargetLOS)),// 有视线就该拉了
        BT_CreateIsNotInRange(850.0),                          // 射程内交给 closeRangeStrafe
        BT_CreateAction(ACT_HoldRouteAmbush)
    );

    // Root selector — v4.0.3: 攻击簇冷却 → 走位/选人，挠击消除。
    int root = BT_Create(BTN_SELECTOR);
    // v5.0 控制链核心：拉中 → SI_SignalAttack 开窗（队友跟进集火被拉者，
    // 原逻辑拉中不开窗 = 控制链断裂）+ 拖向酸液池（无酸则引擎托管拉）。
    int pinSeq = BT_CreateSequence(3,
        BT_CreateCondition(CND_IsPinningSurvivor),
        BT_CreateAction(ACT_SignalAttack),
        BT_CreateAction(SmokerAct_SteerPinToAcid)
    );
    BT_AddChild(root, pinSeq); // 1. v5.0: 拉中 → 开窗 + 拖酸
    BT_AddChild(root, cooldownPull);          // 2. v4.0.3: 全部拉人分支（1.8s 冷却）
    BT_AddChild(root, routeAmbushSeq);        // 2b. v5.18: flow 前方 → 蹲守等人进射程
    BT_AddChild(root, mode3Approach);         // 3. v4.0: mode 3 → 外侧走位接近
    BT_AddChild(root, openStrategyRoll);      // 4a. open → roll token
    BT_AddChild(root, openS0_Approach);       // 4c. open strat0 → flank approach
    BT_AddChild(root, openS1_Approach);       // 5b. open strat1 → erratic approach
    BT_AddChild(root, closeRangeStrafe);      // 6. v3.6: close + noLOS → strafe, don't approach
    BT_AddChild(root, ledgeRetargetGated);    // 7. v4.0.3: ledge 附近 → 90% 拉最远（门控）
    BT_AddChild(root, retargetCooldown);      // 8. standard retarget（孤立度选人）
    BT_AddChild(root, approachAct);           // 9. approach (only when far)
    BT_AddChild(root, BT_CreateAction(ACT_Wander)); // 10. last resort — melee IS valid here

    return root;
}

public Smoker_OnModuleStart() {
    SetConVarFloat(FindConVar("smoker_tongue_delay"), 1.0);
}
