// tank_wave_mutator.sp
// Tank 波次突变系统：10% 随机突变 + 连续5波无倒地强制双Tank + 连续11波无Tank强制单Tank + Tank波后3波冷静期
// v2.2.0: Tank 波强制清缴条件 = Tank 死亡（挂起 specialspawner 清缴判定）
// v2.3.0: 新增11波无Tank保底（第12波必刷单Tank，冷静期波不计数）+ 冷静期 9→3 波
// v2.4.0: 就近生成修复 —— 多次采样取 ≥450u 里最近点，确保 Tank 在引擎激活范围（防待命站桩+掉队被清）
// v2.5.0: 冷静期倍率（Tank 波前 ×1.5）+ SS_MarkWaveTank（Tank 波剿灭得分 ×3）
// v2.6.0: 双Tank生成约束 + 卡住看护（用户定稿 2026-08-16）——
//   · 生成互斥：第二只 Tank 采样点与第一只水平距离 ≥800u（防重叠互卡）
//   · 防前后包夹：两只相对幸存者方位夹角 ≤90°（同侧推进，不摆夹击阵型）
//   · 卡住看护：监控发现 Tank 位置 8s 几乎不动 → 重定位到有 LOS 的新点
//     （抢在引擎 stuck 处理/处决前，Tank 卡住根因=生成点重叠+不可达+AI 清跳）
// v2.6.1: 实机修复（2026-08-16 19:01 双Tank 50u 重叠+跨层案例）——
//   · 约束评估移到所有候选（v2.6.0 只在 ≥MIN_DIST 分支评估，贴脸兜底分支
//     绕过约束 → c8m2 PZ 点池 <750u 时约束形同虚设）
//   · 兜底改取"最远"候选（v2.4.0 注释承诺取最远、实现取第一个随机点——老坑）
//   · 生成点 LOS 检查（防跨层/隔墙生成：Tank #2 曾生成在楼下平台玩家看不到）
//   · 重定位兜底：LOS 采样失败 → 传送到最近幸存者前方 500u 地面点（必定成功）
// v2.6.2: 双Tank"放一起"（用户定稿 2026-08-16，取代互斥/夹角约束）——
//   · 生成：第二只 Tank 锚定第一只位置，4 方向 150u 微偏移（同 Z 同层），
//     LOS 通过者优先，全失败同点生成——两只一起出现，天然同侧不包夹互见；
//     删除 TANK_SPAWN_SEPARATION/MAX_ANGLE（互斥/夹角约束整套移除）
//   · 重定位：优先依附另一只存活 Tank（200u 偏移传过去，两只重新"放一起"）；
//     单 Tank 卡住 LOS 无解时 → 随机方向 700u 地面点（不再传送玩家正前方
//     500u 糊脸——用户否决该方案）
// v2.6.3: 三角形刷新 + 至少 800u（用户定稿 2026-08-16，取代"放一起"/"一前一后"）——
//   · 两只 Tank 与玩家构成【三角形】：每只距玩家 ≥800u（"至少保持800u距离"），
//     两只相对玩家夹角 60°-120°（水平面）——60° 下限保证两只间距 ≥800u
//     物理不接触不互卡；120° 上限防侧翼包夹（仍同侧推进不夹击）
//   · 严格执行距离：无 ≥800u+LOS 候选就【不刷】（删除全部贴脸 fallback——
//     历史贴脸案例 dist=298/502/561；用户："必须距离生还者队伍足够远"）
//   · 第二只失败 → 只刷第一只（单 Tank 波），不违背"足够远"
//   · 采样 12→20 降低失败率；LOS 检查防跨层/隔墙（玩家看不到 = 白刷）
// v2.6.4: 前后刷新 fallback（用户拍板 2026-08-16，tew2_1stem 20:45 实测 0/2 全灭）——
//   · 起因：20:45 室内段 20 次采样无 ≥800u+LOS 候选（specialspawner 同刻
//     10/10 invis-fb），双 Tank 预告后一只没刷（v2.6.3 严格执行的代价）
//   · 三角形优先不变；无合格点 → fallback：第一只刷队伍【前方】、第二只刷
//     【后方】（全队平均朝向/中心，用户："做一个fallback，就是前后刷新"）
//   · 距离 600→500→400 逐级缩短 + 向下 trace 找地面（防卡墙/落地）；无 LOS 要求
//   · 仍找不到地面点才放弃该只（日志区分 fallback 成功/失败原因）
// v2.6.5: fallback 距离档位 600/500/400 → 800/600/450（用户拍板，拉开前后距离）
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "2.6.5"

// 配置常量
#define MUTATION_CHANCE 0.10        // 10% 突变概率
#define FORCE_TANK_WAVES 5          // 连续5波无倒地触发强制双Tank
#define FORCE_TANK_NO_SPAWN 11      // 连续11波无Tank触发保底单Tank（第12波必刷）
#define TANK_COOLDOWN_WAVES 3       // Tank波后冷静期（9→3）
#define MAX_TRACKED_TANKS 4         // 最多跟踪的 Tank 数量
// v2.4.0: 就近生成 —— 突变 Tank 生成后必须在幸存者活跃模拟范围内，否则引擎
// 不 tick 其 AI（待命站桩），且远离流程会被导演判定掉队自动清除（"被系统处死"）。
#define TANK_SPAWN_MIN_DIST 800.0   // v2.6.3: 750→800（用户："至少保持800u距离"）
#define TANK_SPAWN_SAMPLES  20      // 采样次数（v2.6.3: 12→20，严格 ≥MIN 后提高命中率）
// v2.6.3: 三角形刷新（用户定稿）——两只与玩家构成三角形，夹角 60°-120°
#define TANK_SPAWN_ANGLE_MIN 60.0   // 夹角下限（60° 保证两只间距 ≥800u 不互卡）
#define TANK_SPAWN_ANGLE_MAX 120.0  // 夹角上限（防侧翼包夹）
// v2.6.4: 前后刷新 fallback（用户定稿）——三角形无解时第一只前方、第二只后方
// v2.6.5: 距离档位 800 → 600 → 450（用户拍板，替代 600→500→400）
#define TANK_FALLBACK_DIST_1 800.0   // 首档：尽量拉开前后距离
#define TANK_FALLBACK_DIST_2 600.0
#define TANK_FALLBACK_DIST_3 450.0   // 末档：窄段保底
// v2.6.0: 卡住看护（用户定稿）——位置长时间几乎不动 → 重定位
#define TANK_STUCK_MOVE   40.0      // 单次检查（2s）移动 < 此值视为"没动"
#define TANK_STUCK_CHECKS 4         // 连续 4 次没动（8s）→ 判定卡住 → 重定位

// specialspawner native 声明
native void SS_HoldClearing(bool hold);
// v2.5.0: 标记本波为 Tank 波（specialspawner 剿灭得分 ×3）
native void SS_MarkWaveTank();

// 全局变量
int g_iWaveCounter = 0;             // 总波次计数
int g_iNoDownWaves = 0;             // 连续无倒地波次
int g_iNoTankWaves = 0;             // 连续无Tank波次（冷静期不累加）
int g_iTankCooldown = 0;            // Tank波后冷静期剩余
bool g_bNextWaveIsTank = false;     // 下一波是否为Tank波（预警标志）
int g_iNextTankCount = 0;           // 下一波Tank数量（1=突变, 2=强制）

// Tank 波跟踪
int g_iTanks[MAX_TRACKED_TANKS];    // 当前 Tank 波生成的 Tank client 索引
int g_iTankCount = 0;               // 当前活跃 Tank 数量
Handle g_hTankMonitor = null;       // Tank 状态监控定时器
ConVar g_hCvarRestScale = null;     // v2.5.0: Tank 波前冷静期倍率
// v2.6.0: 卡住看护状态（与 g_iTanks 同下标）
float g_fTankLastPos[MAX_TRACKED_TANKS][3];   // 上次监控位置
int   g_iTankStuckChecks[MAX_TRACKED_TANKS];  // 连续"没动"检查计数

public Plugin myinfo = {
    name = "Tank Wave Mutator",
    author = "Suli",
    description = "Random tank waves with forced spawn after 5 waves without downs",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart() {
    // 监听倒地和死亡事件
    HookEvent("player_incapacitated", Event_PlayerDown);
    HookEvent("player_death", Event_PlayerDeath);

    // 换图重置
    HookEvent("round_start", Event_RoundStart);

    // v2.5.0: Tank 波前冷静期倍率（用户设计：下一波是 Tank → 冷静期 ×1.5）
    g_hCvarRestScale = CreateConVar("tank_wave_rest_scale", "1.5",
        "Tank 波前冷静期倍率（ss_rest_min/max 基准 × 本值；1.0 = 不放大）",
        FCVAR_NONE, true, 1.0, true, 3.0);

    LogMessage("[Tank Mutator] Plugin loaded. Mutation: %.0f%%, Force: %d waves, Cooldown: %d waves",
               MUTATION_CHANCE * 100.0, FORCE_TANK_WAVES, TANK_COOLDOWN_WAVES);
}

public void OnPluginEnd() {
    // 卸载时释放清缴挂起
    ReleaseClearingHold();
}

// ============ 事件处理 ============

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    // 换图重置所有状态
    g_iWaveCounter = 0;
    g_iNoDownWaves = 0;
    g_iNoTankWaves = 0;
    g_iTankCooldown = 0;
    g_bNextWaveIsTank = false;
    g_iNextTankCount = 0;
    ClearTankTracking();
    ReleaseClearingHold();
    LogMessage("[Tank Mutator] Round start, all counters reset");
}

void Event_PlayerDown(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && IsClientInGame(client) && GetClientTeam(client) == 2) {
        // 生还者倒地，重置连续无倒地计数
        g_iNoDownWaves = 0;
        LogMessage("[Tank Mutator] Survivor down, reset no-down counter");
    }
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || !IsClientInGame(client)) return;

    if (GetClientTeam(client) == 2) {
        // 生还者死亡，重置连续无倒地计数
        g_iNoDownWaves = 0;
        LogMessage("[Tank Mutator] Survivor death, reset no-down counter");
    } else if (GetClientTeam(client) == 3 && IsTank(client)) {
        // Tank 死亡，检查是否在跟踪列表中
        CheckTankDeath(client);
    }
}

// ============ specialspawner forward 监听 ============

public void SS_OnWaveRest(float totalCountdown) {
    // 波次清缴结束，进入 REST 冷静期。specialspawner v5.25 起在本函数
    // 返回后抽取冷静期（rest = Random(ss_rest_min/max)）——本函数对
    // ss_rest_min/max 的修改即作用于本波冷静期。
    // v2.5.0: 冷静期倍率（用户设计：下一波是 Tank → 冷静期 ×1.5）。
    // 基准与 specialspawner cfg 同步（ss_rest_min/max = 25/35）。
    float baseMin = 25.0, baseMax = 35.0;
    float scale = (g_hCvarRestScale != null) ? g_hCvarRestScale.FloatValue : 1.5;
    ConVar hRestMin = FindConVar("ss_rest_min");
    ConVar hRestMax = FindConVar("ss_rest_max");
    if (hRestMin != null) hRestMin.SetFloat(baseMin);
    if (hRestMax != null) hRestMax.SetFloat(baseMax);
    // 此时判定下一波是否为 Tank 波，如果是则提前预警

    // 首波保护：第一波必定不是 Tank
    if (g_iWaveCounter == 0) {
        g_bNextWaveIsTank = false;
        LogMessage("[Tank Mutator] Wave #1 upcoming, first wave protection");
        return;
    }

    // Tank波后冷静期：不刷Tank，冻结无倒地/无Tank计数（打完Tank后的波次不算在内）
    if (g_iTankCooldown > 0) {
        g_iTankCooldown--;
        g_bNextWaveIsTank = false;
        g_iNextTankCount = 0;
        LogMessage("[Tank Mutator] Next wave: normal (cooldown %d left, counters frozen)", g_iTankCooldown);
        return;
    }

    // 结算刚打完的这一波（非冷静期普通波）：先累加计数，再判定下一波
    // 无倒地计数在 player_incapacitated/player_death 中被清零，此处递增=本波全程无倒地
    g_iNoDownWaves++;
    g_iNoTankWaves++;

    bool shouldSpawnTank = false;
    bool doubleTank = false;
    char reason[128];

    if (g_iNoDownWaves >= FORCE_TANK_WAVES) {
        // 强制双Tank波（连续N波无倒地）
        shouldSpawnTank = true;
        doubleTank = true;
        Format(reason, sizeof(reason), "Forced double (no downs for %d waves)", g_iNoDownWaves);
    } else if (g_iNoTankWaves >= FORCE_TANK_NO_SPAWN) {
        // 保底单Tank波（连续N波无Tank，第N+1波必刷）
        shouldSpawnTank = true;
        Format(reason, sizeof(reason), "Guaranteed (no tank for %d waves)", g_iNoTankWaves);
    } else {
        // 10% 随机突变
        float roll = GetURandomFloat();
        if (roll < MUTATION_CHANCE) {
            shouldSpawnTank = true;
            Format(reason, sizeof(reason), "Random mutation (rolled %.1f%%)", roll * 100.0);
        } else {
            Format(reason, sizeof(reason), "No mutation (rolled %.1f%%)", roll * 100.0);
        }
    }

    if (shouldSpawnTank) {
        g_bNextWaveIsTank = true;

        // v2.5.0: 下一波是 Tank → 冷静期 ×scale（specialspawner 在 forward
        // 返回后抽取 rest，此修改即生效于本波冷静期）
        if (hRestMin != null) hRestMin.SetFloat(baseMin * scale);
        if (hRestMax != null) hRestMax.SetFloat(baseMax * scale);

        // 预警秒数由 specialspawner 播报（"X 秒后下一波"，已含倍率），
        // 此处不再报具体秒数（v2.5.0: totalCountdown 在 forward 时尚未确定）
        if (doubleTank) {
            g_iNextTankCount = 2;
            LogMessage("[Tank Mutator] DOUBLE TANK WAVE predicted! Reason: %s", reason);
            PrintToChatAll("\x04☠ 警告：下一波将刷新 \x03双倍 TANK\x01！");
            PrintCenterTextAll("☠ 警告：下一波双倍 TANK 来袭！");
        } else {
            g_iNextTankCount = 1;
            LogMessage("[Tank Mutator] TANK WAVE predicted! Reason: %s", reason);
            PrintToChatAll("\x04☠ 警告：下一波将刷新 TANK！\x01");
            PrintCenterTextAll("☠ 警告：下一波 TANK 来袭！");
        }

        PrintToChatAll("\x04[Tank Mutator]\x01 做好准备！");

        // Tank 波后进入 N 波冷静期，计数器归零
        g_iTankCooldown = TANK_COOLDOWN_WAVES;
        g_iNoDownWaves = 0;
        g_iNoTankWaves = 0;
    } else {
        // 普通波：计数已在上方累加
        g_bNextWaveIsTank = false;
        g_iNextTankCount = 0;
        LogMessage("[Tank Mutator] Next wave: normal. No-down: %d/%d, No-tank: %d/%d. %s",
                   g_iNoDownWaves, FORCE_TANK_WAVES, g_iNoTankWaves, FORCE_TANK_NO_SPAWN, reason);
    }
}

public void SS_OnWaveStart(bool started) {
    // 波次开始（PHASE_PRESSURE），started = 是否真的刷出了特感
    g_iWaveCounter++;

    if (!started) {
        // 零波（上限满/全倒等），specialspawner 直接进收尾期
        LogMessage("[Tank Mutator] Wave #%d: zero wave (no SI spawned)", g_iWaveCounter);
        return;
    }

    LogMessage("[Tank Mutator] Wave #%d started", g_iWaveCounter);

    // 如果这波预判为 Tank 波，现在生成 Tank
    if (g_bNextWaveIsTank) {
        // 立即挂起清缴（Tank 波期间强制等 Tank 死）
        SetClearingHold(true);

        // 延迟1.5秒生成（等 specialspawner 批次完成），传入 Tank 数量
        DataPack pack;
        CreateDataTimer(1.5, Timer_SpawnTank, pack, TIMER_FLAG_NO_MAPCHANGE);
        pack.WriteCell(g_iNextTankCount);
        g_bNextWaveIsTank = false;  // 消费标志位
        g_iNextTankCount = 0;
    }
}

Action Timer_SpawnTank(Handle timer, DataPack pack) {
    pack.Reset();
    int tankCount = pack.ReadCell();
    if (tankCount < 1) tankCount = 1;

    // 清空旧跟踪
    ClearTankTracking();

    int spawned = 0;
    for (int n = 0; n < tankCount && spawned < MAX_TRACKED_TANKS; n++) {
        // 每只 Tank 独立找参考幸存者
        int client = GetAnyAliveSurvivor();
        if (client <= 0) {
            LogMessage("[Tank Mutator] Tank spawn failed: no alive survivor found");
            break;
        }

        float refPos[3];
        GetClientAbsOrigin(client, refPos);
        float eye[3];
        GetClientEyePosition(client, eye);

        float spawnPos[3], spawnAng[3] = {0.0, 0.0, 0.0};
        float bestPos[3];
        float bestDist = -1.0;
        int validCount = 0;

        // v2.6.3: 三角形刷新（用户定稿）——两只 Tank 与玩家构成三角形：
        // 每只 ≥800u + LOS（玩家可见）+ 两只相对玩家水平夹角 60°-120°。
        // 严格执行距离：无合格点 → 不刷（绝不贴脸 fallback——用户："必须
        // 距离生还者队伍足够远"；历史贴脸案例 dist=298/502/561）。
        bool hasBuddy = (spawned > 0 && g_iTanks[0] > 0 && IsClientInGame(g_iTanks[0]));
        float buddyPos[3];
        if (hasBuddy)
            GetClientAbsOrigin(g_iTanks[0], buddyPos);

        // 夹角阈值：cos60°=0.5（太挤） / cos120°=-0.5（快包夹）
        float maxCos = Cosine(TANK_SPAWN_ANGLE_MIN * 0.01745329252);
        float minCos = Cosine(TANK_SPAWN_ANGLE_MAX * 0.01745329252);

        for (int attempt = 0; attempt < TANK_SPAWN_SAMPLES; attempt++) {
            float candidate[3];
            if (!L4D_GetRandomPZSpawnPosition(client, 8, 5, candidate))
                continue;
            float dist = GetVectorDistance(refPos, candidate);
            validCount++;

            // 严格距离：≥800u（用户："至少保持800u距离"）
            if (dist < TANK_SPAWN_MIN_DIST)
                continue;

            // LOS：玩家可见（防跨层/隔墙——只算世界几何，忽略玩家实体）
            TR_TraceRayFilter(candidate, eye, MASK_SOLID, RayType_EndPoint, TraceFilter_World);
            if (TR_GetFraction() < 0.95)
                continue;

            // 三角形夹角：两只相对玩家 60°-120°（水平面；同侧推进不包夹）
            if (hasBuddy) {
                float d1x = buddyPos[0] - refPos[0];
                float d1y = buddyPos[1] - refPos[1];
                float d2x = candidate[0] - refPos[0];
                float d2y = candidate[1] - refPos[1];
                float len1 = SquareRoot(d1x * d1x + d1y * d1y);
                float len2 = SquareRoot(d2x * d2x + d2y * d2y);
                if (len1 > 1.0 && len2 > 1.0) {
                    float cosA = (d1x * d2x + d1y * d2y) / (len1 * len2);
                    if (cosA > maxCos || cosA < minCos)
                        continue;   // 夹角 <60°（两只太挤）或 >120°（接近包夹）
                }
            }

            if (bestDist < 0.0 || dist < bestDist) {
                bestDist = dist;
                bestPos[0] = candidate[0]; bestPos[1] = candidate[1]; bestPos[2] = candidate[2];
            }
        }

        if (bestDist < 0.0) {
            LogMessage("[Tank Mutator] Tank #%d spawn failed: no candidate ≥%.0fu with LOS%s (足够远约束)",
                       n + 1, TANK_SPAWN_MIN_DIST, hasBuddy ? " + triangle angle" : "");
            // v2.6.4: 前后刷新 fallback（用户拍板）——三角形无解时第一只刷队伍
            // 前方、第二只刷后方（全队平均朝向/中心），距离逐级缩短 + 地面点
            if (SpawnTankFallback(n, spawnPos)) {
                int tank = L4D2_SpawnTank(spawnPos, spawnAng);
                if (tank > 0 && IsClientInGame(tank)) {
                    g_iTanks[spawned] = tank;
                    GetClientAbsOrigin(tank, g_fTankLastPos[spawned]);
                    g_iTankStuckChecks[spawned] = 0;
                    spawned++;
                    LogMessage("[Tank Mutator] Tank #%d FALLBACK spawned (%s) at (%.1f, %.1f, %.1f), client: %d",
                               n + 1, (n % 2 == 0) ? "front" : "back",
                               spawnPos[0], spawnPos[1], spawnPos[2], tank);
                } else {
                    LogMessage("[Tank Mutator] Tank #%d fallback spawn failed: invalid entity", n + 1);
                }
            } else {
                LogMessage("[Tank Mutator] Tank #%d fallback failed: no ground point front/back", n + 1);
            }
            continue;
        }

        spawnPos[0] = bestPos[0]; spawnPos[1] = bestPos[1]; spawnPos[2] = bestPos[2];

        // 直接生成 Tank
        int tank = L4D2_SpawnTank(spawnPos, spawnAng);
        if (tank > 0 && IsClientInGame(tank)) {
            g_iTanks[spawned] = tank;
            // v2.6.0: 初始化卡住看护状态
            GetClientAbsOrigin(tank, g_fTankLastPos[spawned]);
            g_iTankStuckChecks[spawned] = 0;
            spawned++;
            LogMessage("[Tank Mutator] Tank #%d spawned at (%.1f, %.1f, %.1f), dist=%.0f, client: %d",
                       n + 1, spawnPos[0], spawnPos[1], spawnPos[2], bestDist, tank);
        } else {
            LogMessage("[Tank Mutator] Tank #%d spawn failed: invalid entity", n + 1);
        }
    }

    g_iTankCount = spawned;
    LogMessage("[Tank Mutator] Spawn complete: %d/%d tanks tracked", spawned, tankCount);

    if (spawned > 0) {
        // v2.5.0: 标记本波为 Tank 波（specialspawner 剿灭得分三档 ×3）
        if (GetFeatureStatus(FeatureType_Native, "SS_MarkWaveTank") == FeatureStatus_Available) {
            SS_MarkWaveTank();
            LogMessage("[Tank Mutator] Wave marked as TANK wave for clear score x3");
        }
    }

    if (spawned == 0) {
        // 没生成任何 Tank，立即释放挂起
        LogMessage("[Tank Mutator] No tanks spawned, releasing clearing hold immediately");
        ReleaseClearingHold();
    } else {
        // 启动监控定时器（每 2 秒检查 Tank 状态）
        if (g_hTankMonitor != null) {
            KillTimer(g_hTankMonitor);
        }
        g_hTankMonitor = CreateTimer(2.0, Timer_MonitorTanks, _, TIMER_REPEAT);
    }

    return Plugin_Stop;
}

// ============ Tank 跟踪管理 ============

void ClearTankTracking() {
    for (int i = 0; i < MAX_TRACKED_TANKS; i++) {
        g_iTanks[i] = 0;
        g_iTankStuckChecks[i] = 0;
        g_fTankLastPos[i][0] = g_fTankLastPos[i][1] = g_fTankLastPos[i][2] = 0.0;
    }
    g_iTankCount = 0;
    if (g_hTankMonitor != null) {
        KillTimer(g_hTankMonitor);
        g_hTankMonitor = null;
    }
}

void CheckTankDeath(int client) {
    bool wasTracked = false;
    for (int i = 0; i < MAX_TRACKED_TANKS; i++) {
        if (g_iTanks[i] == client) {
            g_iTanks[i] = 0;
            wasTracked = true;
            LogMessage("[Tank Mutator] Tracked tank %d died", client);
            break;
        }
    }

    if (wasTracked) {
        // 重新统计存活 Tank
        CheckAllTanksStatus();
    }
}

Action Timer_MonitorTanks(Handle timer) {
    CheckAllTanksStatus();
    return Plugin_Continue;
}

void CheckAllTanksStatus() {
    int alive = 0;
    for (int i = 0; i < MAX_TRACKED_TANKS; i++) {
        if (g_iTanks[i] > 0) {
            // 检查该 Tank 是否仍然有效且存活
            if (IsClientInGame(g_iTanks[i]) && IsPlayerAlive(g_iTanks[i]) && IsTank(g_iTanks[i])) {
                alive++;

                // v2.6.0: 卡住看护 —— 位置 8s 几乎不动 → 重定位（抢在引擎
                // stuck 处理/掉队处决前；根因=双Tank重叠互卡/生成点不可达）
                float pos[3];
                GetClientAbsOrigin(g_iTanks[i], pos);
                float moved = GetVectorDistance(g_fTankLastPos[i], pos);
                if (moved < TANK_STUCK_MOVE) {
                    g_iTankStuckChecks[i]++;
                    if (g_iTankStuckChecks[i] >= TANK_STUCK_CHECKS) {
                        LogMessage("[Tank Mutator] Tank %d stuck (moved %.0f in %d checks), relocating",
                                   g_iTanks[i], moved, g_iTankStuckChecks[i]);
                        RelocateStuckTank(g_iTanks[i]);
                        GetClientAbsOrigin(g_iTanks[i], g_fTankLastPos[i]);
                        g_iTankStuckChecks[i] = 0;
                    }
                } else {
                    g_fTankLastPos[i] = pos;
                    g_iTankStuckChecks[i] = 0;
                }
            } else {
                // Tank 已失效或死亡
                if (g_iTanks[i] != 0) {
                    LogMessage("[Tank Mutator] Tank client %d no longer valid", g_iTanks[i]);
                }
                g_iTanks[i] = 0;
            }
        }
    }

    // 所有 Tank 都死了，释放清缴挂起
    if (alive == 0 && g_iTankCount > 0) {
        LogMessage("[Tank Mutator] All tanks eliminated, releasing clearing hold");
        ReleaseClearingHold();
        ClearTankTracking();
    }
}

// v2.6.0: 卡住 Tank 重定位 —— 采样 450-1500u 且与幸存者有 LOS 的点（LOS=可达性
// 代理：能看见基本能寻路到达，避免再次生成到隔墙/悬崖点）。找不到就放弃，
// 下个监控 tick 再试。传送会打断 Tank 当前动作，但卡住的 Tank 本就无有效动作。
void RelocateStuckTank(int tank) {
    // v2.6.2: 优先依附另一只存活 Tank（用户："把两个tank放一起"）——传送到
    // 伙伴 200u 随机偏移处，两只重新并肩推进。伙伴本身在动（未被判卡）→
    // 传送后直接跟上。
    int buddy = -1;
    for (int i = 0; i < MAX_TRACKED_TANKS; i++) {
        if (g_iTanks[i] > 0 && g_iTanks[i] != tank &&
            IsClientInGame(g_iTanks[i]) && IsPlayerAlive(g_iTanks[i]) && IsTank(g_iTanks[i])) {
            buddy = g_iTanks[i];
            break;
        }
    }
    if (buddy > 0) {
        float bPos[3];
        GetClientAbsOrigin(buddy, bPos);
        float angRand = GetURandomFloat() * 6.2831853;  // 0-2π 随机方向
        float dest[3];
        dest[0] = bPos[0] + Cosine(angRand) * 200.0;
        dest[1] = bPos[1] + Sine(angRand) * 200.0;
        dest[2] = bPos[2] + 80.0;   // 抬高向下 trace 找地面

        float end[3];
        end[0] = dest[0]; end[1] = dest[1]; end[2] = dest[2] - 3000.0;
        TR_TraceRayFilter(dest, end, MASK_SOLID, RayType_EndPoint, TraceFilter_World);
        if (TR_GetFraction() > 0.0 && TR_GetFraction() < 1.0) {
            float ground[3];
            TR_GetEndPosition(ground);
            float ang2[3] = {0.0, 0.0, 0.0};
            TeleportEntity(tank, ground, ang2, NULL_VECTOR);
            LogMessage("[Tank Mutator] Stuck tank %d relocated next to buddy %d at (%.1f, %.1f, %.1f)",
                       tank, buddy, ground[0], ground[1], ground[2]);
        } else {
            // 地面 trace 异常 → 直接传伙伴位置（同点，引擎物理推开）
            float ang2[3] = {0.0, 0.0, 0.0};
            TeleportEntity(tank, bPos, ang2, NULL_VECTOR);
            LogMessage("[Tank Mutator] Stuck tank %d relocated to buddy %d exact spot (%.1f, %.1f, %.1f)",
                       tank, buddy, bPos[0], bPos[1], bPos[2]);
        }
        return;
    }

    // 无另一只 Tank（单 Tank 卡住）→ LOS 采样 450-1500u 最近点
    int survivor = GetAnyAliveSurvivor();
    if (survivor <= 0) {
        LogMessage("[Tank Mutator] Stuck tank %d relocate skipped: no alive survivor", tank);
        return;
    }

    float refPos[3];
    GetClientAbsOrigin(survivor, refPos);
    float eye[3];
    GetClientEyePosition(survivor, eye);

    float bestPos[3];
    float bestDist = -1.0;

    for (int attempt = 0; attempt < TANK_SPAWN_SAMPLES; attempt++) {
        float candidate[3];
        if (!L4D_GetRandomPZSpawnPosition(survivor, 8, 5, candidate))
            continue;

        float dist = GetVectorDistance(refPos, candidate);
        if (dist < 450.0 || dist > 1500.0)
            continue;   // 贴脸不传、太远不传

        // 视线通畅（只算世界几何，忽略玩家实体）
        TR_TraceRayFilter(candidate, eye, MASK_SOLID, RayType_EndPoint, TraceFilter_World);
        if (TR_GetFraction() < 0.95)
            continue;   // 被墙/天花板挡

        if (bestDist < 0.0 || dist < bestDist) {
            bestDist = dist;
            bestPos[0] = candidate[0];
            bestPos[1] = candidate[1];
            bestPos[2] = candidate[2];
        }
    }

    if (bestDist < 0.0) {
        // v2.6.2: LOS 采样无解 → 随机方向 700u 地面点（用户否决"玩家正前方
        // 500u 糊脸"方案——随机方向大多数时候不在玩家眼前，距离也拉开些）
        float origin[3];
        GetClientAbsOrigin(survivor, origin);
        float angRand = GetURandomFloat() * 6.2831853;
        float dest[3];
        dest[0] = origin[0] + Cosine(angRand) * 700.0;
        dest[1] = origin[1] + Sine(angRand) * 700.0;
        dest[2] = origin[2] + 80.0;

        float end[3];
        end[0] = dest[0]; end[1] = dest[1]; end[2] = dest[2] - 3000.0;
        TR_TraceRayFilter(dest, end, MASK_SOLID, RayType_EndPoint, TraceFilter_World);
        if (TR_GetFraction() > 0.0 && TR_GetFraction() < 1.0) {
            float ground[3];
            TR_GetEndPosition(ground);
            float ang2[3] = {0.0, 0.0, 0.0};
            TeleportEntity(tank, ground, ang2, NULL_VECTOR);
            LogMessage("[Tank Mutator] Stuck tank %d relocated (random 700u) to (%.1f, %.1f, %.1f)",
                       tank, ground[0], ground[1], ground[2]);
        } else {
            LogMessage("[Tank Mutator] Stuck tank %d relocate failed: no LOS candidate AND no fallback ground", tank);
        }
        return;
    }

    float ang[3] = {0.0, 0.0, 0.0};
    TeleportEntity(tank, bestPos, ang, NULL_VECTOR);
    LogMessage("[Tank Mutator] Stuck tank %d relocated to (%.1f, %.1f, %.1f), dist=%.0f",
               tank, bestPos[0], bestPos[1], bestPos[2], bestDist);
}

// 射线过滤器：忽略玩家实体（幸存者/特感），只把世界几何当阻挡
public bool TraceFilter_World(int entity, int contentsMask, any data) {
    return (entity >= 1 && entity <= MaxClients);
}

// ============ v2.6.4 前后刷新 fallback ============

// 全队存活幸存者平均位置（队伍中心）
bool GetTeamCenter(float center[3]) {
    center[0] = center[1] = center[2] = 0.0;
    int n = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || GetClientTeam(i) != 2 || !IsPlayerAlive(i)) continue;
        float pos[3];
        GetClientAbsOrigin(i, pos);
        center[0] += pos[0]; center[1] += pos[1]; center[2] += pos[2];
        n++;
    }
    if (n == 0) return false;
    center[0] /= n; center[1] /= n; center[2] /= n;
    return true;
}

// 全队存活幸存者平均朝向（水平面单位向量）；幸存者两两对向时平均值抵消 → false
bool GetTeamForward(float fwd[3]) {
    float sx = 0.0, sy = 0.0;
    int n = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || GetClientTeam(i) != 2 || !IsPlayerAlive(i)) continue;
        float ang[3], f[3];
        GetClientEyeAngles(i, ang);
        GetAngleVectors(ang, f, NULL_VECTOR, NULL_VECTOR);
        sx += f[0]; sy += f[1];
        n++;
    }
    if (n == 0) return false;
    float len = SquareRoot(sx * sx + sy * sy);
    if (len < 0.001) return false;
    fwd[0] = sx / len; fwd[1] = sy / len; fwd[2] = 0.0;
    return true;
}

// 前后刷新生成点：第 n 只（0=前方 / 1=后方，交替）相对队伍中心 ± 朝向。
// 距离 TANK_FALLBACK_DIST 逐级 -100 缩短，向下 trace 找地面（防卡墙/悬空）。
// 返回是否找到生成点（找不到时 spawnPos 不变）。
bool SpawnTankFallback(int n, float spawnPos[3]) {
    float center[3];
    if (!GetTeamCenter(center)) return false;

    float fwd[3];
    if (!GetTeamForward(fwd)) {
        // 全队平均朝向失效（对向/异常）→ 退化为参考幸存者朝向
        int survivor = GetAnyAliveSurvivor();
        if (survivor <= 0) return false;
        float ang[3];
        GetClientEyeAngles(survivor, ang);
        GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
        fwd[2] = 0.0;
        float len = SquareRoot(fwd[0] * fwd[0] + fwd[1] * fwd[1]);
        if (len < 0.001) return false;
        fwd[0] /= len; fwd[1] /= len;
    }

    float dir = (n % 2 == 0) ? 1.0 : -1.0;   // 第一只前方、第二只后方
    float tiers[3] = { TANK_FALLBACK_DIST_1, TANK_FALLBACK_DIST_2, TANK_FALLBACK_DIST_3 };

    for (int i = 0; i < 3; i++) {
        float dist = tiers[i] * dir;
        float start[3];
        start[0] = center[0] + fwd[0] * dist;
        start[1] = center[1] + fwd[1] * dist;
        start[2] = center[2] + 80.0;   // 抬高向下 trace 找地面

        float end[3];
        end[0] = start[0]; end[1] = start[1]; end[2] = start[2] - 3000.0;
        TR_TraceRayFilter(start, end, MASK_SOLID, RayType_EndPoint, TraceFilter_World);
        if (TR_GetFraction() > 0.0 && TR_GetFraction() < 1.0) {
            TR_GetEndPosition(spawnPos);
            return true;
        }
    }
    return false;
}

// ============ specialspawner native 调用 ============

void SetClearingHold(bool hold) {
    if (GetFeatureStatus(FeatureType_Native, "SS_HoldClearing") != FeatureStatus_Available) {
        LogMessage("[Tank Mutator] WARNING: SS_HoldClearing native not available");
        return;
    }
    SS_HoldClearing(hold);
}

void ReleaseClearingHold() {
    SetClearingHold(false);
}

// ============ 工具函数 ============

// 返回任意一个存活的幸存者 client index，找不到返回 -1
int GetAnyAliveSurvivor() {
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i)) {
            return i;
        }
    }
    return -1;
}

bool IsTank(int client) {
    if (client <= 0 || client > MaxClients || !IsClientInGame(client)) {
        return false;
    }
    if (GetClientTeam(client) != 3) {
        return false;
    }
    int class = GetEntProp(client, Prop_Send, "m_zombieClass");
    return class == 8;  // 8 = Tank
}
