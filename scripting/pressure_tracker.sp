// ============================================================================
// pressure_tracker.sp — L4D2 Global Pressure Tracking System
// ============================================================================
// Tracks global pressure value (0-100) based on team performance and adjusts
// difficulty tier (T1-T5). Pressure changes are tightened to require multiple
// waves before tier transitions.
//
// Design principles:
//   - Only modify AI behavior/decisions, NOT SI health/damage/speed
//   - Global pressure only, no individual player tracking
//   - Tier transitions require 3+ consecutive waves (more for higher tiers)
//   - Higher tiers are harder to reach (T4->T5 needs 5 waves)
//   - Cooling also requires stabilization (3 waves)
//
// Tier system:
//   T1 (20-35)  : Casual    - 3 batches, long rest, conservative AI
//   T2 (35-50)  : Standard  - 2 batches, normal rest, balanced AI
//   T3 (50-65)  : Challenge - 2 batches, short rest, standard AI
//   T4 (65-80)  : Hard      - 1 batch, very short rest, aggressive AI
//   T5 (80-100) : Hell      - 1 batch, minimal rest, very aggressive AI
//
// Integration:
//   - Publishes cvars: sm_pressure_value, sm_pressure_tier, sm_pressure_aggression
//   - specialspawner reads tier to adjust rest/batches/suicide time
//   - si_composition_manager reads tier to filter tactics
//   - AI_HardSI reads aggression to adjust decision thresholds
// ============================================================================

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.0.0"

// Pressure bounds
#define PRESSURE_MIN 20
#define PRESSURE_MAX 100
#define PRESSURE_START 40

// Tier definitions
#define TIER_COUNT 5

enum PressureTier {
    TIER_CASUAL = 1,     // 20-35
    TIER_STANDARD = 2,   // 35-50
    TIER_CHALLENGE = 3,  // 50-65
    TIER_HARD = 4,       // 65-80
    TIER_HELL = 5        // 80-100
}

// ============================================================================
// Global State
// ============================================================================
int g_iGlobalPressure = PRESSURE_START;
int g_iCurrentTier = TIER_STANDARD;
int g_iPendingTier = TIER_STANDARD;
int g_iTierStableCount[TIER_COUNT + 1];  // Index 1-5
int g_iWaveCount = 0;

// Wave statistics (reset each wave)
int g_iWaveDamage = 0;
int g_iWaveIncaps = 0;
int g_iWaveDeaths = 0;
float g_fWaveStartTime = 0.0;
bool g_bWaveActive = false;

// Streak counters
int g_iPerfectStreakCount = 0;  // Consecutive waves with zero incaps/deaths

// ============================================================================
// ConVars (published for other plugins)
// ============================================================================
ConVar g_cvPressureValue;     // Current pressure (0-100)
ConVar g_cvPressureTier;      // Current tier (1-5)
ConVar g_cvPressureAggression; // AI aggression multiplier (0.7-1.3)

// Configuration cvars
ConVar g_cvEnable;
ConVar g_cvAnnounce;

// Pressure change rates (tightened)
ConVar g_cvPerfectWave;       // +5 (was +12)
ConVar g_cvFastClear;         // +3 (was +8)
ConVar g_cvPerfectStreak;     // +8 for 5-wave streak (was +10 for 3-wave)
ConVar g_cvIncapPenalty;      // -4 per incap (was -8)
ConVar g_cvDeathPenalty;      // -8 per death (was -15)
ConVar g_cvWipeReset;         // Reset to 30 (was 25)
ConVar g_cvSlowClear;         // -3 (was -6)
ConVar g_cvDamageThreshold;   // 200 HP threshold
ConVar g_cvDamagePenalty;     // -2 (was -5)
ConVar g_cvDecayPerWave;      // -1 (was -2)

// Tier thresholds
int g_iTierBounds[TIER_COUNT + 1][2] = {
    {0, 0},       // Unused
    {20, 35},     // T1
    {35, 50},     // T2
    {50, 65},     // T3
    {65, 80},     // T4
    {80, 100}     // T5
};

// Tier names
char g_sTierNames[TIER_COUNT + 1][32] = {
    "",
    "休闲",
    "标准",
    "挑战",
    "困难",
    "地狱"
};

// AI aggression multipliers per tier
float g_fTierAggression[TIER_COUNT + 1] = {
    0.0,   // Unused
    0.7,   // T1
    0.85,  // T2
    1.0,   // T3
    1.15,  // T4
    1.3    // T5
};

// ============================================================================
// Plugin Info
// ============================================================================
public Plugin myinfo = {
    name        = "Pressure Tracker",
    author      = "Claude",
    description = "Global pressure tracking system with tier-based difficulty adjustment",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
// OnPluginStart
// ============================================================================
public void OnPluginStart()
{
    // Published cvars (read by other plugins)
    g_cvPressureValue = CreateConVar("sm_pressure_value", "40",
        "Current global pressure value (20-100)", FCVAR_NOTIFY);
    g_cvPressureTier = CreateConVar("sm_pressure_tier", "2",
        "Current difficulty tier (1=Casual, 2=Standard, 3=Challenge, 4=Hard, 5=Hell)", FCVAR_NOTIFY);
    g_cvPressureAggression = CreateConVar("sm_pressure_aggression", "0.85",
        "AI aggression multiplier for current tier (0.7-1.3)", FCVAR_NOTIFY);

    // Configuration cvars
    g_cvEnable = CreateConVar("sm_pressure_enable", "1",
        "Enable pressure tracking system (0=off, 1=on)", _, true, 0.0, true, 1.0);
    g_cvAnnounce = CreateConVar("sm_pressure_announce", "1",
        "Announce tier changes in chat (0=off, 1=on)", _, true, 0.0, true, 1.0);

    // Pressure change rates (tightened from original design)
    g_cvPerfectWave = CreateConVar("sm_pressure_perfect_wave", "5",
        "Pressure gain for perfect wave (zero incaps/deaths)", _, true, 0.0, true, 50.0);
    g_cvFastClear = CreateConVar("sm_pressure_fast_clear", "3",
        "Pressure gain for fast clear (<25s)", _, true, 0.0, true, 50.0);
    g_cvPerfectStreak = CreateConVar("sm_pressure_perfect_streak", "8",
        "Bonus pressure for 5 consecutive perfect waves", _, true, 0.0, true, 50.0);
    g_cvIncapPenalty = CreateConVar("sm_pressure_incap_penalty", "4",
        "Pressure loss per incap", _, true, 0.0, true, 50.0);
    g_cvDeathPenalty = CreateConVar("sm_pressure_death_penalty", "8",
        "Pressure loss per death", _, true, 0.0, true, 50.0);
    g_cvWipeReset = CreateConVar("sm_pressure_wipe_reset", "30",
        "Pressure value after team wipe", _, true, 20.0, true, 60.0);
    g_cvSlowClear = CreateConVar("sm_pressure_slow_clear", "3",
        "Pressure loss for slow clear (>60s)", _, true, 0.0, true, 50.0);
    g_cvDamageThreshold = CreateConVar("sm_pressure_damage_threshold", "200",
        "Damage threshold for pressure penalty", _, true, 50.0, true, 1000.0);
    g_cvDamagePenalty = CreateConVar("sm_pressure_damage_penalty", "2",
        "Pressure loss when damage exceeds threshold", _, true, 0.0, true, 50.0);
    g_cvDecayPerWave = CreateConVar("sm_pressure_decay_per_wave", "1",
        "Natural pressure decay per wave", _, true, 0.0, true, 10.0);

    AutoExecConfig(true, "pressure_tracker");

    // Event hooks
    HookEvent("player_incapacitated", Event_PlayerIncapacitated);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("player_hurt", Event_PlayerHurt);

    // Initialize published cvars
    UpdatePublishedCvars();
}

// ============================================================================
// Public API: Called by specialspawner when wave starts
// ============================================================================
public void OnWaveStarted()
{
    if (!g_cvEnable.BoolValue)
        return;

    g_bWaveActive = true;
    g_fWaveStartTime = GetGameTime();
    g_iWaveDamage = 0;
    g_iWaveIncaps = 0;
    g_iWaveDeaths = 0;
}

// ============================================================================
// Public API: Called by specialspawner when wave clears
// ============================================================================
public void OnWaveCleared()
{
    if (!g_cvEnable.BoolValue || !g_bWaveActive)
        return;

    g_bWaveActive = false;
    g_iWaveCount++;

    float clearTime = GetGameTime() - g_fWaveStartTime;

    // Calculate pressure change
    int pressureChange = 0;

    // Check for team wipe first
    if (IsTeamWiped()) {
        g_iGlobalPressure = g_cvWipeReset.IntValue;
        g_iPerfectStreakCount = 0;
        LogMessage("[Pressure] Team wipe! Reset to %d", g_iGlobalPressure);

        UpdateTierLogic();
        return;
    }

    // Perfect wave bonus
    bool isPerfect = (g_iWaveIncaps == 0 && g_iWaveDeaths == 0);
    if (isPerfect) {
        pressureChange += g_cvPerfectWave.IntValue;
        g_iPerfectStreakCount++;

        // Perfect streak bonus (every 5 waves)
        if (g_iPerfectStreakCount >= 5) {
            pressureChange += g_cvPerfectStreak.IntValue;
            g_iPerfectStreakCount = 0;
            LogMessage("[Pressure] Perfect streak bonus! +%d", g_cvPerfectStreak.IntValue);
        }
    }
    else {
        g_iPerfectStreakCount = 0;
    }

    // Fast clear bonus
    if (clearTime < 25.0) {
        pressureChange += g_cvFastClear.IntValue;
    }

    // Slow clear penalty
    if (clearTime > 60.0) {
        pressureChange -= g_cvSlowClear.IntValue;
    }

    // Incap penalty
    if (g_iWaveIncaps > 0) {
        pressureChange -= g_cvIncapPenalty.IntValue * g_iWaveIncaps;
    }

    // Death penalty
    if (g_iWaveDeaths > 0) {
        pressureChange -= g_cvDeathPenalty.IntValue * g_iWaveDeaths;
    }

    // Damage penalty
    if (g_iWaveDamage > g_cvDamageThreshold.IntValue) {
        pressureChange -= g_cvDamagePenalty.IntValue;
    }

    // Natural decay
    pressureChange -= g_cvDecayPerWave.IntValue;

    // Apply change
    g_iGlobalPressure += pressureChange;
    g_iGlobalPressure = ClampPressure(g_iGlobalPressure);

    LogMessage("[Pressure] Wave #%d cleared in %.1fs | Incaps: %d, Deaths: %d, Damage: %d | Change: %+d | Pressure: %d",
        g_iWaveCount, clearTime, g_iWaveIncaps, g_iWaveDeaths, g_iWaveDamage, pressureChange, g_iGlobalPressure);

    // Update tier logic
    UpdateTierLogic();
}

// ============================================================================
// Tier Update Logic (with stabilization)
// ============================================================================
void UpdateTierLogic()
{
    int targetTier = CalculateTierFromPressure(g_iGlobalPressure);

    if (targetTier == g_iCurrentTier) {
        // Pressure within current tier, reset all counters
        for (int i = 1; i <= TIER_COUNT; i++) {
            g_iTierStableCount[i] = 0;
        }
        g_iPendingTier = g_iCurrentTier;
    }
    else if (targetTier == g_iPendingTier) {
        // Consecutive wave in pending tier
        g_iTierStableCount[targetTier]++;

        int requiredWaves = GetRequiredWavesForTier(g_iCurrentTier, targetTier);

        LogMessage("[Pressure] Tier transition progress: %d/%d waves towards T%d",
            g_iTierStableCount[targetTier], requiredWaves, targetTier);

        if (g_iTierStableCount[targetTier] >= requiredWaves) {
            // Transition confirmed
            SwitchToTier(targetTier);
            g_iTierStableCount[targetTier] = 0;
        }
    }
    else {
        // Pressure jumped to new pending tier, reset
        g_iPendingTier = targetTier;
        g_iTierStableCount[targetTier] = 1;

        LogMessage("[Pressure] New pending tier T%d (1 wave)", targetTier);
    }

    UpdatePublishedCvars();
}

// ============================================================================
// Calculate tier from pressure value
// ============================================================================
int CalculateTierFromPressure(int pressure)
{
    for (int tier = TIER_COUNT; tier >= 1; tier--) {
        if (pressure >= g_iTierBounds[tier][0]) {
            return tier;
        }
    }
    return TIER_CASUAL;
}

// ============================================================================
// Get required waves for tier transition
// ============================================================================
int GetRequiredWavesForTier(int fromTier, int toTier)
{
    if (toTier > fromTier) {
        // Heating: higher tiers require more waves
        switch (toTier) {
            case 2: return 3;  // T1->T2: 3 waves
            case 3: return 3;  // T2->T3: 3 waves
            case 4: return 4;  // T3->T4: 4 waves
            case 5: return 5;  // T4->T5: 5 waves (hardest)
        }
    }
    else {
        // Cooling: slightly faster but still requires adaptation
        switch (toTier) {
            case 4: return 3;  // T5->T4: 3 waves
            case 3: return 3;  // T4->T3: 3 waves
            case 2: return 3;  // T3->T2: 3 waves
            case 1: return 2;  // T2->T1: 2 waves
        }
    }
    return 3;  // Default
}

// ============================================================================
// Switch to new tier
// ============================================================================
void SwitchToTier(int newTier)
{
    int oldTier = g_iCurrentTier;
    g_iCurrentTier = newTier;

    LogMessage("[Pressure] Tier changed: T%d (%s) -> T%d (%s) | Pressure: %d",
        oldTier, g_sTierNames[oldTier], newTier, g_sTierNames[newTier], g_iGlobalPressure);

    // Announce to players
    if (g_cvAnnounce.BoolValue) {
        AnnounceTierChange(oldTier, newTier);
    }

    UpdatePublishedCvars();
}

// ============================================================================
// Announce tier change (chat only, no HUD)
// ============================================================================
void AnnounceTierChange(int oldTier, int newTier)
{
    if (newTier > oldTier) {
        // Heating announcements
        switch (newTier) {
            case 2: {
                PrintToChatAll("\x04[压力系统] \x05特感威胁正在上升，请保持警惕！");
            }
            case 3: {
                PrintToChatAll("\x04[压力系统] \x05检测到特感攻势增强，小心应对！");
            }
            case 4: {
                PrintToChatAll("\x04[压力系统] \x03警告：特感即将进入高强度攻势，务必小心！");
            }
            case 5: {
                PrintToChatAll("\x04[压力系统] \x07危险：特感进入狂暴状态，极度危险！");
            }
        }
    }
    else {
        // Cooling announcements
        switch (newTier) {
            case 4: {
                PrintToChatAll("\x04[压力系统] \x05特感攻势有所减弱，抓紧喘息！");
            }
            case 3: {
                PrintToChatAll("\x04[压力系统] \x05压力正在下降，稳住阵型！");
            }
            case 2: {
                PrintToChatAll("\x04[压力系统] \x05特感攻势明显减弱，抓紧整备！");
            }
            case 1: {
                PrintToChatAll("\x04[压力系统] \x05威胁已大幅降低，保持节奏推进！");
            }
        }
    }

    EmitSoundToAll("ui/beep_synthtone01.wav");
}

// ============================================================================
// Update published cvars (for other plugins to read)
// ============================================================================
void UpdatePublishedCvars()
{
    g_cvPressureValue.SetInt(g_iGlobalPressure);
    g_cvPressureTier.SetInt(g_iCurrentTier);
    g_cvPressureAggression.SetFloat(g_fTierAggression[g_iCurrentTier]);
}

// ============================================================================
// Event Handlers
// ============================================================================
public void Event_PlayerIncapacitated(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bWaveActive)
        return;

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && IsSurvivor(client)) {
        g_iWaveIncaps++;
    }
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bWaveActive)
        return;

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && IsSurvivor(client)) {
        g_iWaveDeaths++;
    }
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bWaveActive)
        return;

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && IsSurvivor(client)) {
        int damage = event.GetInt("dmg_health");
        g_iWaveDamage += damage;
    }
}

// ============================================================================
// Helper Functions
// ============================================================================
bool IsSurvivor(int client)
{
    return IsClientInGame(client) && GetClientTeam(client) == 2;
}

bool IsTeamWiped()
{
    for (int i = 1; i <= MaxClients; i++) {
        if (IsSurvivor(i) && IsPlayerAlive(i)) {
            return false;
        }
    }
    return true;
}

int ClampPressure(int value)
{
    if (value < PRESSURE_MIN)
        return PRESSURE_MIN;
    if (value > PRESSURE_MAX)
        return PRESSURE_MAX;
    return value;
}

// ============================================================================
// Map transition handlers
// ============================================================================
public void OnMapEnd()
{
    // Decay pressure by 20% on map change
    g_iGlobalPressure = RoundToNearest(g_iGlobalPressure * 0.8);
    g_iGlobalPressure = ClampPressure(g_iGlobalPressure);

    // Reset tier stabilization counters
    for (int i = 1; i <= TIER_COUNT; i++) {
        g_iTierStableCount[i] = 0;
    }

    LogMessage("[Pressure] Map end | Pressure decayed to %d", g_iGlobalPressure);
}
