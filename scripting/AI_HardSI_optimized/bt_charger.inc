// ============================================================================
// bt_charger.inc — Charger Behavior Tree (v3.2)
// ============================================================================
// v5.22（云端审查任务书 §8）：真实冲锋确认 —— 按 IN_ATTACK ≠ 冲锋成功。
// 冲锋分支统一走 ChargerAct_TryCharge：ability_charge 事件（AI_HardSI.sp
// 置位 g_fChargerChargeConfirmed）到达才 BT_SUCCESS（arm 外层 12s 冷却）；
// ~1.1s 未确认 = 引擎拒绝 → 短退避 FAILURE，绝不"Attempt==Success 白锁 12s"。
// Key behaviors preserved from v2.4:
//   - Charge proximity blocking (wait until in range)
//   - Velocity-based prediction (via ability_use event hook)
//   - Wall-slam detection (via ability_use event hook)
//   - Off-angle sweep charge (via ability_use event hook)
//   - Low-health desperation charge
//   - Coordination target switching
// v3.2 terrain-aware additions:
//   - Narrow corridor: hold chokepoint → charge down center (survivor can't dodge)
//   - Open area: flank approach → charge from side (survivor facing elsewhere)
//   - Near ledge: charge to punch survivors off cliffs
// ============================================================================

#if defined _bt_charger_included
  #endinput
#endif
#define _bt_charger_included



// Block charge ability — keep extending cooldown
BT_Status ChargerAct_BlockCharge(int client) {
    int chargeEntity = GetEntPropEnt(client, Prop_Send, "m_customAbility");
    if (chargeEntity > 0) {
        SetEntPropFloat(chargeEntity, Prop_Send, "m_timestamp", GetGameTime() + 0.1);
    }
    return BT_RUNNING;
}

// v4.0.1: 出生保护 —— unghost 后 2s 内禁止释放 charge。
// 症状：Charger 出生（运出复活）后立刻对着空气冲一次。
// 根因：出生瞬间 charge 技能即 ready（m_timestamp 是过去时间），而 coordSeq
//       （攻击窗口分支）没有距离/LOS 限制 —— 窗口常被其他 SI 的攻击/pin 广播
//       打开，一出生就冲远处或隔墙的协同目标，观感就是"对空气冲"。
// 修法：ghost→unghost 边沿检测，unghost 后 2s 内本条件 SUCCESS → 根 selector
//       停在 BlockCharge 分支（持续推后 m_timestamp，引擎 AI 也释放不了），
//       2s 后 FAIL 恢复正常战术。
// v4.0.2: 加 freshSpawn 兜底 —— 未观察到 ghost 阶段（运出复活出生即实体、
//       或 player_spawn 在 unghost 时重发导致黑板被 BB_Init 重置）时，
//       从 Event_PlayerSpawn 记录的 _charger_spawn_at 起 2s 内同样保护。
//       ghost 期间引擎不会攻击，保护期对正常流程无害。
BT_Status CND_ChargerSpawnProtect(int client) {
    bool ghostNow = L4D_IsPlayerGhost(client);
    float ghostSince = BB_GetFloat(client, "_charger_ghost_since", 0.0);
    float unghostAt = BB_GetFloat(client, "_charger_unghost_at", 0.0);

    if (ghostNow) {
        if (ghostSince <= 0.0) {
            BB_SetFloat(client, "_charger_ghost_since", GetGameTime());
        }
        BB_SetFloat(client, "_charger_unghost_at", 0.0);
        return BT_FAILURE;  // ghost 期间引擎忽略攻击，无需保护
    }

    if (ghostSince > 0.0) {
        // 刚 unghost —— 记录时刻并立即进入保护
        unghostAt = GetGameTime();
        BB_SetFloat(client, "_charger_unghost_at", unghostAt);
        BB_SetFloat(client, "_charger_ghost_since", 0.0);
    }

    if (unghostAt > 0.0) {
        return (GetGameTime() - unghostAt < 2.0) ? BT_SUCCESS : BT_FAILURE;
    }

    // v4.0.2 freshSpawn 兜底（须在边沿检测之后，避免 long-ghost 场景双重保护）
    float spawnAt = BB_GetFloat(client, "_charger_spawn_at", 0.0);
    if (spawnAt > 0.0 && GetGameTime() - spawnAt < 2.0) {
        return BT_SUCCESS;
    }

    return BT_FAILURE;
}

// v4.0: 酸液配合 —— 找站在 Spitter 酸液里的生还者作为冲撞目标。
// Charger × Spitter 经典组合：把人撞倒在酸里 → 掉血 + 队友救人要趟酸 → 快速减员。
// 被撞中后 pin 广播会触发 Spitter 吐被撞者（spitOnPinned 分支），形成闭环。
BT_Status ChargerAct_AcquireAcidTarget(int client) {
    int acid = -1;
    float acidPos[3];
    while ((acid = FindEntityByClassname(acid, "spit_acid")) != INVALID_ENT_REFERENCE) {
        GetEntPropVector(acid, Prop_Send, "m_vecOrigin", acidPos);
        for (int i = 1; i <= MaxClients; i++) {
            if (!IsSurvivor(i) || !IsPlayerAlive(i)) continue;
            if (IsPinned(i) || IsIncapacitated(i)) continue;
            float p[3];
            GetClientAbsOrigin(i, p);
            if (GetVectorDistance(p, acidPos) < 200.0) {
                BB_SetInt(client, "target", i);
                return BT_SUCCESS;
            }
        }
    }
    return BT_FAILURE;
}

// ============================================================================
// v5.15: 骚扰模式接近（Harasser Approach）
// 保持 400-800u 距离威慑，但允许短距离冲锋（玩家边缘/落单时）
// ============================================================================

BT_Status ChargerAct_HarasserApproach(int client) {
    int target = BB_GetInt(client, "target", -1);
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) {
        return BT_FAILURE;
    }

    float myPos[3], tPos[3];
    GetClientAbsOrigin(client, myPos);
    GetClientAbsOrigin(target, tPos);
    float distance = GetVectorDistance(myPos, tPos);

    // === v5.15: 机会性冲锋检测 ===
    // 检查冷却（降低攻击频率，比正常模式少 50%）
    float now = GetGameTime();
    float lastOpportunisticCharge = BB_GetFloat(client, "_harass_last_charge", 0.0);
    bool canOpportunisticCharge = (now - lastOpportunisticCharge > 18.0);  // 18秒冷却（正常12秒）

    if (canOpportunisticCharge && distance >= 300.0 && distance <= 600.0) {
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

        // 检测玩家是否接近边缘（前方 200u 内有悬崖）
        bool nearEdge = false;
        float tAng[3], forwardVec[3], checkPos[3];
        GetClientEyeAngles(target, tAng);
        GetAngleVectors(tAng, forwardVec, NULL_VECTOR, NULL_VECTOR);
        checkPos[0] = tPos[0] + forwardVec[0] * 200.0;
        checkPos[1] = tPos[1] + forwardVec[1] * 200.0;
        checkPos[2] = tPos[2];

        float groundCheck[3];
        groundCheck[0] = checkPos[0];
        groundCheck[1] = checkPos[1];
        groundCheck[2] = checkPos[2] - 300.0;

        TR_TraceRayFilter(checkPos, groundCheck, MASK_PLAYERSOLID, RayType_EndPoint, TracerayFilter, client);
        if (!TR_DidHit() || TR_GetFraction() > 0.8) {
            nearEdge = true;
        }

        // 满足条件：进行短距离冲锋（距离限制 600u）
        if (isIsolated || nearEdge) {
            // 检查 LOS
            TR_TraceRayFilter(myPos, tPos, MASK_SHOT, RayType_EndPoint, TracerayFilter, client);
            if (TR_GetFraction() > 0.95) {
                BB_SetFloat(client, "_harass_last_charge", now);
                float dir[3], ang[3];
                MakeVectorFromPoints(myPos, tPos, dir);
                GetVectorAngles(dir, ang);
                BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
                BT_AddButton(client, IN_ATTACK);
                BT_AddButton(client, IN_FORWARD);
                SI_SignalAttack(client);
                return BT_RUNNING;
            }
        }
    }

    // === 正常骚扰行为：距离控制 ===
    if (distance > 800.0) {
        // 太远：接近
        float dir[3], ang[3];
        MakeVectorFromPoints(myPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        BT_AddButton(client, IN_FORWARD);
    } else if (distance < 400.0) {
        // 太近：后退
        float dir[3], ang[3];
        MakeVectorFromPoints(myPos, tPos, dir);
        GetVectorAngles(dir, ang);
        ang[1] += 180.0;  // 反向
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        BT_AddButton(client, IN_FORWARD);
    } else {
        // 400-800u：横移威慑
        float dir[3], ang[3];
        MakeVectorFromPoints(myPos, tPos, dir);
        GetVectorAngles(dir, ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);

        // 随机横移
        float nextSwitch = BB_GetFloat(client, "_harass_strafe_next", 0.0);
        if (nextSwitch <= 0.0 || now >= nextSwitch) {
            BB_SetBool(client, "_harass_strafe_left", GetRandomInt(0, 1) == 0);
            BB_SetFloat(client, "_harass_strafe_next", now + GetRandomFloat(0.5, 1.2));
        }

        if (BB_GetBool(client, "_harass_strafe_left", false)) {
            BT_AddButton(client, IN_MOVELEFT);
        } else {
            BT_AddButton(client, IN_MOVERIGHT);
        }
    }

    BT_StuckDetour(client);
    return BT_RUNNING;
}

// v3.8: Aim at blackboard target before charging.
// Fixes "charging into empty walls" — previously ChargerAct_Charge fired
// IN_ATTACK+IN_FORWARD in whatever direction the previous BT branch left,
// which could be WANDER's random angle pointing at a wall.
// v5.20: Zero pitch — charge is horizontal movement, aiming up/down causes
// collision with ceiling/ground. Only yaw matters for charge direction.
BT_Status ChargerAct_AimAtTarget(int client) {
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        ang[0] = 0.0;  // v5.20: zero pitch — charge horizontally
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    return BT_SUCCESS;
}

// ============================================================================
// v5.22: 统一冲锋尝试动作 ChargerAct_TryCharge（云端审查任务书 §8：
// 按 ATTACK ≠ 冲锋成功）
// ----------------------------------------------------------------------------
// 根因：旧 ChargerAct_Charge 每次按 IN_ATTACK 立即 BT_SUCCESS —— 引擎拒绝
// （冲锋冷却 z_charge_interval=12s / 风阻吞键 / 角度几何 / 距离）时也照样
// SUCCESS → 外层 BT_CreateCooldown(12.0) 记录 12s 冷却 = "Attempt == Success"，
// 白锁一个冷却窗口；被拒多少次就白锁多少个窗口。
// 修法：真实冲锋确认唯一依据 = ability_charge 事件（AI_HardSI.sp
// Event_AbilityUse 置位 g_fChargerChargeConfirmed[client]=GetGameTime()）。
// 只有引擎实际发起冲锋才 BT_SUCCESS（arm 外层 12s 冷却）；约 1.1s 未确认
// = 引擎拒绝 → SI_AbilityBackoff 短退避 0.5-1.0s → BT_FAILURE（外层 Cooldown
// 在 v5.6 已实现"失败不 arm"，树落冷却期走位分支，绝不锁 12s）。
// 状态机记账全部走 SI_Ability*（"_charger" 前缀）：
//   TRYING —— 已按 ATTACK，等真实事件；CONFIRMED —— 事件已到（仅记账）。
// 冷却源唯一 = 外层 BT_CreateCooldown(12.0)（v4.0.3 对齐 z_charge_interval）；
// 本动作不用 SI_AbilityStartCooldown，避免内外双计时把间隔叠成 24s。
#define CHARGER_TRY_TIMEOUT 1.1     // 尝试超时（任务书 0.6-1.2s，取居中）
#define CHARGER_CONFIRM_WINDOW 2.0  // 确认事件有效窗口（防跨多轮的陈旧标记）
BT_Status ChargerAct_TryCharge(int client) {
    float now = GetGameTime();

    // 退避中：不按 ATTACK，FAILURE → 树落冷却期走位分支（v5.1 已有）
    if (SI_AbilityBackoffActive(client, "_charger")) {
        return BT_FAILURE;
    }

    // 进入/续行尝试：非 TRYING（空闲或上次超时后的残留状态）或上次尝试已
    // 过期（被高优先级分支中断后残留的陈旧 try_at）→ 重新标记开始时刻并
    // 置 TRYING。SI_SignalAttack 只在尝试开始时发一次（同旧版按压时刻语义，
    // 事件到达时 .sp 还会再发一次）。
    float tryAt = SI_AbilityGetTryAt(client, "_charger");
    if (SI_AbilityGetState(client, "_charger") != ABILITY_TRYING ||
        now - tryAt > CHARGER_TRY_TIMEOUT) {
        tryAt = now;
        SI_AbilityMarkTry(client, "_charger", tryAt);
        SI_AbilitySetState(client, "_charger", ABILITY_TRYING);
        SI_SignalAttack(client);

        // v5.33/v5.34: 情境化冲锋（用户："纯概率生硬"）—— 墙冲概率由战场
        // 情境动态决定，概率仅作兜底；直冲内部保持跳冲 40% / 地面 60%。
        //   v5.34 用户修正：
        //     近距（≤300u）障碍 = "中间有障碍物" → 冲锋白挨打 → 不冲（走位）
        //     中远（300-600u）障碍 → 墙冲 60%（原 100% 太绝对）
        //   目标孤立（400u 内无队友）→ 12% 墙冲（直冲稳吃，花活无意义）
        //   目标附近密集（400u 内 ≥2 人）→ 55% 墙冲（震荡收益最大）
        //   目标贴墙（150u 内有几何）→ 45% 墙冲（撞墙顺带震墙边）
        //   普通情况 → 30%（v5.31 原设定兜底）
        float wallProb = 0.30;
        bool blockedPath = false;
        int target = BB_GetInt(client, "target", -1);
        if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
            float myPos[3], tPos[3];
            GetClientAbsOrigin(client, myPos);
            GetClientAbsOrigin(target, tPos);

            // 目标附近密集度
            int nearby = 0;
            for (int i = 1; i <= MaxClients; i++) {
                if (i == target || !IsSurvivor(i) || !IsPlayerAlive(i)) continue;
                float p[3];
                GetClientAbsOrigin(i, p);
                if (GetVectorDistance(tPos, p) < 400.0) nearby++;
            }
            if (nearby >= 2) wallProb = 0.55;
            else if (nearby == 0) wallProb = 0.12;

            // 目标贴墙检测（绝对四向 150u trace，只算世界几何）
            bool nearWall = false;
            float baseAng[4][3] = {
                {0.0, 0.0, 0.0}, {0.0, 90.0, 0.0}, {0.0, 180.0, 0.0}, {0.0, 270.0, 0.0}
            };
            for (int d = 0; d < 4 && !nearWall; d++) {
                float fwd[3], end[3];
                GetAngleVectors(baseAng[d], fwd, NULL_VECTOR, NULL_VECTOR);
                end[0] = tPos[0] + fwd[0] * 150.0;
                end[1] = tPos[1] + fwd[1] * 150.0;
                end[2] = tPos[2];
                TR_TraceRayFilter(tPos, end, MASK_PLAYERSOLID, RayType_EndPoint, TerrainTraceFilter, client);
                if (TR_DidHit()) nearWall = true;
            }
            if (nearWall && wallProb < 0.45) wallProb = 0.45;

            // 直线通路检测（分两段，v5.34 用户修正）：
            //   近距（≤300u）被挡 = "中间有障碍物" → 冲锋白挨打 → 不冲
            //   （backoff 交走位分支绕行找角度，本尝试放弃）
            //   中远（300-600u）被挡 → 墙冲概率 60%（用户：不要 100%）
            float fwd[3], end[3];
            MakeVectorFromPoints(myPos, tPos, fwd);
            float dist = NormalizeVector(fwd, fwd);
            bool nearBlocked = false;
            float probeNear = (dist < 300.0) ? dist * 0.8 : 300.0;
            end[0] = myPos[0] + fwd[0] * probeNear;
            end[1] = myPos[1] + fwd[1] * probeNear;
            end[2] = myPos[2] + 30.0;
            TR_TraceRayFilter(myPos, end, MASK_PLAYERSOLID, RayType_EndPoint, LOS_TraceFilter, client);
            if (TR_DidHit()) {
                int ent = TR_GetEntityIndex();
                if (ent != target) nearBlocked = true;
            }
            if (nearBlocked) {
                // 中间有障碍物：冲锋白挨打 → 放弃本尝试，交走位绕行
                SI_AbilityBackoff(client, "_charger", now, GetRandomFloat(0.5, 1.0));
                BB_SetBool(client, "_charger_leap_charge", false);
                BB_SetBool(client, "_charger_wall_mode", false);
                return BT_FAILURE;
            }
            bool blockedPath = false;
            float probeFar = (dist < 600.0) ? dist * 0.8 : 600.0;
            end[0] = myPos[0] + fwd[0] * probeFar;
            end[1] = myPos[1] + fwd[1] * probeFar;
            end[2] = myPos[2] + 30.0;
            TR_TraceRayFilter(myPos, end, MASK_PLAYERSOLID, RayType_EndPoint, LOS_TraceFilter, client);
            if (TR_DidHit()) {
                int ent = TR_GetEntityIndex();
                if (ent != target) blockedPath = true;
            }
            if (blockedPath && wallProb < 0.60) wallProb = 0.60;
        }

        // 掷骰：wallProb 墙冲 / 其余直冲（内层跳冲 40% / 地面 60%）
        float roll = GetRandomFloat(0.0, 1.0);
        if (roll < wallProb) {
            BB_SetBool(client, "_charger_wall_mode", true);
            BB_SetBool(client, "_charger_leap_charge", false);
        } else {
            BB_SetBool(client, "_charger_wall_mode", false);
            BB_SetBool(client, "_charger_leap_charge", GetRandomFloat(0.0, 1.0) < 0.4);
        }
    }

    // v5.29: 墙冲震荡模式 —— 重新瞄准"目标侧向偏移点"
    // （不直接冲人，冲进人群边缘/撞墙 → impact 震荡；偏移方向随机避免套路）
    bool wallMode = BB_GetBool(client, "_charger_wall_mode", false);
    int target = BB_GetInt(client, "target", -1);
    if (wallMode && target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        // v5.29: 侧向偏移两轮收窄（用户实测定向）：150-250 → 60-120 → 40-80。
        // 撞点越贴目标，impact 震荡覆盖越稳；40-80u 是"擦边不撞人"的紧贴区。
        float side = GetRandomFloat(40.0, 80.0) * (GetRandomInt(0, 1) ? 1.0 : -1.0);
        float off[3];
        // 目标侧向偏移（垂直于目标方向）
        off[0] = tPos[0] - dir[1] * side;
        off[1] = tPos[1] + dir[0] * side;
        off[2] = tPos[2];
        MakeVectorFromPoints(sPos, off, dir);
        GetVectorAngles(dir, ang);
        ang[0] = 0.0;
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }

    // v5.28: 跳起空中冲锋模式（30% 掷骰结果）——
    // 地面阶段：按 IN_JUMP 跳起（保持朝目标前进，不按 ATTACK）
    // 离地阶段：按 IN_ATTACK 在空中发起冲刺（轨迹难预判）
    if (BB_GetBool(client, "_charger_leap_charge", false)) {
        if (GetEntityFlags(client) & FL_ONGROUND) {
            BT_AddButton(client, IN_JUMP);
            BT_AddButton(client, IN_FORWARD);
        } else {
            BT_AddButton(client, IN_ATTACK);
            BT_AddButton(client, IN_FORWARD);
        }
    } else {
        // 普通/墙冲：地面冲锋（撞墙后树自然落近战簇贴身拳击）
        BT_AddButton(client, IN_ATTACK);
        BT_AddButton(client, IN_FORWARD);
    }

    // 真实确认：ability_charge 事件已到（2s 窗口内）→ 清标记防重复消费、
    // 记 CONFIRMED、BT_SUCCESS → 外层 Cooldown(12.0) arm（唯一 12s 冷却源）
    if (g_fChargerChargeConfirmed[client] > 0.0) {
        if (now - g_fChargerChargeConfirmed[client] <= CHARGER_CONFIRM_WINDOW) {
            g_fChargerChargeConfirmed[client] = 0.0;
            SI_AbilitySetState(client, "_charger", ABILITY_CONFIRMED);
            SI_AbilityMarkConfirmed(client, "_charger", now);
            BB_SetBool(client, "_charger_leap_charge", false);   // 重置，下次重新掷骰
            BB_SetBool(client, "_charger_wall_mode", false);
            return BT_SUCCESS;
        }
        // 陈旧标记（上一轮冲锋的残留/跨重生）：丢弃，不当作本次确认
        g_fChargerChargeConfirmed[client] = 0.0;
    }

    // 超时未确认 = 引擎拒绝（冲锋冷却/风阻吞键/角度几何/距离）→ 短退避。
    // 退避期 TryCharge FAILURE 挡住下一 tick 立刻重按，强制 0.5-1.0s 间隔。
    if (now - tryAt > CHARGER_TRY_TIMEOUT) {
        SI_AbilityBackoff(client, "_charger", now, GetRandomFloat(0.5, 1.0));
        BB_SetBool(client, "_charger_leap_charge", false);       // 重置，下次重新掷骰
        BB_SetBool(client, "_charger_wall_mode", false);
        return BT_FAILURE;
    }

    return BT_RUNNING;
}

// ============================================================================
// v5.27: 高处幸存者震落冲锋（用户设计："幸存者跳上特感够不到的高处，
// Charger 冲撞其脚下支撑结构/平台边缘，用 charge impact 把人震下来"）
// 引擎机制：Charger 冲锋撞到障碍物时产生冲击（charge impact），可推倒/
// 震落冲击范围内的幸存者。瞄准"目标正下方支撑点"直线冲锋 → 撞平台边缘/
// 支撑结构 → 高处目标被震落（不再干望）。
// 与普通冲锋（TryCharge）的区别：无通路检查 —— 撞墙正是目的。
// ============================================================================
#define CHARGER_SHOCK_MIN_DZ 80.0     // 目标至少高这么多才算"高处"
#define CHARGER_SHOCK_MAX_DZ 250.0    // 太高 charge impact 够不着
#define CHARGER_SHOCK_MIN_DIST 250.0
#define CHARGER_SHOCK_MAX_DIST 900.0

BT_Status ChargerCond_HighShockTarget(int client) {
    int target = BB_GetInt(client, "target", -1);
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) return BT_FAILURE;

    float myPos[3], tPos[3];
    GetClientAbsOrigin(client, myPos);
    GetClientAbsOrigin(target, tPos);

    // 垂直落差（目标在高处）
    float dz = tPos[2] - myPos[2];
    if (dz < CHARGER_SHOCK_MIN_DZ || dz > CHARGER_SHOCK_MAX_DZ) return BT_FAILURE;

    // 水平距离（冲锋覆盖范围）
    float dx = tPos[0] - myPos[0], dy = tPos[1] - myPos[1];
    float hDist = SquareRoot(dx * dx + dy * dy);
    if (hDist < CHARGER_SHOCK_MIN_DIST || hDist > CHARGER_SHOCK_MAX_DIST) return BT_FAILURE;

    // 目标脚下必须有实体支撑（向下 trace 命中 = 站在平台/屋顶/箱子上，
    // 而非悬空/水面 —— 悬空的冲了也震不到）
    float down[3];
    down[0] = tPos[0];
    down[1] = tPos[1];
    down[2] = tPos[2] - 250.0;
    TR_TraceRayFilter(tPos, down, MASK_PLAYERSOLID, RayType_EndPoint, LOS_TraceFilter, client);
    if (!TR_DidHit()) return BT_FAILURE;

    return BT_SUCCESS;
}

// 瞄准目标正下方的支撑点（水平方向，pitch 归零）—— 冲锋撞支撑结构
BT_Status ChargerAct_ShockAim(int client) {
    int target = BB_GetInt(client, "target", -1);
    if (target <= 0 || !IsSurvivor(target) || !IsPlayerAlive(target)) return BT_FAILURE;
    float tPos[3], myPos[3], dir[3], ang[3];
    GetClientAbsOrigin(target, tPos);
    GetClientAbsOrigin(client, myPos);
    MakeVectorFromPoints(myPos, tPos, dir);
    dir[2] = 0.0;
    if (GetVectorLength(dir) < 10.0) return BT_FAILURE;
    NormalizeVector(dir, dir);
    GetVectorAngles(dir, ang);
    ang[0] = 0.0;   // 水平冲撞
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    return BT_SUCCESS;
}

// 震落冲锋状态机：与 TryCharge 相同（ability_charge 事件确认 arm 12s 冷却 /
// 超时退避），但独立状态前缀 "_charger_shock" 且【无通路检查】——撞墙是目的
BT_Status ChargerAct_TryShockCharge(int client) {
    float now = GetGameTime();

    if (SI_AbilityBackoffActive(client, "_charger_shock")) {
        return BT_FAILURE;
    }

    // 真实确认：ability_charge 事件（2s 窗口）→ arm 外层 Cooldown(12.0)
    if (g_fChargerChargeConfirmed[client] > 0.0) {
        if (now - g_fChargerChargeConfirmed[client] <= CHARGER_CONFIRM_WINDOW) {
            g_fChargerChargeConfirmed[client] = 0.0;
            SI_AbilitySetState(client, "_charger_shock", ABILITY_CONFIRMED);
            SI_AbilityMarkConfirmed(client, "_charger_shock", now);
            return BT_SUCCESS;
        }
        g_fChargerChargeConfirmed[client] = 0.0;
    }

    float tryAt = SI_AbilityGetTryAt(client, "_charger_shock");
    if (SI_AbilityGetState(client, "_charger_shock") != ABILITY_TRYING ||
        now - tryAt > CHARGER_TRY_TIMEOUT) {
        tryAt = now;
        SI_AbilityMarkTry(client, "_charger_shock", tryAt);
        SI_AbilitySetState(client, "_charger_shock", ABILITY_TRYING);
        SI_SignalAttack(client);
    }

    BT_AddButton(client, IN_ATTACK);
    BT_AddButton(client, IN_FORWARD);

    if (now - tryAt > CHARGER_TRY_TIMEOUT) {
        SI_AbilityBackoff(client, "_charger_shock", now, GetRandomFloat(0.5, 1.0));
        return BT_FAILURE;
    }

    return BT_RUNNING;
}

// v3.6: Blind charge — charge even without LOS (30% chance).
// Charger's charge has a wide hitbox that can clip survivors around corners.
// Sometimes a blind charge is better than circling forever.
// v5.20: Zero pitch + add cooldown to prevent spam (was firing every 0.17s).
BT_Status ChargerAct_BlindCharge(int client) {
    // v5.20: cooldown check — prevent blind charge spam (30%×60tick = every 0.17s)
    float now = GetGameTime();
    float lastBlind = BB_GetFloat(client, "_charger_last_blind", 0.0);
    if (now - lastBlind < 8.0) return BT_FAILURE;  // 8s cooldown for blind charges

    BB_SetFloat(client, "_charger_last_blind", now);

    // Face the acquired target direction even without LOS
    int target = BB_GetInt(client, "target", -1);
    if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
        float sPos[3], tPos[3], dir[3], ang[3];
        GetClientAbsOrigin(client, sPos);
        GetClientAbsOrigin(target, tPos);
        MakeVectorFromPoints(sPos, tPos, dir);
        GetVectorAngles(dir, ang);
        ang[0] = 0.0;  // v5.20: zero pitch
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    }
    // v5.22: 按压与结果解耦 —— 旧版"按 IN_ATTACK 即 SUCCESS"（Attempt==Success，
    // 引擎拒绝时也假成功白锁 12s）。现在交给 ChargerAct_TryCharge 做真实确认
    // 状态机：按住 ATTACK 直到 ability_charge 事件才 SUCCESS（arm 外层 12s）；
    // ~1.1s 未确认 → 短退避 FAILURE（不锁冷却）。盲冲自身 8s 门（_charger_last_blind）
    // 继续兜底防 spam（被拒后 8s 内不再盲冲，其余冲锋分支照常经退避重试）。
    return ChargerAct_TryCharge(client);
}

// v3.6: Step-back then charge — when too close (<200u), back up briefly
// to create optimal charge distance, then charge.
BT_Status ChargerAct_StepBackCharge(int client) {
    float now = GetGameTime();
    float backUntil = BB_GetFloat(client, "_charger_backup_until", 0.0);

    if (backUntil <= 0.0) {
        // Start backing up
        BB_SetFloat(client, "_charger_backup_until", now + 0.4);
    }

    if (now < backUntil) {
        // Backpedal: face target, move backward
        int target = BB_GetInt(client, "target", -1);
        if (target > 0 && IsSurvivor(target) && IsPlayerAlive(target)) {
            float sPos[3], tPos[3], dir[3], ang[3];
            GetClientAbsOrigin(client, sPos);
            GetClientAbsOrigin(target, tPos);
            MakeVectorFromPoints(sPos, tPos, dir);
            GetVectorAngles(dir, ang);
            BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        }
        BT_AddButton(client, IN_BACK);
        return BT_RUNNING;
    }

    // v3.8 FIX: Re-check LOS before charging. During the 0.4s back-up,
    // the survivor may have moved behind cover. If LOS is lost, abort
    // and let the selector try another branch (approach/blind charge).
    if (GetEntProp(client, Prop_Send, "m_hasVisibleThreats") <= 0) {
        BB_SetFloat(client, "_charger_backup_until", 0.0);
        return BT_FAILURE;
    }

    // Back-up complete → charge now
    // v5.22: 尝试状态机 —— 真实 ability_charge 事件确认才 SUCCESS（arm 外层
    // 12s）；被引擎拒绝（冷却/风阻）时 ~1.1s 超时 FAILURE → 交走位分支，
    // 不再"按了就假成功白锁 12s"（贴脸时若引擎拒绝，IN_ATTACK 变近战拳击
    // 的旧兜底语义仍由引擎侧保留，但不会消耗插件冷却）。
    BB_SetFloat(client, "_charger_backup_until", 0.0);
    return ChargerAct_TryCharge(client);
}
stock int BT_CreateChargerTree() {
    // --- Read charge-range cvars (v3.4 FIX: were created but never read) ---
    float fChargeProx = 750.0;  // v3.6: increased from 500 for more aggressive charging
    int   iHpThreshold = 200;
    ConVar hCvar = FindConVar("ai_charge_proximity");
    if (hCvar != null) fChargeProx = GetConVarFloat(hCvar);
    hCvar = FindConVar("ai_health_threshold_charger");
    if (hCvar != null) iHpThreshold = GetConVarInt(hCvar);

    // --- v3.2 terrain strategies: narrow ---
    // v4.0.2: 移除 narrowHoldSeq（HoldChokepoint 站桩是 Tank/Boomer 卡点动作，
    // 对 Charger 是"原地不动看着生还者"）——窄巷本应无解直冲；
    // narrowChargeSeq 距离 400→fChargeProx(750)，与开阔地冲锋距离对齐。
    int narrowChargeSeq = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可冲)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fChargeProx),
        BT_CreateAction(ChargerAct_AimAtTarget),
        BT_CreateAction(ChargerAct_TryCharge)
    );

    // === v3.5: Open terrain — 3-way random strategies ===
    int openStrategyRoll = BT_CreateSequence(2,
        BT_CreateCondition(CND_IsOpenArea),
        BT_CreateRollStrategy(3)
    );
    // Strat 0: Flank charge — circle around → charge from side
    // v4.0: 大弧线绕后（CircleFlank）—— 120° 大圈绕到队伍侧后方再冲
    int openS0_Approach = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(0),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可冲)
        BT_CreateIsNotTargetInRange(600.0),
        BT_CreateAction(ACT_CircleFlank)
    );
    int openS0_Charge = BT_CreateSequence(7,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(0),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可冲)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fChargeProx),
        BT_CreateAction(ChargerAct_AimAtTarget),
        BT_CreateAction(ChargerAct_TryCharge)
    );
    // Strat 1: Erratic charge — zigzag approach → charge
    int openS1_Approach = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(1),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可冲)
        BT_CreateIsNotTargetInRange(500.0),
        BT_CreateAction(ACT_ErraticApproach)
    );
    int openS1_Charge = BT_CreateSequence(7,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(1),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可冲)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fChargeProx),
        BT_CreateAction(ChargerAct_AimAtTarget),
        BT_CreateAction(ChargerAct_TryCharge)
    );
    // Strat 2: Standard — falls through to defaultChargeSeq below

    // Ledge nearby: charge toward survivors near the edge
    int ledgeChargeSeq = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsNearLedge),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可冲)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(450.0),
        BT_CreateAction(ChargerAct_AimAtTarget),
        BT_CreateAction(ChargerAct_TryCharge)
    );

    // Low-health desperation charge (v3.8 FIX: added AcquireClosestTarget + HasLOS
    // + AimAtTarget — previously had none of these, would charge in whatever
    // direction the previous BT branch left, often straight into a wall)
    int lowHpSeq = BT_CreateSequence(6,
        BT_CreateHealthBelow(float(iHpThreshold)),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可冲)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fChargeProx),
        BT_CreateAction(ChargerAct_AimAtTarget),
        BT_CreateAction(ChargerAct_TryCharge)
    );

    // Coordination attack
    // v4.0: 目标由 SI_GetCoordinatedTarget 决定 ——
    //   集火模式（0/1/2/3/5）：窗口内优先冲被 pin 者（队友锁住的人必中）
    //   分散模式（4/6）：冲未受控目标（Tank 模式下冲别的目标减轻 Tank 压力）
    // v4.0.1 FIX: 补上 HasLOS + inRange —— 原版无任何距离/LOS 限制，
    //   攻击窗口（5.5s，常被其他 SI 攻击/pin 广播打开）一开，Charger 在
    //   2000u+ 外/隔墙也直接释放 charge，造成"出生对空气冲"与平时白冲。
    // v5.7: 补 AcquireCoordTarget —— 原版门控量 BB target（常空/陈旧）
    // 而瞄准/冲锋用 SI_GetCoordinatedTarget（另一幸存者），LOS 与距离判断
    // 对错了人
    int coordSeq = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsAttackWindow),
        BT_CreateAction(ACT_AcquireCoordTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fChargeProx),
        BT_CreateAction(ACT_SnapAimToCoordTarget),
        BT_CreateAction(ChargerAct_TryCharge)
    );

    // ==========================================
    // v4.0: 钢铁洪流 (mode 0) —— 正面直冲，更远距离开冲。
    // 洪流的战术 = 近战 SI 一波涌入：Charger 是开路先锋，
    // 900u 直接冲（比默认 750 更凶），冲散阵型后 Hunter/Jockey 跟进。
    // ==========================================
    int mode0Charge = BT_CreateSequence(6,
        BT_CreateIsMode(0),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可冲)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(900.0),
        BT_CreateAction(ChargerAct_AimAtTarget),
        BT_CreateAction(ChargerAct_TryCharge)
    );

    // ==========================================
    // v4.0: 酸液配合 —— 冲站在 Spitter 酸液里的生还者（任何模式生效）
    // Charger × Spitter 经典组合：撞进酸里锁住 → 掉血 + 救人趟酸 → 快速减员
    // ==========================================
    int acidCharge = BT_CreateSequence(5,
        BT_CreateAction(ChargerAct_AcquireAcidTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fChargeProx),
        BT_CreateAction(ChargerAct_AimAtTarget),
        BT_CreateAction(ChargerAct_TryCharge)
    );

    // ==========================================
    // v5.0 突破手：幸存者密集（≥3 人 500u 内）→ 锁定密集区中心成员
    // （ACT_AcquireClusterTarget）→ 冲锋撕开火力网。密集区 = 队伍火力最
    // 集中处，冲散阵型后 Hunter/Jockey/Boomer 跟进收割。与"抓最近者"
    // 不同：目标是整片火力网，不是单兵（用户定位：Charger 是突破手）。
    // ==========================================
    int breakthroughCharge = BT_CreateSequence(6,
        BT_CreateSurvivorsClustered(3, 500.0),
        BT_CreateAction(ACT_AcquireClusterTarget),
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fChargeProx),
        BT_CreateAction(ChargerAct_AimAtTarget),
        BT_CreateAction(ChargerAct_TryCharge)
    );

    // Default charge: in range + LOS → charge (v3.2 fix: was missing)
    int defaultChargeSeq = BT_CreateSequence(5,
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可冲)
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsTargetInRange(fChargeProx),
        BT_CreateAction(ChargerAct_AimAtTarget),
        BT_CreateAction(ChargerAct_TryCharge)
    );

    // v3.2 FIX: approach when in range but no LOS (LOS blind-spot deadlock).
    // Previously: distance ≤500 + no LOS → neither charge nor approach fires
    // → falls to BlockCharge → Charger stands still extending cooldown forever.
    int noLosApproach = BT_CreateSequence(4,
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可冲)
        BT_CreateInverter(BT_CreateCondition(CND_HasTargetLOS)),
        BT_CreateIsTargetInRange(fChargeProx),
        BT_CreateAction(ACT_StrafeMoveToTarget)   // keep moving, may regain LOS
    );

    // Standard approach: strafe toward target when too far to charge
    int approachSeq = BT_CreateSequence(3,
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可冲)
        BT_CreateInverter(BT_CreateIsTargetInRange(fChargeProx)),
        BT_CreateAction(ACT_StrafeMoveToTarget)
    );

    // ==========================================
    // v3.6: Aggressive charge — blind charge + step-back charge.
    // Charger's charge has a wide hitbox; a blind charge around corners
    // is often better than circling forever. When too close (<200u),
    // step back briefly to create optimal charge distance.
    // ==========================================
    // v3.7 FIX (P0): Removed RandomChance from stepBackCharge.
    // RandomChance re-evaluates every tick → step-back was being aborted mid-way
    // when the dice roll changed. Now always step back when too close.
    // Close range + HasLOS → step back 0.4s then charge. If charge is on
    // cooldown, IN_ATTACK becomes melee punch (valid fallback 贴脸近战).
    int stepBackCharge = BT_CreateSequence(4,
        BT_CreateCondition(CND_HasTargetLOS),
        BT_CreateIsInRange(200.0),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可冲)
        BT_CreateAction(ChargerAct_StepBackCharge)
    );
    // v3.7 FIX (P0): Removed ForceSuccess wrapper from blindCharge.
    // ForceSuccess caused deadlock: when RandomChance failed, ForceSuccess
    // returned SUCCESS anyway → selector consumed → Charger did nothing
    // every tick. Now blindCharge fails naturally, selector moves to
    // next branch (noLosApproach / approachSeq / Wander).
    int blindCharge = BT_CreateSequence(5,
        BT_CreateInverter(BT_CreateCondition(CND_HasTargetLOS)),
        BT_CreateIsInRange(400.0),
        BT_CreateRandomChance(0.30),
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可冲)
        BT_CreateAction(ChargerAct_BlindCharge)
    );

    // ==========================================
    // v4.0.3: 冲锋冷却簇 —— 冲锋与近战共享 IN_ATTACK。
    // 引擎冲锋冷却 z_charge_interval=12s（空服 rcon 实测，非 3s！）期间按
    // ATTACK = 近战拳击；原版 11 个冲锋分支全部无冷却：进入冲锋距离后每
    // tick 都按 → 冷却期贴脸拳击/退后-挠循环（v3.7 注释承认"拳击是有效
    // fallback"，但每 tick 狂按不是设计意图）。
    // 簇冷却 12.0 对齐引擎冷却：12s 内整个簇 FAIL，树落到 BlockCharge/
    // 走位分支（不按 ATTACK），12s 一到引擎技能就绪 → 立刻再冲，零浪费。
    // 分支相对顺序与 v4.0 一致：出生保护 > pin 判断 > 近距离/盲冲/洪流/
    // 协同/酸液/悬崖/窄巷/开阔/残血/默认。
    // v5.22（任务书 §8）：簇内所有 ATTACK 动作统一替换为
    // ChargerAct_TryCharge —— 真实 ability_charge 事件确认才 SUCCESS（arm
    // 本 12s 冷却），引擎拒绝时 ~1.1s 超时 → 短退避 FAILURE（v5.6 失败不
    // arm）。外层 Cooldown(12.0) 仍是唯一冷却源；"被拒也白锁 12s"的
    // Attempt==Success 问题从根上消除。
    // ==========================================
    int chargeCluster = BT_Create(BTN_SELECTOR);
    BT_AddChild(chargeCluster, stepBackCharge);    // too close → step back + charge
    BT_AddChild(chargeCluster, blindCharge);       // no LOS + close → 30% blind charge
    BT_AddChild(chargeCluster, mode0Charge);       // v4.0: mode 0 → 900u 正面直冲
    BT_AddChild(chargeCluster, coordSeq);          // v4.0: coordination 冲被 pin 者
    BT_AddChild(chargeCluster, acidCharge);        // v4.0: 冲酸液里的人
    BT_AddChild(chargeCluster, breakthroughCharge);// v5.0: 突破手 → 冲密集区中心
    BT_AddChild(chargeCluster, ledgeChargeSeq);    // v3.2: ledge → charge
    BT_AddChild(chargeCluster, narrowChargeSeq);   // v3.2/v4.0.2: narrow → charge
    BT_AddChild(chargeCluster, openS0_Charge);     // v3.5: open strat0 → flank charge
    BT_AddChild(chargeCluster, openS1_Charge);     // v3.5: open strat1 → erratic charge
    BT_AddChild(chargeCluster, lowHpSeq);          // FALLBACK: low HP charge
    BT_AddChild(chargeCluster, defaultChargeSeq);  // FALLBACK: default charge

    // v5.18 功能 2：冲锋前的挂边守卫
    // ------------------------------------------
    // 12s 冷却的冲锋是 Charger 最贵的资源。GetClosestSurvivor 不过滤倒地/挂边
    // （只查 IsPlayerAlive），所以 defaultChargeSeq 这类 fallback 会锁上挂边者
    // 白冲一次。这里在整簇外加守卫：目标不可控（挂边/倒地/已被控）时整簇 FAIL，
    // 树落到走位分支等一个站着的目标，冷却不被浪费。
    //
    // 例外：挂边者本身值得撞（撞落即死），但那由 hangingCharge 单独处理，
    // 它显式选人所以不受本守卫影响 —— 守卫只挡"误锁"，不挡"故意打"。
    int guardedChargeCluster = BT_CreateSequence(2,
        BT_CreateCondition(CND_TargetIsPinnable),
        chargeCluster
    );

    // 挂边者专用冲锋：把挂边的人撞下去（即死）。显式选人 + 400u 内，
    // 排在守卫簇之前，是主动机会而非误锁。
    int hangingCharge = BT_CreateSequence(3,
        BT_CreateAcquireHangingTarget(400.0),
        BT_CreateAction(ChargerAct_AimAtTarget),
        BT_CreateAction(ChargerAct_TryCharge)
    );

    int chargeRoot = BT_Create(BTN_SELECTOR);
    BT_AddChild(chargeRoot, hangingCharge);        // v5.18: 撞落挂边者
    BT_AddChild(chargeRoot, guardedChargeCluster); // v5.18: 守卫后的原冲锋簇
    int cooldownCharge = BT_CreateCooldown(12.0, chargeRoot);  // v4.0.3: 对齐 z_charge_interval=12s

    // v5.0 突破手绕行：12s 冲锋冷却期间绕侧后接近密集区（CircleFlank 大弧线，
    // 从生还者视线外绕到侧后方），技能冷却一好立即被 cooldownCharge 的
    // breakthroughCharge 接手冲锋 —— 冷却期绕行、冷却好就冲，节奏自洽。
    int breakthroughApproach = BT_CreateSequence(4,
        BT_CreateSurvivorsClustered(3, 500.0),
        BT_CreateAction(ACT_AcquireClusterTarget),
        BT_CreateIsNotTargetInRange(fChargeProx),
        BT_CreateAction(ACT_CircleFlank)
    );

    // Root selector — terrain branches fail when disabled → fallback to standard.
    int root = BT_Create(BTN_SELECTOR);
    // v4.0.1: 0. 出生保护 —— unghost 后 2s 内强制 BlockCharge（防出生对空气冲）
    int spawnProtect = BT_CreateSequence(2,
        BT_CreateCondition(CND_ChargerSpawnProtect),
        BT_CreateAction(ChargerAct_BlockCharge)
    );
    BT_AddChild(root, spawnProtect);                               // 0. v4.0.1
    BT_AddChild(root, BT_CreateCondition(CND_IsPinningSurvivor)); // 1

    // v5.13: 骚扰模式 —— 作为骚扰者时不冲锋，只接近威慑
    // v5.18: 解放条件放宽为 CND_HarasserReleased（发起者得手 OR 齐射令下）
    int harassSeq = BT_CreateSequence(3,
        BT_CreateCondition(CND_IsHarasser),
        BT_CreateInverter(BT_CreateCondition(CND_HarasserReleased)),
        BT_CreateSequence(2,
            BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可冲)
            BT_CreateAction(ChargerAct_HarasserApproach)
        )
    );
    BT_AddChild(root, harassSeq);                  // 2. v5.13: harasser mode

    // 2.5. v5.27: 高处幸存者震落冲锋 —— 目标在够不到的高处时冲撞其脚下
    // 支撑结构（charge impact 震落），优先于普通冲锋（普通冲锋通路 trace
    // 会被平台挡 → FAIL，落走位干望）
    int shockDownSeq = BT_CreateCooldown(12.0,
        BT_CreateSequence(4,
            BT_CreateCondition(CND_OnGround),
            BT_CreateCondition(ChargerCond_HighShockTarget),
            BT_CreateAction(ChargerAct_ShockAim),
            BT_CreateAction(ChargerAct_TryShockCharge)
        )
    );
    BT_AddChild(root, shockDownSeq);

    BT_AddChild(root, cooldownCharge);          // 3. v4.0.3: 全部冲锋分支（12s 冷却）
    BT_AddChild(root, breakthroughApproach);    // 4. v5.0: 冷却期绕侧后接近密集区
    BT_AddChild(root, openStrategyRoll);         // 5. v3.5: open → roll token
    BT_AddChild(root, openS0_Approach);          // 6. v3.5: open strat0 → flank approach
    BT_AddChild(root, openS1_Approach);          // 7. v3.5: open strat1 → erratic approach
    // open strat2 → falls through to generic approaches
    // ==========================================
    // v5.1: 站桩修复 —— 原 child 9 直接挂 ChargerAct_BlockCharge：
    //   ① 不按移动键 → 观感 = 站原地挨打（"傻站"）；
    //   ② 每 2 tick 推后引擎 m_timestamp +0.1s → 引擎冲锋永久不就绪，
    //      12s 插件冷却结束后尝试冲锋仍是挠击，循环站桩。
    // 修复：冷却期改为走位逼近（不按 ATTACK，防挠击语义保留），
    // m_timestamp 推后仅保留在出生保护分支（spawnProtect，2s 有界）。
    // ==========================================
    int cooldownReposition = BT_CreateSequence(2,
        BT_CreateAction(ACT_AcquirePinnableTarget),  // v5.19: 优先站立目标(倒地不可冲)
        BT_CreateAction(ACT_StrafeMoveToTarget)
    );
    BT_AddChild(root, noLosApproach);            // 8. FALLBACK: in-range no-LOS approach
    BT_AddChild(root, approachSeq);              // 9. FALLBACK: approach from far
    BT_AddChild(root, cooldownReposition);       // 10. v5.1: 冲锋冷却期走位逼近（不按 ATTACK）
    BT_AddChild(root, BT_CreateAction(ACT_Wander));             // 11. last resort

    return root;
}

public Charger_OnModuleStart() {
    // ai_charge_proximity：BT 发起冲锋的距离门槛（按钮路径，引擎对按钮冲锋
    // 无距离限制；是否打得中取决于冲锋物理覆盖）。
    // v4.0.3 验证结论（空服 rcon 实测，见 ENGINE_CVARS.md）：
    //   z_charge_duration=2.5s × z_charge_max_speed=500u/s + warmup 0.5s 加速
    //   → 冲锋覆盖 ≈ 940~1190u。750u 发起完全打得到，500 反而保守浪费一半覆盖。
    //   服务器当前内存值本就是 750（手动设过）——源码默认必须对齐 750，
    //   否则重启会掉回 v2.4 的 500。
    CreateConVar("ai_charge_proximity", "750", "Charger charge proximity");
    CreateConVar("ai_health_threshold_charger", "200", "Low HP charge threshold");
}
