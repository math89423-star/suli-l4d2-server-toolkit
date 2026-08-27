// ============================================================================
// bt_hunter.inc — Hunter Behavior Tree (v5.23)
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
// v5.23 (2026-08, 云端审查, 任务书 §4/§5/§17.2):
//   - P0 FIX: root selector 重排 —— routeAmbushSeq/routeFlankSeq 移到
//     crouchPrepSeq 之前（fastPounceSeq 之后）。原顺序 sprintApproachSeq
//     （OnGround + >400u，动作恒 RUNNING）排在战术分支之前 → 距离 >400u 时
//     routeAmbush/routeFlank 永远被遮蔽（§5.1）。战术分支优先于泛用接近（§5.2）
//   - P0 FIX: HunterAct_WallPounce 类型错误 —— ACT_AcquirePinnableTarget 的
//     返回值（BT_Status 0/1）被赋给 int target（client index），改显式
//     FAILURE 判定 + 从黑板读回目标（§5.3）
//   - P1: 扑击序列统一 "Acquire→Validate→LOS→Range→Execute"（§4/§17.2）：
//     narrowPounceSeq 补 CND_TargetIsPinnable（挂边/倒地/被控不可扑）；
//     coordPounceSeq / openStrat0 / openStrat1 的 Inverter(CND_IsTargetPinned)
//     替换为 CND_TargetIsPinnable（原守卫只防"已被控"）；disruptionSeq 补
//     CND_TargetIsPinnable（原序列无任何可扑守卫）
// v5.40 (2026-08-25, 审查修复):
//   - FIX H1(P1): 二段扑状态机孤儿化 —— v5.24 删 missEsc 分支后 justLunged/
//     usedWallPounce 的清理点全部不可达：justLunged 首扑后整条命恒 true →
//     任意腾空贴墙误触发空中二段扑；usedWallPounce 一生一次即永久失效且跨命
//     残留（全局数组，出生重置未清）。现 CanWallPounce 内落地/超时(3s 窗口)
//     双路径清理 + lunge 事件重置预算 + 出生重置补清（AI_HardSI.sp），
//     新增 g_fHunterLungeAt 时间戳基准。
//   - FIX H2: _wall_pounce_yaw 死写入删除（无读者，且循环累进改 ang 导致
//     记录值错误）；墙面检测重写为 yaw 环形水平射线；WallPounce 冗余双重
//     校验删除。
// ============================================================================

#if defined _bt_hunter_included
  #endinput
#endif
#define _bt_hunter_included

// ---------------------------------------------------------------------------
// Hunter-specific state (shared with main plugin via extern)
// ---------------------------------------------------------------------------

bool g_bHunterJustLunged[MAXPLAYERS + 1];

// v4.0.1: 扑击范围缓存（BT_CreateHunterTree 里从 ai_fast_pounce_proximity 读取），
// crouchApproach 需要用它判断"是否已进入扑击范围"来决定蹲伏 vs 站立快跑。
float g_fHunterPounceRange = 1000.0;

// v5.12: 欺骗性跳跃冷却（检测被瞄准时触发闪避跳）
float g_fHunterEvasiveCooldown[MAXPLAYERS + 1];

// v5.16: 墙面二段跳状态跟踪
bool g_bHunterUsedWallPounce[MAXPLAYERS + 1];  // 本次起跳是否已使用二段跳

// v5.40: 最近一次扑击（ability_lunge 事件）时刻 —— CanWallPounce 的 3s 有效
// 窗口基准；0=无效。修复 justLunged 卡 true 导致的任意腾空误触发（H1）。
float g_fHunterLungeAt[MAXPLAYERS + 1];

// Forward declarations for tree builder

// ---------------------------------------------------------------------------
// Hunter-specific callbacks
// ---------------------------------------------------------------------------

// v5.40: missEscSeq（扑空逃跳）已随 v5.24 从 root 移除 —— 其构建体与
// HunterCond_JustMissed / HunterAct_EscapeJump 两个孤儿函数、以及只被它们
// 消费的 g_fHunterMissEscapeCooldown 一并删除（编译警告 203/204 实锤死代码）。
// justLunged 的清理职责由 HunterCond_CanWallPounce 接管（落地/超时双路径，
// 见 H1 注释）。

// ============================================================================
// v5.16: 墙面二段跳（Wall Pounce）
// Hunter 扑空后在空中检测墙面，可以进行二次扑击
// ============================================================================

// Condition: Hunter 在空中贴墙且可以进行二段跳
// v5.40 FIX (H1): justLunged 生命周期 —— 原 flag 在 ability_lunge 事件置 true
// 后，清理点全挂在 v5.24 已从 root 删除的 missEsc 分支（JustMissed/EscapeJump）
// → 首次扑击后整条命恒 true：任何"腾空+贴墙+竖直速度"时刻（掉落/被推下高台/
// Tank 击飞）都会误触发空中自动二段扑；且 usedWallPounce 的复位同样全部不可达，
// 二段扑一生只触发一次然后永久失效（全局数组跨命存活，出生重置也没清它）。
// 现语义收紧为"本次扑击后 3s 内的空中贴墙窗口"：落地或超时即清全部标记；
// usedWallPounce 预算改由 lunge 事件重置（每次新扑击都有一次机会）。
BT_Status HunterCond_CanWallPounce(int client) {
    // 必须刚扑击过（扑空状态）
    if (!g_bHunterJustLunged[client]) return BT_FAILURE;

    float now = GetGameTime();

    // 落地 = 扑空流程结束：清标记（原逻辑在不可达的 JustMissed 分支里）
    if (GetEntityFlags(client) & FL_ONGROUND) {
        g_bHunterJustLunged[client] = false;
        g_bHunterUsedWallPounce[client] = false;
        return BT_FAILURE;
    }

    // lunge 后 3s 有效窗口：超时的腾空与该次扑击无关，清标记防残留误触发
    if (g_fHunterLungeAt[client] <= 0.0 || now - g_fHunterLungeAt[client] > 3.0) {
        g_bHunterJustLunged[client] = false;
        g_bHunterUsedWallPounce[client] = false;
        return BT_FAILURE;
    }

    // 本次起跳已使用过二段跳
    if (g_bHunterUsedWallPounce[client]) return BT_FAILURE;

    // 必须有足够的垂直速度（正在下落或上升）
    float vel[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", vel);
    if (FloatAbs(vel[2]) < 50.0) return BT_FAILURE;

    // 检测四个方向是否有墙面（水平距离 < 80u）
    // v5.40 (H2): 原循环累进修改 ang[1]、把 pitch 混入射线方向、命中时写
    // _wall_pounce_yaw（无任何读者且记录值错误）—— 死代码删除，重写为
    // yaw 环形水平检测（前/左/右/后），射线平 pitch。
    float pos[3];
    GetClientAbsOrigin(client, pos);
    float baseYaw;
    if (g_bBT_AnglesSet[client]) {
        baseYaw = g_fBT_Angles[client][1];   // v5.21 同款：优先读瞄准累加器
    } else {
        float eyeAng[3];
        GetClientEyeAngles(client, eyeAng);
        baseYaw = eyeAng[1];
    }

    float yawOffsets[4];
    yawOffsets[0] = 0.0;     // 前
    yawOffsets[1] = -90.0;   // 左
    yawOffsets[2] = 90.0;    // 右
    yawOffsets[3] = 180.0;   // 后

    float fwd[3], rayAng[3];
    rayAng[0] = 0.0;         // 平 pitch：纯水平环形检测
    rayAng[2] = 0.0;
    for (int i = 0; i < 4; i++) {
        rayAng[1] = baseYaw + yawOffsets[i];
        GetAngleVectors(rayAng, fwd, NULL_VECTOR, NULL_VECTOR);

        float endPos[3];
        endPos[0] = pos[0] + fwd[0] * 80.0;
        endPos[1] = pos[1] + fwd[1] * 80.0;
        endPos[2] = pos[2];

        TR_TraceRayFilter(pos, endPos, MASK_PLAYERSOLID, RayType_EndPoint, TracerayFilter, client);
        if (TR_DidHit() && TR_GetFraction() < 0.9) {
            return BT_SUCCESS;
        }
    }

    return BT_FAILURE;
}

// Action: 执行墙面二段跳
BT_Status HunterAct_WallPounce(int client) {
    // v5.23 FIX: 类型错误 —— ACT_AcquirePinnableTarget 返回 BT_Status
    // （0=SUCCESS/1=FAILURE），原代码把返回值赋给 int target（client index），
    // 导致 target 恒为 0/1、瞄准块永远不执行。改为显式判定失败即退 + 从
    // 黑板读回目标（任务书 §5.3）。
    if (ACT_AcquirePinnableTarget(client) == BT_FAILURE) return BT_FAILURE;
    int target = BB_GetInt(client, "target", -1);
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) return BT_FAILURE;

    // 瞄准目标（v5.40: 删除重复的内层有效性 if —— 上方守卫已保证）
    {
        float myPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, myPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(myPos, tPos, dir);
        GetVectorAngles(dir, ang);

        // v5.20: 归零基础 pitch（扑击水平），再加小偏移模拟墙面反弹不稳定性
        ang[0] = 0.0 + GetRandomFloat(-10.0, 10.0);
        ang[1] += GetRandomFloat(-15.0, 15.0);

        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }

    // 执行二段跳扑击
    BT_AddButton(client, IN_ATTACK);
    g_bHunterUsedWallPounce[client] = true;
    SI_SignalAttack(client);

    return BT_SUCCESS;
}

// ============================================================================
// v5.12: 欺骗性跳跃（Evasive Jump）
// 当 Hunter 检测到被幸存者瞄准时，执行随机方向的闪避跳跃
// 来源：Improved Hunter AI (Steam Workshop #3140922442)
// ============================================================================

// Condition: Hunter is being aimed at by a survivor
BT_Status HunterCond_UnderThreat(int client) {
    // 冷却检查（避免频繁跳）
    float now = GetGameTime();
    if (g_fHunterEvasiveCooldown[client] > now) return BT_FAILURE;

    // 必须在地面且未蹲伏（蹲伏时是潜行接近，不适合跳跃）
    if (!(GetEntityFlags(client) & FL_ONGROUND)) return BT_FAILURE;
    if (GetEntityFlags(client) & FL_DUCKING) return BT_FAILURE;

    float hunterPos[3], hunterAng[3];
    GetClientAbsOrigin(client, hunterPos);
    GetClientEyeAngles(client, hunterAng);

    // 遍历所有幸存者，检测是否有人瞄准 Hunter
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || !IsPlayerAlive(i)) continue;
        if (GetClientTeam(i) != 2) continue;  // 只检查幸存者

        float survivorPos[3], survivorAng[3];
        GetClientAbsOrigin(i, survivorPos);
        GetClientEyeAngles(i, survivorAng);

        float distance = GetVectorDistance(hunterPos, survivorPos);

        // v5.22 FIX: 距离限制改为 <400u 高危区 —— 原版 300-800u 全区间触发，
        // 打断中远距离的横移接近节奏（用户观感"跳一下蹲一下"，正常接近被
        // 跳跃抢占）。现在只在近距离（<400u）被瞄准时规避，400u 外依靠横移
        // 接近+扑击，不跳。下限 150u：极近距离来不及反应，且扑击分支已接管。
        if (distance < 150.0 || distance >= 400.0) continue;

        // 计算幸存者到 Hunter 的方向向量
        float toHunter[3], dir[3];
        MakeVectorFromPoints(survivorPos, hunterPos, toHunter);
        NormalizeVector(toHunter, toHunter);

        // 计算幸存者的视线方向向量
        GetAngleVectors(survivorAng, dir, NULL_VECTOR, NULL_VECTOR);

        // 计算夹角（点积）
        float dotProduct = GetVectorDotProduct(dir, toHunter);

        // 夹角 < 15° 判定为瞄准（cos(15°) ≈ 0.966）
        if (dotProduct > 0.966) {
            // 额外检查：幸存者必须有视线（不能被墙挡住）
            TR_TraceRayFilter(survivorPos, hunterPos, MASK_SHOT, RayType_EndPoint, TracerayFilter, i);
            if (TR_GetFraction() > 0.95) {  // 95% 通畅即判定有视线
                return BT_SUCCESS;  // 检测到威胁
            }
        }
    }

    return BT_FAILURE;  // 无威胁
}

// Action: Perform evasive jump to avoid being aimed at
BT_Status HunterAct_EvasiveJump(int client) {
    float ang[3];
    GetClientEyeAngles(client, ang);

    // 随机选择侧向或后向跳跃
    // 60-120° 左右侧跳，或 150-180° 后跳
    float jumpAngle;
    int jumpType = GetRandomInt(0, 2);

    if (jumpType == 0) {
        // 左侧跳
        jumpAngle = GetRandomFloat(60.0, 120.0);
    } else if (jumpType == 1) {
        // 右侧跳
        jumpAngle = GetRandomFloat(-120.0, -60.0);
    } else {
        // 后跳
        jumpAngle = GetRandomFloat(150.0, 180.0) * (GetRandomInt(0, 1) ? 1.0 : -1.0);
    }

    ang[1] += jumpAngle;
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_JUMP);

    // 设置冷却时间（3-5 秒）
    g_fHunterEvasiveCooldown[client] = GetGameTime() + GetRandomFloat(3.0, 5.0);

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
// v5.15: 骚扰模式接近（Harasser Approach）
// 保持 600-1000u 距离游走，但允许机会性扑击（玩家落单/背对时）
// ============================================================================

BT_Status HunterAct_HarasserApproach(int client) {
    int target = BB_GetInt(client, "target", -1);
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) {
        return BT_FAILURE;
    }

    float myPos[3], tPos[3];
    GetClientAbsOrigin(client, myPos);
    GetClientAbsOrigin(target, tPos);
    float distance = GetVectorDistance(myPos, tPos);

    // === v5.15: 机会性扑击检测 ===
    // 检查冷却（降低攻击频率，比正常模式少 40%）
    float now = GetGameTime();
    float lastOpportunisticPounce = BB_GetFloat(client, "_harass_last_pounce", 0.0);
    bool canOpportunisticPounce = (now - lastOpportunisticPounce > 8.0);  // 8秒冷却

    if (canOpportunisticPounce && distance >= 400.0 && distance <= 800.0) {
        // 检测玩家是否落单（距离队友 >500u）
        bool isIsolated = true;
        for (int i = 1; i <= MaxClients; i++) {
            if (i == target || !IsSurvivor(i) || !IsPlayerAlive(i)) continue;
            float tPos2[3];
            GetClientAbsOrigin(i, tPos2);
            if (GetVectorDistance(tPos, tPos2) < 500.0) {
                isIsolated = false;
                break;
            }
        }

        // 检测玩家是否背对（视角差 >90°）
        bool isFacingAway = false;
        float tAng[3], dir[3], lookDir[3];
        GetClientEyeAngles(target, tAng);
        GetAngleVectors(tAng, lookDir, NULL_VECTOR, NULL_VECTOR);
        MakeVectorFromPoints(tPos, myPos, dir);
        NormalizeVector(dir, dir);
        float dot = GetVectorDotProduct(lookDir, dir);
        if (dot < 0.0) {  // 背对（>90°）
            isFacingAway = true;
        }

        // 满足条件：进行机会性扑击
        if ((isIsolated || isFacingAway) && (GetEntityFlags(client) & FL_ONGROUND)) {
            // 检查 LOS
            TR_TraceRayFilter(myPos, tPos, MASK_SHOT, RayType_EndPoint, TracerayFilter, client);
            if (TR_GetFraction() > 0.95) {
                // 蹲下准备扑击（如果还没蹲）
                if (!(GetEntityFlags(client) & FL_DUCKING)) {
                    BT_AddButton(client, IN_DUCK);
                    float ang[3];
                    MakeVectorFromPoints(myPos, tPos, dir);
                    GetVectorAngles(dir, ang);
                    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
                    return BT_RUNNING;
                }

                // 已蹲下：执行扑击
                BB_SetFloat(client, "_harass_last_pounce", now);
                float ang[3];
                MakeVectorFromPoints(myPos, tPos, dir);
                GetVectorAngles(dir, ang);
                ang[0] = 0.0;  // v5.20: zero pitch for pounce
                BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
                BT_AddButton(client, IN_ATTACK);
                SI_SignalAttack(client);
                return BT_RUNNING;
            }
        }
    }

    // === 正常骚扰行为：距离控制 ===
    if (distance > 1000.0) {
        // 太远：接近到 800u
        float dir[3], ang[3];
        MakeVectorFromPoints(myPos, tPos, dir);
        GetVectorAngles(dir, ang);
        // 添加 ±30° 偏移，不直线接近
        ang[1] += GetRandomFloat(-30.0, 30.0);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        BT_AddButton(client, IN_FORWARD);
        BT_RemoveButton(client, IN_DUCK);  // 全速跑
    } else if (distance < 600.0) {
        // v5.19 FIX: 原版"太近就转身后退到 700u" —— 观感就是用户反馈的
        // "傻站着跑走"。后退是 Smoker 的保距逻辑，对 Hunter 是纯负收益：
        // 已经贴到 600u 内还往外跑，等放行时又得重新跑回来。
        // 改为原地蹲守：蹲姿本身是扑击前置态，CND_HarasserReleased 一放行，
        // fastPounce（root 分支 10）下一 tick 直接扑出去，零过渡损耗。
        float dir[3], ang[3];
        MakeVectorFromPoints(myPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);   // 面向目标，不反向
        BT_AddButton(client, IN_DUCK);                     // 蹲守 = 隐蔽 + 待扑
        BT_RemoveButton(client, IN_FORWARD);
    } else {
        // 600-1000u：横移骚扰
        float dir[3], ang[3];
        MakeVectorFromPoints(myPos, tPos, dir);
        GetVectorAngles(dir, ang);
        // 面向目标但横移
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);

        // 随机横移方向
        float nextSwitch = BB_GetFloat(client, "_harass_strafe_next", 0.0);
        if (nextSwitch <= 0.0 || now >= nextSwitch) {
            BB_SetBool(client, "_harass_strafe_left", GetRandomInt(0, 1) == 0);
            BB_SetFloat(client, "_harass_strafe_next", now + GetRandomFloat(0.5, 1.0));
        }

        if (BB_GetBool(client, "_harass_strafe_left", false)) {
            BT_AddButton(client, IN_MOVELEFT);
        } else {
            BT_AddButton(client, IN_MOVERIGHT);
        }

        BT_RemoveButton(client, IN_DUCK);
    }

    // v5.34: 仅运动态声明意图 — <600 蹲守非运动，误判停滞蹦（P0-1）
    if (distance >= 600.0)
        BT_BeginMovement(client);
    else
        BB_SetBool(client, "_stuck_movement_intent", false);
    BT_StuckDetour(client);
    return BT_RUNNING;
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
// v5.11: 增强横移+角度偏移（用户反馈"直来直去"）—— 切换间隔缩短到 0.2-0.5s，
// 角度偏移加大到 ±40°，绕后概率提升到 50%，绕后距离加大到 300u。
BT_Status HunterAct_SprintApproach(int client) {
    float now = GetGameTime();

    // Strafe + aim-offset roll — change together every 0.2-0.5s（加快横移切换）
    float nextSwitch = BB_GetFloat(client, "_strafe_next");
    if (nextSwitch <= 0.0 || now >= nextSwitch) {
        bool goLeft = (GetRandomInt(0, 1) == 0);
        BB_SetBool(client, "_strafe_left", goLeft);
        // 缓存 ±40° 偏移 —— 换向时才重掷，蛇形更明显
        BB_SetFloat(client, "_aim_offset", GetRandomFloat(-40.0, 40.0));
        BB_SetFloat(client, "_strafe_next", now + GetRandomFloat(0.2, 0.5));
    }
    // Flank-behind roll — 提升到 50% 概率，更频繁绕后
    float nextFlank = BB_GetFloat(client, "_flank_next");
    if (nextFlank <= 0.0 || now >= nextFlank) {
        BB_SetBool(client, "_flank_behind", GetRandomFloat(0.0, 1.0) < 0.5);
        BB_SetFloat(client, "_flank_next", now + GetRandomFloat(1.0, 1.8));
    }
    if (BB_GetBool(client, "_strafe_left", false)) {
        BT_AddButton(client, IN_MOVELEFT);
        BT_RemoveButton(client, IN_MOVERIGHT);
    } else {
        BT_AddButton(client, IN_MOVERIGHT);
        BT_RemoveButton(client, IN_MOVELEFT);
    }

    // Forward movement — face target ±cached offset, or the point BEHIND it
    // v5.25: 远近分流 —— 远处（>600u）不覆盖视角，交还 Valve 导航找路
    // （防直线撞墙）；近处保留绕后/偏移瞄准逻辑。
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        if (GetVectorDistance(sPos, tPos) <= 600.0) {
            MakeVectorFromPoints(sPos, tPos, dir);
            GetVectorAngles(dir, ang);
            if (BB_GetBool(client, "_flank_behind", false)) {
                // 绕后跑位：aim 目标后方 300u 的地面点 → 跑更大弧线绕到背后
                float behind[3];
                behind[0] = tPos[0] + dir[0] * 300.0;
                behind[1] = tPos[1] + dir[1] * 300.0;
                behind[2] = tPos[2];
                MakeVectorFromPoints(sPos, behind, dir);
                GetVectorAngles(dir, ang);
            } else {
                ang[1] += BB_GetFloat(client, "_aim_offset", 0.0);
            }
            BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        }
    }
    BT_AddButton(client, IN_FORWARD);

    // CRITICAL: Ensure NOT ducking — sprint at full running speed.
    // The old approachFull forced crouch BEFORE approach, causing slow crawl.
    BT_RemoveButton(client, IN_DUCK);
    BT_BeginMovement(client);   // v5.34: 声明运动意图
    BT_StuckDetour(client);   // v5.2: 顶墙绕行

    return BT_RUNNING;
}

// Action: Crouched approach with forward movement toward target + lateral strafe.
// Fixes the old crouchApproachSeq bug: it used ACT_StrafeRandom which only
// pressed IN_MOVELEFT/IN_MOVERIGHT with NO forward movement at all.
// The Hunter was literally strafing in place without closing distance.
// v5.11: 增强横移频率（用户反馈"直来直去"）—— 切换间隔缩短到 0.3-0.8s。
BT_Status HunterAct_CrouchApproach(int client) {
    float dist = 999999.0;
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        dist = GetVectorDistance(sPos, tPos);
        // v5.25: 远近分流 —— 远处交还 Valve 导航（防直线撞墙），近处瞄准
        if (dist <= 600.0) {
            MakeVectorFromPoints(sPos, tPos, dir);
            GetVectorAngles(dir, ang);
            // v5.11: 蹲伏接近时也加 ±20° 偏移，不再只有横移
            ang[1] += GetRandomFloat(-20.0, 20.0);
            BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        }
    }

    // Lateral strafe — change direction every 0.3-0.8s（加快横移切换）
    float now = GetGameTime();
    float nextSwitch = BB_GetFloat(client, "_strafe_next_crouch");
    if (nextSwitch <= 0.0 || now >= nextSwitch) {
        bool goLeft = (GetRandomInt(0, 1) == 0);
        BB_SetBool(client, "_strafe_left_crouch", goLeft);
        BB_SetFloat(client, "_strafe_next_crouch", now + GetRandomFloat(0.3, 0.8));
    }
    if (BB_GetBool(client, "_strafe_left_crouch", false)) {
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
    BT_BeginMovement(client);   // v5.34: 声明运动意图
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
// v5.5: 过顶扑 —— 30% 概率把瞄准点移到"目标正后方 + 头顶之上"：
// 弹道抛物线越过幸存者头顶，落点在其身后（"越到后方突袭"）。
// 掷不中则原样保留现有瞄准（BT_SUCCESS 不改 aim）。扑空后由 missEsc 逃跳
// 接续，无死局。
// ============================================================================

BT_Status HunterAct_OverheadOffset(int client) {
    // v5.25: 过顶扑概率 30%→40%（用户设计："先越过幸存者扑到身后，再回头扑杀"）
    if (GetRandomFloat(0.0, 1.0) > 0.4) return BT_SUCCESS;

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
// v5.25: 扑击节奏控制（用户设计：连续扑太变态，每次扑击停顿 0.4s）
// ============================================================================
// 条件：距上次扑击 ≥ ai_hunter_pounce_interval（默认 0.4s）才允许发起新扑。
// 冷却中 FAIL → 攻击分支整支 FAIL → selector 落走位/接近分支（0.4s 缓冲），
// 不引入 Cooldown 节点（避免 v5.9/v5.10 的"冷却期反复选中=站桩"历史问题）。
static ConVar s_hPounceInterval = null;   // 缓存句柄（每 tick 热路径）

BT_Status HunterCond_PounceReady(int client) {
    if (s_hPounceInterval == null) s_hPounceInterval = FindConVar("ai_hunter_pounce_interval");
    float interval = (s_hPounceInterval != null) ? s_hPounceInterval.FloatValue : 0.4;
    if (interval <= 0.0) return BT_SUCCESS;   // 0 = 不限制（纯引擎冷却）
    float last = BB_GetFloat(client, "_hunter_last_pounce", 0.0);
    return (GetGameTime() - last >= interval) ? BT_SUCCESS : BT_FAILURE;
}

// 动作：记录本次扑击时刻（插在攻击序列末尾）
BT_Status HunterAct_MarkPounce(int client) {
    BB_SetFloat(client, "_hunter_last_pounce", GetGameTime());
    return BT_SUCCESS;
}

// ============================================================================
// v5.25: 扇形随机扑击角度（用户设计："扑击不是直线，左右扇形内随机角度"）
// ============================================================================
// 在 SnapAim 之后调用：把当前瞄准（黑板目标方向）再叠加 ±spread 均匀随机
// （ai_hunter_pounce_spread，默认 30°）—— 扑击弹道落在目标方向左右扇形内。
// 读累加器（同 v5.21 FIX：不读 EyeAngles，避免覆盖前面节点刚算好的瞄准）。
static ConVar s_hPounceSpread = null;

BT_Status HunterAct_SectorOffset(int client) {
    if (s_hPounceSpread == null) s_hPounceSpread = FindConVar("ai_hunter_pounce_spread");
    float spread = (s_hPounceSpread != null) ? s_hPounceSpread.FloatValue : 30.0;
    if (spread <= 0.0) return BT_SUCCESS;

    float ang[3];
    if (g_bBT_AnglesSet[client]) {
        ang[0] = g_fBT_Angles[client][0];
        ang[1] = g_fBT_Angles[client][1];
        ang[2] = g_fBT_Angles[client][2];
    } else {
        GetClientEyeAngles(client, ang);
    }
    ang[1] += GetRandomFloat(-spread, spread);   // 扇形均匀随机（左右）
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
    // v5.19 REVERT: fallback 500→1000。v5.3 把门控从 1000 砍到 500 的依据是
    // "引擎 hunter_pounce_ready_range=500 只在 500u 内发起扑击"，但该 cvar 是
    // 本模块自己 SetConVarInt 设的（见 Hunter_OnModuleStart），且它管的是引擎
    // bot 的蹲伏准备判定，不是 IN_ATTACK 扑击射程 —— ENGINE_CVARS.md 第 54 行
    // 已确认扑击射程无 cvar（全硬编码），第 111 行记录 1000 是 v4.0.1 实战
    // 验证值。500 门控让 500-1000u 全部扑击分支不可达（观感"远处根本不会扑"），
    // 现恢复 1000，并把引擎 ready_range 一起抬到 1000 消除两者不一致。
    // v5.24: fallback 1500→1000 —— 攻击门控必须 ≤ 引擎有效扑击射程。
    // 引擎扑击射程无 cvar 全硬编码，v4.0.1 实测有效 ≈1000u；v5.21 的 1500
    // 门控在 1000-1500u 段持续按 IN_ATTACK = 引擎扑不出（v5.3 同款教训：
    // "扑不出 → 扑空 → 逃跳 → 再扑"循环）。Jockey 对照：leap 门控 450 对齐
    // 引擎有效 250-400u + 余量。Hunter 门控 1000 = 引擎射程 + 0 余量。
    // "更早扑击"的意图由 crouchPrep(≤1000 蹲) + hunter_pounce_ready_range=1500
    // （引擎更早进入准备）承接，不再靠超射程按键。
    float fPounceRange = 1000.0;
    float fStraightRange = 200.0;
    ConVar hCvar = FindConVar("ai_fast_pounce_proximity");
    if (hCvar != null) fPounceRange = GetConVarFloat(hCvar);
    hCvar = FindConVar("ai_straight_pounce_proximity");
    if (hCvar != null) fStraightRange = GetConVarFloat(hCvar);
    g_fHunterPounceRange = fPounceRange;  // v4.0.1: 供 crouchApproach 判断蹲伏 vs 快跑

    // --- Leaf nodes ---
    // v5.40: missEscSeq 构建体已删（v5.24 移出 root 后成为死代码，见文件头
    // 回调区注释）。root 里的历史注释行 "// BT_AddChild(root, missEscSeq)"
    // 保留作版本记录。

    // v5.12: 欺骗性跳跃 —— 检测到被瞄准时触发闪避
    int evasiveJumpSeq = BT_CreateSequence(2,
        BT_CreateCondition(HunterCond_UnderThreat),
        BT_CreateAction(HunterAct_EvasiveJump)
    );

    // v5.16: 墙面二段跳 —— 空中贴墙时可以进行二次扑击
    int wallPounceSeq = BT_CreateSequence(2,
        BT_CreateCondition(HunterCond_CanWallPounce),
        BT_CreateAction(HunterAct_WallPounce)
    );

    // v5.13: 骚扰模式 —— 作为骚扰者时保持距离，等待发起者开团
    // 条件：是骚扰者 AND 尚未解放
    // v5.18: 解放条件放宽为 CND_HarasserReleased（发起者得手 OR 齐射令下）
    // v5.21: 用户反馈骚扰导致 Hunter 永远保距不扑 → 曾完全禁用。
    // v5.26: 恢复骚扰，但语义明确为"游走一会再攻击"（用户拍板：
    //   骚扰 ≠ 一定不攻击）——
    //   a) CND_HarasserReleased 内置 5s 硬超时（ai_harass_max_hold）+ "目标到
    //      嘴边"（≤扑击距离且 LOS）立即放行 → 游走有界，超时转全力进攻；
    //   b) HunterAct_HarasserApproach 内部本就有机会性扑击（落单/背对 + 8s
    //      冷却）→ 游走期间也会出手；
    //   c) <600u 时蹲守（扑击前置态），放行后 fastPounce 下一 tick 直接扑。
    int harassSeq = BT_CreateSequence(3,
        BT_CreateCondition(CND_IsHarasser),
        BT_CreateInverter(BT_CreateCondition(CND_HarasserReleased)),
        BT_CreateSequence(2,
            BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可扑)
            BT_CreateAction(HunterAct_HarasserApproach)
        )
    );

    // v3.2: HasHighGround check so Hunter only climbs when there is
    // actually elevated ground above. Without it, 35% of crouched ticks trace-hit
    // the ground at Hunter's feet and jump uselessly (原地跳跃).
    // v4.0.3: 加距离门控 —— 原版无任何距离/LOS 限制，只要蹲着 + 头顶
    // 40-200u 有高台，35%/65% 概率每 tick 重掷跳台（跳-蹲-跳抖动，高台图
    // 上大量时间在爬不在扑）。现在只在"最近生还者 1000-1600u"才爬高：
    //   ≤1000u：直接扑（closePounce/fastPounce 分支处理，不再爬高）
    //   >1600u：爬了够不着，交给 sprintApproach 快跑接近
    // v5.27: 移除 CND_IsDucking 前置条件 —— Hunter 远距离接近时通常未蹲伏，
    //         该条件使 highPounce 分支几乎永不触发（死代码）。ClimbHighGround
    //         内部已处理蹲伏/跳跃逻辑，无需前置门控。
    int highPounceSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_OnGround),
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
    // v5.23: 补可扑性守卫 —— 挂边/倒地/被控目标不可扑，扑上去是空转浪费
    // （任务书 §4/§17.2：Acquire→Validate→LOS→Range→Execute 统一链）
    // v5.24: 删 IsDucking —— Jockey 对照改造：攻击分支不再要求蹲姿
    // （站立即可扑，与 Jockey leap 同构）；蹲仅是 crouchPrep 的隐蔽准备态
    int narrowPounceSeq = BT_CreateSequence(6,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可扑)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(800.0),  // longer range in corridors
        BT_CreateCondition(CND_TargetIsPinnable)
    );
    int narrowAttackSeq = BT_CreateSequence(6,
        BT_CreateCondition(HunterCond_PounceReady),  // v5.25: 扑击节奏（0.4s）
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(HunterAct_SectorOffset),      // v5.25: 扇形随机角度
        BT_CreateAction(ACT_QueueLunge),
        BT_CreateAction(HunterAct_MarkPounce),        // v5.25: 记录扑击时刻
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
    // v5.24: 删 IsDucking（同 narrowPounceSeq）
    int openStrat0_WidePounce = BT_CreateSequence(7,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateStrategyIs(0),
        BT_CreateCondition(CND_OnGround),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可扑)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fPounceRange),
        BT_CreateCondition(CND_TargetIsPinnable)  // v5.23: 同 pounceInnerSeq —— 同时拒挂边/倒地/被控
    );
    int widePounceAttack = BT_CreateSequence(5,
        BT_CreateCondition(HunterCond_PounceReady),  // v5.25: 扑击节奏（0.4s）
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(HunterAct_SectorOffset),      // v5.25: 扇形随机角度（替换 WideGauss）
        BT_CreateAction(ACT_QueueLunge),
        BT_CreateAction(HunterAct_MarkPounce)         // v5.25: 记录扑击时刻
    );
    // v5.9: 移除 Cooldown，直接合并（同 narrowPounceSeq 修复）
    BT_AddChild(openStrat0_WidePounce, widePounceAttack);

    // Strategy 1: Erratic pounce — standard Gauss offset + unpredictable approach
    // v5.24: 删 IsDucking（同 narrowPounceSeq）
    int openStrat1_ErraticPounce = BT_CreateSequence(7,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateStrategyIs(1),
        BT_CreateCondition(CND_OnGround),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可扑)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fPounceRange),
        BT_CreateCondition(CND_TargetIsPinnable)  // v5.23: 同 pounceInnerSeq —— 同时拒挂边/倒地/被控
    );
    int erraticPounceAttack = BT_CreateSequence(5,
        BT_CreateCondition(HunterCond_PounceReady),  // v5.25: 扑击节奏（0.4s）
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(HunterAct_SectorOffset),      // v5.25: 扇形随机角度（替换 Gauss）
        BT_CreateAction(ACT_QueueLunge),
        BT_CreateAction(HunterAct_MarkPounce)         // v5.25: 记录扑击时刻
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
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可扑)
        BT_CreateInverter(BT_CreateCondition(CND_HasTargetLOS))
    );
    int semiHugAction = BT_CreateSequence(2,
        BT_CreateAction(ACT_Crouch),             // duck first (before RUNNING blocks it)
        BT_CreateAction(ACT_HugWall)             // move along wall (RUNNING, last)
    );
    BT_AddChild(semiApproachSeq, semiHugAction);

    // --- Standard fast pounce ---
    // v5.24: 删 IsDucking —— 站立即可扑（同 narrowPounceSeq 对照改造）。
    // 引擎扑击不依赖蹲姿（玩家 Hunter 站立按攻击即扑）；蹲姿仅为隐蔽接近态。
    int fastPounceSeq = BT_CreateSequence(1,
        BT_CreateCondition(CND_OnGround)
    );

    // v5.18 功能 2：加挂边/倒地守卫 —— ACT_AcquireClosestTarget 底层
    // GetClosestSurvivor 只查 IsPlayerAlive，不过滤倒地/挂边，会锁上挂边者
    // 白扑一次。CND_TargetIsPinnable 同时覆盖"已被控"，语义包含原
    // CND_IsTargetPinned 反向闸，故替换而非叠加。
    int pounceInnerSeq = BT_CreateSequence(4,
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可扑)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fPounceRange),
        BT_CreateCondition(CND_TargetIsPinnable)
    );

    // v3.2: GaussianAimOffset for unpredictable pounce angles.
    // Sum-of-3-uniforms approximates Gaussian with ~15° std dev spread.
    // v5.5: OverheadOffset 插在 SnapAim 之后 —— 30% 概率改瞄目标后方头顶，
    // 过顶抛物线落后（掷不中则保留 SnapAim 的瞄准，Gauss 照常微调）。
    // v5.10 FIX: 移除 Cooldown 包裹 —— fastPounceSeq 是 v5.9 遗漏的最后一个
    // 站桩 bug：冷却期内前置条件满足但 Cooldown FAIL → 整支 FAIL → selector
    // 反复选中分支7又反复 FAIL = 站着不动。引擎自带扑击冷却（z_lunge_interval
    // 默认 0.5s），插件侧不需要再锁。直接合并攻击序列到 fastPounceSeq。
    int attackActionSeq = BT_CreateSequence(7,
        BT_CreateCondition(HunterCond_PounceReady),  // v5.25: 扑击节奏（0.4s）
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(HunterAct_OverheadOffset),   // v5.25: 40% 过顶扑（越到身后）
        BT_CreateAction(HunterAct_SectorOffset),     // v5.25: 扇形随机角度（替换 Gauss）
        BT_CreateAction(ACT_QueueLunge),
        BT_CreateAction(HunterAct_MarkPounce),       // v5.25: 记录扑击时刻
        BT_CreateAction(ACT_SignalAttack)
    );

    // --- v3.3: Close-range direct pounce (no Gauss offset, faster reaction) ---
    // v5.24: 删 IsDucking（同 narrowPounceSeq）
    int closePounceSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_OnGround),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可扑)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fStraightRange),
        BT_CreateCondition(CND_TargetIsPinnable)   // v5.18: 同 pounceInnerSeq
    );
    int closeAttackSeq = BT_CreateSequence(4,
        BT_CreateCondition(HunterCond_PounceReady),  // v5.25: 扑击节奏（0.4s）
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(ACT_QueueLunge),
        BT_CreateAction(HunterAct_MarkPounce)         // v5.25: 记录扑击时刻
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
    // v5.19: 停跑距离改绝对值 400 —— 原 fPounceRange-100 在门控恢复 1000 后
    // 会变成 900u 停跑，400-900u 掉进 crouchApproach 蹲爬 = v5.4/v5.5 修过的
    // "慢速蠕动"回归。400 是 v5.4 实测消除边界回弹的值，与门控解耦。
    int sprintApproachSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_OnGround),
        BT_CreateInverter(BT_CreateIsInRange(400.0)),
        BT_CreateSequence(2,
            BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可扑)
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
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可扑)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateAction(ACT_Crouch)
    );

    // --- v3.3: Fixed crouch approach (in range + ducking + no LOS) ---
    // Uses HunterAct_CrouchApproach which moves FORWARD while strafing.
    // Old version used ACT_StrafeRandom which only did lateral movement.
    // v5.5: 加 ≤600u 门控 —— 只允许扑击距离边缘的最后一小段蹲爬接近；
    //       更远处一律交给 sprintApproachSeq 全速冲刺（不再兜底慢走）。
    // v5.19: 门控改绝对值 600 —— 同 sprintApproachSeq，防门控恢复 1000 后
    // 蹲爬区扩到 1100u（v5.5 明确只允许"扑击距离边缘最后一小段"蹲爬）。
    int crouchApproachSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_OnGround),
        BT_CreateIsInRange(600.0),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可扑)
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
    // v5.23: Inverter(CND_IsTargetPinned) → CND_TargetIsPinnable —— 原守卫只
    // 防"已被控"，挂边/倒地目标仍会扑空转。替换后契合"反聚堆分散扑"语义：
    // 协同分配的目标若已被控/倒地/挂边则跳过本分支，落到其它扑击/走位分支
    // （任务书 §4/§17.2 统一 Acquire→Validate→LOS→Range→Execute 链）
    // v5.24: 删 IsDucking（同 narrowPounceSeq）
    int coordPounceSeq = BT_CreateSequence(6,
        BT_CreateCondition(CND_OnGround),
        BT_CreateIsModeAny(4, 6),
        BT_CreateAction(ACT_AcquireCoordTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fPounceRange),
        BT_CreateCondition(CND_TargetIsPinnable)  // v5.23: 替换 Inverter(IsTargetPinned)，同时拒挂边/倒地/被控
    );
    int coordPounceAttack = BT_CreateSequence(4,
        BT_CreateCondition(HunterCond_PounceReady),  // v5.25: 扑击节奏（0.4s）
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(ACT_QueueLunge),
        BT_CreateAction(HunterAct_MarkPounce)         // v5.25: 记录扑击时刻
    );
    // v5.9: 移除 Cooldown，直接合并（同 narrowPounceSeq 修复）
    BT_AddChild(coordPounceSeq, coordPounceAttack);

    // ==========================================
    // v5.0 枪线扰乱者（任何模式生效）：优先扑"正在输出的人"——
    // 高火力威胁目标（SI_GetHighestThreatSurvivor：狙击/霰弹/榴弹枪手）。
    // 扑掉枪手 = 打乱幸存者火力网，为近战 SI 创造突破窗口。
    // 与 coordPounce（mode 4/6 分散）区分：这是通用身份行为，优先级
    // 放在分散扑之后 —— 分散模式仍优先防 dogpile，其余模式优先打枪手。
    // v5.23: 补可扑性守卫 —— 原序列无任何 pinnable/被控闸：枪手若已倒地/
    // 挂边/被控，扑上去是空转。CND_TargetIsPinnable 同时拒三种状态；若枪手
    // 已被控则跳过本分支（合理：优先维持压制，不打重复控制）
    // （任务书 §4/§17.2：Acquire→Validate→LOS→Range→Execute 统一链）
    // v5.24: 删 IsDucking（同 narrowPounceSeq）
    // ==========================================
    int disruptionSeq = BT_CreateSequence(5,
        BT_CreateCondition(CND_OnGround),
        BT_CreateAction(ACT_AcquireThreatTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fPounceRange),
        BT_CreateCondition(CND_TargetIsPinnable)
    );
    int disruptionAttack = BT_CreateSequence(5,
        BT_CreateCondition(HunterCond_PounceReady),  // v5.25: 扑击节奏（0.4s）
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(ACT_QueueLunge),
        BT_CreateAction(HunterAct_MarkPounce),        // v5.25: 记录扑击时刻
        BT_CreateAction(ACT_SignalAttack)
    );
    // v5.9: 移除 Cooldown，直接合并（同 narrowPounceSeq 修复）
    BT_AddChild(disruptionSeq, disruptionAttack);

    int wander = BT_CreateAction(ACT_Wander);

    // --- Build main tree ---
    BT_AddChild(fastPounceSeq, pounceInnerSeq);
    BT_AddChild(fastPounceSeq, attackActionSeq);

    // Root selector — priority order (v5.24):
    //   0. 骑乘中（零输出，引擎管骑乘）[v5.24]
    //   (1. Escape after miss —— v5.24 REMOVED：用户要求"连续扑不带停"，
    //      扑空落地直接重扑；逃跳+3s 冷却 = "扑完顿一下"主因)
    //   1. Wall pounce when airborne near wall [v5.16]
    //   2. Evasive jump when being aimed at [v5.12]
    //   3. Harasser mode [v5.26 恢复]：骚扰游走（有界——5s 硬超时/目标到嘴边
    //      立即放行；游走期间有机会性扑击），超时后转全力进攻
    //   4. High-ground positioning (tactical advantage)
    //   5. Narrow corridor → straight pounce
    //   5.5. mode 4/6 分散扑（防 dogpile）[v4.0]
    //   5.6. 枪线扰乱 → 扑火力输出者 [v5.0]
//   6a. Open area → roll strategy token
//   6b. Open + strat0 → wide flank pounce (±35° Gauss)
//   6c. Open + strat1 → erratic pounce (standard ±15° Gauss)
//   6d. Open + strat2 → falls through to standard fast pounce
//   7. Semi open → hug wall approach
    //   8. Close range (≤200) → direct pounce (no Gauss, faster) [v3.3]
    //   9. Standard fast pounce (LOS + inRange → pounce with Gauss)
    //   10. Flow 前方 → 蹲守埋伏（路线感知战术分支）[v5.18]
    //   11. Flow 后方 → 绕行抢位（路线感知战术分支）[v5.18]
    //   12. In range + not ducking → crouch to prepare pounce [v3.3]
    //   13. Far away → SPRINT full speed toward target [v3.3]
    //   14. In range + ducking + no LOS → crouch approach with forward movement [v3.3]
    //   15. Last resort → wander
    //
    // v5.24: 攻击分支不再要求蹲姿（站立即可扑，Jockey 对照改造）；
    // 门控 1000 = 引擎有效射程（v5.21 的 1500 超射程白按）。
    //
    // v5.23 P0 FIX: 战术分支（11/12）移到 crouchPrep（13）、sprint（14）之前
    // —— 原顺序 sprintApproachSeq（OnGround + >400u，动作恒 RUNNING）排在
    // 战术分支之前，距离 >400u 时 routeAmbush/routeFlank 永远被遮蔽（§5.1）。
    // 战术分支必须优先于泛用接近分支（§5.2）：
    // 能扑就扑 → 够不到先走路线战术 → 才退泛用接近（蹲伏准备/冲刺/蹲爬）。
    //
    // v5.24: 攻击分支不再要求蹲姿 → sprint→crouch→pounce 流程简化为
    // sprint→pounce：冲刺接近 → 进 1000u 站立直接扑（无 LOS 时蹲爬找角度）。
    // crouchPrep 保留为隐蔽接近的可选姿态，不再 gate 攻击。
    // ==========================================
    // v5.18 功能 1：flow 路线感知（两支）
    // ------------------------------------------
    // a) 已在前方 → 蹲守（Hunter 蹲着不动最难被发现，玩家一进射程攻击分支
    //    立刻接管扑出去 —— 埋伏与攻击天然衔接）
    // b) 落在后方 → 朝 flow 增大方向绕行抢位，而不是从背后直线追
    //    （从后方追 = 全队枪线正对，白给）
    // 两支都排在扑击分支之后：能扑就扑，够不到才走路线逻辑。
    // v5.23: 且都移到 crouchPrep/sprint 泛用接近之前 —— 路线感知是"战术"
    // 分支，优先级必须高于泛用接近（任务书 §5.2）。
    // ==========================================
    // v5.44 激进模式: flow 路线感知两支已移除 —— 远处刷出直接 sprint 朝生还者冲，不蹲守/绕路
    // 原 routeAmbushSeq(500flow/!LOS/>700 -> Crouch+Hold) 与 routeFlankSeq(落后800flow -> MoveToRouteAhead) 按用户"1"选项禁用
    // int routeAmbushSeq = BT_CreateSequence(4, BT_CreateIsAheadOnRoute(500.0), ... HoldRouteAmbush);
    // int routeFlankSeq = BT_CreateSequence(3, BT_CreateIsBehindOnRoute(800.0), ... MoveToRouteAhead);

    int root = BT_Create(BTN_SELECTOR);
    // v5.24: 骑乘守卫置顶 —— 扑中后树零输出（引擎管骑乘动画），
    // 消除骑乘中落 wander 乱按 IN_FORWARD 造成的"顿"。
    int rideSeq = BT_CreateSequence(2,
        BT_CreateCondition(CND_IsPinningSurvivor),
        BT_CreateAction(ACT_HoldVictim)
    );
    BT_AddChild(root, rideSeq);                 // 0. v5.24: 骑乘中（零输出，引擎管理）
    // v5.24: missEsc 逃跳已从 root 移除（用户要求"连续扑不带停"）——
    // 原行为：扑空落地贴脸 → 逃跳跳开 + 3s 冷却 → 跑回再扑 = 明显停顿。
    // 现扑空落地后直接由攻击分支重扑（引擎 z_lunge_interval=0.5s 为节奏下限）。
    // BT_AddChild(root, missEscSeq);            // 1. (v5.24 removed) escape after miss
    BT_AddChild(root, wallPounceSeq);           // 1. v5.16: wall pounce when airborne
    BT_AddChild(root, evasiveJumpSeq);          // 2. v5.12: evasive jump when aimed at
    BT_AddChild(root, harassSeq);               // 3. v5.26: 骚扰游走（有界：5s 硬超时/到嘴边放行/机会性扑击）
    BT_AddChild(root, highPounceSeq);           // 4. high-ground positioning
    BT_AddChild(root, narrowPounceSeq);         // 5. v3.2: narrow → straight pounce
    BT_AddChild(root, coordPounceSeq);          // 5.5. v4.0: mode 4/6 分散扑（防 dogpile）
    BT_AddChild(root, disruptionSeq);           // 6.6. v5.0: 枪线扰乱 → 扑火力输出者
    BT_AddChild(root, openStrategyRoll);        // 7a. v3.5: open → roll token
    BT_AddChild(root, openStrat0_WidePounce);   // 7b. v3.5: open strat0 → wide pounce
    BT_AddChild(root, openStrat1_ErraticPounce);// 7c. v3.5: open strat1 → erratic pounce
    // 7d: open strat2 → falls through to fastPounceSeq
    BT_AddChild(root, semiApproachSeq);         // 8. v3.2: semi → hug wall
    BT_AddChild(root, closePounceSeq);          // 9. v3.3: close-range direct pounce
    BT_AddChild(root, fastPounceSeq);           // 10. standard fast pounce (Gauss angle)
    // v5.44 激进模式: flow 两支已移除，远距直接落泛用接近（sprint/crouchApproach）
    // BT_AddChild(root, routeAmbushSeq);          // 11. v5.18: flow 前方 → 蹲守埋伏 (已禁用)
    // BT_AddChild(root, routeFlankSeq);           // 12. v5.18: flow 后方 → 绕行抢位 (已禁用)
    BT_AddChild(root, crouchPrepSeq);           // 11. v3.3: inRange + noDuck → crouch
    BT_AddChild(root, sprintApproachSeq);       // 14. v3.3: far away → SPRINT full speed
    BT_AddChild(root, crouchApproachSeq);       // 15. v3.3: inRange + ducking + noLOS → strafe+forward
    BT_AddChild(root, wander);                  // 16. last resort

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
        // v5.24: 默认 1500→1000 —— 对齐引擎有效扑击射程（v4.0.1 实测）。
        // 超射程门控 = 1000-1500u 持续按无效 IN_ATTACK（v5.3 同款教训）。
        hCvar = CreateConVar("ai_fast_pounce_proximity", "1000",
            "Hunter 扑击距离门控（v5.24: 1000u = 引擎有效射程实测值）",
            FCVAR_NONE, true, 100.0, true, 3000.0);
    } else if (hCvar.FloatValue < 1000.0) {
        // v5.24: 门槛 1500→1000（引擎射程对齐）
        hCvar.SetFloat(1000.0);
    } else if (hCvar.FloatValue > 1000.0) {
        // v5.24: 现存 1500 运行值（v5.21 遗留）收敛回引擎射程 1000
        hCvar.SetFloat(1000.0);
    }
    hCvar = FindConVar("ai_straight_pounce_proximity");
    if (hCvar == null) {
        hCvar = CreateConVar("ai_straight_pounce_proximity", "200",
            "Hunter 近距离直扑距离（无 Gauss 偏移）",
            FCVAR_NONE, true, 50.0, true, 1000.0);
    }
    // v5.25: 扑击节奏 + 扇形角度 cvar（用户设计微调）
    if (FindConVar("ai_hunter_pounce_interval") == null) {
        CreateConVar("ai_hunter_pounce_interval", "0.4",
            "Hunter 每次扑击后的停顿秒数（0 = 不限制，纯引擎冷却）",
            FCVAR_NONE, true, 0.0, true, 3.0);
    }
    if (FindConVar("ai_hunter_pounce_spread") == null) {
        CreateConVar("ai_hunter_pounce_spread", "55.0",
            "Hunter 扑击扇形随机角度（±度，0 = 直线瞄准）。v5.43: 30→55 加大不可预测性",
            FCVAR_NONE, true, 0.0, true, 60.0);
    }
    // v5.43: 同名 cvar 会恢复会话旧值 → 显式钉到新默认(30→55)
    SetConVarFloat(FindConVar("ai_hunter_pounce_spread"), 55.0);
    SetConVarInt(FindConVar("hunter_committed_attack_range"), 10000);
    // v5.24: ready_range 保持 1500（引擎"更早进入扑击准备"= 提前蹲伏走位），
    // 与 BT 攻击门控 1000（引擎有效射程）分工：1500u 内引擎开始准备、
    // ≤1000u 插件才按 IN_ATTACK —— 消除超射程白按。
    SetConVarInt(FindConVar("hunter_pounce_ready_range"), 1500);
    SetConVarInt(FindConVar("hunter_leap_away_give_up_range"), 0);
    SetConVarInt(FindConVar("hunter_pounce_max_loft_angle"), 0);
}
