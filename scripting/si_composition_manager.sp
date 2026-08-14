// ============================================================================
// si_composition_manager.sp — L4D2 Special Infected Spawn Composition Manager
// ============================================================================
// Dynamically adjusts SI class selection to create tactically diverse spawn
// compositions. Hooks L4D_OnSpawnSpecial to override the zombieClass before
// the engine spawns the bot.
//
// Design:
//   - 6 regular modes rotate every 35-50s (v5.1: range source = own cvars)
//   - Each mode OMITS 2-3 SI types entirely (0% ratio) for strong identity
//   - Only Mode 6 (Balanced) includes all 6 classes
//   - 1 Tank override mode: auto-activates when Tank spawns
//   - Deficit-first algorithm: picks the class furthest below its target ratio
//   - Zero-ratio classes are never selected (deficit ≤ 0)
//   - g_iAliveByClass pre-counted in L4D_OnSpawnSpecial → intra-wave deficit awareness
//   - Class limits (ss_*_limit) enforced within the same wave, not just between waves
//   - Requires ss_time_mode 1 (random); pin min=max per wave for exact countdown
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

#define PLUGIN_VERSION "2.5.0"

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
// Mode complexity classification (v2.5.0 — pressure tier filtering)
// ============================================================================
// 1 = SIMPLE   (easy to counter, few threat types, predictable)
// 2 = MODERATE (mixed threats, standard challenge)
// 3 = COMPLEX  (multi-vector assault, high coordination required)
int g_iModeComplexity[SCM_MODE_COUNT] = { 1, 2, 3, 2, 3, 2 };
// Mode 1 "钢铁洪流" — SIMPLE:   pure melee (C+H+J), predictable positioning
// Mode 2 "暗影锁链" — MODERATE: ranged control mix (Sm+Bm+Sp+J)
// Mode 3 "地空协同" — COMPLEX:  air + ground multi-threat (H+C+J+Sp)
// Mode 4 "生化危机" — MODERATE: zone denial + breach (Bm+Sp+Sm+C)
// Mode 5 "猎手集群" — COMPLEX:  speed swarm, high incap rate (H+J+Sp+Sm)
// Mode 6 "均衡演武" — MODERATE: all-rounder baseline (all 6 classes)

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

// Wave announcement state
float  g_fLastWaveAnnounce = 0.0;                // GameTime of last wave chat message

// ============================================================================
// Pressure tier integration (v2.5.0 — tactical filtering)
// ============================================================================
ConVar g_cvPressureTier;      // sm_pressure_tier from pressure_tracker (lazy-bind)
int    g_iPressureTier = 2;   // Default T2 Standard; updated on cvar change

// Timing pin: we own ss_time_min and ss_time_max handles to pin both
// to the same value each wave. ss_time_mode 1 then produces exactly that value
// (random(X, X) = X), giving us exact countdown control.
// v5.1: 区间来源 = 自身 cvar（si_comp_mode_interval_min/max）——原 CaptureSourceRange
// 从 ss_time_min/max 捕获，但 ss_time_* 会被本插件钉成单值：reload 时
// OnConfigsExecuted 不触发 → 捕获失效 → 区间漂到硬编码默认 45/60
// （2026-08-04 实测 reload 后钉 56.6/58.2，波次 35-50 完全不生效）。
// 自身 cvar 永不被动 → reload 即生效，且与模式轮换共用同一区间
// （cvar 描述本意就是 "synced to ss_time_*"）。
// v2.0.0 语义: 钉值 = 冷静期结束后的下一波间隔。specialspawner 波间三态
// （压力/收尾/冷静）下, 冷静期(12-18s)吃掉波间隔前段, 冷静期后按
// 钉值 − 平均冷静时长 排下一波 → 总波周期仍 ≈ 钉值 40-55。倒计时播报由
// specialspawner 进入冷静期时统一给出, 本插件不再播"下一波 X 秒后"。
ConVar g_cvSsTimeMin;
ConVar g_cvSsTimeMax;

// Spawn-size scaling: dynamically adjust ss_spawn_size per survivor count.
// Uses same extra_limit/extra_size formula as specialspawner's alive limit.
ConVar g_cvSsSpawnSize;
ConVar g_cvSsBaseLimit;
ConVar g_cvSsExtraLimit;
ConVar g_cvSsBaseSize;
ConVar g_cvSsExtraSize;

// Fixed baseline captured once at startup — NOT read from the mutable ConVar
// each time. Otherwise AdjustSpawnSize feeds its own output back as input,
// converging irreversibly to the minimum clamp (4) on the first low-player event.
float g_fCfgBaseSpawnSize = 6.0;  // overridden from ss_spawn_size in OnPluginStart

// ============================================================================
// ConVars
// ============================================================================
ConVar g_cvEnable;
ConVar g_cvModeIntervalMin;
ConVar g_cvModeIntervalMax;
ConVar g_cvAnnounce;
ConVar g_cvWaveAnnounce;
ConVar g_cvActiveMode;   // v2.4: 战术指令下发 —— AI_HardSI_bt 读取并执行模式配合

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
    g_cvModeIntervalMin = CreateConVar("si_comp_mode_interval_min",   "35.0",
        "v5.1: 波次间隔 + 模式轮换区间下限（钉到 ss_time_min/max）", _, true, 10.0, true, 600.0);
    g_cvModeIntervalMax = CreateConVar("si_comp_mode_interval_max",   "50.0",
        "v5.1: 波次间隔 + 模式轮换区间上限（钉到 ss_time_min/max）", _, true, 10.0, true, 600.0);
    g_cvAnnounce        = CreateConVar("si_comp_announce",            "0",
        "Announce mode changes in chat (0=off, 1=on)", _, true, 0.0, true, 1.0);
    g_cvWaveAnnounce    = CreateConVar("si_comp_wave_announce",      "1",
        "Announce each spawn wave in chat with strategy + next wave timer (0=off, 1=on)",
        _, true, 0.0, true, 1.0);
    g_cvActiveMode      = CreateConVar("si_comp_active_mode",        "-1",
        "Current tactical mode published to AI_HardSI_bt (0-5 regular, 6 Tank). -1 = inactive. Do NOT set manually.");

    AutoExecConfig(true, "si_composition_manager");

    // --- Lazy-bind pressure tracker (may load after us) ---
    TryBindPressureTracker();

    // --- Read specialspawner limits ---
    ReadClassLimits();

    // --- Grab handles for ss_time_min / ss_time_max (we pin them per-wave) ---
    g_cvSsTimeMin = FindConVar("ss_time_min");
    g_cvSsTimeMax = FindConVar("ss_time_max");

    // --- Grab handles for spawn-size scaling ---
    g_cvSsSpawnSize  = FindConVar("ss_spawn_size");
    g_cvSsBaseLimit  = FindConVar("ss_base_limit");
    g_cvSsExtraLimit = FindConVar("ss_extra_limit");
    g_cvSsBaseSize   = FindConVar("ss_base_size");
    g_cvSsExtraSize  = FindConVar("ss_extra_size");

    // NOTE: g_fCfgBaseSpawnSize is now captured in OnConfigsExecuted —
    // at OnPluginStart, specialspawner.cfg hasn't executed yet,
    // so ss_spawn_size still holds the compile default (4 vs cfg 6).

    // NOTE: CaptureSourceRange / PinSpawnTiming / AdjustSpawnSize are
    // deferred to OnConfigsExecuted — in OnPluginStart, specialspawner.cfg
    // hasn't executed yet, so the ConVars still hold compile defaults (~10-15s).

    // --- Hook spawn events ---
    HookEvent("player_spawn",     Event_PlayerSpawn,     EventHookMode_Post);
    HookEvent("player_death",     Event_PlayerDeath,     EventHookMode_Pre);
    HookEvent("player_team",      Event_PlayerTeam,      EventHookMode_Post);
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Post);
    HookEvent("round_start",      Event_RoundStart,      EventHookMode_PostNoCopy);
    HookEvent("round_end",        Event_RoundEnd,        EventHookMode_PostNoCopy);

    // v2.3.9 实测结论（2026-08-04）：SourceMod 对 late-load 插件补发 OnMapStart
    // （重载后 active_mode 0→1 实证）→ 模式轮换定时器链由 OnMapStart 自动重建，
    // 无需热重载兜底。曾加的 late-load 重建块已撤（多余 + 会把钉值抓成基准）。
}

// ============================================================================
// OnAllPluginsLoaded — retry pressure tracker binding
// ============================================================================
public void OnAllPluginsLoaded()
{
    TryBindPressureTracker();
}

// ============================================================================
// TryBindPressureTracker — lazy-bind sm_pressure_tier ConVar
// ============================================================================
void TryBindPressureTracker()
{
    if (g_cvPressureTier != null) return;  // already bound

    g_cvPressureTier = FindConVar("sm_pressure_tier");
    if (g_cvPressureTier != null) {
        g_iPressureTier = g_cvPressureTier.IntValue;
        HookConVarChange(g_cvPressureTier, OnPressureTierChanged);
        LogMessage("[SCM] Pressure tracker bound: tier T%d", g_iPressureTier);
    }
}

// ============================================================================
// OnPressureTierChanged — track tier changes
// ============================================================================
public void OnPressureTierChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    int oldTier = g_iPressureTier;
    g_iPressureTier = convar.IntValue;
    if (oldTier != g_iPressureTier) {
        LogMessage("[SCM] Pressure tier changed: T%d → T%d (tactical filter updated)",
            oldTier, g_iPressureTier);
    }
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
// Spawn timing (pin trick)
//
// specialspawner (ss_time_mode 0) picks ss_time_max for the next wave.
// We pin BOTH to the SAME value → random(X, X) = X → exact countdown.
// v5.1: 区间来源改为自身 cvar（si_comp_mode_interval_min/max，默认 35/50）——
// reload/热应用即生效，无捕获环节（见上方 Timing pin 注释）。
// ============================================================================

// Generate next interval and pin both cvars to it.
// v2.3.7: 返回值 = 钉值前的旧值（实际生效间隔），供播报使用。
// specialspawner 在刷出帧先读 cvar 决定下次间隔（读到旧钉值），si_comp 在
// 刷出事件里才钉新值 —— 播报新值会差一轮（实测偏差 0-15s）。播旧值后：
// 播报 X 秒 → 实际 X 秒后刷下一波，完全对齐。回合重开（ResetTracking）
// 打断波次导致的 15s 提前第一波不在本函数处理范围。
// v2.0.0: 返回值不再用于播报（specialspawner 三态下播报在冷静期进入时给出），
// 仍保留返回值供 Debug/未来使用。
float PinSpawnTiming()
{
    // v5.1: 自身 cvar 为唯一区间来源（永不被动、reload 即生效）
    float min = (g_cvModeIntervalMin != null) ? g_cvModeIntervalMin.FloatValue : 35.0;
    float max = (g_cvModeIntervalMax != null) ? g_cvModeIntervalMax.FloatValue : 50.0;
    if (min > max) min = max;
    float interval = GetRandomFloat(min, max);
    float prev = (g_cvSsTimeMin != null) ? g_cvSsTimeMin.FloatValue : min;
    if (g_cvSsTimeMin != null) g_cvSsTimeMin.SetFloat(interval);
    if (g_cvSsTimeMax != null) g_cvSsTimeMax.SetFloat(interval);

    AdjustSpawnSize();  // re-scale per current survivor count

    return prev;
}

// ============================================================================
// Spawn-size scaling — mirrors specialspawner's limit formula
//
//   spawn_size = base_spawn_size + ss_extra_limit * (survivors - ss_base_size) / ss_extra_size
//
// with ss_spawn_size from cfg as the "base_spawn_size" (for 4 survivors).
// Clamped to minimum 4 and capped at the computed alive limit.
// ============================================================================
int GetSurvivorCount()
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i)) {
            count++;
        }
    }
    return (count > 0) ? count : 4;  // fallback to 4 if no survivors found
}

void AdjustSpawnSize()
{
    if (g_cvSsSpawnSize == null) return;

    int survivors    = GetSurvivorCount();
    float baseSpawn  = g_fCfgBaseSpawnSize;  // FIXED baseline, not mutable ConVar
    float extraLimit = (g_cvSsExtraLimit != null) ? g_cvSsExtraLimit.FloatValue : 1.5;
    float baseSize   = (g_cvSsBaseSize != null)   ? g_cvSsBaseSize.FloatValue   : 4.0;
    float extraSize  = (g_cvSsExtraSize != null)  ? g_cvSsExtraSize.FloatValue  : 1.0;
    float baseLimit  = (g_cvSsBaseLimit != null)  ? g_cvSsBaseLimit.FloatValue  : 8.0;

    // survivor delta: how many more (or fewer) than base_size
    float delta = (float(survivors) - baseSize) / extraSize;

    // Compute target spawn_size
    int spawn = RoundToNearest(baseSpawn + extraLimit * delta);
    if (spawn < 4) spawn = 4;

    // Compute alive limit (same formula as specialspawner)
    int limit = RoundToNearest(baseLimit + extraLimit * delta);
    if (spawn > limit) spawn = limit;

    g_cvSsSpawnSize.SetInt(spawn);
}

// ============================================================================
// Map / Round lifecycle
// ============================================================================
public void OnMapStart()
{
    // v5.1: 无需捕获 —— 波次区间来自自身 cvar（si_comp_mode_interval_*），
    // 换图后由 si_composition_manager.cfg 重新 exec（AutoExecConfig），
    // 无需等待 OnConfigsExecuted 的捕获时机。

    // Retry pressure tracker binding (in case it loaded after OnPluginStart)
    TryBindPressureTracker();

    // Pick tier-appropriate starting mode (v2.5.0)
    g_iCurrentMode = PickStartingMode();
    g_bTankOverride = false;
    g_bTankAlive = false;
    PublishMode();      // v2.4: 战术指令下发（换图后 AI_HardSI 读到新模式）
    ResetTracking();

    // Start mode rotation timer
    ScheduleNextModeRotation();  // creates new timer (old one killed by TIMER_FLAG_NO_MAPCHANGE)
}

// OnConfigsExecuted fires AFTER specialspawner.cfg + sourcemod.cfg on every map load.
// v5.1: 只重捕获波次大小基线（ss_spawn_size 的 cfg 值；波次区间已改用自身 cvar）。
public void OnConfigsExecuted()
{
    // Re-capture configured spawn size baseline (cfg just executed, value is fresh)
    if (g_cvSsSpawnSize != null) {
        g_fCfgBaseSpawnSize = float(g_cvSsSpawnSize.IntValue);
    }

    PinSpawnTiming();
    AdjustSpawnSize();
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bTankOverride = false;
    g_bTankAlive = false;
    PublishMode();      // v2.4: 新回合下发当前模式
    ResetTracking();
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    if (g_hModeTimer != null) {
        KillTimer(g_hModeTimer);
        g_hModeTimer = null;
    }
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
    g_fLastWaveAnnounce = 0.0;
    PinSpawnTiming();   // set random interval for the first wave
    AdjustSpawnSize();  // set spawn_size for current survivor count
}

// ============================================================================
// Player team / disconnect — re-scale spawn_size immediately
// ============================================================================
public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    // Only care about team changes involving survivors
    int oldTeam = event.GetInt("oldteam");
    int newTeam = event.GetInt("team");
    if (oldTeam == 2 || newTeam == 2) {
        AdjustSpawnSize();
    }
}

public void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    // Player may have been on survivor team — re-check
    AdjustSpawnSize();
}

// ============================================================================
// Mode rotation timer
// ============================================================================
void ScheduleNextModeRotation()
{
    // v2.4.1 FIX: the previous timer's handle may already be closed by the
    // engine (one-shot callback fired at the map-change edge) while
    // g_hModeTimer still points at it — `delete` on a closed handle throws
    // "Invalid Handle" (seen every map change in errors log).
    if (g_hModeTimer != null && IsValidHandle(g_hModeTimer)) {
        KillTimer(g_hModeTimer);
    }
    g_hModeTimer = null;
    float interval = GetRandomFloat(
        g_cvModeIntervalMin.FloatValue,
        g_cvModeIntervalMax.FloatValue);
    g_hModeTimer = CreateTimer(interval, Timer_RotateMode, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_RotateMode(Handle timer)
{
    // One-shot timer has fired — engine already closed the handle.
    // Null it so ScheduleNextModeRotation's `delete g_hModeTimer` is a safe no-op.
    g_hModeTimer = null;

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
    // Refresh tier before rotation (v2.5.0)
    if (g_cvPressureTier != null) {
        g_iPressureTier = g_cvPressureTier.IntValue;
    }

    // Build weighted pool based on tier + complexity
    ArrayList pool = new ArrayList();
    for (int m = 0; m < SCM_MODE_COUNT; m++) {
        if (m == g_iCurrentMode) continue;  // no repeat
        int weight = GetModeWeightForTier(m, g_iPressureTier);
        for (int w = 0; w < weight; w++) {
            pool.Push(m);
        }
    }

    // Fallback: if pool is empty (all excluded by tier), allow all other modes
    if (pool.Length == 0) {
        for (int m = 0; m < SCM_MODE_COUNT; m++) {
            if (m != g_iCurrentMode) {
                pool.Push(m);
            }
        }
        LogMessage("[SCM] Tier T%d filter yielded empty pool, using all modes", g_iPressureTier);
    }

    int newMode = pool.Get(GetRandomInt(0, pool.Length - 1));
    delete pool;

    int oldMode = g_iCurrentMode;
    g_iCurrentMode = newMode;
    PublishMode();      // v2.4: 下发战术指令

    if (g_cvAnnounce.BoolValue) {
        PrintToChatAll("\x04[SI组合]\x01 进攻模式切换: \x03%s\x01 → \x05%s",
            g_sModeNames[oldMode], g_sModeNames[newMode]);
    }

    LogMessage("[SCM] Mode rotated (T%d): %s → %s [complexity %d→%d]",
        g_iPressureTier, g_sModeNames[oldMode], g_sModeNames[newMode],
        g_iModeComplexity[oldMode], g_iModeComplexity[newMode]);
}

// ============================================================================
// v2.4: 战术指令下发 —— 写入 si_comp_active_mode 供 AI_HardSI_bt 读取。
// 行为树据此切换模式配合分支：0-5 普通模式，6 = Tank 巨兽协同。
// ============================================================================
void PublishMode()
{
    if (g_cvActiveMode != null) {
        g_cvActiveMode.SetInt(g_bTankOverride ? 6 : g_iCurrentMode);
    }
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
            PublishMode();      // v2.4: 下发 6 = 巨兽协同
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
            PublishMode();      // v2.4: 恢复普通模式
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

    // SI alive counting moved to L4D_OnSpawnSpecial (pre-spawn)
    // so subsequent spawns in the same wave can see earlier picks.
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
        // Still track spawn for accurate alive counts
        if (zombieClass >= ZC_SMOKER && zombieClass <= ZC_CHARGER) {
            g_iAliveByClass[zombieClass]++;
            g_fLastSpawnedTime[zombieClass] = GetGameTime();
        }
        return Plugin_Continue;
    }

    // v2.0.1: 波次检测/播报提前到 class 覆盖之前——PickClass 返回 -1（各类
    // 计数触顶）时旧代码走 fallback 分支静默吞掉播报，玩家只见波来不见
    // [SI波次] 播报（2026-08-05 实测"第二波来袭不播报"）。波次检测只看
    // 冷却时间，与 class 选择无关，提前调用无副作用。
    DetectAndAnnounceWave();

    int chosen = PickClass();
    if (chosen >= ZC_SMOKER && chosen <= ZC_CHARGER) {
        zombieClass = chosen;
        g_iAliveByClass[chosen]++;                       // pre-count for intra-wave deficit calc
        g_fLastSpawnedTime[chosen] = GetGameTime();

        return Plugin_Changed;
    }

    // Fallback: let specialspawner decide, but still track the original class
    if (zombieClass >= ZC_SMOKER && zombieClass <= ZC_CHARGER) {
        g_iAliveByClass[zombieClass]++;
        g_fLastSpawnedTime[zombieClass] = GetGameTime();
    }
    return Plugin_Continue;
}

// ============================================================================
// Wave detection: if cooldown expired, this spawn starts a new wave
// ============================================================================
void DetectAndAnnounceWave()
{
    float now = GetGameTime();
    float minInterval = (g_cvModeIntervalMin != null) ? g_cvModeIntervalMin.FloatValue : 35.0;
    float cooldown = minInterval * 0.5;  // half of interval range min (v5.1: 自身 cvar)
    if (cooldown < 15.0) cooldown = 15.0;

    if (now - g_fLastWaveAnnounce > cooldown) {
        g_fLastWaveAnnounce = now;

        // Pin min=max to a new random interval → specialspawner picks exactly this
        PinSpawnTiming();

        AnnounceWave();
    }
}

void AnnounceWave()
{
    if (!g_cvWaveAnnounce.BoolValue) return;

    char modeName[32];
    if (g_bTankOverride) {
        strcopy(modeName, sizeof(modeName), "巨兽协同 (Tank支援)");
    } else {
        strcopy(modeName, sizeof(modeName), g_sModeNames[g_iCurrentMode]);
    }

    int spawnSize = (g_cvSsSpawnSize != null) ? g_cvSsSpawnSize.IntValue : 6;
    int effective = spawnSize;

    // v2.3.8 倒地补偿镜像：与 specialspawner v1.5.0 ExecuteSpawnQueue 同一公式
    // (ss_incap_compensation 强度 × 站立/总人数 比例)。仅用于播报真实波次数量，
    // 改公式必须两处同步。播报时机 = 波次首只刷新（L4D_OnSpawnSpecial），若
    // 补偿把整波压没（存活≥补偿上限）则不会有任何刷新 → 自然无播报，无需处理。
    ConVar cvComp = FindConVar("ss_incap_compensation");
    if (cvComp != null && cvComp.FloatValue > 0.0) {
        int total = 0;
        int standing = 0;
        for (int i = 1; i <= MaxClients; i++) {
            if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i)) {
                total++;
                if (!GetEntProp(i, Prop_Send, "m_isIncapacitated")) {
                    standing++;
                }
            }
        }
        if (total > 0 && standing < total) {
            float ratio = float(standing) / float(total);
            float scale = 1.0 - cvComp.FloatValue * (1.0 - ratio);
            effective = RoundToNearest(float(spawnSize) * scale);
            if (effective < 1) effective = 1;
        }
    }

    // v2.0.0: 去掉"下一波 X 秒后"——新波间三态下间隔在冷静期结束才消费（且被
    // 冷静时长抵扣），旧"播旧钉值"对齐技巧失效；倒计时播报由 specialspawner
    // 进入冷静期时统一给出（[特感] 波次清剿完毕，X 秒后下一波）。
    if (effective < spawnSize) {
        PrintToChatAll("\x04[SI波次]\x01 特感已刷新 \x05%d\x01只(\x03倒地补偿 %d→%d\x01)!",
            effective, spawnSize, effective);
    } else {
        PrintToChatAll("\x04[SI波次]\x01 特感已刷新 \x05%d\x01只!",
            spawnSize);
    }
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

        // Skip zero-ratio classes (excluded from current mode)
        if (ratios[idx] <= 0.0) {
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
            // Skip zero-ratio classes here too (same reason as above)
            if (ratios[idx] <= 0.0) {
                continue;
            }
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

// ============================================================================
// v2.5.0: Tier-based tactical filtering helpers
// ============================================================================

// Returns spawn weight for a mode at the given pressure tier.
// Weight 0 = excluded; higher = more likely to be selected.
// Complexity: 1=SIMPLE, 2=MODERATE, 3=COMPLEX
int GetModeWeightForTier(int modeIdx, int tier)
{
    int complexity = g_iModeComplexity[modeIdx];

    switch (tier) {
        case 1: {
            // T1 Casual: SIMPLE strongly preferred, MODERATE rarely, COMPLEX excluded
            if (complexity == 1) return 5;
            if (complexity == 2) return 1;
            return 0;
        }
        case 2: {
            // T2 Standard: SIMPLE + MODERATE, no COMPLEX
            if (complexity == 1) return 3;
            if (complexity == 2) return 2;
            return 0;
        }
        case 3: {
            // T3 Challenge: all modes equally available
            return 2;
        }
        case 4: {
            // T4 Hard: MODERATE + COMPLEX, no SIMPLE
            if (complexity == 1) return 0;
            if (complexity == 2) return 2;
            return 3;
        }
        case 5: {
            // T5 Hell: COMPLEX strongly preferred, MODERATE rarely, SIMPLE excluded
            if (complexity == 1) return 0;
            if (complexity == 2) return 1;
            return 5;
        }
    }
    return 1;  // Unknown tier — all equal
}

// Pick a tier-appropriate starting mode (used at map start)
int PickStartingMode()
{
    ArrayList pool = new ArrayList();
    for (int m = 0; m < SCM_MODE_COUNT; m++) {
        int weight = GetModeWeightForTier(m, g_iPressureTier);
        for (int w = 0; w < weight; w++) {
            pool.Push(m);
        }
    }

    if (pool.Length == 0) {
        // Fallback: any mode
        delete pool;
        return GetRandomInt(0, SCM_MODE_COUNT - 1);
    }

    int result = pool.Get(GetRandomInt(0, pool.Length - 1));
    delete pool;
    return result;
}
