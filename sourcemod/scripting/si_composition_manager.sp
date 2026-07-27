// ============================================================================
// si_composition_manager.sp — L4D2 Special Infected Spawn Composition Manager
// ============================================================================
// Dynamically adjusts SI class selection to create tactically diverse spawn
// compositions. Hooks L4D_OnSpawnSpecial to override the zombieClass before
// the engine spawns the bot.
//
// Design:
//   - 6 regular modes rotate every 90-120s, each with a DISTINCT class signature
//   - Each mode OMITS 2-3 SI types entirely (0% ratio) for strong identity
//   - Only Mode 6 (Balanced) includes all 6 classes
//   - 1 Tank override mode: auto-activates when Tank spawns
//   - Deficit-first algorithm: picks the class furthest below its target ratio
//   - Zero-ratio classes are never selected (deficit ≤ 0)
//
// Mode table (Smoker, Boomer, Hunter, Spitter, Jockey, Charger):
//   Mode 1 "钢铁洪流"  — C+H+J only, zero ranged/zoning
//   Mode 2 "暗影锁链"  — Sm+Bm+Sp+J only, zero melee assault
//   Mode 3 "地空协同"  — H+C+J+Sp only, zero Sm/Bm
//   Mode 4 "生化危机"  — Bm+Sp+Sm+C only, zero H/J
//   Mode 5 "猎手集群"  — H+J+Sp+Sm only, zero C/Bm
//   Mode 6 "均衡演武"  — all 6 classes evenly
//   Mode T "巨兽协同"  — C+H+Sp+J, no Sm/Bm (Tank support)
// ============================================================================

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "2.0.0"

// Zombie class enum (matching left4dhooks)
#define ZC_SMOKER  1
#define ZC_BOOMER  2
#define ZC_HUNTER  3
#define ZC_SPITTER 4
#define ZC_JOCKEY  5
#define ZC_CHARGER 6
#define ZC_TANK    8

#define SCM_MODE_COUNT  6   // Regular modes (doesn't include Tank override)
#define SCM_CLASS_COUNT 6   // 6 SI classes (excludes Tank/Witch)

// ============================================================================
// Mode definitions: target ratios (sum = 1.0 per row)
// Columns: Smoker, Boomer, Hunter, Spitter, Jockey, Charger
// ============================================================================
float g_fModeRatios[SCM_MODE_COUNT][SCM_CLASS_COUNT] = {
    // Mode 1: 钢铁洪流 — pure melee: C+H+J only
    //           Omitted: Smoker, Boomer, Spitter (zero ranged/zoning)
    { 0.00, 0.00, 0.35, 0.00, 0.25, 0.40 },
    // Mode 2: 暗影锁链 — ranged control + horde: Sm+Bm+Sp+J only
    //           Omitted: Charger, Hunter (zero direct melee)
    { 0.35, 0.25, 0.00, 0.25, 0.15, 0.00 },
    // Mode 3: 地空协同 — air+ground assault: H+C+J+Sp only
    //           Omitted: Smoker, Boomer (zero pull/horde)
    { 0.00, 0.00, 0.35, 0.20, 0.20, 0.25 },
    // Mode 4: 生化危机 — zone denial siege: Bm+Sp+Sm+C only
    //           Omitted: Hunter, Jockey (zero chase)
    { 0.25, 0.30, 0.00, 0.30, 0.00, 0.15 },
    // Mode 5: 猎手集群 — speed swarm: H+J+Sp+Sm only
    //           Omitted: Charger, Boomer (zero heavy/support)
    { 0.15, 0.00, 0.40, 0.15, 0.30, 0.00 },
    // Mode 6: 均衡演武 — all 6 classes evenly
    { 0.17, 0.16, 0.17, 0.16, 0.17, 0.17 }
};

// Mode T (Tank override): 巨兽协同 — Tank support squad
// Omitted: Smoker (pulls away from Tank), Boomer (horde chaos on top of Tank)
// Active: C+H+Sp+J — pin/control survivors for Tank to land punches
float g_fTankModeRatios[SCM_CLASS_COUNT] = {
    0.00, 0.00, 0.30, 0.20, 0.20, 0.30
};

// Mode display names
char g_sModeNames[SCM_MODE_COUNT][] = {
    "钢铁洪流",
    "暗影锁链",
    "地空协同",
    "生化危机",
    "猎手集群",
    "均衡演武"
};

// ============================================================================
// State tracking
// ============================================================================
int    g_iCurrentMode = 0;                       // Active mode index (0-5)
int    g_iSavedMode = 0;                         // Mode saved before Tank override
bool   g_bTankOverride = false;                  // True when Tank mode is active
bool   g_bTankAlive = false;                     // True when a Tank bot is alive

int    g_iAliveByClass[SCM_CLASS_COUNT + 1];     // 1-indexed by zombieClass
int    g_iClassLimit[SCM_CLASS_COUNT + 1];       // Hard caps from ss_*_limit
float  g_fLastSpawnedTime[SCM_CLASS_COUNT + 1];  // Timestamp of last spawn per class

Handle g_hModeTimer = INVALID_HANDLE;

// ============================================================================
// ConVars
// ============================================================================
ConVar g_cvEnable;
ConVar g_cvModeIntervalMin;
ConVar g_cvModeIntervalMax;
ConVar g_cvAnnounce;

// ============================================================================
// Plugin Info
// ============================================================================
public Plugin myinfo = {
    name        = "SI Spawn Composition Manager",
    author      = "Claude",
    description = "Dynamically overrides SI spawn class to create diverse tactical compositions",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
// OnPluginStart
// ============================================================================
public void OnPluginStart()
{
    // --- Our cvars ---
    g_cvEnable          = CreateConVar("si_comp_enable",              "1",
        "Enable spawn composition manager (0=off, 1=on)", _, true, 0.0, true, 1.0);
    g_cvModeIntervalMin = CreateConVar("si_comp_mode_interval_min",   "90.0",
        "Minimum seconds between mode changes", _, true, 30.0, true, 600.0);
    g_cvModeIntervalMax = CreateConVar("si_comp_mode_interval_max",   "120.0",
        "Maximum seconds between mode changes", _, true, 30.0, true, 600.0);
    g_cvAnnounce        = CreateConVar("si_comp_announce",            "0",
        "Announce mode changes in chat (0=off, 1=on)", _, true, 0.0, true, 1.0);

    AutoExecConfig(true, "si_composition_manager");

    // --- Read specialspawner hard limits ---
    ReadClassLimits();

    // --- Hook spawn events ---
    HookEvent("player_spawn",  Event_PlayerSpawn,  EventHookMode_Post);
    HookEvent("player_death",  Event_PlayerDeath,  EventHookMode_Pre);
    HookEvent("round_start",   Event_RoundStart,   EventHookMode_PostNoCopy);
    HookEvent("round_end",     Event_RoundEnd,     EventHookMode_PostNoCopy);
}

// ============================================================================
// Read specialspawner class limits
// ============================================================================
void ReadClassLimits()
{
    g_iClassLimit[ZC_SMOKER]  = GetConVarIntSafe("ss_smoker_limit",  3);
    g_iClassLimit[ZC_BOOMER]  = GetConVarIntSafe("ss_boomer_limit",  2);
    g_iClassLimit[ZC_HUNTER]  = GetConVarIntSafe("ss_hunter_limit",  3);
    g_iClassLimit[ZC_SPITTER] = GetConVarIntSafe("ss_spitter_limit", 2);
    g_iClassLimit[ZC_JOCKEY]  = GetConVarIntSafe("ss_jockey_limit",  3);
    g_iClassLimit[ZC_CHARGER] = GetConVarIntSafe("ss_charger_limit", 3);
}

int GetConVarIntSafe(const char[] name, int defaultVal)
{
    ConVar cv = FindConVar(name);
    return (cv != null) ? cv.IntValue : defaultVal;
}

// ============================================================================
// Map / Round lifecycle
// ============================================================================
public void OnMapStart()
{
    // Pick random starting mode
    g_iCurrentMode = GetRandomInt(0, SCM_MODE_COUNT - 1);
    g_bTankOverride = false;
    g_bTankAlive = false;
    ResetTracking();

    // Start mode rotation timer
    delete g_hModeTimer;
    ScheduleNextModeRotation();
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bTankOverride = false;
    g_bTankAlive = false;
    ResetTracking();
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    delete g_hModeTimer;
    g_bTankOverride = false;
    g_bTankAlive = false;
    ResetTracking();
}

void ResetTracking()
{
    for (int i = 1; i <= SCM_CLASS_COUNT; i++) {
        g_iAliveByClass[i] = 0;
        g_fLastSpawnedTime[i] = 0.0;
    }
}

// ============================================================================
// Mode rotation timer
// ============================================================================
void ScheduleNextModeRotation()
{
    delete g_hModeTimer;
    float interval = GetRandomFloat(
        g_cvModeIntervalMin.FloatValue,
        g_cvModeIntervalMax.FloatValue);
    g_hModeTimer = CreateTimer(interval, Timer_RotateMode, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_RotateMode(Handle timer)
{
    if (!g_cvEnable.BoolValue || g_bTankOverride) {
        // If Tank override is active, postpone rotation
        ScheduleNextModeRotation();
        return Plugin_Continue;
    }

    RotateMode();
    ScheduleNextModeRotation();
    return Plugin_Continue;
}

void RotateMode()
{
    // Pick random mode != current (guaranteed: SCM_MODE_COUNT >= 2)
    int newMode = GetRandomInt(0, SCM_MODE_COUNT - 2);
    if (newMode >= g_iCurrentMode) {
        newMode++;
    }

    int oldMode = g_iCurrentMode;
    g_iCurrentMode = newMode;

    if (g_cvAnnounce.BoolValue) {
        PrintToChatAll("\x04[SI组合]\x01 进攻模式切换: \x03%s\x01 → \x05%s",
            g_sModeNames[oldMode], g_sModeNames[newMode]);
    }

    LogMessage("[SCM] Mode rotated: %s → %s", g_sModeNames[oldMode], g_sModeNames[newMode]);
}

// ============================================================================
// Tank detection — switch to/from Tank override mode
// ============================================================================
void OnTankSpawned()
{
    if (!g_bTankAlive) {
        g_bTankAlive = true;
        if (!g_bTankOverride) {
            g_iSavedMode = g_iCurrentMode;
            g_bTankOverride = true;
            LogMessage("[SCM] Tank detected — switching to 巨兽协同 (was %s)", g_sModeNames[g_iSavedMode]);
            if (g_cvAnnounce.BoolValue) {
                PrintToChatAll("\x04[SI组合]\x01 Tank 出现 — 切换至 \x05巨兽协同\x01 模式 (不刷Smoker/Boomer)");
            }
        }
    }
}

void OnTankDied()
{
    // Check if any other Tank bot is still alive
    bool anyTankAlive = false;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && IsFakeClient(i) && IsPlayerAlive(i)
            && GetClientTeam(i) == 3
            && GetInfectedClass(i) == ZC_TANK)
        {
            anyTankAlive = true;
            break;
        }
    }

    if (!anyTankAlive && g_bTankAlive) {
        g_bTankAlive = false;
        if (g_bTankOverride) {
            g_iCurrentMode = g_iSavedMode;
            g_bTankOverride = false;
            LogMessage("[SCM] Tank dead — restoring mode %s", g_sModeNames[g_iCurrentMode]);
            if (g_cvAnnounce.BoolValue) {
                PrintToChatAll("\x04[SI组合]\x01 Tank 已死 — 恢复 \x05%s\x01 模式", g_sModeNames[g_iCurrentMode]);
            }
        }
    }
}

// ============================================================================
// Player spawn — track alive SI
// ============================================================================
public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client) || !IsFakeClient(client)) return;
    if (GetClientTeam(client) != 3) return;

    int zombieClass = GetInfectedClass(client);

    // Track Tank separately
    if (zombieClass == ZC_TANK) {
        OnTankSpawned();
        return;
    }

    if (zombieClass < ZC_SMOKER || zombieClass > ZC_CHARGER) return;

    g_iAliveByClass[zombieClass]++;
}

// ============================================================================
// Player death — decrement alive count
// ============================================================================
public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client) || !IsFakeClient(client)) return;
    if (GetClientTeam(client) != 3) return;

    int zombieClass = GetInfectedClass(client);

    // Track Tank separately
    if (zombieClass == ZC_TANK) {
        OnTankDied();
        return;
    }

    if (zombieClass < ZC_SMOKER || zombieClass > ZC_CHARGER) return;

    if (g_iAliveByClass[zombieClass] > 0) {
        g_iAliveByClass[zombieClass]--;
    }
}

// ============================================================================
// L4D_OnSpawnSpecial — THE CORE: override zombieClass before spawn
// ============================================================================
public Action L4D_OnSpawnSpecial(int &zombieClass, const float vecPos[3], const float vecAng[3])
{
    if (!g_cvEnable.BoolValue) {
        return Plugin_Continue;
    }

    int chosen = PickClass();
    if (chosen >= ZC_SMOKER && chosen <= ZC_CHARGER) {
        zombieClass = chosen;
        g_fLastSpawnedTime[chosen] = GetGameTime();
        return Plugin_Changed;
    }

    return Plugin_Continue;  // Fallback: let specialspawner decide
}

// ============================================================================
// Deficit-first class selection algorithm
// ============================================================================
int PickClass()
{
    int    total = GetTotalAliveSI();
    float  now   = GetGameTime();

    // Determine which ratios to use
    float ratios[SCM_CLASS_COUNT];
    if (g_bTankOverride) {
        for (int i = 0; i < SCM_CLASS_COUNT; i++) {
            ratios[i] = g_fTankModeRatios[i];
        }
    } else {
        for (int i = 0; i < SCM_CLASS_COUNT; i++) {
            ratios[i] = g_fModeRatios[g_iCurrentMode][i];
        }
    }

    // --- First spawn of the round: weighted random ---
    if (total == 0) {
        return PickWeightedRandom(ratios);
    }

    // --- Calculate deficits ---
    // target[cls] = ratio[cls] * total
    // deficit[cls] = target[cls] - alive[cls]
    // Pick the class with the largest positive deficit
    float bestDeficit = -999.0;
    ArrayList candidates = new ArrayList();

    for (int cls = ZC_SMOKER; cls <= ZC_CHARGER; cls++) {
        int idx = cls - 1;

        // Hard limit check
        if (g_iAliveByClass[cls] >= g_iClassLimit[cls]) {
            continue;
        }

        float target  = ratios[idx] * float(total);
        float deficit = target - float(g_iAliveByClass[cls]);

        // Starvation boost: if this class hasn't spawned in 30+ seconds
        if (g_fLastSpawnedTime[cls] > 0.0 && (now - g_fLastSpawnedTime[cls]) > 30.0) {
            deficit += 1.0;
        }

        if (deficit > bestDeficit + 0.05) {
            // New best — clear candidates
            bestDeficit = deficit;
            candidates.Clear();
            candidates.Push(cls);
        } else if (FloatAbs(deficit - bestDeficit) <= 0.05) {
            // Tiebreaker zone — add to candidates
            candidates.Push(cls);
        }
    }

    // --- If no positive deficits found, pick closest to zero ---
    if (candidates.Length == 0) {
        float bestAbs = 999.0;
        for (int cls = ZC_SMOKER; cls <= ZC_CHARGER; cls++) {
            if (g_iAliveByClass[cls] >= g_iClassLimit[cls]) {
                continue;
            }
            int idx = cls - 1;
            float target  = ratios[idx] * float(total);
            float deficit = target - float(g_iAliveByClass[cls]);
            float absDef  = FloatAbs(deficit);
            if (absDef < bestAbs - 0.01) {
                bestAbs = absDef;
                candidates.Clear();
                candidates.Push(cls);
            } else if (FloatAbs(absDef - bestAbs) <= 0.01) {
                candidates.Push(cls);
            }
        }
    }

    // --- Pick from candidates ---
    int result = -1;
    if (candidates.Length > 0) {
        result = candidates.Get(GetRandomInt(0, candidates.Length - 1));
    }
    delete candidates;
    return result;
}

// ============================================================================
// Weighted random pick (used when total == 0)
// ============================================================================
int PickWeightedRandom(float ratios[SCM_CLASS_COUNT])
{
    float totalWeight = 0.0;
    float availableRatios[SCM_CLASS_COUNT];

    for (int i = 0; i < SCM_CLASS_COUNT; i++) {
        int cls = i + 1;
        if (g_iAliveByClass[cls] >= g_iClassLimit[cls]) {
            availableRatios[i] = 0.0;
        } else {
            availableRatios[i] = ratios[i];
            totalWeight += ratios[i];
        }
    }

    if (totalWeight <= 0.0) {
        // All at limit — pick a random valid class
        ArrayList fallback = new ArrayList();
        for (int cls = ZC_SMOKER; cls <= ZC_CHARGER; cls++) {
            if (g_iAliveByClass[cls] < g_iClassLimit[cls]) {
                fallback.Push(cls);
            }
        }
        int result = -1;
        if (fallback.Length > 0) {
            result = fallback.Get(GetRandomInt(0, fallback.Length - 1));
        }
        delete fallback;
        return result;
    }

    float roll = GetRandomFloat(0.0, totalWeight);
    float cumulative = 0.0;
    for (int i = 0; i < SCM_CLASS_COUNT; i++) {
        cumulative += availableRatios[i];
        if (roll <= cumulative) {
            return i + 1;
        }
    }

    // Fallback: return first non-limited class
    for (int cls = ZC_SMOKER; cls <= ZC_CHARGER; cls++) {
        if (g_iAliveByClass[cls] < g_iClassLimit[cls]) {
            return cls;
        }
    }
    return -1;
}

// ============================================================================
// Count total alive bot SI (excludes Tank)
// ============================================================================
int GetTotalAliveSI()
{
    int total = 0;
    for (int cls = ZC_SMOKER; cls <= ZC_CHARGER; cls++) {
        total += g_iAliveByClass[cls];
    }
    return total;
}

// ============================================================================
// Helpers
// ============================================================================
stock bool IsValidClient(int client)
{
    return (client >= 1 && client <= MaxClients && IsClientInGame(client));
}

stock int GetInfectedClass(int client)
{
    return GetEntProp(client, Prop_Send, "m_zombieClass");
}
