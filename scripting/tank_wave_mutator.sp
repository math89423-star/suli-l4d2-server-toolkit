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
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "2.6.0"

// 配置常量
#define MUTATION_CHANCE 0.10        // 10% 突变概率
#define FORCE_TANK_WAVES 5          // 连续5波无倒地触发强制双Tank
#define FORCE_TANK_NO_SPAWN 11      // 连续11波无Tank触发保底单Tank（第12波必刷）
#define TANK_COOLDOWN_WAVES 3       // Tank波后冷静期（9→3）
#define MAX_TRACKED_TANKS 4         // 最多跟踪的 Tank 数量
// v2.4.0: 就近生成 —— 突变 Tank 生成后必须在幸存者活跃模拟范围内，否则引擎
// 不 tick 其 AI（待命站桩），且远离流程会被导演判定掉队自动清除（"被系统处死"）。
#define TANK_SPAWN_MIN_DIST 750.0   // v5.35: 最近生成距离 450→750（用户：刷新远一点，避免贴脸出生）
#define TANK_SPAWN_SAMPLES  12      // 采样次数（取 ≥MIN 里最近的点）
// v2.6.0: 双Tank生成约束（用户定稿）——互斥防重叠互卡 + 方位角防前后包夹
#define TANK_SPAWN_SEPARATION 800.0 // 与已有 Tank 生成点最小水平距离（防重叠物理推挤）
#define TANK_SPAWN_MAX_ANGLE  90.0  // 与已有 Tank 相对幸存者的最大方位夹角°（0=同向；180=正背后）
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
        // 每只 Tank 独立找参考幸存者和生成点
        int client = GetAnyAliveSurvivor();
        if (client <= 0) {
            LogMessage("[Tank Mutator] Tank spawn failed: no alive survivor found");
            break;
        }

        // v2.6.0: 已有第一只 Tank → 第二只采样受互斥 + 方位角约束
        // （防重叠互卡 + 防前后包夹；第一只生成失败则无约束）
        bool hasPrev = (spawned > 0 && g_iTanks[0] > 0 && IsClientInGame(g_iTanks[0]));
        float prevPos[3];
        if (hasPrev)
            GetClientAbsOrigin(g_iTanks[0], prevPos);

        // v2.4.0: 多次采样取最近的合法生成点（≥MIN_DIST 避免贴脸，取最近确保引擎立即激活）
        float refPos[3];
        GetClientAbsOrigin(client, refPos);

        float spawnPos[3], spawnAng[3] = {0.0, 0.0, 0.0};
        float bestPos[3];
        float bestDist = -1.0;
        float relaxedPos[3];        // v2.6.0: 放宽候选（仅 ≥MIN_DIST，无视双Tank约束）
        float relaxedDist = -1.0;
        int validCount = 0;
        float maxCos = Cosine(TANK_SPAWN_MAX_ANGLE * 0.01745329252);  // 角度→cos 阈值

        for (int attempt = 0; attempt < TANK_SPAWN_SAMPLES; attempt++) {
            float candidate[3];
            if (L4D_GetRandomPZSpawnPosition(client, 8, 5, candidate)) {
                float dist = GetVectorDistance(refPos, candidate);
                validCount++;

                if (dist >= TANK_SPAWN_MIN_DIST) {
                    // 合格距离点：满足双Tank约束 → best；不满足 → 记入 relaxed 兜底
                    bool ok = true;
                    if (hasPrev) {
                        // 互斥：与已有 Tank 水平距离 ≥SEPARATION（忽略 Z）
                        float dx = candidate[0] - prevPos[0];
                        float dy = candidate[1] - prevPos[1];
                        if (SquareRoot(dx * dx + dy * dy) < TANK_SPAWN_SEPARATION)
                            ok = false;
                        // 防包夹：两只相对幸存者方位夹角 ≤MAX_ANGLE（水平面）
                        if (ok) {
                            float d1x = prevPos[0] - refPos[0];
                            float d1y = prevPos[1] - refPos[1];
                            float d2x = candidate[0] - refPos[0];
                            float d2y = candidate[1] - refPos[1];
                            float len1 = SquareRoot(d1x * d1x + d1y * d1y);
                            float len2 = SquareRoot(d2x * d2x + d2y * d2y);
                            if (len1 > 1.0 && len2 > 1.0) {
                                float cosA = (d1x * d2x + d1y * d2y) / (len1 * len2);
                                if (cosA < maxCos)
                                    ok = false;
                            }
                        }
                    }
                    if (ok) {
                        if (bestDist < 0.0 || dist < bestDist) {
                            bestDist = dist;
                            bestPos[0] = candidate[0];
                            bestPos[1] = candidate[1];
                            bestPos[2] = candidate[2];
                        }
                    } else if (relaxedDist < 0.0 || dist < relaxedDist) {
                        relaxedDist = dist;
                        relaxedPos[0] = candidate[0];
                        relaxedPos[1] = candidate[1];
                        relaxedPos[2] = candidate[2];
                    }
                } else if (bestDist < 0.0 && relaxedDist < 0.0) {
                    // 暂无任何合格点，记录这个偏近的候选（fallback）
                    bestDist = dist;
                    bestPos[0] = candidate[0];
                    bestPos[1] = candidate[1];
                    bestPos[2] = candidate[2];
                }
            }
        }

        // v2.6.0: 严格约束无解 → 放宽到"仅 ≥MIN_DIST"（至少不贴脸、不重叠概率低）
        if (bestDist < 0.0 && relaxedDist > 0.0) {
            bestDist = relaxedDist;
            bestPos[0] = relaxedPos[0];
            bestPos[1] = relaxedPos[1];
            bestPos[2] = relaxedPos[2];
            LogMessage("[Tank Mutator] Tank #%d: no candidate within constraints, relaxed to dist=%.0f",
                       n + 1, relaxedDist);
        }

        if (validCount == 0) {
            LogMessage("[Tank Mutator] Tank #%d spawn failed: no valid spawn position after %d attempts",
                       n + 1, TANK_SPAWN_SAMPLES);
            continue;
        }

        spawnPos[0] = bestPos[0];
        spawnPos[1] = bestPos[1];
        spawnPos[2] = bestPos[2];

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
        LogMessage("[Tank Mutator] Stuck tank %d relocate failed: no LOS candidate", tank);
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
