// ============================================================================
// bt_jockey.inc — Jockey Behavior Tree (v5.7)
// ============================================================================
// Key behaviors preserved from v2.4:
//   - Alternating jump/leap cycle
//   - High-arc jumps (pitch up before jumping)
//   - Irregular cooldown (+-35% jitter)
//   - Lateral strafing during approach
//   - Target lowest-HP survivor during coordination
//   - Stumble bystanders (via jockey_ride event hook, unchanged)
// v3.2 terrain-aware additions:
//   - Narrow corridor: approach along wall → leap from cover
//   - Open area: flank leap → ride survivor away from team
//   - Near ledge: ride survivor toward cliff/ledge
// ============================================================================

#if defined _bt_jockey_included
  #endinput
#endif
#define _bt_jockey_included



// ============================================================================
// v5.15: 骚扰模式骑乘（Harasser Ride）
// 快速骑乘但不往危险区骑，3-5秒后主动跳下
// ============================================================================

BT_Status JockeyAct_HarasserRide(int client) {
    int target = BB_GetInt(client, "target", -1);
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) {
        return BT_FAILURE;
    }

    float myPos[3], tPos[3];
    GetClientAbsOrigin(client, myPos);
    GetClientAbsOrigin(target, tPos);
    float distance = GetVectorDistance(myPos, tPos);

    float now = GetGameTime();

    // === 距离控制：保持 400-700u ===
    if (distance > 700.0) {
        // 太远：接近
        float dir[3], ang[3];
        MakeVectorFromPoints(myPos, tPos, dir);
        GetVectorAngles(dir, ang);
        ang[1] += GetRandomFloat(-25.0, 25.0);  // 小角度偏移
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        BT_AddButton(client, IN_FORWARD);
    } else if (distance < 400.0) {
        // 太近：后退
        float dir[3], ang[3];
        MakeVectorFromPoints(myPos, tPos, dir);
        GetVectorAngles(dir, ang);
        ang[1] += 180.0;
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        BT_AddButton(client, IN_FORWARD);
    } else {
        // 400-700u：横移 + 伺机骑乘
        float dir[3], ang[3];
        MakeVectorFromPoints(myPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);

        // 横移
        float nextSwitch = BB_GetFloat(client, "_jockey_harass_strafe_next", 0.0);
        if (nextSwitch <= 0.0 || now >= nextSwitch) {
            BB_SetBool(client, "_jockey_harass_strafe_left", GetRandomInt(0, 1) == 0);
            BB_SetFloat(client, "_jockey_harass_strafe_next", now + GetRandomFloat(0.5, 1.0));
        }

        if (BB_GetBool(client, "_jockey_harass_strafe_left", false)) {
            BT_AddButton(client, IN_MOVELEFT);
        } else {
            BT_AddButton(client, IN_MOVERIGHT);
        }

        // === 机会性骑乘（降低频率）===
        float lastHarassLeap = BB_GetFloat(client, "_jockey_harass_last_leap", 0.0);
        bool canHarassLeap = (now - lastHarassLeap > 10.0);  // 10秒冷却

        if (canHarassLeap && distance <= 450.0 && (GetEntityFlags(client) & FL_ONGROUND)) {
            // 检测玩家前方是否安全（无悬崖/酸液）
            bool isSafe = true;
            float tAng[3], forwardVec[3], checkPos[3];
            GetClientEyeAngles(target, tAng);
            GetAngleVectors(tAng, forwardVec, NULL_VECTOR, NULL_VECTOR);

            // 检查前方 300u 是否有地面（悬崖检测）
            for (int step = 0; step < 3; step++) {
                checkPos[0] = tPos[0] + forwardVec[0] * (100.0 * float(step + 1));
                checkPos[1] = tPos[1] + forwardVec[1] * (100.0 * float(step + 1));
                checkPos[2] = tPos[2];

                float groundCheck[3];
                groundCheck[0] = checkPos[0];
                groundCheck[1] = checkPos[1];
                groundCheck[2] = checkPos[2] - 300.0;

                TR_TraceRayFilter(checkPos, groundCheck, MASK_PLAYERSOLID, RayType_EndPoint, TracerayFilter, client);
                if (!TR_DidHit() || TR_GetFraction() > 0.8) {
                    isSafe = false;
                    break;
                }
            }

            // 检查附近是否有酸液（200u内）
            float acidPos[3];
            float acidDist = SI_GetNearestAcid(tPos, acidPos, 200.0);
            if (acidDist >= 0.0 && acidDist < 200.0) {
                isSafe = false;
            }

            // 安全环境：进行快速骑乘
            if (isSafe) {
                BB_SetFloat(client, "_jockey_harass_last_leap", now);
                BB_SetFloat(client, "_jockey_harass_ride_start", now);  // 记录骑乘开始时间
                BT_AddButton(client, IN_ATTACK);
                return BT_RUNNING;
            }
        }
    }

    BT_StuckDetour(client);
    return BT_RUNNING;
}

// ============================================================================
// v4.0: 骑乘 steering —— 骑上人后把人往远离队伍中心的方向带。
// 引擎默认 Jockey 骑乘后漫无目的乱跑；真人 Jockey 会把人往队伍外/
// 特感堆方向带，拉散阵型。骑乘时按 W + 朝向 = 被骑者被往那个方向拖。
// ============================================================================

BT_Status JockeyAct_SteerRide(int client) {
    int victim = GetEntPropEnt(client, Prop_Send, "m_jockeyVictim");
    if (victim <= 0) return BT_FAILURE;
    if (!IsSurvivor(victim) || !IsPlayerAlive(victim)) return BT_FAILURE;

    // === v5.15: 骚扰模式下的快速骑乘 ===
    // 检查是否是骚扰模式的骑乘（有开始时间记录）
    float rideStart = BB_GetFloat(client, "_jockey_harass_ride_start", 0.0);
    if (rideStart > 0.0) {
        float now = GetGameTime();
        float rideDuration = now - rideStart;

        // 3-5秒后主动跳下
        float maxRideDuration = GetRandomFloat(3.0, 5.0);
        if (rideDuration >= maxRideDuration) {
            BB_SetFloat(client, "_jockey_harass_ride_start", 0.0);  // 清除标记
            BT_AddButton(client, IN_JUMP);  // 跳下
            return BT_SUCCESS;
        }

        // 骑乘期间：小幅度移动（不往危险区带）
        float vPos[3];
        GetClientAbsOrigin(victim, vPos);

        // 随机小角度移动（不固定方向）
        float ang[3];
        GetClientEyeAngles(client, ang);
        ang[1] += GetRandomFloat(-15.0, 15.0);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        BT_AddButton(client, IN_FORWARD);
        return BT_RUNNING;
    }

    // === 正常骑乘模式（完整 steering）===
    float vPos[3];
    GetClientAbsOrigin(victim, vPos);

    // v5.0 毒压搬运：骑乘航向优先级 1 —— 把被骑者拖进 Spitter 酸液池。
    // 酸液落在脚下（<80u）说明已被吐中无需再拖；拖向 80-900u 的酸池 =
    // 酸伤持续 + 队友救人必须趟酸（用户定位：地面有酸时 Jockey 把人往酸里带）。
    float acidPos[3];
    float acidDist = SI_GetNearestAcid(vPos, acidPos, 900.0);
    if (acidDist >= 80.0) {
        float aDir[3];
        MakeVectorFromPoints(vPos, acidPos, aDir);
        aDir[2] = 0.0;
        if (GetVectorLength(aDir) > 10.0) {
            float ang[3];
            GetVectorAngles(aDir, ang);

            // === v5.16: 弹跳骑乘增强 ===
            // 更频繁的转向（0.3-0.5s 切换）+ 更大角度（±60-90°）
            float now = GetGameTime();
            float nextBounce = BB_GetFloat(client, "_jockey_bounce_next", 0.0);
            if (nextBounce <= 0.0 || now >= nextBounce) {
                // 随机大角度偏移
                float bounceOffset = GetRandomFloat(60.0, 90.0) * (GetRandomInt(0, 1) ? 1.0 : -1.0);
                BB_SetFloat(client, "_jockey_bounce_offset", bounceOffset);
                BB_SetFloat(client, "_jockey_bounce_next", now + GetRandomFloat(0.3, 0.5));
            }
            ang[1] += BB_GetFloat(client, "_jockey_bounce_offset", 0.0);

            BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
            BT_AddButton(client, IN_FORWARD);

            // v5.16: 垂直抖动（10% 概率每 tick 跳跃）
            if (GetRandomFloat(0.0, 1.0) < 0.10) {
                BT_AddButton(client, IN_JUMP);
            }

            return BT_RUNNING;
        }
    }

    // 队伍中心（除 victim 外其他存活生还者平均位置）
    float center[3];
    int count = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsSurvivor(i) && IsPlayerAlive(i) && i != victim) {
            float p[3];
            GetClientAbsOrigin(i, p);
            center[0] += p[0];
            center[1] += p[1];
            center[2] += p[2];
            count++;
        }
    }

    float ang[3];
    if (count > 0) {
        center[0] /= float(count);
        center[1] /= float(count);
        // 方向 = victim → 队伍中心的**反方向**（远离队伍）
        float dir[3];
        MakeVectorFromPoints(center, vPos, dir);
        dir[2] = 0.0;
        if (GetVectorLength(dir) < 10.0) {
            // 被队伍包围：就近找最近特感方向带
            float nearestInf[3];
            float bestD = 999999.0;
            bool found = false;
            for (int k = 1; k <= MaxClients; k++) {
                if (!IsBotInfected(k) || !IsPlayerAlive(k) || k == client) continue;
                float q[3];
                GetClientAbsOrigin(k, q);
                float d = GetVectorDistance(vPos, q);
                if (d < bestD) { bestD = d; nearestInf = q; found = true; }
            }
            if (found) {
                MakeVectorFromPoints(vPos, nearestInf, dir);
            } else {
                GetClientEyeAngles(client, ang);

                // === v5.16: 弹跳骑乘增强（被包围时也抖动）===
                float now = GetGameTime();
                float nextBounce = BB_GetFloat(client, "_jockey_bounce_next", 0.0);
                if (nextBounce <= 0.0 || now >= nextBounce) {
                    float bounceOffset = GetRandomFloat(60.0, 90.0) * (GetRandomInt(0, 1) ? 1.0 : -1.0);
                    BB_SetFloat(client, "_jockey_bounce_offset", bounceOffset);
                    BB_SetFloat(client, "_jockey_bounce_next", now + GetRandomFloat(0.3, 0.5));
                }
                ang[1] += BB_GetFloat(client, "_jockey_bounce_offset", 0.0);

                BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
                BT_AddButton(client, IN_FORWARD);

                // v5.16: 垂直抖动
                if (GetRandomFloat(0.0, 1.0) < 0.10) {
                    BT_AddButton(client, IN_JUMP);
                }

                return BT_RUNNING;
            }
        }
        GetVectorAngles(dir, ang);

        // === v5.16: 弹跳骑乘增强（拖向队伍外时也抖动）===
        float now = GetGameTime();
        float nextBounce = BB_GetFloat(client, "_jockey_bounce_next", 0.0);
        if (nextBounce <= 0.0 || now >= nextBounce) {
            float bounceOffset = GetRandomFloat(60.0, 90.0) * (GetRandomInt(0, 1) ? 1.0 : -1.0);
            BB_SetFloat(client, "_jockey_bounce_offset", bounceOffset);
            BB_SetFloat(client, "_jockey_bounce_next", now + GetRandomFloat(0.3, 0.5));
        }
        ang[1] += BB_GetFloat(client, "_jockey_bounce_offset", 0.0);
    } else {
        // 单人局：保持当前朝向
        GetClientEyeAngles(client, ang);
    }

    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_FORWARD);

    // v5.16: 垂直抖动（10% 概率每 tick 跳跃）
    if (GetRandomFloat(0.0, 1.0) < 0.10) {
        BT_AddButton(client, IN_JUMP);
    }

    return BT_RUNNING;
}

// Alternating hop: normal jump ↔ leap attack
BT_Status JockeyAct_AlternatingHop(int client) {
    // Choose between normal jump and leap attack
    // Blackboard tracks: "jockey_next_is_jump" (bool toggle)
    bool doJump = BB_GetBool(client, "jockey_next_is_jump", false);

    // 15% chance: double leap (skip normal jump)
    bool doubleLeap = (GetRandomFloat(0.0, 1.0) < 0.15);

    if (doJump && !doubleLeap) {
        // High arc normal jump
        // v5.2: 跳模式向前跳进 —— 原版只按 IN_JUMP + pitch 上仰，yaw 保持
        // 当前朝向且不按前进 = 原地跳（350-700u 有 LOS 时 hopSeq 命中，
        // 观感"原地跳跃"）。现在瞄准黑板 target（如有）+ IN_FORWARD：
        // 朝目标方向跳进，远距离持续拉近。
        float eyeAng[3];
        int target = BB_GetInt(client, "target", -1);
        if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
            float sPos[3], tPos[3], dir[3];
            GetClientAbsOrigin(client, sPos);
            GetClientAbsOrigin(target, tPos);
            MakeVectorFromPoints(sPos, tPos, dir);
            GetVectorAngles(dir, eyeAng);
        } else {
            GetClientEyeAngles(client, eyeAng);
        }
        eyeAng[0] = -1.0 * GetRandomFloat(15.0, 30.0);  // pitch up
        BT_SetAimAngles(client, eyeAng[0], eyeAng[1], eyeAng[2]);
        BT_AddButton(client, IN_JUMP);
        BT_AddButton(client, IN_FORWARD);
        BB_SetBool(client, "jockey_next_is_jump", false);
    } else {
        // Leap attack
        BT_AddButton(client, IN_ATTACK);
        BB_SetBool(client, "jockey_next_is_jump", !doubleLeap);
        SI_SignalAttack(client);
    }
    return BT_SUCCESS;
}

// v5.6: 贴脸无 LOS 横移限时条件 —— 6s 内找不到角度 → FAIL 交走位分支
// （见 closeRangeStrafe 注释；38s 原地蠕动 5u/s 现场）
BT_Status JockeyCond_CloseStrafeTimeout(int client) {
    float now = GetGameTime();
    float start = BB_GetFloat(client, "_close_strafe_start", 0.0);
    if (start <= 0.0) {
        BB_SetFloat(client, "_close_strafe_start", now);
    } else if (now - start >= 6.0) {
        BB_SetFloat(client, "_close_strafe_start", 0.0);   // 重置，允许下次再进
        return BT_FAILURE;
    }
    return BT_SUCCESS;
}

stock int BT_CreateJockeyTree() {
    // Riding — v4.0: 骑乘 steering（把人往队伍外带），不再原地 hold
    int rideSeq = BT_CreateSequence(2,
        BT_CreateCondition(CND_IsPinningSurvivor),
        BT_CreateAction(JockeyAct_SteerRide)
    );

    // v5.15: 骚扰模式 —— 作为骚扰者时快速骑乘但不往危险区骑
    // v5.18: 解放条件放宽为 CND_HarasserReleased（发起者得手 OR 齐射令下）
    int harassSeq = BT_CreateSequence(3,
        BT_CreateCondition(CND_IsHarasser),
        BT_CreateInverter(BT_CreateCondition(CND_HarasserReleased)),
        BT_CreateSequence(2,
            BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可骑)
            BT_CreateAction(JockeyAct_HarasserRide)
        )
    );

    // ==========================================
    // v4.0: 暗影锁链 (mode 1) —— Smoker 拉中 → Jockey 骑同一人（拉散）
    // 窗口 = Smoker 拉中的 pin 广播；被拉的人无法移动，Jockey 骑 = 必中。
    // 骑上后再被 steering 往队伍外带 —— 锁链完整：拉→骑→拖走。
    // ==========================================
    // v5.7: 距离改 target 口径 —— 原 IsInRange/IsNotInRange 量"最近幸存者"
    // 而非 AcquirePinTarget 锁定的被拉者，链式配合判断对错了人
    int mode1ChainApproach = BT_CreateSequence(5,
        BT_CreateIsMode(1),
        BT_CreateCondition(CND_IsAttackWindow),
        BT_CreateAction(ACT_AcquirePinTarget),
        BT_CreateIsNotTargetInRange(500.0),
        BT_CreateAction(ACT_StrafeMoveToTarget)
    );
    int mode1ChainLeap = BT_CreateSequence(5,
        BT_CreateIsMode(1),
        BT_CreateCondition(CND_IsAttackWindow),
        BT_CreateAction(ACT_AcquirePinTarget),
        BT_CreateIsTargetInRange(500.0),
        BT_CreateAction(JockeyAct_AlternatingHop)  // v5.7: 移除 Cooldown(1.0)
    );

    // --- v3.2 FIX: Terrain-aware leap strategies ---
    // Each terrain type is split into TWO branches:
    //   Approach (far):  terrain match + onGround + HasLOS + NOT inRange → move
    //   Attack  (close): terrain match + onGround + HasLOS + inRange → AlternatingHop
    // Previously these branches ended with RUNNING-type movement actions
    // (HugWall/FlankApproach), which blocked the hopSeq fallback forever.
    // Now the approach runs when far; when close, it fails (Inverter trips)
    // and the selector moves to the attack branch.

    // v5.6: 全部地形分支补 ACT_AcquireClosestTarget —— 原版地形分支无目标
    // 获取：出生第一 tick 地形分支胜出时 FlankApproach/CircleFlank 空
    // RUNNING（target 无效无按键输出）→ 整条命插件侧零输出（出生冻结）；
    // + HasLOS → HasTargetLOS（引擎标志失真）+ 距离改 target 口径。
    // Ledge: approach (far) → flank
    int ledgeApproach = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsNearLedge),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateInverter(BT_CreateIsTargetInRange(400.0)),   // still far
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可骑)
        BT_CreateAction(ACT_FlankApproach)
    );
    int ledgeLeap = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsNearLedge),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(400.0),                       // close enough
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可骑)
        BT_CreateAction(JockeyAct_AlternatingHop)  // v5.7: 移除 Cooldown(1.2)
    );

    // Narrow: approach (far) → hug wall
    int narrowApproach = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateInverter(BT_CreateIsTargetInRange(350.0)),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可骑)
        BT_CreateAction(ACT_HugWall)
    );
    int narrowLeap = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(350.0),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可骑)
        BT_CreateAction(JockeyAct_AlternatingHop)  // v5.7: 移除 Cooldown(1.2)
    );

    // ==========================================
    // v3.5: Open terrain — 2-way random + reduced cooldown (2.0→1.2)
    // ==========================================
    int openStrategyRoll = BT_CreateSequence(2,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateRollStrategy(2)
    );
    // Strat 0: Flank leap — circle around → leap from side
    // v4.0: 大弧线绕后（CircleFlank）—— 从视线外绕到队伍侧后方跳骑
    // v5.6: +Acquire + HasTargetLOS + target 口径（同 ledge/narrow）
    int openS0_Approach = BT_CreateSequence(7,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(0),
        BT_CreateCondition(CND_OnGround), BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsNotTargetInRange(400.0),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可骑)
        BT_CreateAction(ACT_CircleFlank)
    );
    int openS0_Leap = BT_CreateSequence(7,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(0),
        BT_CreateCondition(CND_OnGround), BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(400.0),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可骑)
        BT_CreateAction(JockeyAct_AlternatingHop)  // v5.7: 移除 Cooldown(1.2)
    );
    // Strat 1: Erratic leap — zigzag approach → leap from varied angle
    // v5.6: +Acquire + HasTargetLOS + target 口径（同 ledge/narrow）
    int openS1_Approach = BT_CreateSequence(7,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(1),
        BT_CreateCondition(CND_OnGround), BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsNotTargetInRange(350.0),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可骑)
        BT_CreateAction(ACT_ErraticApproach)
    );
    int openS1_Leap = BT_CreateSequence(7,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(1),
        BT_CreateCondition(CND_OnGround), BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(350.0),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可骑)
        BT_CreateAction(JockeyAct_AlternatingHop)  // v5.7: 移除 Cooldown(1.2)
    );

    // --- Standard hop attack ---
    // v5.6: 700 → 450 —— 引擎有效 leap 距离实测 250-400u：400-700u 段按
    // ATTACK 大概率被引擎拒绝 → 挠击（"跳一下挠一下"）。450u 对齐实测上限。
    int hopPreCond = BT_CreateSequence(3,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(450.0)
    );

    int hopAcquireTarget = BT_CreateAction(JockeyAct_AlternatingHop);
    // v5.7: 移除 Cooldown(1.2) —— 和 Hunter v5.8/v5.9 同理：冷却期内 hopPreCond
    // 仍满足（地面+LOS+距离）→ hopSeq FAIL，但 selector 反复选中 → 站桩。
    // 引擎自带跳跃冷却，插件侧不需要再锁。

    // v5.18 功能 2：挂边/倒地守卫 —— 骑挂边或倒地的人是空转（引擎不成立），
    // 而 fallback 选人不过滤这两态。守卫放在 hopSeq 外层：目标不可骑时整支
    // FAIL，树落到走位分支重找站着的目标。
    int hopSeq = BT_CreateSequence(3,
        hopPreCond,
        hopAcquireTarget,
        BT_CreateCondition(CND_TargetIsPinnable)
    );

    // Approach: always strafe while closing in
    int strafeApproach = BT_CreateSequence(2,
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可骑)
        BT_CreateAction(ACT_StrafeMoveToTarget)
    );

    // ==========================================
    // v3.6: Anti-melee — close range + no LOS → strafe for leap angle.
    // Don't blindly approach when too close — the engine default melee
    // (shared IN_ATTACK button) kicks in when leap can't fire.
    // ==========================================
    // v5.2: 横移 + 前进（原 ACT_StrafeRandom 只横移不前进 —— ≤300u 无 LOS 时
    // 原地左右晃，观感"站桩"；StrafeApproach 绕圈接近）
    // v5.6: 加 6s 超时 —— 原版无超时：楼上/隔层横向 <300u 但永远无 LOS 时
    // 该分支恒 RUNNING（38s 蠕动 5u/s 现场）。超时 FAIL → 落 strafeApproach
    // 走位找路（引擎导航帧配合）。
    int closeRangeStrafe = BT_CreateSequence(5,
        BT_CreateIsInRange(300.0),
        BT_CreateInverter(BT_CreateCondition(CND_HasTargetLOS)),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可骑)
        BT_CreateCondition(JockeyCond_CloseStrafeTimeout),
        BT_CreateAction(ACT_StrafeApproach)
    );

    // Root selector — v3.6: close-range strafe prevents blind melee at no LOS.
    // When HasLOS: hopSeq fires → IN_ATTACK → engine decides leap vs melee.
    // When no LOS + close: strafe for angle instead of approaching into melee range.
    // When nothing works: Wander (melee IS valid as last resort).
    // v5.15: 添加骚扰模式分支（优先级 2）
    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, rideSeq);             // 1. 骑乘（最高优先级）
    BT_AddChild(root, harassSeq);           // 2. v5.15: 骚扰模式（快速骑乘）
    BT_AddChild(root, mode1ChainApproach);  // 3. v4.0: mode 1 → 锁链接近被拉者
    BT_AddChild(root, mode1ChainLeap);      // 4. v4.0: mode 1 → 锁链骑被拉者
    BT_AddChild(root, ledgeLeap);           // 5. ledge → leap
    BT_AddChild(root, ledgeApproach);       // 6. ledge → approach
    BT_AddChild(root, narrowLeap);          // 7. narrow → leap
    BT_AddChild(root, narrowApproach);      // 8. narrow → approach
    BT_AddChild(root, openStrategyRoll);    // 9a. open → roll token
    BT_AddChild(root, openS0_Leap);         // 9b. open strat0 → flank leap
    BT_AddChild(root, openS0_Approach);     // 9c. open strat0 → flank approach
    BT_AddChild(root, openS1_Leap);         // 10a. open strat1 → erratic leap
    BT_AddChild(root, openS1_Approach);     // 10b. open strat1 → erratic approach
    BT_AddChild(root, hopSeq);              // 11. standard hop (HasLOS → ATTACK)
    BT_AddChild(root, closeRangeStrafe);    // 12. v3.6: close+noLOS → strafe
    BT_AddChild(root, strafeApproach);      // 13. approach from far
    BT_AddChild(root, BT_CreateAction(ACT_Wander)); // 14. last resort

    return root;
}

public Jockey_OnModuleStart() {
    SetConVarInt(FindConVar("z_jockey_leap_range"), 1000);
}
