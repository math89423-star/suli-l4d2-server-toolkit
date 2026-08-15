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
// v4.0.4: 全部呕吐距离对齐引擎实测 z_vomit_range=300（空服 rcon，见
//   ENGINE_CVARS.md）。v3.5 的 500/550 为自创值：引擎在 300u 外不发射，
//   approach 在 550u 就停 → Boomer 永远进不了射程，站桩对空气无限按无效
//   呕吐键（原版 Boomer 就是贴脸吐，射程只有 300u）。
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
        BB_SetBool(client, "just_vomited", false);   // v5.22: 与吐中标记同生命周期清零
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

    bool watched = IsTargetWatchingAttacker(client);
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
// v5.6: 按住 IN_ATTACK 直到真实吐出（player_now_it 事件置 _boomer_vomit_hit）
// 或 2s 超时。原版单帧按键 + 无条件锁 10s：引擎 boomer_vomit_delay=0.1s
// 风阻窗口吞掉单帧按键 → 按了个寂寞还锁 10s（"300u 内不吐"主因之一）。
// 超时未命中 = 引擎拒绝（射程/LOS/冷却），返回 FAILURE 不设锁，交走位分支。
BT_Status BoomerAct_Vomit(int client) {
    float now = GetGameTime();
    float pressStart = BB_GetFloat(client, "_vomit_press_start", 0.0);
    if (pressStart <= 0.0) {
        BB_SetFloat(client, "_vomit_press_start", now);
        BB_SetBool(client, "_boomer_vomit_hit", false);
    }
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

    BT_AddButton(client, IN_ATTACK);  // vomit (held)

    if (BB_GetBool(client, "_boomer_vomit_hit", false)) {
        // 真实吐出 —— 锁由 OnPlayerBoomed 事件设置（事件时刻 + 10s）
        BB_SetFloat(client, "_vomit_press_start", 0.0);
        return BT_SUCCESS;
    }
    if (now - pressStart > 2.0) {
        // 引擎拒绝（风阻/冷却/超射程）—— 撤销按压，不设锁
        BB_SetFloat(client, "_vomit_press_start", 0.0);
        return BT_FAILURE;
    }
    return BT_RUNNING;
}

// ============================================================================
// Tree builder
// ============================================================================

stock int BT_CreateBoomerTree() {
    // ==========================================
    // v4.0: 伏击等待 —— narrow 地形不冲脸，原地隐藏等目标进 300u 再吐。
    // 真人 Boomer 会提前预判队伍行进路线，藏在必经之路上。
    // 目标 < 300u 时本分支 FAIL → 落到 narrowHoldVomit/vomitSeq 吐。
    // v4.1.1: 两道保险 —— ① 目标 > 1500u 不伏击（出生太远直接 approach，
    // 先拉近距离再说）；② 伏击超时 8s（目标迟迟不进射程 = 不会来，
    // 放弃伏击主动接近）。修复"出生远 → 无限站桩 → 被电脑处死"。
    // ==========================================
    int ambushHold = BT_CreateAction(ACT_AmbushHold);
    BT_SetUserParam1(ambushHold, 8.0);          // 伏击超时 8s
    int ambushSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateIsNotInRange(300.0),
        BT_CreateIsInRange(1500.0),             // 距离上限：>1500u 直接接近
        ambushHold
    );

    // ==========================================
    // v4.0: 暗影锁链 (mode 1) —— 吐被拉的人（解救时全家被喷）
    // Smoker 拉中 → 窗口 → Boomer 吐被拉者：救他的人挤成一团全被喷
    // ==========================================
    // v5.6: HasLOS → HasTargetLOS（引擎标志失真时吐不出）+ 距离改 target 口径
    int mode1Vomit = BT_CreateSequence(5,
        BT_CreateIsMode(1),
        BT_CreateCondition(CND_IsAttackWindow),
        BT_CreateAction(ACT_AcquirePinTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange_Scaled(300.0),  // v5.8: pressure-scaled vomit range
        BT_CreateAction(BoomerAct_Vomit)
    );

    // ==========================================
    // v5.0 补刀者：有幸存者被控（Smoker 拉/Charger 撞/Jockey 骑等）→
    // 专程逼近被控者 → 300u 内喷。被控者无法躲闪吐必中；救人者挤上来 =
    // 全家被喷（用户定位：Boomer 是补刀者，贴近已被控制的人造成更多伤害）。
    // 与 mode1Vomit 的区别：mode1 只在窗口内靠 pin 广播（3s 过期）吐，
    // 这里用实时谁控谁映射（SI_GetNearestPinnedSurvivor），任何模式生效。
    // 目标限定 600u（射程 300，被控者 300-600u 之间接近期不浪费呕吐）。
    // ==========================================
    // v5.6: 距离条件改 target 口径 —— 原版 IsInRange(300) 量"最近幸存者"：
    // 被控者 250u（该吐！）但最近者 320u 时 finishApproach 误判"还远"继续
    // 逼近；反向（最近者贴脸、被控者 400u）时按无效吐键。被控者 300-600u
    // 之间是接近期，300u 内才吐。
    int finishApproach = BT_CreateSequence(4,
        BT_CreateCondition(CND_AnySurvivorPinned),
        BT_CreateAcquirePinnedTarget(600.0),
        BT_CreateIsNotTargetInRange(300.0),
        BT_CreateAction(BoomerAct_FlankApproach)
    );
    int finishVomit = BT_CreateSequence(5,
        BT_CreateCondition(CND_AnySurvivorPinned),
        BT_CreateAcquirePinnedTarget(600.0),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange_Scaled(300.0),  // v5.8: pressure-scaled vomit range
        BT_CreateAction(BoomerAct_Vomit)
    );

    // --- v3.2: Terrain-aware vomit strategies ---
    // Narrow corridor: hold chokepoint → vomit to cover entire passage
    // v5.6: 删除 ACT_HoldChokepoint 死代码（返回 SUCCESS 且不按任何键——
    // "守窄口"从未生效，同 tick 直接继续执行 Vomit）+ HasLOS → HasTargetLOS
    int narrowHoldVomit = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange_Scaled(300.0),  // v5.8: pressure-scaled vomit range
        BT_CreateAction(BoomerAct_Vomit)
    );

    // v3.2 FIX: Split into approach + vomit branches.
    // Previously FlankApproach(RUNNING) blocked BoomerAct_Vomit in the sequence.
    // ==========================================
    // v3.5: Open terrain — 2-way random
    // v4.0.4: 550/500 射程对齐引擎 300（见文件头注释）
    // ==========================================
    int openStrategyRoll = BT_CreateSequence(2,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateRollStrategy(2)
    );
    // Strat 0: Flank vomit — circle around → vomit from side
    int openS0_Approach = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(0),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateIsNotInRange(300.0),
        BT_CreateAction(ACT_FlankApproach)
    );
    // v5.6: HasLOS → HasTargetLOS
    int openS0_Vomit = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(0),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange_Scaled(300.0),  // v5.8: pressure-scaled vomit range
        BT_CreateAction(BoomerAct_Vomit)
    );
    // Strat 1: Erratic vomit — zigzag approach → vomit from varied angle
    int openS1_Approach = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(1),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateIsNotInRange(300.0),
        BT_CreateAction(ACT_ErraticApproach)
    );
    // v5.6: HasLOS → HasTargetLOS
    int openS1_Vomit = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(1),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange_Scaled(300.0),  // v5.8: pressure-scaled vomit range
        BT_CreateAction(BoomerAct_Vomit)
    );

    // v3.2 FIX: Split into approach + vomit branches.
    // Previously HugWall(RUNNING) blocked BoomerAct_Vomit in the sequence.
    // Semi-open: hug wall approach while far from target
    int semiHugApproach = BT_CreateSequence(4,
        BT_CreateCondition(CND_IsSemiOpen),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateInverter(BT_CreateIsInRange(300.0)),
        BT_CreateAction(ACT_HugWall)
    );
    // Semi-open: vomit from cover when in range
    // v5.6: HasLOS → HasTargetLOS
    int semiHugVomit = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsSemiOpen),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange_Scaled(300.0),  // v5.8: pressure-scaled vomit range
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
    // v5.6: HasLOS → HasTargetLOS
    int vomitSeq = BT_CreateSequence(4,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange_Scaled(300.0),  // v5.8: pressure-scaled vomit range
        BT_CreateAction(BoomerAct_Vomit)
    );

    // --- Approach: get in range for vomit ---
    int approachSeq = BT_CreateSequence(2,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(BoomerAct_FlankApproach)
    );

    // ==========================================
    // v5.18 功能 1：flow 前置埋伏
    // ------------------------------------------
    // Boomer 主动接近就是送 —— 被远距离打爆等于给队伍免费清场。
    // 已在队伍前方时蹲住等玩家自己走进 300u 吐射程，是它最强的一手。
    // 排在吐/补刀分支之后，只在够不到人时接管。
    // ==========================================
    int routeAmbushSeq = BT_CreateSequence(4,
        BT_CreateIsAheadOnRoute(500.0),
        BT_CreateInverter(BT_CreateCondition(CND_HasTargetLOS)),
        BT_CreateIsNotInRange(450.0),   // 450u 内已进接近战，交给既有分支
        BT_CreateAction(ACT_HoldRouteAmbush)
    );

    // Root selector — terrain branches fail when disabled → fallback to standard.
    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, postVomitSeq);
    BT_AddChild(root, ambushSeq);          // 1.5. v4.0: narrow → 伏击等待
    BT_AddChild(root, mode1Vomit);         // 1.5. v4.0: mode 1 → 吐被拉者
    BT_AddChild(root, finishApproach);     // 2. v5.0: 补刀者 → 逼近被控者
    BT_AddChild(root, finishVomit);        // 3. v5.0: 补刀者 → 吐被控者
    BT_AddChild(root, narrowHoldVomit);    // 4. v3.2: narrow → block + vomit
    BT_AddChild(root, openStrategyRoll);   // 5a. v3.5: open → roll token
    BT_AddChild(root, openS0_Vomit);       // 5b. v3.5: open strat0 → flank vomit
    BT_AddChild(root, openS0_Approach);    // 5c. v3.5: open strat0 → flank approach
    BT_AddChild(root, openS1_Vomit);       // 6a. v3.5: open strat1 → erratic vomit
    BT_AddChild(root, openS1_Approach);    // 6b. v3.5: open strat1 → erratic approach
    BT_AddChild(root, semiHugVomit);       // 7. v3.2: semi → vomit
    BT_AddChild(root, semiHugApproach);    // 7b. v3.2: semi → hug wall
    BT_AddChild(root, routeAmbushSeq);     // 7c. v5.18: flow 前方 → 蹲守等人进吐程
    BT_AddChild(root, vomitSeq);           // 8. ← FALLBACK: standard vomit
    BT_AddChild(root, approachSeq);        // 9. ← FALLBACK: approach
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
        // v5.6: 真实吐出确认 —— 原版在按 IN_ATTACK 的瞬间就设 10s 锁：
        // 引擎拒绝时（超射程/LOS 假/冷却）白白锁 10s。锁起点移到事件：
        // 只在真的吐到人后才锁 + 掷 80/20 后置行为。
        BB_SetBool(attacker, "_boomer_vomit_hit", true);
        BB_SetFloat(attacker, "_boomer_vomit_time", GetGameTime());
        // v5.22 FIX: 补写 just_vomited —— CND_InitiatorEngaged(bt_common.inc:436)
        // 读此键判定 Boomer 发起者是否得手，但全代码库从无写入点 → 恒假 →
        // Boomer 当发起者时骚扰者(Hunter/Jockey/Charger)只能靠 5s 硬超时放行，
        // 配合窗口延迟 5s。此键与 _boomer_vomit_time 同生命周期，在 Boomer_Tick
        // 的 10s 到期处(bt_boomer.inc:38 一带)一并清零。
        BB_SetBool(attacker, "just_vomited", true);
        bool approach = (GetRandomFloat(0.0, 1.0) < 0.8);
        BB_SetBool(attacker, "_boomer_approach", approach);
    }
}
