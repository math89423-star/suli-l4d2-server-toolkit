// ============================================================================
// bt_spitter.inc — Spitter Behavior Tree (v3.2)
// ============================================================================
// v3.1: Post-spit behavior — 80% approach survivors (body-block/distract),
//       20% retreat. No longer suicides after spitting.
// Key behaviors preserved from v2.4:
//   - Combo targeting: pinned survivors > boomed survivors
//   - Snap aim to best target
// v3.2 terrain-aware additions:
//   - Narrow corridor: spit to block passage (area denial — survivors must wait or take damage)
//   - Open area: prediction spit toward escape route (cut off retreat)
//   - Near ledge: spit toward safe side to push survivors toward edge
// ============================================================================

#if defined _bt_spitter_included
  #endinput
#endif
#define _bt_spitter_included


// ---------------------------------------------------------------------------
// Post-spit state conditions
// ---------------------------------------------------------------------------

BT_Status SpitterCnd_HasSpit(int client) {
    // v3.2 FIX: use timestamp so Spitter can re-spit after cooldown (8s).
    // Previously _spitter_spit was a permanent flag that never reset,
    // turning the Spitter into a melee-only bot after its first spit.
    float spitTime = BB_GetFloat(client, "_spitter_spit_time", 0.0);
    if (spitTime <= 0.0) return BT_FAILURE;
    if (GetGameTime() - spitTime > 8.0) {
        BB_SetFloat(client, "_spitter_spit_time", 0.0);
        BB_SetInt(client, "_spitter_post_mode", 1);
        return BT_FAILURE;
    }
    return BT_SUCCESS;
}

// v5.0: 吐后行为 —— 区域毒压身份：吐完据守封锁位（8s 喷吐冷却内保持压制
// 距离重新占位），不再 80% 贴脸送死。_spitter_post_mode：
//   0 = 靠近压迫（25%）  1 = 撤退保持距离（35%）  2 = 据守封锁位（40%）
BT_Status SpitterCnd_PostSpitMode(int client) {
    int nodeId = g_iBTCurrentTickNode;
    int expected = RoundToNearest(g_fBTNodeUserParam1[nodeId]);
    return (BB_GetInt(client, "_spitter_post_mode", 1) == expected) ? BT_SUCCESS : BT_FAILURE;
}

stock int BT_CreatePostSpitMode(int mode) {
    int id = BT_Create(BTN_CONDITION);
    g_hBTFunc[id] = SpitterCnd_PostSpitMode;
    g_fBTNodeUserParam1[id] = float(mode);
    return id;
}

// ---------------------------------------------------------------------------
// Target acquisition
// ---------------------------------------------------------------------------

// Find closest pinned survivor and set as target
BT_Status SpitterAct_FindPinnedTarget(int client) {
    float spitterPos[3];
    GetClientAbsOrigin(client, spitterPos);
    int bestTarget = -1;
    float bestDist = -1.0;

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsSurvivor(i) || !IsPlayerAlive(i)) continue;
        if (!IsPinned(i)) continue;
        float survPos[3];
        GetClientAbsOrigin(i, survPos);
        float dist = GetVectorDistance(spitterPos, survPos);
        if (bestDist < 0.0 || dist < bestDist) {
            bestDist = dist;
            bestTarget = i;
        }
    }

    if (bestTarget > 0) {
        BB_SetInt(client, "target", bestTarget);
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}

// Find closest boomed survivor and set as target
BT_Status SpitterAct_FindBoomedTarget(int client) {
    if (!SI_IsBoomerActive()) return BT_FAILURE;

    float spitterPos[3];
    GetClientAbsOrigin(client, spitterPos);
    int bestTarget = -1;
    float bestDist = -1.0;

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsSurvivor(i) || !IsPlayerAlive(i)) continue;
        if (!SI_IsSurvivorBoomed(i)) continue;   // v4.1.2: prop 不存在，事件跟踪替代
        float survPos[3];
        GetClientAbsOrigin(i, survPos);
        float dist = GetVectorDistance(spitterPos, survPos);
        if (bestDist < 0.0 || dist < bestDist) {
            bestDist = dist;
            bestTarget = i;
        }
    }

    if (bestTarget > 0) {
        BB_SetInt(client, "target", bestTarget);
        return BT_SUCCESS;
    }
    return BT_FAILURE;
}

// ============================================================================
// v4.0: 预判吐 —— 目标在移动时吐向其行进路线前方（提前量 0.8s）。
// 生还者直线走位就能躲开"吐脚下"；真人 Spitter 吐的是"将到的位置"，
// 逼对方改道或直接踩上去。目标静止/低速时退回普通吐（脚下）。
// ============================================================================

BT_Status SpitterAct_PredictiveSpit(int client) {
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float tPos[3], tVel[3];
        GetClientAbsOrigin(target, tPos);
        GetEntPropVector(target, Prop_Data, "m_vecVelocity", tVel);
        float speed = GetVectorLength(tVel);
        float aimPos[3];
        if (speed > 50.0) {
            // 预测位置 = 当前 + 速度 × 0.8s（只预测水平，保持地面高度）
            aimPos[0] = tPos[0] + tVel[0] * 0.8;
            aimPos[1] = tPos[1] + tVel[1] * 0.8;
            aimPos[2] = tPos[2];
        } else {
            aimPos = tPos;
        }
        float sPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        MakeVectorFromPoints(sPos, aimPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    BT_AddButton(client, IN_ATTACK);

    // 决定 post-spit 行为（同普通吐）—— v5.0 三分：40% 据守 / 35% 撤退 / 25% 靠近
    int r = GetRandomInt(0, 9);
    BB_SetInt(client, "_spitter_post_mode", r < 4 ? 2 : (r < 7 ? 1 : 0));
    BB_SetFloat(client, "_spitter_spit_time", GetGameTime());

    return BT_SUCCESS;
}

// ============================================================================
// v4.0: 巨兽协同 (mode 6) —— 吐在 Tank 追击路线前方（掩护 Tank）。
// Tank 冲人时生还者必须后退/绕路，踩酸 = 无暇打 Tank。
// ============================================================================

BT_Status SpitterAct_SpitTankCover(int client) {
    int tank = FindTankClient(-1);
    if (tank <= 0 || !IsPlayerAlive(tank)) return BT_FAILURE;

    float tPos[3], tAng[3], fwd[3], aimPos[3];
    GetClientAbsOrigin(tank, tPos);
    GetClientEyeAngles(tank, tAng);
    tAng[0] = 0.0;
    GetAngleVectors(tAng, fwd, NULL_VECTOR, NULL_VECTOR);
    aimPos[0] = tPos[0] + fwd[0] * 250.0;
    aimPos[1] = tPos[1] + fwd[1] * 250.0;
    aimPos[2] = tPos[2];

    float sPos[3], dir[3], ang[3];
    GetClientAbsOrigin(client, sPos);
    MakeVectorFromPoints(sPos, aimPos, dir);
    GetVectorAngles(dir, ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_ATTACK);

    // 掩护吐完稍微后退（保持距离）
    BB_SetInt(client, "_spitter_post_mode", 1);
    BB_SetFloat(client, "_spitter_spit_time", GetGameTime());
    return BT_SUCCESS;
}

// ---------------------------------------------------------------------------
// Spit action — also decides post-spit behavior (80% approach / 20% retreat)
// ---------------------------------------------------------------------------

BT_Status SpitterAct_Spit(int client) {
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

    // v5.0: 吐后行为三分 —— 40% 据守封锁位 / 35% 撤退保持距离 / 25% 贴脸压迫
    // （原 80% 贴脸送死：Spitter 血 100，贴脸 = 白送，区域毒压应保持压制距离）
    int r = GetRandomInt(0, 9);
    BB_SetInt(client, "_spitter_post_mode", r < 4 ? 2 : (r < 7 ? 1 : 0));
    BB_SetFloat(client, "_spitter_spit_time", GetGameTime());  // v3.2 FIX: timestamp, not permanent flag

    return BT_SUCCESS;
}

// ============================================================================
// Tree builder
// ============================================================================

stock int BT_CreateSpitterTree() {
    // --- v3.2 terrain: narrow ---
    int narrowBlockSpit = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(900.0),
        BT_CreateAction(SpitterAct_Spit)
    );

    // ==========================================
    // v3.5: Open terrain — 2-way random strategies
    // ==========================================
    int openStrategyRoll = BT_CreateSequence(2,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateRollStrategy(2)
    );
    // Strat 0: Flank spit — approach from side → spit (area denial)
    int openS0_Approach = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(0),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateIsNotInRange(800.0),
        BT_CreateAction(ACT_FlankApproach)
    );
    int openS0_Spit = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(0),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(800.0),
        BT_CreateAction(SpitterAct_Spit)
    );
    // Strat 1: Direct spit — standard behavior (falls through to defaultSpit)

    // --- Post-spit behavior (v5.0 三分：40% 据守 / 35% 撤退 / 25% 靠近) ---
    int postSpitApproach = BT_CreateSequence(3,
        BT_CreatePostSpitMode(0),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(ACT_StrafeMoveToTarget)
    );

    int postSpitRetreat = BT_CreateSequence(2,
        BT_CreatePostSpitMode(1),
        BT_CreateAction(ACT_Retreat)
    );

    // v5.0: 据守封锁位 —— 吐完原地面向队伍保持压制距离，等 8s 冷却重新吐
    int postSpitHold = BT_CreateSequence(3,
        BT_CreatePostSpitMode(2),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(ACT_HoldPosition)
    );

    int postSpitSelector = BT_Create(BTN_SELECTOR);
    BT_AddChild(postSpitSelector, postSpitApproach);
    BT_AddChild(postSpitSelector, postSpitRetreat);
    BT_AddChild(postSpitSelector, postSpitHold);

    int postSpitSeq = BT_CreateSequence(2,
        BT_CreateCondition(SpitterCnd_HasSpit),
        postSpitSelector
    );

    // ==========================================
    // v4.0: 暗影锁链 (mode 1) —— 吐被拉的人（防救）
    // Smoker 拉中 → 窗口 → Spitter 吐被拉者脚下：救他的人必须踩酸。
    // 锁链第三环：拉 → 骑/吐 → 拖走。
    // ==========================================
    int mode1Spit = BT_CreateSequence(5,
        BT_CreateIsMode(1),
        BT_CreateCondition(CND_IsAttackWindow),
        BT_CreateAction(ACT_AcquirePinTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(900.0),
        BT_CreateAction(SpitterAct_Spit)
    );

    // ==========================================
    // v4.0: 巨兽协同 (mode 6) —— 吐 Tank 追击路线（掩护 Tank）
    // ==========================================
    int mode6Spit = BT_CreateSequence(2,
        BT_CreateIsMode(6),
        BT_CreateAction(SpitterAct_SpitTankCover)
    );

    // --- Spit on pinned survivors (combo damage) ---
    // v3.4 FIX: added CND_HasLOS + IsInRange — without these, Spitter would
    // spit toward pinned survivors through walls from across the map.
    int spitOnPinned = BT_CreateSequence(5,
        BT_CreateCondition(CND_AnySurvivorPinned),
        BT_CreateAction(SpitterAct_FindPinnedTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(900.0),
        BT_CreateAction(SpitterAct_Spit)
    );

    // --- Spit on boomed survivors ---
    // v3.4 FIX: added CND_HasLOS + IsInRange (same rationale as spitOnPinned).
    // v4.0: 预判吐 —— 被喷的人会跑，吐其逃跑路线。
    int spitOnBoomed = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsBoomerActive),
        BT_CreateAction(SpitterAct_FindBoomedTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(900.0),
        BT_CreateAction(SpitterAct_PredictiveSpit)
    );

    // ==========================================
    // v5.0 区域毒压：幸存者密集（≥3 人 500u 内）→ 吐密集区中心。
    // 密集区 = 队伍火力最集中处/推进咽喉 —— 酸液砸中心逼全员改道，
    // 封锁整片区域（用户定位：Spitter 是区域毒压，不是单兵吐）。
    // 落点自动成为全插件酸液锚点（SI_GetNearestAcid 扫描 spit_acid），
    // Jockey/Smoker/Charger 的拖人进酸/冲酸里人以此为基础。
    // ==========================================
    int spitCluster = BT_CreateSequence(5,
        BT_CreateSurvivorsClustered(3, 500.0),
        BT_CreateAction(ACT_AcquireClusterTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(900.0),
        BT_CreateAction(SpitterAct_PredictiveSpit)
    );

    // --- Default: find any target, check LOS, then spit ---
    // v3.2 FIX: added CND_HasLOS — without it, Spitter would spit toward the
    // closest survivor even when a wall was in the way, wasting the ability.
    // v4.0: 预判吐 —— 吐行进路线逼走位。
    int defaultSpit = BT_CreateSequence(3,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateAction(SpitterAct_PredictiveSpit)
    );

    // Root selector — v3.5: open terrain uses strategy tokens.
    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, postSpitSeq);
    BT_AddChild(root, mode1Spit);              // 0.5. v4.0: mode 1 → 吐被拉者
    BT_AddChild(root, mode6Spit);              // 0.5. v4.0: mode 6 → 吐 Tank 前方
    BT_AddChild(root, spitOnPinned);           // 1. combo: spit on pinned
    BT_AddChild(root, spitOnBoomed);           // 2. combo: spit on boomed
    BT_AddChild(root, spitCluster);            // 3. v5.0: 区域毒压 → 吐密集区中心
    BT_AddChild(root, narrowBlockSpit);        // 4. v3.2: narrow → area denial
    BT_AddChild(root, openStrategyRoll);       // 5a. v3.5: open → roll token
    BT_AddChild(root, openS0_Spit);            // 5b. v3.5: open strat0 → flank spit
    BT_AddChild(root, openS0_Approach);        // 5c. v3.5: open strat0 → flank approach
    // 5d: open strat1 → falls through to defaultSpit
    BT_AddChild(root, defaultSpit);            // 6. ← FALLBACK: default spit
    BT_AddChild(root, BT_CreateAction(ACT_Wander));

    return root;
}

public Spitter_OnModuleStart() {
    // v4.0.3: 引擎喷吐冷却 z_spit_interval=20s（空服 rcon 实测）vs 插件
    // post-spit 自锁 8s —— 8~20s 窗口内树已解锁、按 ATTACK 全部无效
    // （贴脸时变成挠击）。按既有模式干预引擎数值（同 smoker_tongue_delay、
    // boomer_vomit_delay）：20s → 8s，与 SpitterCnd_HasSpit 的 8s 自锁对齐，
    // 每 8s 一次有效喷吐，零无效按键。见 ENGINE_CVARS.md。
    SetConVarFloat(FindConVar("z_spit_interval"), 8.0);
}
