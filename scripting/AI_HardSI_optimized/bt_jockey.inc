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
// v5.40 (2026-08-25, 审查修复):
//   - FIX J1(P0): 骑跃零瞄准 —— 全部 IN_ATTACK 路径（AlternatingHop leap/
//     骚扰机会骑）发射前瞄黑板目标且 pitch 归零。原版沿当前引擎视角发射：
//     跳跃分支的上仰 pitch(-15~-30°) 被 leap tick 继承 → 朝天飞；走位分支
//     （HugWall/CircleFlank）切入时 yaw 沿墙 → 撞墙扑。对齐 Hunter v5.7。
//   - FIX J2: _jockey_harass_ride_start 残留 —— leap 未命中无人清理，之后
//     第一次普通骑乘被误判为骚扰骑立即卸载。加 8s 陈旧窗口自愈。
//   - FIX J3: 骚扰骑乘时长每 tick 重掷 → 落地首 tick 缓存；计时起点改落地。
//   - FIX J4: <400u"转身后退"分支删除（v5.19 Hunter 同款反模式），合并为
//     ≤700u 单一横移带（机会性骑乘全带可用）。
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

    // === 距离控制（v5.40 J4: 两带制）===
    if (distance > 700.0) {
        // 太远：接近
        float dir[3], ang[3];
        MakeVectorFromPoints(myPos, tPos, dir);
        GetVectorAngles(dir, ang);
        ang[1] += GetRandomFloat(-25.0, 25.0);  // 小角度偏移
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        BT_AddButton(client, IN_FORWARD);
    } else {
        // ≤700u：横移 + 伺机骑乘
        // v5.40 FIX (J4): 删除原 <400u 的"转身后退"分支 —— v5.19 已在 Hunter
        // 定性为纯负收益的反模式（背对目标跑走 = 看不见人 + 白白放弃位置，
        // 观感"傻站着跑走"）；且 250-400u 恰是实测引擎有效 leap 距离，最该
        // 骑的范围反而在逃跑。现合并为单一带：面向目标横移保持角度，机会性
        // 骑乘判定全带可用（v5.40 实测后门控统一为 ≤320u，见下）
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

        // === 机会性骑乘（v5.26: 用户"骚扰者也不是一定不攻击"→ 更积极：
        // 冷却 10s→5s、距离 450→520；骚扰游走本身有 CND_HarasserReleased
        // 的 5s 硬超时兜底 → 游走 ≤5s 必转全力进攻）===
        float lastHarassLeap = BB_GetFloat(client, "_jockey_harass_last_leap", 0.0);
        bool canHarassLeap = (now - lastHarassLeap > 5.0);  // v5.26: 10s→5s

        // v5.40: 520 → 320（2026-08-25 空服实测：骑跃飞行上限 ~305u，
        //        可靠命中 ≤250u；520/500 段按键必然落空）
        if (canHarassLeap && distance <= 320.0 && (GetEntityFlags(client) & FL_ONGROUND)) {
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
            // v5.23: 补 pinnable 守卫 —— 目标已倒地/被控时按 IN_ATTACK 是空转
            // （引擎不成立）；不可骑则跳过骑乘，继续横移（走下述 StuckDetour）。
            if (isSafe && SI_IsPinnable(target)) {
                BB_SetFloat(client, "_jockey_harass_last_leap", now);
                BB_SetFloat(client, "_jockey_harass_ride_start", now);  // 记录骑乘开始时间
                // v5.40 (J1): 发射前重瞄目标且 pitch 归零 —— 横移带虽已面向目标，
                // 但视角含高度差 pitch（±10-20°），骑跃沿其发射会短距/砸地。
                // （复用外层 dir/ang）
                MakeVectorFromPoints(myPos, tPos, dir);
                GetVectorAngles(dir, ang);
                ang[0] = 0.0;
                BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
                BT_AddButton(client, IN_ATTACK);
                return BT_RUNNING;
            }
        }
    }

    BT_BeginMovement(client);   // v5.34: 声明运动意图
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
    // v5.40 FIX (J2/J3)：
    //   J2 —— _jockey_harass_ride_start 在按 ATTACK 时写入，leap 未命中
    //     （引擎拒绝/被闪避）时无人清理 → 残留整条命 → 之后第一次普通骑乘
    //     被 duration 巨大误判为"该下骑了"，立即 IN_JUMP 白白卸载。
    //     现加 8s 陈旧窗口：超时视为未命中的残留，清除后走正常 steering。
    //   J3 —— maxRideDuration 原在循环体内每 tick 重掷 GetRandomFloat(3,5)
    //     （"3-5s 定时下骑"实为 ≥3s 后逐 tick 抽签，期望 ~3.6s 且不可控）。
    //     现落地首 tick 掷一次缓存进黑板；且计时起点从【按键时刻】改为
    //     【落地时刻】（首次进入本分支），不再把飞行/寻的时间算进骑乘时长。
    float rideStart = BB_GetFloat(client, "_jockey_harass_ride_start", 0.0);
    if (rideStart > 0.0) {
        float now = GetGameTime();

        if (now - rideStart > 8.0) {
            // J2: leap 未命中的残留标记 —— 清除，按普通骑乘处理
            BB_SetFloat(client, "_jockey_harass_ride_start", 0.0);
            BB_SetFloat(client, "_jockey_harass_ride_max", 0.0);
        } else {
            // 有效骚扰骑乘：ride_max 未缓存 = 落地首 tick，掷定时长并记落地时刻
            float rideMax = BB_GetFloat(client, "_jockey_harass_ride_max", 0.0);
            if (rideMax <= 0.0) {
                rideMax = GetRandomFloat(3.0, 5.0);
                BB_SetFloat(client, "_jockey_harass_ride_max", rideMax);
                BB_SetFloat(client, "_jockey_harass_ride_land", now);
            }
            float landAt = BB_GetFloat(client, "_jockey_harass_ride_land", now);

            // 到时主动跳下
            if (now - landAt >= rideMax) {
                BB_SetFloat(client, "_jockey_harass_ride_start", 0.0);
                BB_SetFloat(client, "_jockey_harass_ride_max", 0.0);
                BT_AddButton(client, IN_JUMP);  // 跳下
                return BT_SUCCESS;
            }

            // 骑乘期间：小幅度移动（不往危险区带）——随机小角度移动
            float ang[3];
            GetClientEyeAngles(client, ang);
            ang[1] += GetRandomFloat(-15.0, 15.0);
            BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
            BT_AddButton(client, IN_FORWARD);
            return BT_RUNNING;
        }
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
        // v5.40 FIX (J1): 骑跃零瞄准 —— 原版只按 IN_ATTACK，发射沿当前引擎视角：
        //   ① 跳跃分支上一 tick 刚设的 pitch 上仰(-15~-30°)被本分支继承 → 部分
        //      骑跃朝天飞/短距落地；② 从 HugWall/CircleFlank 等走位分支切入时
        //      yaw 沿墙/绕行点 → 撞墙扑。对齐 Hunter 攻击链统一
        //      SnapAimToBlackboardTarget（v5.7）的做法：发射前瞄黑板目标且
        //      pitch 归零（骑跃是水平技能，弧线由引擎计算，同 Hunter v5.20）。
        //      Jockey 是全部攻击类中唯一没做 snap aim 的（Spitter v5.37 /
        //      Hunter v5.7 同族根因的最后一个漏网者）。
        int target = BB_GetInt(client, "target", -1);
        if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
            float sPos[3], tPos[3], dir[3], ang[3];
            GetClientAbsOrigin(client, sPos);
            GetClientAbsOrigin(target, tPos);
            MakeVectorFromPoints(sPos, tPos, dir);
            GetVectorAngles(dir, ang);
            ang[0] = 0.0;
            BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        }
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
        BT_CreateIsNotTargetInRange(350.0),          // v5.40: 500→350 实测对齐
        BT_CreateAction(ACT_StrafeMoveToTarget)
    );
    int mode1ChainLeap = BT_CreateSequence(5,
        BT_CreateIsMode(1),
        BT_CreateCondition(CND_IsAttackWindow),
        BT_CreateAction(ACT_AcquirePinTarget),
        BT_CreateIsTargetInRange(350.0),             // v5.40: 500→350 实测对齐（目标被拉住不动，余量略宽）
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
    // v5.23: 各地形分支统一把 Acquire 移到 HasTargetLOS 之前 —— 先换新目标再
    // 验证 LOS/Range，消除"先验证旧目标再换目标攻击"（任务书 §6.1）。
    // Ledge: approach (far) → flank
    int ledgeApproach = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsNearLedge),
        BT_CreateCondition(CND_OnGround),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可骑)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateInverter(BT_CreateIsTargetInRange(320.0)),   // v5.40: still far (400→320)
        BT_CreateAction(ACT_FlankApproach)
    );
    int ledgeLeap = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsNearLedge),
        BT_CreateCondition(CND_OnGround),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可骑)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(320.0),                       // v5.40: close enough (400→320)
        BT_CreateAction(JockeyAct_AlternatingHop)  // v5.7: 移除 Cooldown(1.2)
    );

    // Narrow: approach (far) → hug wall
    int narrowApproach = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateCondition(CND_OnGround),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可骑)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateInverter(BT_CreateIsTargetInRange(320.0)),   // v5.40: 350→320
        BT_CreateAction(ACT_HugWall)
    );
    int narrowLeap = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateCondition(CND_OnGround),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可骑)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(320.0),                       // v5.40: 350→320
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
        BT_CreateCondition(CND_OnGround),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可骑)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsNotTargetInRange(320.0),   // v5.40: 400→320
        BT_CreateAction(ACT_CircleFlank)
    );
    int openS0_Leap = BT_CreateSequence(7,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(0),
        BT_CreateCondition(CND_OnGround),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可骑)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(320.0),      // v5.40: 400→320
        BT_CreateAction(JockeyAct_AlternatingHop)  // v5.7: 移除 Cooldown(1.2)
    );
    // Strat 1: Erratic leap — zigzag approach → leap from varied angle
    // v5.6: +Acquire + HasTargetLOS + target 口径（同 ledge/narrow）
    int openS1_Approach = BT_CreateSequence(7,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(1),
        BT_CreateCondition(CND_OnGround),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可骑)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsNotTargetInRange(320.0),   // v5.40: 350→320
        BT_CreateAction(ACT_ErraticApproach)
    );
    int openS1_Leap = BT_CreateSequence(7,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(1),
        BT_CreateCondition(CND_OnGround),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可骑)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(320.0),      // v5.40: 350→320
        BT_CreateAction(JockeyAct_AlternatingHop)  // v5.7: 移除 Cooldown(1.2)
    );

    // --- Standard hop attack ---
    // v5.6: 700 → 450 —— 引擎有效 leap 距离实测 250-400u：400-700u 段按
    // ATTACK 大概率被引擎拒绝 → 挠击（"跳一下挠一下"）。450u 对齐实测上限。
    // v5.23: 重建为单层 Sequence —— 原结构（hopPreCond 独立 sequence + Acquire
    // 后置 + pinnable 守卫在攻击动作之后）有两个问题（任务书 §6.2）：
    //   a) 守卫在攻击动作之后：守卫 FAIL 时本帧 IN_ATTACK 副作用已发生；
    //   b) LOS/Range 校验的是攻击前的陈旧黑板 target（任务书 §4.1/§6.1）。
    // 现在顺序严格为：OnGround → Acquire(写黑板) → LOS(新目标) → Range(新目标)
    // → Pinnable 守卫(攻击前) → Execute(IN_ATTACK 副作用最后)。
    // v5.7: 移除 Cooldown(1.2) —— 和 Hunter v5.8/v5.9 同理：冷却期内条件仍满足
    // → hopSeq FAIL 但 selector 反复选中 → 站桩。引擎自带跳跃冷却，插件侧不
    // 需要再锁。
    // v5.18 功能 2：挂边/倒地守卫 —— 骑挂边或倒地的人是空转（引擎不成立），
    // 而 fallback 选人不过滤这两态。守卫必须在攻击动作之前：目标不可骑时整支
    // FAIL，树落到走位分支重找站着的目标。
    int hopSeq = BT_CreateSequence(6,
        BT_CreateCondition(CND_OnGround),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // Acquire：写黑板 target（优先站立未控，v5.19）
        BT_CreateCondition(CND_HasTargetLOS),        // LOS：校验新目标
        BT_CreateIsTargetInRange(320.0),             // v5.40: Range 450→320 实测对齐
        BT_CreateCondition(CND_TargetIsPinnable),    // Validate：攻击前守卫（§6.2）
        BT_CreateAction(JockeyAct_AlternatingHop)    // Execute：IN_ATTACK 副作用最后
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
    // v5.40 查证：z_jockey_leap_range（引擎默认 200）只是引擎 bot AI 的起跳
    // 触发半径（"If victim is this close, leap at them"），不是物理射程——
    // 本插件 BT 直接按键驱动、绕过该决策层。实测物理飞行上限 ~305u、可靠
    // 命中 ≤250u。此 cvar 对 BT 路径无实际作用，保留现值仅避免影响其他逻辑。
    SetConVarInt(FindConVar("z_jockey_leap_range"), 1000);
}
