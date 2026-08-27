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
// v5.23:
//   - 尝试-确认分离（任务书 §9）：tongue attempt ≠ tongue confirmed —— 拉人分支
//     末端改 SmokerAct_TryTongue：持续按压直到 m_tongueVictim>0（引擎拉中）确认
//     成功（SUCCESS → 外层 Cooldown(1.8) arm），1.2s 超时未拉中 → 短退避 +
//     FAILURE（不锁冷却）。动作不再"按了就算成功"。SteerPinToAcid 拖拽不受影响。
// v5.39:
//   - FIX: TryTongue 超时死循环 —— 原写法到期 tick 先本地清零再无条件
//     MarkTry(now) 重开窗口 → 超时/退避路径永不可达 → 拉不中时无限按
//     ATTACK（引擎冷却期变挠击+站桩）。改为仅【非 TRYING】开新尝试。
//   - 视角保真窗口 _smoker_tongue_trying：配合 AI_HardSI.sp 非决策帧弹道角
//     重放，消除舌头发射落在引擎帧时沿混合朝向飞歪的问题。
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
#define SMOKER_TONGUE_TRY_TIMEOUT  1.2   // v5.23: 尝试超时（按压窗口，覆盖舌头发射+飞行+挂钩）
#define SMOKER_TONGUE_BACKOFF      0.5   // v5.23: 未发射出舌头的短退避（几何拒绝/吞键）

// v5.41: 最近一次舌头【真实发射】时刻（ability_tongue 事件写入，AI_HardSI.sp）。
// 引擎 tongue_miss_delay=15s：发射后落空 → 引擎锁 15s 拒绝再次发射，期间按键
// 全变近战挠击。超时分支用它区分"已发射未拉中"（长退避）vs"没发射出来"（短退避）。
float g_fSmokerTongueShotAt[MAXPLAYERS + 1];
ConVar g_hCvarTongueMissDelay = null;

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
    float distToTarget = GetVectorDistance(myPos, tPos);
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
    // v5.34 FIX: 远距离不强制视角 —— 距离 >750u（v5.41 对齐 tongue_range）时交还 Valve
    // NextBot 导航自由调整方向沿 navmesh 绕障碍；只有进入射程附近才
    // 强制朝向 standPos（瞄准/战术位置需要精确朝向）。
    // 原版无论距离一律 BT_SetAimAngles → 远距离剥夺引擎导航 → 撞墙循环。
    if (distToTarget <= 750.0) {   // v5.41: 850→750
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    BT_AddButton(client, IN_FORWARD);
    BT_BeginMovement(client);   // v5.34: 声明运动意图
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
    // （目标被拖离队伍/拖进特感堆）。后退受限：目标距 Smoker ≥750u 停止
    // （v5.41: 防拉断舌头，阈值对齐真实 tongue_range=750），到限后引擎托管
    // 拉，断舌/松开后回正常分支。
    int victim = GetEntPropEnt(client, Prop_Send, "m_tongueVictim");
    if (victim > 0 && IsSurvivor(victim) && IsPlayerAlive(victim)) {
        float vPos[3];
        GetClientAbsOrigin(victim, vPos);
        float dist = GetVectorDistance(myPos, vPos);
        // v6.8.1: 修复死代码——原 <750 return 后 <700 分支永假，统一为 <700 后退、≥700 横移
        if (dist < 700.0) {
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
        // >=700u 横移保持活性（防拉断）
        float dir[3], ang[3];
        MakeVectorFromPoints(vPos, myPos, dir);   // 目标→我 = 背对目标方向
        dir[2] = 0.0;
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        // 横移保持活性（引擎托管拉，不后退防断舌）
        float now2 = GetGameTime();
        float nextSwitch = BB_GetFloat(client, "_smoker_pin_strafe_next", 0.0);
        if (nextSwitch <= 0.0 || now2 >= nextSwitch) {
            BB_SetBool(client, "_smoker_pin_strafe_left", GetRandomInt(0,1)==0);
            BB_SetFloat(client, "_smoker_pin_strafe_next", now2 + GetRandomFloat(0.4, 0.9));
        }
        if (BB_GetBool(client, "_smoker_pin_strafe_left", false)) {
            BT_AddButton(client, IN_MOVELEFT);
            BT_RemoveButton(client, IN_MOVERIGHT);
        } else {
            BT_AddButton(client, IN_MOVERIGHT);
            BT_RemoveButton(client, IN_MOVELEFT);
        }
        return BT_RUNNING;
    }
    return BT_SUCCESS;  // 无victim/无酸液：引擎托管拉(极短帧)
}

// ============================================================================
// v5.23: SmokerAct_TryTongue —— 尝试-确认分离（任务书 §9：tongue attempt ≠
// tongue confirmed）
// 原版 6 个拉人分支末端全是 ACT_Attack："按了 IN_ATTACK 就返回 SUCCESS"，
// 外层 Cooldown(1.8) 把"尝试"当"成功"武装冷却，舌头冷却期还贴脸挠击。
// 现在改为处理态动作：持续按压 IN_ATTACK，直到
//   1. m_tongueVictim > 0（引擎真实拉中）→ SI_AbilityMarkConfirmed +
//      SUCCESS —— 外层 Cooldown(1.8) 只在此时 arm（拉中确认 → 1.8s 反挠击
//      窗口，拉断舌头后不会立刻再按）；
//   2. 1.2s 超时仍未拉中（舌头被闪避/打断/射程假阳性）→ SI_AbilityBackoff
//      (0.5) + FAILURE —— 不 arm 外层冷却，树立即回走位/选人分支重试。
// 引擎判据说明：m_tongueVictim 在拉中瞬间才 > 0，飞行中无已验证 prop
// （m_tongueEntity 未在本服 netprops 验证；left4dhooks PlayerAnimState 系
// 可选 native 不可依赖）。用 1.2s 超时窗口覆盖"发射→飞行→挂钩"全程，
// 超时未拉中即视为尝试失败退避，不做假成功。
// 拉中后的拖拽 steering（SmokerAct_SteerPinToAcid）与 pinSeq 分支不受影响。
// ============================================================================

BT_Status SmokerAct_TryTongue(int client) {
    float now = GetGameTime();

    // 退避中（上一次尝试超时后的短惩罚）：不按键直接失败，交走位分支
    if (SI_AbilityBackoffActive(client, "_smoker")) return BT_FAILURE;

    // --- 已拉中：引擎 latch 确认（与 pinSeq/SteerPinToAcid 同口径）---
    int victim = GetEntPropEnt(client, Prop_Send, "m_tongueVictim");
    if (victim > 0) {
        SI_AbilityMarkConfirmed(client, "_smoker", now);
        SI_AbilitySetState(client, "_smoker", ABILITY_CONFIRMED);
        SI_AttackClearTarget(client, "_smoker");   // v5.33: 释放锁定
        BB_SetBool(client, "_smoker_tongue_trying", false);   // v5.39: 退出视角保真窗口
        return BT_SUCCESS;   // 触发外层 Cooldown arm（1.8s 反挠击窗口）
    }

    // --- 尝试计时（v5.39 FIX：超时死循环修复）---
    // 原写法在到期 tick 先把本地 tryAt 清零再无条件 MarkTry(now) 重开窗口，
    // 末尾的超时判断拿到的永远是新鲜时间戳 → 超时/退避路径成死代码 →
    // LOS+射程内拉不中时（舌头被栏杆挡/引擎几何拒绝）无限按 IN_ATTACK：
    // 引擎冷却期按键全变近战挠击、树永不交还走位分支（站桩挠击根因）。
    // 现对齐正确语义：仅【非 TRYING】时开新尝试（锁目标+记起点）；到期
    // tick 不重置，落到底部超时分支 → Backoff(0.5)+FAILURE，Backoff 内部
    // 置回 IDLE，退避结束自然开下一轮。残留陈旧 try_at（被抢占中断）自愈：
    // 首个 tick 即触发超时分支重新走门控。
    float tryAt = SI_AbilityGetTryAt(client, "_smoker");
    if (SI_AbilityGetState(client, "_smoker") != ABILITY_TRYING) {
        // v5.33: 新尝试开始 → 锁定当前 target，后续 tick 不再换人
        int bbTarget = BB_GetInt(client, "target", -1);
        SI_AttackLockTarget(client, "_smoker", bbTarget);
        SI_AbilityMarkTry(client, "_smoker", now);
        SI_AbilitySetState(client, "_smoker", ABILITY_TRYING);
        tryAt = now;
        BB_SetBool(client, "_smoker_tongue_trying", true);   // v5.39: 进入视角保真窗口
        // v5.44: 舌攻动作时间戳——bt_common 卡死检测在攻击后静止期
        // (弹道+收舌+失手退避)会误判"停滞"注入原地跳, 观感极差。
        // 8s 覆盖发射+回收+miss_delay(7s) 全周期, 期间只允许绕行不允许跳。
        BB_SetFloat(client, "_last_tongue_action", now);
    }

    // --- v5.33: 用锁定目标瞄准（不再读 BB target，防止 Sequence 重评换人）---
    int target = SI_AttackGetLockedTarget(client, "_smoker");
    // v5.34 FIX: lock_target 无效时立即失败 —— Abort 清了 lock 但 try_at 残留
    // 的场景下（或目标死亡），不应无条件按 IN_ATTACK 对着空气吐 1.2s
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) {
        SI_AttackClearTarget(client, "_smoker");
        SI_AbilityBackoff(client, "_smoker", now, 0.3);
        BB_SetBool(client, "_smoker_tongue_trying", false);   // v5.39: 退出视角保真窗口
        return BT_FAILURE;
    }
    // v6.8.0 隔墙拉人修复：持续 LOS/距离/可控校验，隔墙或超距立即中断
    {
        float sEye[3], tEye[3];
        GetClientEyePosition(client, sEye);
        GetClientEyePosition(target, tEye);
        TR_TraceRayFilter(sEye, tEye, MASK_SOLID, RayType_EndPoint, LOS_TraceFilter, client);
        if (TR_DidHit() && TR_GetEntityIndex() != target) {
            float sChest[3], tChest[3];
            GetClientAbsOrigin(client, sChest); sChest[2] += 45.0;
            GetClientAbsOrigin(target, tChest); tChest[2] += 40.0;
            TR_TraceRayFilter(sChest, tChest, MASK_SOLID, RayType_EndPoint, LOS_TraceFilter, client);
            if (TR_DidHit() && TR_GetEntityIndex() != target) {
                SI_AttackClearTarget(client, "_smoker");
                SI_AbilityBackoff(client, "_smoker", now, 0.3);
                BB_SetBool(client, "_smoker_tongue_trying", false);
                return BT_FAILURE;
            }
        }
        float sAbs[3], tAbs[3];
        GetClientAbsOrigin(client, sAbs);
        GetClientAbsOrigin(target, tAbs);
        if (GetVectorDistance(sAbs, tAbs) > 750.0 || !SI_IsPinnable(target)) {
            SI_AttackClearTarget(client, "_smoker");
            SI_AbilityBackoff(client, "_smoker", now, 0.3);
            BB_SetBool(client, "_smoker_tongue_trying", false);
            return BT_FAILURE;
        }
    }
    {
        float sPos[3], tPos[3], tVel[3], dir[3], ang[3];
        GetClientEyePosition(client, sPos);
        GetClientAbsOrigin(target, tPos);
        tPos[2] += 30.0; // 胸口高度
        GetEntPropVector(target, Prop_Data, "m_vecVelocity", tVel);
        float dist = GetVectorDistance(sPos, tPos);
        // v5.41: 1600→1000 对齐 tongue_fly_speed; v6.8.1: 源点改眼 + 预判收敛0.6防折返空
        float leadT = dist / 1000.0;
        if (leadT > 0.75) leadT = 0.75;
        if (leadT < 0.1) leadT = 0.1;
        float aimPos[3];
        float speed2d = SquareRoot(tVel[0]*tVel[0] + tVel[1]*tVel[1]);
        if (speed2d > 100.0) {
            aimPos[0] = tPos[0] + tVel[0] * leadT * 0.6;
            aimPos[1] = tPos[1] + tVel[1] * leadT * 0.6;
            aimPos[2] = tPos[2];
        } else {
            aimPos = tPos;
        }
        MakeVectorFromPoints(sPos, aimPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    BT_AddButton(client, IN_ATTACK);

    // --- 尝试超时未拉中：按失败类型退避 + FAILURE ---
    // v5.41 FIX: 原版一律短退避(0.5s) → 若本次已真实发射且落空，引擎
    // tongue_miss_delay=15s 内拒绝再射，BT 每 ~1.7s 重按 ATTACK = 挠击站桩
    // 循环整个锁期（"拉不中挠击"第二根因，v5.39 只修了超时死循环）。
    // 现区分：已发射（g_fSmokerTongueShotAt >= tryAt）→ 长退避 ≈ miss 锁剩余；
    // 未发射（引擎几何拒绝/吞键）→ 保持 0.5s 短退避立即重试。
    if ((now - tryAt) > SMOKER_TONGUE_TRY_TIMEOUT) {
        SI_AttackClearTarget(client, "_smoker");   // v5.33: 超时释放锁定
        bool launched = (g_fSmokerTongueShotAt[client] >= tryAt);
        float backoff = SMOKER_TONGUE_BACKOFF;
        if (launched) {
            backoff = 15.0;
            if (g_hCvarTongueMissDelay != null) {
                backoff = g_hCvarTongueMissDelay.FloatValue;
            }
            // 从发射时刻起算剩余锁期（try 窗口最长 1.2s，扣掉已流逝部分）
            float elapsed = now - g_fSmokerTongueShotAt[client];
            backoff -= elapsed;
            if (backoff < 1.0) backoff = 1.0;
        }
        SI_AbilityBackoff(client, "_smoker", now, backoff);
        BB_SetBool(client, "_smoker_tongue_trying", false);   // v5.39: 退出视角保真窗口
        return BT_FAILURE;
    }
    return BT_RUNNING;   // 继续按住直到拉中或超时
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

// v5.27: Backoff期走位 —— 射程内有LOS但舌头在Backoff时拉人簇FAIL，
// approachAct(需!InRange)与closeRangeStrafe(需!LOS)均FAIL -> 零移动一帧。
// 此分支接管InRange+Backoff场景横移找角度，不让树漏到零移动retarget。
BT_Status SmokerCond_BackoffActive(int client) {
    return SI_AbilityBackoffActive(client, "_smoker") ? BT_SUCCESS : BT_FAILURE;
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
        BT_CreateIsTargetInRange(750.0),  // v5.41: 850→750 对齐引擎 tongue_range
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(SmokerAct_TryTongue)
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
        BT_CreateIsTargetInRange(750.0),  // v5.41: 850→750 对齐引擎 tongue_range
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(SmokerAct_TryTongue)
    );
    // Strat 2: Standard pull — falls through to pullSeq below

    // --- v3.2: Terrain-aware pull strategies ---
    // Ledge: 90% farthest target → pull for fall damage
    int ledgeTargetAcquire = BT_CreateAction(SmokerAct_AcquireLedgeTarget);
    // v3.2 FIX: ledgePullSeq now uses SmokerAct_AcquireLedgeTarget (90% farthest)
    // before snapping aim, instead of relying on the engine's default target.
    // v5.6: 补 IsTargetInRange（原版缺距离门：ledge 地形命中时 2000u 外
    // 也按 ATTACK）+ HasTargetLOS + SnapAimToBlackboardTarget
    int ledgePullSeq = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsLedgeBetweenTarget),
        BT_CreateAction(SmokerAct_AcquireLedgeTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(750.0),  // v5.41: 850→750 对齐引擎 tongue_range
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(SmokerAct_TryTongue)
    );

    // Narrow: 50/50 target mix → pull through chokepoint
    // v5.6: 同 ledgePullSeq
    int narrowPullSeq = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateAction(SmokerAct_AcquireNarrowTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(750.0),  // v5.41: 850→750 对齐引擎 tongue_range
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(SmokerAct_TryTongue)
    );

    // Standard: pull (mixed targeting), check LOS, aim, attack
    // v4.0.3: 加 IsInRange（原版无距离限制，2000u 外有 LOS 也每 tick 按
    // ATTACK（舌头够不着，纯浪费按键；与 openS0/S1 pull 的距离口径对齐）。
    // v5.6: HasLOS → HasTargetLOS（Smoker 拉人全灭根因）+ target 口径 + 黑板瞄准
    int acquireTarget = BT_CreateAction(SmokerAct_AcquireTarget);
    int pullSeq = BT_CreateSequence(4,
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(750.0),  // v5.41: 850→750 对齐引擎 tongue_range
        BT_CreateAction(ACT_SnapAimToBlackboardTarget),
        BT_CreateAction(SmokerAct_TryTongue)
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
    // v5.6: 加距离门控（IsNotInRange）—— 原版注释声称 "only when far"
    // 但无任何距离条件：750u 内（舌头射程内）拉人分支全 FAIL 时也落此分支
    // 盲走（386-800u 反复"拱人+侧滑"现场）。射程内走位 = closeRangeStrafe
    // 的职责，approachAct 只负责射程外绕位。
    int approachAct = BT_CreateSequence(2,
        BT_CreateIsNotInRange(750.0),   // v5.41: 850→750
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
        BT_CreateIsTargetInRange(750.0),  // v5.41: 850→750 对齐引擎 tongue_range
        BT_CreateAction(SmokerAct_TryTongue)
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
        BT_CreateIsInRange(750.0),  // v5.41: 850→750 tongue_range
        BT_CreateInverter(BT_CreateCondition(CND_HasTargetLOS)),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可拉)
        BT_CreateAction(ACT_StrafeApproach)
    );

    // v6.8.1: Backoff期逃脱 —— miss后短退避内明确后撤(逃跑躲避)，不再横移
    // 原横移观感“原地晃”，用户反馈释放后不逃。改Retreat拉开距离找掩体
    int backoffStrafe = BT_CreateSequence(5,
        BT_CreateIsInRange(750.0),  // v5.41: 850→750 tongue_range
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateCondition(SmokerCond_BackoffActive),
        BT_CreateAction(ACT_AcquirePinnableTarget),
        BT_CreateAction(ACT_Retreat)
    );

    // v5.37: 冷却期走位 —— 拉人成功后 1.8s Cooldown(1.8) arm 期间：
    // pullCluster 全 FAIL + pinSeq FAIL（舌头断了）+ closeRangeStrafe FAIL（有LOS）
    // + backoffStrafe FAIL（非Backoff期）→ 零移动傻站。此分支接管：
    // InRange + 有LOS + cooldownPull 内（pullCluster FAIL 的冷却期）→ 横移找角度。
    // 用 SmokerCond_BackoffActive 的反面（非Backoff=冷却期但非退避）区分。
    // 注意：此分支优先级在 backoffStrafe 之后、retarget 之前。
    // v5.37 FIX: 简化为 Cooldown(1.8) 期间 + InRange + HasLOS → 横移，不依赖
    // Backoff 状态（冷却期 = pullCluster 的 cooldown，与 backoff 独立）。

    // ==========================================
    // v4.0.3: 拉人冷却簇 —— 舌头与近战共享 IN_ATTACK。
    // 引擎舌头冷却 (smoker_tongue_delay=1.0) 期间按 ATTACK = 近战挠击，
    // 原版 6 个拉人分支全部无冷却：只要 LOS+射程内就每 tick 按 →
    // 舌头冷却期贴脸挠击（v3.6 注释声称的 Cooldown(1.8) 从未落地）。
    // 现在所有拉人分支包进一个 Cooldown(1.8)：冷却窗口内整个簇 FAIL，
    // 树落到走位/重新选人分支（v3.6 设计意图原样落地），
    // ATTACK 频率从每 tick → 每 1.8s。
    // v5.23: 语义升级（任务书 §9 尝试-确认分离）—— 末端动作换
    // SmokerAct_TryTongue：只有 m_tongueVictim>0 拉中返回 SUCCESS 才 arm
    // 1.8s；失败/超时返回 FAILURE 不消耗冷却（v5.6 框架已保证"失败不 arm"，
    // 动作本身也不再把"按了"当成功）。尝试期间动作 RUNNING 持续按压，拉中
    // 后下一 tick 由 root 第 1 子 pinSeq 接管拖拽，冷却期不挠击。
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
    // v5.44 激进模式: flow 前置埋伏已移除 —— 远处刷出直接追击，不原地蹲守
    // 原 routeAmbushSeq(600flow/!LOS/>750) = 站桩等靠近，已按用户"1"选项禁用
    // int routeAmbushSeq = BT_CreateSequence(4, BT_CreateIsAheadOnRoute(600.0), ... HoldRouteAmbush);

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
    BT_AddChild(root, mode3Approach);         // 3. v4.0: mode 3 → 外侧走位接近
    BT_AddChild(root, openStrategyRoll);      // 4a. open → roll token
    BT_AddChild(root, openS0_Approach);       // 4c. open strat0 → flank approach
    BT_AddChild(root, openS1_Approach);       // 5b. open strat1 → erratic approach
    BT_AddChild(root, closeRangeStrafe);      // 6. v3.6: close + noLOS → strafe, don't approach
    BT_AddChild(root, backoffStrafe);         // 6b. v5.27: InRange+有LOS+Backoff → 横移找角度(防零移动)
    // v6.8.1: 冷却期前压 —— 拉后/拉空冷却期明确前压(主动攻击)，不再横移
    // 原横移在LOS下“原地晃”，用户反馈释放后不主动压。改StrafeMoveToTarget前压
    int cooldownStrafe = BT_CreateSequence(4,
        BT_CreateIsInRange(750.0),  // v5.41: 850→750 tongue_range
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateAction(ACT_AcquirePinnableTarget),
        BT_CreateAction(ACT_StrafeMoveToTarget)
    );
    BT_AddChild(root, cooldownStrafe);        // 6c. v6.8.1: cooldown期+InRange+LOS → 前压
    BT_AddChild(root, ledgeRetargetGated);    // 7. v4.0.3: ledge 附近 → 90% 拉最远（门控）
    BT_AddChild(root, retargetCooldown);      // 8. standard retarget（孤立度选人）
    BT_AddChild(root, approachAct);           // 9. approach (only when far)
    BT_AddChild(root, BT_CreateAction(ACT_Wander)); // 10. last resort — melee IS valid here

    return root;
}

public Smoker_OnModuleStart() {
    SetConVarFloat(FindConVar("smoker_tongue_delay"), 1.0);
    // v5.42 攻击欲望修正(🥇): tongue_miss_delay 15→7 —— 引擎默认失手后
    // 蒸发 15s 是 Smoker 存在感低的主因。单源原则: 本 cvar 即唯一真值,
    // v5.41 的失手退避逻辑锁读此值, 自动跟随。
    SetConVarFloat(FindConVar("tongue_miss_delay"), 7.0);
    g_hCvarTongueMissDelay = FindConVar("tongue_miss_delay");
}
