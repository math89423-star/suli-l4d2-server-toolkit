// ============================================================================
// bt_jockey.inc — Jockey Behavior Tree (v3.2)
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
// v4.0: 骑乘 steering —— 骑上人后把人往远离队伍中心的方向带。
// 引擎默认 Jockey 骑乘后漫无目的乱跑；真人 Jockey 会把人往队伍外/
// 特感堆方向带，拉散阵型。骑乘时按 W + 朝向 = 被骑者被往那个方向拖。
// ============================================================================

BT_Status JockeyAct_SteerRide(int client) {
    int victim = GetEntPropEnt(client, Prop_Send, "m_jockeyVictim");
    if (victim <= 0) return BT_FAILURE;
    if (!IsSurvivor(victim) || !IsPlayerAlive(victim)) return BT_FAILURE;

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
            BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
            BT_AddButton(client, IN_FORWARD);
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
                BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
                BT_AddButton(client, IN_FORWARD);
                return BT_RUNNING;
            }
        }
        GetVectorAngles(dir, ang);
    } else {
        // 单人局：保持当前朝向
        GetClientEyeAngles(client, ang);
    }
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_FORWARD);
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
        float eyeAng[3];
        GetClientEyeAngles(client, eyeAng);
        eyeAng[0] = -1.0 * GetRandomFloat(15.0, 30.0);  // pitch up
        BT_SetAimAngles(client, eyeAng[0], eyeAng[1], eyeAng[2]);
        BT_AddButton(client, IN_JUMP);
        BB_SetBool(client, "jockey_next_is_jump", false);
    } else {
        // Leap attack
        BT_AddButton(client, IN_ATTACK);
        BB_SetBool(client, "jockey_next_is_jump", !doubleLeap);
        SI_SignalAttack(client);
    }
    return BT_SUCCESS;
}
stock int BT_CreateJockeyTree() {
    // Riding — v4.0: 骑乘 steering（把人往队伍外带），不再原地 hold
    int rideSeq = BT_CreateSequence(2,
        BT_CreateCondition(CND_IsPinningSurvivor),
        BT_CreateAction(JockeyAct_SteerRide)
    );

    // ==========================================
    // v4.0: 暗影锁链 (mode 1) —— Smoker 拉中 → Jockey 骑同一人（拉散）
    // 窗口 = Smoker 拉中的 pin 广播；被拉的人无法移动，Jockey 骑 = 必中。
    // 骑上后再被 steering 往队伍外带 —— 锁链完整：拉→骑→拖走。
    // ==========================================
    int mode1ChainApproach = BT_CreateSequence(5,
        BT_CreateIsMode(1),
        BT_CreateCondition(CND_IsAttackWindow),
        BT_CreateAction(ACT_AcquirePinTarget),
        BT_CreateIsNotInRange(500.0),
        BT_CreateAction(ACT_StrafeMoveToTarget)
    );
    int mode1ChainLeap = BT_CreateSequence(5,
        BT_CreateIsMode(1),
        BT_CreateCondition(CND_IsAttackWindow),
        BT_CreateAction(ACT_AcquirePinTarget),
        BT_CreateIsInRange(500.0),
        BT_CreateCooldown(1.0, BT_CreateAction(JockeyAct_AlternatingHop))
    );

    // --- v3.2 FIX: Terrain-aware leap strategies ---
    // Each terrain type is split into TWO branches:
    //   Approach (far):  terrain match + onGround + HasLOS + NOT inRange → move
    //   Attack  (close): terrain match + onGround + HasLOS + inRange → AlternatingHop
    // Previously these branches ended with RUNNING-type movement actions
    // (HugWall/FlankApproach), which blocked the hopSeq fallback forever.
    // Now the approach runs when far; when close, it fails (Inverter trips)
    // and the selector moves to the attack branch.

    // Ledge: approach (far) → flank
    int ledgeApproach = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsNearLedge),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateInverter(BT_CreateIsInRange(400.0)),   // still far
        BT_CreateAction(ACT_FlankApproach)
    );
    int ledgeLeap = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsNearLedge),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(400.0),                       // close enough
        BT_CreateCooldown(1.2, BT_CreateAction(JockeyAct_AlternatingHop))  // v3.7: 2.0→1.2
    );

    // Narrow: approach (far) → hug wall
    int narrowApproach = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateInverter(BT_CreateIsInRange(350.0)),
        BT_CreateAction(ACT_HugWall)
    );
    int narrowLeap = BT_CreateSequence(5,
        BT_CreateCondition(CND_IsNarrowSpace),
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(350.0),
        BT_CreateCooldown(1.2, BT_CreateAction(JockeyAct_AlternatingHop))  // v3.7: 2.0→1.2
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
    int openS0_Approach = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(0),
        BT_CreateCondition(CND_OnGround), BT_CreateCondition(CND_HasLOS),
        BT_CreateIsNotInRange(400.0),
        BT_CreateAction(ACT_CircleFlank)
    );
    int openS0_Leap = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(0),
        BT_CreateCondition(CND_OnGround), BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(400.0),
        BT_CreateCooldown(1.2, BT_CreateAction(JockeyAct_AlternatingHop))
    );
    // Strat 1: Erratic leap — zigzag approach → leap from varied angle
    int openS1_Approach = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(1),
        BT_CreateCondition(CND_OnGround), BT_CreateCondition(CND_HasLOS),
        BT_CreateIsNotInRange(350.0),
        BT_CreateAction(ACT_ErraticApproach)
    );
    int openS1_Leap = BT_CreateSequence(6,
        BT_CreateCondition(CND_IsOpenArea), BT_CreateStrategyIs(1),
        BT_CreateCondition(CND_OnGround), BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(350.0),
        BT_CreateCooldown(1.2, BT_CreateAction(JockeyAct_AlternatingHop))
    );

    // --- Standard hop attack ---
    int hopPreCond = BT_CreateSequence(3,
        BT_CreateCondition(CND_OnGround),
        BT_CreateCondition(CND_HasLOS),
        BT_CreateIsInRange(700.0)
    );

    int hopAcquireTarget = BT_CreateAction(JockeyAct_AlternatingHop);
    int hopWithCooldown = BT_CreateCooldown(1.2, hopAcquireTarget);  // v3.6: 2.0→1.2

    int hopSeq = BT_CreateSequence(2,
        hopPreCond,
        hopWithCooldown
    );

    // Approach: always strafe while closing in
    int strafeApproach = BT_CreateSequence(2,
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(ACT_StrafeMoveToTarget)
    );

    // ==========================================
    // v3.6: Anti-melee — close range + no LOS → strafe for leap angle.
    // Don't blindly approach when too close — the engine default melee
    // (shared IN_ATTACK button) kicks in when leap can't fire.
    // ==========================================
    int closeRangeStrafe = BT_CreateSequence(4,
        BT_CreateIsInRange(300.0),
        BT_CreateInverter(BT_CreateCondition(CND_HasLOS)),
        BT_CreateAction(ACT_AcquireClosestTarget),
        BT_CreateAction(ACT_StrafeRandom)
    );

    // Root selector — v3.6: close-range strafe prevents blind melee at no LOS.
    // When HasLOS: hopSeq fires → IN_ATTACK → engine decides leap vs melee.
    // When no LOS + close: strafe for angle instead of approaching into melee range.
    // When nothing works: Wander (melee IS valid as last resort).
    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, rideSeq);
    BT_AddChild(root, mode1ChainApproach);  // 1.5. v4.0: mode 1 → 锁链接近被拉者
    BT_AddChild(root, mode1ChainLeap);      // 1.5. v4.0: mode 1 → 锁链骑被拉者
    BT_AddChild(root, ledgeLeap);           // 2. ledge → leap
    BT_AddChild(root, ledgeApproach);       // 3. ledge → approach
    BT_AddChild(root, narrowLeap);          // 4. narrow → leap
    BT_AddChild(root, narrowApproach);      // 5. narrow → approach
    BT_AddChild(root, openStrategyRoll);    // 6a. open → roll token
    BT_AddChild(root, openS0_Leap);         // 6b. open strat0 → flank leap
    BT_AddChild(root, openS0_Approach);     // 6c. open strat0 → flank approach
    BT_AddChild(root, openS1_Leap);         // 7a. open strat1 → erratic leap
    BT_AddChild(root, openS1_Approach);     // 7b. open strat1 → erratic approach
    BT_AddChild(root, hopSeq);              // 8. standard hop (HasLOS → ATTACK)
    BT_AddChild(root, closeRangeStrafe);    // 9. v3.6: close+noLOS → strafe
    BT_AddChild(root, strafeApproach);      // 10. approach from far
    BT_AddChild(root, BT_CreateAction(ACT_Wander)); // 11. last resort

    return root;
}

public Jockey_OnModuleStart() {
    SetConVarInt(FindConVar("z_jockey_leap_range"), 1000);
}
