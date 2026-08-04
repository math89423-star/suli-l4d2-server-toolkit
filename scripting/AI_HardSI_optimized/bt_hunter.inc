// ============================================================================
// bt_hunter.inc — Hunter Behavior Tree (v3.3)
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
    float dz = groundPos[2] - hunterPos[2];
    return (dz > 40.0 && dz < 200.0) ? BT_SUCCESS : BT_FAILURE;
}

// Action: Jump up to an elevated position
BT_Status HunterAct_ClimbHighGround(int client) {
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
    return BT_SUCCESS;
}

// ============================================================================
// v3.3 NEW ACTIONS: sprint approach + crouch approach
// ============================================================================

// Action: Sprint toward target at FULL speed (NO crouch) with erratic zigzag.
// Unlike ACT_ErraticApproach, this REMOVES IN_DUCK to guarantee running speed.
// Used when Hunter is beyond pounce range and needs to close distance fast.
BT_Status HunterAct_SprintApproach(int client) {
    // Strafe component — change direction every 0.3-0.8s
    float now = GetGameTime();
    float nextSwitch = BB_GetFloat(client, "_strafe_next");
    if (nextSwitch <= 0.0 || now >= nextSwitch) {
        bool goLeft = (GetRandomInt(0, 1) == 0);
        BB_SetBool(client, "_strafe_left", goLeft);
        BB_SetFloat(client, "_strafe_next", now + GetRandomFloat(0.3, 0.8));
    }
    if (BB_GetBool(client, "_strafe_left", false)) {
        BT_AddButton(client, IN_MOVELEFT);
        BT_RemoveButton(client, IN_MOVERIGHT);
    } else {
        BT_AddButton(client, IN_MOVERIGHT);
        BT_RemoveButton(client, IN_MOVELEFT);
    }

    // Forward movement at ±30° random offset from target direction
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        ang[1] += GetRandomFloat(-30.0, 30.0);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    BT_AddButton(client, IN_FORWARD);

    // CRITICAL: Ensure NOT ducking — sprint at full running speed.
    // The old approachFull forced crouch BEFORE approach, causing slow crawl.
    BT_RemoveButton(client, IN_DUCK);

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
    if (dist <= g_fHunterPounceRange && (GetEntityFlags(client) & FL_DUCKING)) {
        BT_AddButton(client, IN_DUCK);
    } else {
        BT_RemoveButton(client, IN_DUCK);
    }

    // Move forward toward target
    BT_AddButton(client, IN_FORWARD);

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
// Tree builder
// ============================================================================

stock int BT_CreateHunterTree() {
    // --- Read pounce-range cvars (fall back to safe defaults) ---
    float fPounceRange = 1000.0;
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
    int narrowPounceSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(800.0)  // longer range in corridors
    );
    int narrowAttackSeq = BT_CreateSequence(3,
        BT_CreateAction(ACT_SnapAimToTarget),
        BT_CreateAction(ACT_QueueLunge),
        BT_CreateAction(ACT_SignalAttack)
    );
    // v4.0.3: 攻击序列统一包 Cooldown(1.0)（对齐 fastPounceSeq 的
    // cooldownAttack 既有模式）—— 原版这些分支每 tick 按 IN_ATTACK，
    // 引擎扑击冷却期间全部变成无效按键/近战挥击。
    BT_AddChild(narrowPounceSeq, BT_CreateCooldown(1.0, narrowAttackSeq));

    // ==========================================
    // v3.5: Open terrain — 3-way random pounce strategies
    // ==========================================
    // Strategy roll
    int openStrategyRoll = BT_CreateSequence(2,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateRollStrategy(3)
    );
    // Strategy 0: Wide flank pounce — wider Gaussian spread (±25°, harder to dodge)
    int openStrat0_WidePounce = BT_CreateSequence(7,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateStrategyIs(0),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(fPounceRange),
        BT_CreateInverter(BT_CreateCondition(CND_IsTargetPinned))
    );
    int widePounceAttack = BT_CreateSequence(3,
        BT_CreateAction(ACT_SnapAimToTarget),
        BT_CreateAction(HunterAct_WideGaussOffset),
        BT_CreateAction(ACT_QueueLunge)
    );
    BT_AddChild(openStrat0_WidePounce, BT_CreateCooldown(1.0, widePounceAttack));

    // Strategy 1: Erratic pounce — standard Gauss offset + unpredictable approach
    int openStrat1_ErraticPounce = BT_CreateSequence(7,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateStrategyIs(1),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(fPounceRange),
        BT_CreateInverter(BT_CreateCondition(CND_IsTargetPinned))
    );
    int erraticPounceAttack = BT_CreateSequence(3,
        BT_CreateAction(ACT_SnapAimToTarget),
        BT_CreateAction(ACT_GaussianAimOffset),
        BT_CreateAction(ACT_QueueLunge)
    );
    BT_AddChild(openStrat1_ErraticPounce, BT_CreateCooldown(1.0, erraticPounceAttack));

    // Strategy 2: Standard pounce — falls through to fastPounceSeq below

    // Semi-open / one wall: hug wall for cover while approaching
    int semiApproachSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateCondition(CND_IsSemiOpen),
        BT_CreateInverter(BT_CreateCondition(CND_HasLOS))
    );
    int semiHugAction = BT_CreateSequence(3,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(ACT_Crouch),             // duck first (before RUNNING blocks it)
        BT_CreateAction(ACT_HugWall)             // move along wall (RUNNING, last)
    );
    BT_AddChild(semiApproachSeq, semiHugAction);

    // --- Standard fast pounce ---
    int fastPounceSeq = BT_CreateSequence(2,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking)
    );

    int pounceInnerSeq = BT_CreateSequence(3,
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(fPounceRange),
        BT_CreateInverter(BT_CreateCondition(CND_IsTargetPinned))
    );

    // v3.2: GaussianAimOffset for unpredictable pounce angles.
    // Sum-of-3-uniforms approximates Gaussian with ~15° std dev spread.
    int attackActionSeq = BT_CreateSequence(3,
        BT_CreateAction(ACT_SnapAimToTarget),
        BT_CreateAction(ACT_GaussianAimOffset),
        BT_CreateAction(ACT_QueueLunge)
    );

    int cooldownAttack = BT_CreateCooldown(1.0, attackActionSeq);
    int signalCoord = BT_CreateAction(ACT_SignalAttack);

    // --- v3.3: Close-range direct pounce (no Gauss offset, faster reaction) ---
    int closePounceSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(fStraightRange),
        BT_CreateInverter(BT_CreateCondition(CND_IsTargetPinned))
    );
    int closeAttackSeq = BT_CreateSequence(2,
        BT_CreateAction(ACT_SnapAimToTarget),
        BT_CreateAction(ACT_QueueLunge)
    );
    BT_AddChild(closePounceSeq, BT_CreateCooldown(1.0, closeAttackSeq));

    // --- v3.3: Sprint approach — RUN full speed when far from target ---
    // Replaces the old approachFull which forced crouch BEFORE running.
    // Crouching cuts movement speed by ~50%, making Hunter crawl slowly.
    // This branch only fires when: OnGround + NOT ducking + > pounce range.
    // v4.0.1 FIX: 边界从 fPounceRange+150 改回 fPounceRange —— v4.0 的 +150 迟滞
    //       在 1000~1150u 之间制造了死区（sprint 不触发、crouchPrep 也不触发），
    //       出生运出点常落在这个区间 → 直接掉进 crouchApproachSeq 蹲爬蠕动。
    //       原迟滞意图（防 sprint↔crouch 边界抖动）已由 crouchApproach 的
    //       站立快跑化取代（见 HunterAct_CrouchApproach），抖动代价消失。
    int sprintApproachSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_OnGround),
        BT_CreateInverter(BT_CreateCondition(CND_IsDucking)),
        BT_CreateInverter(BT_CreateIsInRange(fPounceRange)),
        BT_CreateSequence(2,
            BT_CreateAction(ACT_AcquireClosestTarget),
            BT_CreateAction(HunterAct_SprintApproach)
        )
    );

    // --- v3.3: Transition crouch — enter pounce range → crouch immediately ---
    // When the sprint approach brings Hunter within pounce range, this branch
    // fires on the next tick: crouch now. The tick after that, fastPounceSeq
    // triggers the actual pounce. Natural sprint→crouch→pounce flow.
    int crouchPrepSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_OnGround),
        BT_CreateInverter(BT_CreateCondition(CND_IsDucking)),
        BT_CreateIsInRange(fPounceRange),
        BT_CreateCondition(CND_HasLOS)
    );
    int crouchPrepAction = BT_CreateSequence(1,
        BT_CreateAction(ACT_Crouch)
    );
    BT_AddChild(crouchPrepSeq, crouchPrepAction);

    // --- v3.3: Fixed crouch approach (in range + ducking + no LOS) ---
    // Uses HunterAct_CrouchApproach which moves FORWARD while strafing.
    // Old version used ACT_StrafeRandom which only did lateral movement.
    int crouchApproachSeq = BT_CreateSequence(3,
        BT_CreateCondition(CND_OnGround),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(HunterAct_CrouchApproach)
    );

    // ==========================================
    // v4.0: 分散扑（猎手集群 mode 4 / 巨兽协同 mode 6）
    // 用协同分配目标（防 dogpile）：多 Hunter 扑不同目标。
    // mode 4: 猎手集群的核心 —— 数量优势靠分散角度打出
    // mode 6: 巨兽协同 —— 全员分散控制，减轻 Tank 被集火压力
    // ==========================================
    int coordPounceSeq = BT_CreateSequence(6,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(fPounceRange),
        BT_CreateIsModeAny(4, 6),
        BT_CreateInverter(BT_CreateCondition(CND_IsTargetPinned))
    );
    int coordPounceAttack = BT_CreateSequence(3,
        BT_CreateAction(ACT_AcquireCoordTarget),
        BT_CreateAction(ACT_SnapAimToTarget),
        BT_CreateAction(ACT_QueueLunge)
    );
    BT_AddChild(coordPounceSeq, BT_CreateCooldown(1.0, coordPounceAttack));

    // ==========================================
    // v5.0 枪线扰乱者（任何模式生效）：优先扑"正在输出的人"——
    // 高火力威胁目标（SI_GetHighestThreatSurvivor：狙击/霰弹/榴弹枪手）。
    // 扑掉枪手 = 打乱幸存者火力网，为近战 SI 创造突破窗口。
    // 与 coordPounce（mode 4/6 分散）区分：这是通用身份行为，优先级
    // 放在分散扑之后 —— 分散模式仍优先防 dogpile，其余模式优先打枪手。
    // ==========================================
    int disruptionSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsDucking),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(fPounceRange)
    );
    int disruptionAttack = BT_CreateSequence(4,
        BT_CreateAction(ACT_AcquireThreatTarget),
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(ACT_QueueLunge),
        BT_CreateAction(ACT_SignalAttack)
    );
    BT_AddChild(disruptionSeq, BT_CreateCooldown(1.0, disruptionAttack));

    int wander = BT_CreateAction(ACT_Wander);

    // --- Build main tree ---
    BT_AddChild(fastPounceSeq, pounceInnerSeq);
    BT_AddChild(fastPounceSeq, cooldownAttack);
    BT_AddChild(fastPounceSeq, signalCoord);

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
    SetConVarInt(FindConVar("hunter_committed_attack_range"), 10000);
    SetConVarInt(FindConVar("hunter_pounce_ready_range"), 500);
    SetConVarInt(FindConVar("hunter_leap_away_give_up_range"), 0);
    SetConVarInt(FindConVar("hunter_pounce_max_loft_angle"), 0);
}
