// ============================================================================
// bt_hunter.inc — Hunter Behavior Tree (v5.10)
// ============================================================================
// Replaces the old AI_Hunter.sp flat logic with a BT-driven decision tree.
// Key behaviors preserved from v2.4:
//   - Zigzag strafe while crouched
//   - High-pounce positioning (climb to elevated ledges)
//   - Fast pouncing with cooldown
//   - Avoid dogpiling pinned survivors
//   - Missed-pounce escape jump
//   - Gaussian-angle pounce (via ability_use event hook, unchanged)
//   - Fake direction (via ability_use event hook, unchanged)
//   - Wall detection (via ability_use event hook, unchanged)
// v3.2 terrain-aware additions:
//   - Narrow corridor: wall-bounce pounce (un-dodgeable in tight spaces)
//   - Open area: flank approach → pounce from unexpected angles
//   - Semi-open (one wall): hug wall approach → use cover
// v3.3 sprint-pounce flow (2026-07-28):
//   - FIX: Hunter no longer crouches at long range → runs full speed instead
//   - FIX: crouchApproachSeq now includes FORWARD movement (was only lateral strafe)
//   - ADDED: Sprint approach — RUNNING (no crouch) toward target when > pounce range
//   - ADDED: Transition crouch — enter pounce range → duck immediately
//   - ADDED: Direct close-range pounce (≤ straight_pounce_proximity, no Gauss offset)
//   - CHANGED: pounce ranges now read ai_fast_pounce_proximity / ai_straight_pounce_proximity
// v5.5 sprint quality pass (2026-08-05, 用户反馈"远距离慢跑活靶子"):
//   - FIX: Sprint aim offset cached per strafe switch (was re-rolled EVERY tick →
//         ±30° jitter = snake-dance, forward progress halved, looks like slow jog)
//   - ADDED: Flank-behind — 30% of strafe cycles aim at a point 200u BEHIND the
//         target → sprint arcs around to the survivor's back, pounce from behind
//   - FIX: sprintApproachSeq no longer requires NOT-ducking — ducking Hunters far
//         away also get up and sprint (was falling into crouchApproach crawl)
//   - FIX: crouchApproachSeq now gated to ≤600u — no more slow-crawl from afar
//   - ADDED: HunterAct_OverheadOffset — 30% of standard pounces aim at a point
//         above-behind the target → arc flies OVER the survivor, lands behind
// v5.7 LOS migration + crouchPrep stall fix (2026-08-13, 用户报告"Hunter 站桩"):
//   - 9× CND_HasLOS → Acquire + CND_HasTargetLOS —— Hunter 是 v5.6 唯一完全
//     漏迁移的树：引擎 m_hasVisibleThreats 失真 → 8 个扑击分支全部不可达，
//     Hunter 只剩走位 = 从不扑击
//   - crouchPrep ACT_Crouch 包 Cooldown(2.5) —— 零移动 SUCCESS 分支持续胜出
//     （幸存者 ≤500u 时蹲下不动）封顶 1 tick / 2.5s，其余时间落走位分支
//   - coordPounce 瞄准改 SnapAimToBlackboardTarget（原瞄引擎目标，反聚堆扑错人）
//   - 全部扑击攻击序列统一 SnapAimToBlackboardTarget
// ============================================================================

#if defined _bt_hunter_included
  #endinput
#endif
#define _bt_hunter_included

// ---------------------------------------------------------------------------
// Hunter-specific state (shared with main plugin via extern)
// ---------------------------------------------------------------------------

bool g_bHunterJustLunged[MAXPLAYERS + 1];
float g_fHunterMissEscapeCooldown[MAXPLAYERS + 1];

// v4.0.1: 扑击范围缓存（BT_CreateHunterTree 里从 ai_fast_pounce_proximity 读取），
// crouchApproach 需要用它判断"是否已进入扑击范围"来决定蹲伏 vs 站立快跑。
float g_fHunterPounceRange = 1000.0;

// Forward declarations for tree builder

// ---------------------------------------------------------------------------
// Hunter-specific callbacks
// ---------------------------------------------------------------------------

// Condition: Hunter just missed a pounce and is on the ground
BT_Status HunterCond_JustMissed(int client) {
    if (!g_bHunterJustLunged[client]) return BT_FAILURE;
    if (!(GetEntityFlags(client) & FL_ONGROUND)) return BT_FAILURE;

    // Check if there's a pounce victim (successful pounce)
    int victim = GetEntPropEnt(client, Prop_Send, "m_pounceVictim");
    if (victim > 0) {
        g_bHunterJustLunged[client] = false;  // clear flag on success
        return BT_FAILURE;
    }

    // Check cooldown on escape (don't spam escape jumps)
    float now = GetGameTime();
    if (g_fHunterMissEscapeCooldown[client] > now) return BT_FAILURE;

    return BT_SUCCESS;
}

// Action: Jump away in random direction after missed pounce
BT_Status HunterAct_EscapeJump(int client) {
    float ang[3];
    GetClientEyeAngles(client, ang);
    ang[1] += GetRandomFloat(60.0, 120.0) * (GetRandomInt(0, 1) ? 1.0 : -1.0);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_JUMP);
    g_bHunterJustLunged[client] = false;
    g_fHunterMissEscapeCooldown[client] = GetGameTime() + 3.0;
    return BT_SUCCESS;
}

// Condition: Is there elevated ground within 120 units above the hunter?
BT_Status HunterCond_HasHighGround(int client) {
    float hunterPos[3];
    GetClientAbsOrigin(client, hunterPos);

    // Trace from 120 units above down to find ground
    float upCheck[3];
    upCheck[0] = hunterPos[0];
    upCheck[1] = hunterPos[1];
    upCheck[2] = hunterPos[2] + 120.0;

    float downCheck[3];
    downCheck[0] = upCheck[0];
    downCheck[1] = upCheck[1];
    downCheck[2] = upCheck[2] - 200.0;

    TR_TraceRayFilter(upCheck, downCheck, MASK_PLAYERSOLID, RayType_EndPoint, TracerayFilter, client);
    if (!TR_DidHit()) return BT_FAILURE;

    float groundPos[3];
    TR_GetEndPosition(groundPos);

    // Ground must be 40-200 units above hunter
    // v5.2: 上限 200→85 —— 跳跃/蹲跳最大可达 ~85u（引擎重力 800 + 跳跃速度
    // 300 → h≈56u；蹲跳 ~85u）。>85u 的高台必跳失败：Hunter 蹲在高台/房檐下
    // 35% 概率每 tick 重掷原地跳（用户报告"Hunter 原地跳跃"）。只认跳得上的。
    float dz = groundPos[2] - hunterPos[2];
    return (dz > 40.0 && dz < 85.0) ? BT_SUCCESS : BT_FAILURE;
}

// Action: Jump up to an elevated position
BT_Status HunterAct_ClimbHighGround(int client) {
    // v5.2: 跳跃冷却 —— 原版无冷却：35% 概率每 tick 重掷，高台跳不上时原地
    // 反复跳。跳后 2s 内返回 FAILURE → highPounceSeq 整支 FAIL → selector 落到
    // approach 分支（走位拉近），2s 后才有机会再跳。
    float now = GetGameTime();
    float lastJump = BB_GetFloat(client, "_climb_last_jump", -999.0);
    if (now - lastJump < 2.0) return BT_FAILURE;

    float hunterPos[3];
    GetClientAbsOrigin(client, hunterPos);

    // Find where the high ground is (re-trace)
    float upCheck[3];
    upCheck[0] = hunterPos[0];
    upCheck[1] = hunterPos[1];
    upCheck[2] = hunterPos[2] + 120.0;

    float downCheck[3];
    downCheck[0] = upCheck[0];
    downCheck[1] = upCheck[1];
    downCheck[2] = upCheck[2] - 200.0;

    TR_TraceRayFilter(upCheck, downCheck, MASK_PLAYERSOLID, RayType_EndPoint, TracerayFilter, client);
    if (!TR_DidHit()) return BT_FAILURE;

    float groundPos[3];
    TR_GetEndPosition(groundPos);

    // Face the elevated position and jump
    float dir[3], ang[3];
    MakeVectorFromPoints(hunterPos, groundPos, dir);
    GetVectorAngles(dir, ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_JUMP);
    BB_SetFloat(client, "_climb_last_jump", now);   // v5.2: 跳跃冷却计时
    return BT_SUCCESS;
}

// ============================================================================
// v3.3 NEW ACTIONS: sprint approach + crouch approach
// ============================================================================

// Action: Sprint toward target at FULL speed (NO crouch) with erratic zigzag.
// Unlike ACT_ErraticApproach, this REMOVES IN_DUCK to guarantee running speed.
// Used when Hunter is beyond pounce range and needs to close distance fast.
// v5.5: aim offset CACHED per strafe switch (was re-rolled every tick → ±30°
// jitter every frame = snake-dance, forward progress halved, "slow jog" look).
// v5.5: flank-behind — 30% of cycles aim at a point 200u BEHIND the target,
// so the sprint arcs around to the survivor's back for a blind-side pounce.
BT_Status HunterAct_SprintApproach(int client) {
    float now = GetGameTime();

    // Strafe + aim-offset roll — change together every 0.3-0.8s
    float nextSwitch = BB_GetFloat(client, "_strafe_next");
    if (nextSwitch <= 0.0 || now >= nextSwitch) {
        bool goLeft = (GetRandomInt(0, 1) == 0);
        BB_SetBool(client, "_strafe_left", goLeft);
        // 缓存 ±25° 偏移 —— 换向时才重掷，蛇形平滑而非每帧抖动
        BB_SetFloat(client, "_aim_offset", GetRandomFloat(-25.0, 25.0));
        BB_SetFloat(client, "_strafe_next", now + GetRandomFloat(0.3, 0.8));
    }
    // Flank-behind roll — independent, slower cadence (1.2-2.2s per cycle)
    float nextFlank = BB_GetFloat(client, "_flank_next");
    if (nextFlank <= 0.0 || now >= nextFlank) {
        BB_SetBool(client, "_flank_behind", GetRandomFloat(0.0, 1.0) < 0.3);
        BB_SetFloat(client, "_flank_next", now + GetRandomFloat(1.2, 2.2));
    }
    if (BB_GetBool(client, "_strafe_left", false)) {
        BT_AddButton(client, IN_MOVELEFT);
        BT_RemoveButton(client, IN_MOVERIGHT);
    } else {
        BT_AddButton(client, IN_MOVERIGHT);
        BT_RemoveButton(client, IN_MOVELEFT);
    }

    // Forward movement — face target ±cached offset, or the point BEHIND it
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        if (BB_GetBool(client, "_flank_behind", false)) {
            // 绕后跑位：aim 目标后方 200u 的地面点 → 跑弧线绕到背后
            float behind[3];
            behind[0] = tPos[0] + dir[0] * 200.0;
            behind[1] = tPos[1] + dir[1] * 200.0;
            behind[2] = tPos[2];
            MakeVectorFromPoints(sPos, behind, dir);
            GetVectorAngles(dir, ang);
        } else {
            ang[1] += BB_GetFloat(client, "_aim_offset", 0.0);
        }
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    BT_AddButton(client, IN_FORWARD);

    // CRITICAL: Ensure NOT ducking — sprint at full running speed.
    // The old approachFull forced crouch BEFORE approach, causing slow crawl.
    BT_RemoveButton(client, IN_DUCK);
    BT_StuckDetour(client);   // v5.2: 顶墙绕行

    return BT_RUNNING;
}

// Action: Crouched approach with forward movement toward target + lateral strafe.
// Fixes the old crouchApproachSeq bug: it used ACT_StrafeRandom which only
// pressed IN_MOVELEFT/IN_MOVERIGHT with NO forward movement at all.
// The Hunter was literally strafing in place without closing distance.
BT_Status HunterAct_CrouchApproach(int client) {
    float dist = 999999.0;
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        dist = GetVectorDistance(sPos, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }

    // Lateral strafe — change direction every 0.5-1.2s
    float now = GetGameTime();
    float nextSwitch = BB_GetFloat(client, "_strafe_next");
    if (nextSwitch <= 0.0 || now >= nextSwitch) {
        bool goLeft = (GetRandomInt(0, 1) == 0);
        BB_SetBool(client, "_strafe_left", goLeft);
        BB_SetFloat(client, "_strafe_next", now + GetRandomFloat(0.5, 1.2));
    }
    if (BB_GetBool(client, "_strafe_left", false)) {
        BT_AddButton(client, IN_MOVELEFT);
        BT_RemoveButton(client, IN_MOVERIGHT);
    } else {
        BT_AddButton(client, IN_MOVERIGHT);
        BT_RemoveButton(client, IN_MOVELEFT);
    }

    // v4.0.1 FIX: 蹲伏策略 —— 只有已进入扑击范围且已经蹲伏时才保持蹲（潜行接近），
    // 范围外一律站立快跑。原版无条件按 IN_DUCK：出生（运出复活）在 1000-1150u 或
    // 无 LOS 时落入本分支 → 蹲着以 50% 移速爬 6-8 秒才到扑击距离，观感就是"缓慢蠕动"。
    // v5.4 FIX: 蹲伏条件加 LOS（m_hasVisibleThreats）——无 LOS = 障碍后看不见人，
    // 蹲爬毫无意义且速度减半。实测：500u 边界无 LOS 的 Hunter 蹲爬 + 绕行循环
    // （ai_debug: rootBranch 13 持续 8s+ 位移 <150u），观感"原地磨蹭"。
    // 无 LOS 时站立快跑绕障碍找角度，有 LOS 才蹲下潜行最后一段。
    if (dist <= g_fHunterPounceRange && (GetEntityFlags(client) & FL_DUCKING)
        && GetEntProp(client, Prop_Send, "m_hasVisibleThreats") > 0) {
        BT_AddButton(client, IN_DUCK);
    } else {
        BT_RemoveButton(client, IN_DUCK);
    }

    // Move forward toward target
    BT_AddButton(client, IN_FORWARD);
    BT_StuckDetour(client);   // v5.2: 顶墙绕行

    return BT_RUNNING;
}

// ============================================================================
// v4.0: 高位扑概率 —— 地空协同 (mode 2) 时 65%，其他模式 35%。
// 地空协同的战术 = Hunter 高空压制 + Charger 地面跟进，高位扑是核心。
// ============================================================================

BT_Status HunterCond_HighPounceChance(int client) {
    float prob = (SI_GetActiveMode() == 2) ? 0.65 : 0.35;
    return (GetRandomFloat(0.0, 1.0) < prob) ? BT_SUCCESS : BT_FAILURE;
}

// ============================================================================
// v3.5: Wide Gaussian angle offset — larger spread for open-terrain pounces.
// Uses sum-of-3-uniforms to approximate Gaussian with ~25° std dev (vs 15° standard).
// ============================================================================

BT_Status HunterAct_WideGaussOffset(int client) {
    float ang[3];
    GetClientEyeAngles(client, ang);
    float offset = (GetRandomFloat(-1.0, 1.0) + GetRandomFloat(-1.0, 1.0) + GetRandomFloat(-1.0, 1.0)) * 25.0;
    ang[1] += offset;
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    return BT_SUCCESS;
}

// ============================================================================
// v5.5: 过顶扑 —— 30% 概率把瞄准点移到"目标正后方 + 头顶之上"：
// 弹道抛物线越过幸存者头顶，落点在其身后（"越到后方突袭"）。
// 掷不中则原样保留现有瞄准（BT_SUCCESS 不改 aim）。扑空后由 missEsc 逃跳
// 接续，无死局。
// ============================================================================

BT_Status HunterAct_OverheadOffset(int client) {
    if (GetRandomFloat(0.0, 1.0) > 0.3) return BT_SUCCESS;

    int target = BB_GetInt(client, "target", -1);
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) {
        target = GetClientAimTarget(client);   // 黑板未写时退回引擎目标
    }
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) {
        return BT_SUCCESS;
    }

    float sPos[3], tPos[3], dir[3], ang[3];
    GetClientAbsOrigin(client, sPos);
    GetClientAbsOrigin(target, tPos);
    MakeVectorFromPoints(sPos, tPos, dir);

    // 过顶点 = 目标身后 80-120u + 头顶 60-90u（地面 z 之上）
    float behind[3];
    behind[0] = tPos[0] + dir[0] * GetRandomFloat(80.0, 120.0);
    behind[1] = tPos[1] + dir[1] * GetRandomFloat(80.0, 120.0);
    behind[2] = tPos[2] + GetRandomFloat(60.0, 90.0);
    MakeVectorFromPoints(sPos, behind, dir);
    GetVectorAngles(dir, ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    return BT_SUCCESS;
}

// ============================================================================
// Tree builder
// ============================================================================

stock int BT_CreateHunterTree() {
    // --- Read pounce-range cvars (fall back to safe defaults) ---
    // v5.3: fallback 1000→500 —— 引擎 hunter_pounce_ready_range=500（模块启动
    // 设置），引擎只在 500u 内发起扑击；插件 1000u 就按 ATTACK = 600-1000u
    // 区间全无效按键（扑不出 → 扑空 → missEsc 逃跳 → 再扑 = "跳一下扑一下"
    // 循环）。cvar 已由 Hunter_OnModuleStart 创建，此处防无 cvar 时掉回旧值。
    float fPounceRange = 500.0;
    float fStraightRange = 200.0;
    ConVar hCvar = FindConVar("ai_fast_pounce_proximity");
    if (hCvar != null) fPounceRange = GetConVarFloat(hCvar);
    hCvar = FindConVar("ai_straight_pounce_proximity");
    if (hCvar != null) fStraightRange = GetConVarFloat(hCvar);
    g_fHunterPounceRange = fPounceRange;  // v4.0.1: 供 crouchApproach 判断蹲伏 vs 快跑

    // --- Leaf nodes ---
    int missEscSeq = BT_CreateSequence(2,
        BT_CreateCondition(HunterCond_JustMissed),
        BT_CreateAction(HunterAct_EscapeJump)
    );

    // v3.2: HasHighGround check so Hunter only climbs when there is
    // actually elevated ground above. Without it, 35% of crouched ticks trace-hit
    // the ground at Hunter's feet and jump uselessly (原地跳跃).
    // v4.0.3: 加距离门控 —— 原版无任何距离/LOS 限制，只要蹲着 + 头顶
    // 40-200u 有高台，35%/65% 概率每 tick 重掷跳台（跳-蹲-跳抖动，高台图
    // 上大量时间在爬不在扑）。现在只在"最近生还者 1000-1600u"才爬高：
    //   ≤1000u：直接扑（closePounce/fastPounce 分支处理，不再爬高）
    //   >1600u：爬了够不着，交给 sprintApproach 快跑接近
    int highPounceSeq = BT_CreateSequence(6,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateCondition(HunterCond_HasHighGround),
        BT_CreateIsNotInRange(fPounceRange),        // 扑击范围内不爬高，直接扑
        BT_CreateIsInRange(fPounceRange + 600.0),   // 1600u 外爬了没用
        BT_CreateSequence(2,
            BT_CreateCondition(HunterCond_HighPounceChance),  // v4.0: mode 2 → 65%
            BT_CreateAction(HunterAct_ClimbHighGround)
        )
    );

    // --- v3.2: Terrain-aware pounce strategies ---
    // Narrow corridor: wall-bounce pounce — aim forward + ATTACK
    // In tight spaces, survivors can't dodge → just pounce straight
    // v5.7: HasLOS → Acquire + HasTargetLOS（trace 视线；引擎标志失真时
    // 全扑击分支不可达）+ 距离改 target 口径；攻击瞄准改黑板目标
    int narrowPounceSeq = BT_CreateSequence(6,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(800.0)  // longer range in corridors
    );
    int narrowAttackSeq = BT_CreateSequence(3,
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(ACT_QueueLunge),
        BT_CreateAction(ACT_SignalAttack)
    );
    // v5.9 FIX: 移除 Cooldown 包裹 —— v4.0.3 的 Cooldown(1.0) 制造了和 v5.7
    // crouchPrepSeq 一样的站桩 bug：冷却期内 narrowPounceSeq 前置条件仍满足
    // （蹲姿+窄巷+LOS+距离），但 Cooldown FAIL → 整个 Sequence FAIL，selector
    // 反复选中此分支又反复 FAIL = 站着不动。引擎自带扑击冷却（z_lunge_interval
    // 默认 0.5s），插件侧不需要再锁。直接把攻击动作合并进 Sequence。
    BT_AddChild(narrowPounceSeq, narrowAttackSeq);

    // ==========================================
    // v3.5: Open terrain — 3-way random pounce strategies
    // ==========================================
    // Strategy roll
    int openStrategyRoll = BT_CreateSequence(2,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateRollStrategy(3)
    );
    // Strategy 0: Wide flank pounce — wider Gaussian spread (±25°, harder to dodge)
    int openStrat0_WidePounce = BT_CreateSequence(8,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateStrategyIs(0),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fPounceRange),
        BT_CreateInverter(BT_CreateCondition(CND_IsTargetPinned))
    );
    int widePounceAttack = BT_CreateSequence(3,
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(HunterAct_WideGaussOffset),
        BT_CreateAction(ACT_QueueLunge)
    );
    // v5.9: 移除 Cooldown，直接合并（同 narrowPounceSeq 修复）
    BT_AddChild(openStrat0_WidePounce, widePounceAttack);

    // Strategy 1: Erratic pounce — standard Gauss offset + unpredictable approach
    int openStrat1_ErraticPounce = BT_CreateSequence(8,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateStrategyIs(1),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fPounceRange),
        BT_CreateInverter(BT_CreateCondition(CND_IsTargetPinned))
    );
    int erraticPounceAttack = BT_CreateSequence(3,
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(ACT_GaussianAimOffset),
        BT_CreateAction(ACT_QueueLunge)
    );
    // v5.9: 移除 Cooldown，直接合并（同 narrowPounceSeq 修复）
    BT_AddChild(openStrat1_ErraticPounce, erraticPounceAttack);

    // Strategy 2: Standard pounce — falls through to fastPounceSeq below

    // Semi-open / one wall: hug wall for cover while approaching
    // v5.7: Acquire 提到 Inverter 之前 —— 原版黑板无目标时
    // Inverter(HasTargetLOS) 恒真，半开地形无条件贴墙
    int semiApproachSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateCondition(CND_IsSemiOpen),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateInverter(BT_CreateCondition(CND_HasTargetLOS))
    );
    int semiHugAction = BT_CreateSequence(2,
        BT_CreateAction(ACT_Crouch),             // duck first (before RUNNING blocks it)
        BT_CreateAction(ACT_HugWall)             // move along wall (RUNNING, last)
    );
    BT_AddChild(semiApproachSeq, semiHugAction);

    // --- Standard fast pounce ---
    int fastPounceSeq = BT_CreateSequence(2,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking)
    );

    int pounceInnerSeq = BT_CreateSequence(4,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fPounceRange),
        BT_CreateInverter(BT_CreateCondition(CND_IsTargetPinned))
    );

    // v3.2: GaussianAimOffset for unpredictable pounce angles.
    // Sum-of-3-uniforms approximates Gaussian with ~15° std dev spread.
    // v5.5: OverheadOffset 插在 SnapAim 之后 —— 30% 概率改瞄目标后方头顶，
    // 过顶抛物线落后（掷不中则保留 SnapAim 的瞄准，Gauss 照常微调）。
    // v5.10 FIX: 移除 Cooldown 包裹 —— fastPounceSeq 是 v5.9 遗漏的最后一个
    // 站桩 bug：冷却期内前置条件满足但 Cooldown FAIL → 整支 FAIL → selector
    // 反复选中分支7又反复 FAIL = 站着不动。引擎自带扑击冷却（z_lunge_interval
    // 默认 0.5s），插件侧不需要再锁。直接合并攻击序列到 fastPounceSeq。
    int attackActionSeq = BT_CreateSequence(5,
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(HunterAct_OverheadOffset),
        BT_CreateAction(ACT_GaussianAimOffset),
        BT_CreateAction(ACT_QueueLunge),
        BT_CreateAction(ACT_SignalAttack)
    );

    // --- v3.3: Close-range direct pounce (no Gauss offset, faster reaction) ---
    int closePounceSeq = BT_CreateSequence(6,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fStraightRange),
        BT_CreateInverter(BT_CreateCondition(CND_IsTargetPinned))
    );
    int closeAttackSeq = BT_CreateSequence(2,
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(ACT_QueueLunge)
    );
    // v5.9: 移除 Cooldown，直接合并（同 narrowPounceSeq 修复）
    BT_AddChild(closePounceSeq, closeAttackSeq);

    // --- v3.3: Sprint approach — RUN full speed when far from target ---
    // Replaces the old approachFull which forced crouch BEFORE running.
    // Crouching cuts movement speed by ~50%, making Hunter crawl slowly.
    // This branch only fires when: OnGround + NOT ducking + > pounce range.
    // v4.0.1 FIX: 边界从 fPounceRange+150 改回 fPounceRange —— v4.0 的 +150 迟滞
    //       在 1000~1150u 之间制造了死区（sprint 不触发、crouchPrep 也不触发），
    //       出生运出点常落在这个区间 → 直接掉进 crouchApproachSeq 蹲爬蠕动。
    //       原迟滞意图（防 sprint↔crouch 边界抖动）已由 crouchApproach 的
    //       站立快跑化取代（见 HunterAct_CrouchApproach），抖动代价消失。
    // v5.4 FIX: 跑近目标从 500u 改 400u —— 实测 500u 边界处 sprint(12) ↔
    //       crouchApproach(13) 来回切换（ai_debug: Hunter(8) 324→632u 反复）：
    //       跑近 500 → 蹲爬/绕行 → 绕出 500 → 再跑近…… 永远压不进扑击距离。
    //       400u 才停跑 = 500-400u 间让 crouchPrep/蹲扑接管，消除回弹。
    // v5.5 FIX: 去掉 NOT IsDucking —— 蹲姿出生的 Hunter 远处也会站起冲刺
    //       （SprintApproach 内部 RemoveButton(IN_DUCK)），不再掉进
    //       crouchApproach 兜底慢走。远距离一律冲刺。
    int sprintApproachSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_OnGround),
        BT_CreateInverter(BT_CreateIsInRange(fPounceRange - 100.0)),
        BT_CreateSequence(2,
            BT_CreateAction(ACT_AcquireClosestTarget),
            BT_CreateAction(HunterAct_SprintApproach)
        )
    );

    // --- v3.3: Transition crouch — enter pounce range → crouch immediately ---
    // When the sprint approach brings Hunter within pounce range, this branch
    // fires on the next tick: crouch now. The tick after that, fastPounceSeq
    // triggers the actual pounce. Natural sprint→crouch→pounce flow.
    // v5.7 FIX: 站桩根因 —— 原版 ACT_Crouch 每 tick SUCCESS（零移动、只按
    // DUCK），目标 ≤500u 且 LOS 时本分支持续胜出 = 幸存者走近后 Hunter 反而
    // 蹲下不动。修复：① HasLOS → Acquire + HasTargetLOS（trace 视线）；
    // ② Crouch 包 Cooldown(2.5) —— 蹲 1 tick 后冷却期 FAIL → 落
    // crouchApproach/sprint 走位分支，零移动封顶 1 tick / 2.5s。
    // v5.8 FIX: 冷却机制导致新站桩 —— 冷却期内 crouchPrepSeq FAIL，但距离
    // 仍在范围内，条件又满足分支 8，循环 FAIL。修复：移除冷却，改为持续
    // 按住 DUCK（ACT_Crouch 每 tick 返回 SUCCESS），让引擎完成蹲伏动作。
    // fastPounceSeq 优先级更高（分支 7 在 8 之前），一旦 IsDucking 成立立即扑击。
    int crouchPrepSeq = BT_CreateSequence(6,
        BT_CreateCondition(CND_OnGround),
        BT_CreateInverter(BT_CreateCondition(CND_IsDucking)),
        BT_CreateIsInRange(fPounceRange),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateAction(ACT_Crouch)
    );

    // --- v3.3: Fixed crouch approach (in range + ducking + no LOS) ---
    // Uses HunterAct_CrouchApproach which moves FORWARD while strafing.
    // Old version used ACT_StrafeRandom which only did lateral movement.
    // v5.5: 加 ≤600u 门控 —— 只允许扑击距离边缘的最后一小段蹲爬接近；
    //       更远处一律交给 sprintApproachSeq 全速冲刺（不再兜底慢走）。
    int crouchApproachSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_OnGround),
        BT_CreateIsInRange(fPounceRange + 100.0),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(HunterAct_CrouchApproach)
    );

    // ==========================================
    // v4.0: 分散扑（猎手集群 mode 4 / 巨兽协同 mode 6）
    // 用协同分配目标（防 dogpile）：多 Hunter 扑不同目标。
    // mode 4: 猎手集群的核心 —— 数量优势靠分散角度打出
    // mode 6: 巨兽协同 —— 全员分散控制，减轻 Tank 被集火压力
    // ==========================================
    // v5.7: 协同目标上移条件段（门控量同一个人）+ 瞄准改黑板目标 ——
    // 原版门控量 BB target（常空/陈旧）而瞄准引擎目标，反聚堆扑击瞄错人
    int coordPounceSeq = BT_CreateSequence(7,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateIsModeAny(4, 6),
        BT_CreateAction(ACT_AcquireCoordTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fPounceRange),
        BT_CreateInverter(BT_CreateCondition(CND_IsTargetPinned))
    );
    int coordPounceAttack = BT_CreateSequence(2,
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(ACT_QueueLunge)
    );
    // v5.9: 移除 Cooldown，直接合并（同 narrowPounceSeq 修复）
    BT_AddChild(coordPounceSeq, coordPounceAttack);

    // ==========================================
    // v5.0 枪线扰乱者（任何模式生效）：优先扑"正在输出的人"——
    // 高火力威胁目标（SI_GetHighestThreatSurvivor：狙击/霰弹/榴弹枪手）。
    // 扑掉枪手 = 打乱幸存者火力网，为近战 SI 创造突破窗口。
    // 与 coordPounce（mode 4/6 分散）区分：这是通用身份行为，优先级
    // 放在分散扑之后 —— 分散模式仍优先防 dogpile，其余模式优先打枪手。
    // ==========================================
    int disruptionSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateAction(ACT_AcquireThreatTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fPounceRange)
    );
    int disruptionAttack = BT_CreateSequence(3,
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(ACT_QueueLunge),
        BT_CreateAction(ACT_SignalAttack)
    );
    // v5.9: 移除 Cooldown，直接合并（同 narrowPounceSeq 修复）
    BT_AddChild(disruptionSeq, disruptionAttack);

    int wander = BT_CreateAction(ACT_Wander);

    // --- Build main tree ---
    BT_AddChild(fastPounceSeq, pounceInnerSeq);
    BT_AddChild(fastPounceSeq, attackActionSeq);

    // Root selector — priority order (v3.5):
    //   1. Escape after miss (safety first)
    //   2. High-ground positioning (tactical advantage)
    //   3. Narrow corridor → straight pounce
    //   4a. Open area → roll strategy token
    //   4b. Open + strat0 → wide flank pounce (±25° Gauss)
    //   4c. Open + strat1 → erratic pounce (standard ±15° Gauss)
    //   4d. Open + strat2 → falls through to standard fast pounce
    //   5. Semi open → hug wall approach
    //   6. Close range (≤200) → direct pounce (no Gauss, faster) [v3.3]
    //   7. Standard fast pounce (ducking + LOS + inRange → pounce with Gauss)
    //   8. In range + not ducking → crouch to prepare pounce [v3.3]
    //   9. Far away → SPRINT full speed toward target [v3.3]
    //   10. In range + ducking + no LOS → crouch approach with forward movement [v3.3]
    //   11. Last resort → wander
    //
    // The sprint→crouch→pounce flow (8→7 or 9→8→7):
    //   Tick N:   Hunter far away → branch 9 (sprint) activates, runs toward target
    //   Tick N+1: Entered pounce range → branch 8 (crouchPrep) fires, presses DUCK
    //   Tick N+2: FL_DUCKING set → branch 7 (fastPounce) fires, POUNCES!
    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, missEscSeq);              // 1. escape after miss
    BT_AddChild(root, highPounceSeq);           // 2. high-ground positioning
    BT_AddChild(root, narrowPounceSeq);         // 3. v3.2: narrow → straight pounce
    BT_AddChild(root, coordPounceSeq);          // 3.5. v4.0: mode 4/6 分散扑（防 dogpile）
    BT_AddChild(root, disruptionSeq);           // 3.6. v5.0: 枪线扰乱 → 扑火力输出者
    BT_AddChild(root, openStrategyRoll);        // 4a. v3.5: open → roll token
    BT_AddChild(root, openStrat0_WidePounce);   // 4b. v3.5: open strat0 → wide pounce
    BT_AddChild(root, openStrat1_ErraticPounce);// 4c. v3.5: open strat1 → erratic pounce
    // 4d: open strat2 → falls through to fastPounceSeq
    BT_AddChild(root, semiApproachSeq);         // 5. v3.2: semi → hug wall
    BT_AddChild(root, closePounceSeq);          // 6. v3.3: close-range direct pounce
    BT_AddChild(root, fastPounceSeq);           // 7. standard fast pounce (Gauss angle)
    BT_AddChild(root, crouchPrepSeq);           // 8. v3.3: inRange + noDuck → crouch
    BT_AddChild(root, sprintApproachSeq);       // 9. v3.3: far away → SPRINT full speed
    BT_AddChild(root, crouchApproachSeq);       // 10. v3.3: inRange + ducking + noLOS → strafe+forward
    BT_AddChild(root, wander);                  // 11. last resort

    return root;
}

// Module init — register cvars
public Hunter_OnModuleStart() {
    // v5.3: 创建扑击距离 cvar —— v4.0.3 实测确认这两个 cvar 从未被创建
    // （Hunter 一直用 fallback）。创建后 500/200 成为可调值，且树构建
    // （OnPluginStart 内，模块启动之后）能正确读取。
    // reload 时引擎 cvar 常驻 → 存在性判断防重复创建告警。
    ConVar hCvar = FindConVar("ai_fast_pounce_proximity");
    if (hCvar == null) {
        hCvar = CreateConVar("ai_fast_pounce_proximity", "500",
            "Hunter 扑击距离门控（对齐引擎 hunter_pounce_ready_range=500）",
            FCVAR_NONE, true, 100.0, true, 2000.0);
    }
    hCvar = FindConVar("ai_straight_pounce_proximity");
    if (hCvar == null) {
        hCvar = CreateConVar("ai_straight_pounce_proximity", "200",
            "Hunter 近距离直扑距离（无 Gauss 偏移）",
            FCVAR_NONE, true, 50.0, true, 1000.0);
    }
    SetConVarInt(FindConVar("hunter_committed_attack_range"), 10000);
    SetConVarInt(FindConVar("hunter_pounce_ready_range"), 500);
    SetConVarInt(FindConVar("hunter_leap_away_give_up_range"), 0);
    SetConVarInt(FindConVar("hunter_pounce_max_loft_angle"), 0);
}
