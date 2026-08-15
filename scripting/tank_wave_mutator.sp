// tank_wave_mutator.sp
// Tank 波次突变系统：10% 随机突变 + 连续5波无倒地强制 Tank + Tank 波后6波冷静期
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "1.0.1"

// 配置常量
#define MUTATION_CHANCE 1.00        // [临时测试100%] 正式值应为 0.10
#define FORCE_TANK_WAVES 5          // 连续5波无倒地触发强制Tank
#define TANK_COOLDOWN_WAVES 6       // Tank波后冷静期（4 × 1.5）
#define SI_COUNT_THRESHOLD_LOW 2    // 波间特感数下限
#define SI_COUNT_THRESHOLD_HIGH 4   // 新波次特感数上限

// 全局变量
int g_iWaveCounter = 0;             // 总波次计数
int g_iNoDownWaves = 0;             // 连续无倒地波次
int g_iTankCooldown = 0;            // Tank波后冷静期剩余
int g_iLastSICount = 0;             // 上次特感数量
bool g_bWaveActive = false;         // 当前是否在波次中

Handle g_hMonitorTimer = null;      // 监听定时器

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
    HookEvent("tank_spawn", Event_TankSpawn);

    // 换图重置
    HookEvent("round_start", Event_RoundStart);
    HookEvent("round_end", Event_RoundEnd);

    // 启动监听定时器
    g_hMonitorTimer = CreateTimer(1.0, Timer_MonitorWaves, _, TIMER_REPEAT);

    LogMessage("[Tank Mutator] Plugin loaded. Mutation: %.0f%%, Force: %d waves, Cooldown: %d waves",
               MUTATION_CHANCE * 100.0, FORCE_TANK_WAVES, TANK_COOLDOWN_WAVES);
}

public void OnPluginEnd() {
    if (g_hMonitorTimer != null) {
        KillTimer(g_hMonitorTimer);
        g_hMonitorTimer = null;
    }
}

// ============ 事件处理 ============

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    // 换图重置所有状态
    g_iWaveCounter = 0;
    g_iNoDownWaves = 0;
    g_iTankCooldown = 0;
    g_iLastSICount = 0;
    g_bWaveActive = false;
    LogMessage("[Tank Mutator] Round start, all counters reset");
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    // 回合结束暂停监听
    g_bWaveActive = false;
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
    if (client > 0 && IsClientInGame(client) && GetClientTeam(client) == 2) {
        // 生还者死亡，重置连续无倒地计数
        g_iNoDownWaves = 0;
        LogMessage("[Tank Mutator] Survivor death, reset no-down counter");
    }
}

void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    LogMessage("[Tank Mutator] Tank spawned (client: %d)", client);
}

// ============ 波次监听核心 ============

Action Timer_MonitorWaves(Handle timer) {
    int currentSICount = CountSpecialInfected();

    // 检测新波次开始：特感数从 ≤2 增加到 ≥4
    if (g_iLastSICount <= SI_COUNT_THRESHOLD_LOW && currentSICount >= SI_COUNT_THRESHOLD_HIGH) {
        if (!g_bWaveActive) {
            OnNewWave();
            g_bWaveActive = true;
        }
    }

    // 检测波次结束：特感数降至 ≤2
    if (currentSICount <= SI_COUNT_THRESHOLD_LOW && g_bWaveActive) {
        g_bWaveActive = false;
    }

    g_iLastSICount = currentSICount;
    return Plugin_Continue;
}

void OnNewWave() {
    g_iWaveCounter++;
    LogMessage("[Tank Mutator] Wave #%d detected (SI count: %d)", g_iWaveCounter, g_iLastSICount);

    // 判定是否触发Tank波
    bool shouldSpawnTank = false;
    char reason[128];

    if (g_iTankCooldown > 0) {
        // 冷静期中，递减计数，不累加无倒地计数，不触发Tank
        g_iTankCooldown--;
        Format(reason, sizeof(reason), "Cooldown (%d waves remaining)", g_iTankCooldown);
        LogMessage("[Tank Mutator] In cooldown period: %d waves left", g_iTankCooldown);
        // 注意：冷静期内 g_iNoDownWaves 不累加（跳过 else 分支）
    } else if (g_iNoDownWaves >= FORCE_TANK_WAVES) {
        // 强制Tank波（连续5波无倒地）
        shouldSpawnTank = true;
        Format(reason, sizeof(reason), "Forced (no downs for %d waves)", g_iNoDownWaves);
    } else {
        // 10% 随机突变
        float roll = GetURandomFloat();
        if (roll < MUTATION_CHANCE) {
            shouldSpawnTank = true;
            Format(reason, sizeof(reason), "Random mutation (rolled %.1f%%)", roll * 100.0);
        } else {
            Format(reason, sizeof(reason), "No mutation (rolled %.1f%%)", roll * 100.0);
        }

        // 非冷静期的普通波次，累加无倒地计数
        g_iNoDownWaves++;
    }

    if (shouldSpawnTank) {
        LogMessage("[Tank Mutator] TANK WAVE triggered! Reason: %s", reason);

        // 特殊播报（仅一行，全局聊天区）
        PrintToChatAll("\x04☠ TANK 波次来袭！\x01");

        // 延迟生成Tank（避免与specialspawner冲突）
        CreateTimer(1.5, Timer_SpawnTank, _, TIMER_FLAG_NO_MAPCHANGE);

        // 重置无倒地计数，进入冷静期
        g_iNoDownWaves = 0;
        g_iTankCooldown = TANK_COOLDOWN_WAVES;
    } else {
        // 日志记录（不播报）
        LogMessage("[Tank Mutator] Normal wave. No-down streak: %d/%d. %s",
                   g_iNoDownWaves, FORCE_TANK_WAVES, reason);
    }
}

Action Timer_SpawnTank(Handle timer) {
    // 找一个存活的幸存者作为参考点
    int client = GetAnyAliveSurvivor();
    if (client <= 0) {
        LogMessage("[Tank Mutator] Tank spawn failed: no alive survivor found");
        return Plugin_Stop;
    }

    // 使用 left4dhooks 寻找合适的 Tank 生成位置（zombieClass 8 = Tank）
    float spawnPos[3], spawnAng[3] = {0.0, 0.0, 0.0};
    if (!L4D_GetRandomPZSpawnPosition(client, 8, 10, spawnPos)) {
        LogMessage("[Tank Mutator] Tank spawn failed: no valid spawn position found");
        return Plugin_Stop;
    }

    // 直接生成 Tank
    int tank = L4D2_SpawnTank(spawnPos, spawnAng);
    if (tank > 0 && IsClientInGame(tank)) {
        LogMessage("[Tank Mutator] Tank spawned successfully at position (%.1f, %.1f, %.1f), entity: %d",
                   spawnPos[0], spawnPos[1], spawnPos[2], tank);
    } else {
        LogMessage("[Tank Mutator] Tank spawn failed: L4D2_SpawnTank returned invalid entity");
    }

    return Plugin_Stop;
}

// ============ 工具函数 ============

int CountSpecialInfected() {
    int count = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && GetClientTeam(i) == 3) {
            int class = GetEntProp(i, Prop_Send, "m_zombieClass");
            // 1=Smoker, 2=Boomer, 3=Hunter, 4=Spitter, 5=Jockey, 6=Charger
            // Tank (8) 不计入普通特感波次
            if (class >= 1 && class <= 6) {
                count++;
            }
        }
    }
    return count;
}

// 返回任意一个存活的幸存者 client index，找不到返回 -1
int GetAnyAliveSurvivor() {
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i)) {
            return i;
        }
    }
    return -1;
}
