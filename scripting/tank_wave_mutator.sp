// tank_wave_mutator.sp
// Tank 波次突变系统：10% 随机突变 + 连续5波无倒地强制双Tank + 连续11波无Tank强制单Tank + Tank波后3波冷静期
// v2.2.0: Tank 波强制清缴条件 = Tank 死亡（挂起 specialspawner 清缴判定）
// v2.3.0: 新增11波无Tank保底（第12波必刷单Tank，冷静期波不计数）+ 冷静期 9→3 波
// v2.4.0: 就近生成修复 —— 多次采样取 ≥450u 里最近点，确保 Tank 在引擎激活范围（防待命站桩+掉队被清）
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "2.5.0"

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

        // v2.4.0: 多次采样取最近的合法生成点（≥MIN_DIST 避免贴脸，取最近确保引擎立即激活）
        float refPos[3];
        GetClientAbsOrigin(client, refPos);

        float spawnPos[3], spawnAng[3] = {0.0, 0.0, 0.0};
        float bestPos[3];
        float bestDist = -1.0;
        int validCount = 0;

        for (int attempt = 0; attempt < TANK_SPAWN_SAMPLES; attempt++) {
            float candidate[3];
            if (L4D_GetRandomPZSpawnPosition(client, 8, 5, candidate)) {
                float dist = GetVectorDistance(refPos, candidate);
                validCount++;

                // 优先选 ≥MIN_DIST 里最近的；如果全部 <MIN_DIST（罕见），取最远的（相对不贴脸）
                if (dist >= TANK_SPAWN_MIN_DIST) {
                    if (bestDist < 0.0 || dist < bestDist) {
                        bestDist = dist;
                        bestPos[0] = candidate[0];
                        bestPos[1] = candidate[1];
                        bestPos[2] = candidate[2];
                    }
                } else if (bestDist < 0.0) {
                    // 暂无合格点，记录这个偏近的候选（fallback）
                    bestDist = dist;
                    bestPos[0] = candidate[0];
                    bestPos[1] = candidate[1];
                    bestPos[2] = candidate[2];
                }
            }
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
