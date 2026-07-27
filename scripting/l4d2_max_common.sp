/**
 * l4d2_max_common.sp
 *
 * Safely limits common infected with AI Director-friendly
 * leniency and timer system. Based on ball2hi's Max Common design.
 *
 * Features:
 * - Entity-based counting via FindEntityByClassname("infected")
 *   (common infected are server entities, NOT clients — iterating MaxClients
 *   fails because fake clients are special infected / survivor bots only)
 * - Dynamic z_common_limit scaling by player count
 *   (base 30 @ 4p, +6/player, cap 120 — configurable via cvars)
 * - Respects z_common_limit (hot-reloadable via sm_cvar)
 * - Leniency: allows +N extra commons before triggering cleanup
 * - Timer: waits N seconds after threshold exceeded before starting deletion
 * - Cooldown: stops cleanup after N seconds of no excess detected
 * - sm_common_limit / sm_common_count: prints current stats + player count
 * - Kills furthest-from-survivors commons first to minimize visual impact
 *
 * v1.3 — 2026-07-27 (dynamic player-count scaling)
 * v1.2 — 2026-07-24 (fixed counting: common infected are entities, not clients)
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.3"

ConVar g_hEnabled;
ConVar g_hLeniency;
ConVar g_hTimerDelay;
ConVar g_hCooldownTime;

ConVar g_hCommonLimit;      // game cvar z_common_limit

// Dynamic scaling convars
ConVar g_hBaseCount;        // base common count at 4 players
ConVar g_hExtraPerPlayer;   // extra commons per additional player
ConVar g_hCap;              // hard cap

// State
float g_fOverThresholdSince;  // game time when count first exceeded threshold
float g_fLastDeleteTime;      // game time of last deletion
bool  g_bInCleanup;           // currently in cleanup (deleting) mode

public Plugin myinfo =
{
    name        = "L4D2 Max Common",
    author      = "based on ball2hi's Max Common design",
    description = "Dynamic common infected limiter with player-count scaling",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    CreateConVar("l4d2_max_common_version", PLUGIN_VERSION,
        "Max Common plugin version", FCVAR_DONTRECORD|FCVAR_NOTIFY);

    g_hEnabled      = CreateConVar("sm_max_common_enabled",  "1",
        "Enable/disable common limiter (1=on, 0=off)");
    g_hLeniency     = CreateConVar("sm_max_common_leniency", "5",
        "Extra commons allowed above z_common_limit before cleanup");
    g_hTimerDelay   = CreateConVar("sm_max_common_timer",    "3.0",
        "Seconds to wait before deleting after threshold exceeded");
    g_hCooldownTime = CreateConVar("sm_max_common_cooldown", "5.0",
        "Seconds of no deletions before exiting cleanup mode");

    // Dynamic player-count scaling
    g_hBaseCount      = CreateConVar("sm_max_common_base",  "30",
        "Base z_common_limit when 4 players are present");
    g_hExtraPerPlayer = CreateConVar("sm_max_common_extra", "6",
        "Extra commons per player above 4");
    g_hCap            = CreateConVar("sm_max_common_cap",   "120",
        "Hard cap for z_common_limit");

    g_hCommonLimit = FindConVar("z_common_limit");
    if (g_hCommonLimit == null)
        LogError("[MaxCommon] z_common_limit convar not found!");

    RegAdminCmd("sm_common_limit", Cmd_CommonLimit, ADMFLAG_KICK,
        "Show current common infected count and limit");
    RegAdminCmd("sm_common_count", Cmd_CommonLimit, ADMFLAG_KICK,
        "Show current common infected count and limit");

    // Main loop: check every second (update dynamic limit + cleanup)
    CreateTimer(1.0, Timer_CheckCommons, _, TIMER_REPEAT);

    AutoExecConfig(true, "l4d2_max_common");
}

public void OnMapStart()
{
    g_fOverThresholdSince = 0.0;
    g_fLastDeleteTime = 0.0;
    g_bInCleanup = false;
}

// --- Dynamic limit scaling ---

stock int CountRealPlayers()
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
            count++;
    }
    return count;
}

stock int CalculateCommonLimit(int players)
{
    int base  = g_hBaseCount.IntValue;
    int extra = g_hExtraPerPlayer.IntValue;
    int cap   = g_hCap.IntValue;

    int limit = base;
    if (players > 4)
        limit = base + (players - 4) * extra;
    if (limit > cap)
        limit = cap;
    if (limit < base)
        limit = base;

    return limit;
}

stock void UpdateCommonLimit()
{
    if (g_hCommonLimit == null)
        return;

    int players    = CountRealPlayers();
    int newLimit   = CalculateCommonLimit(players);
    int oldLimit   = g_hCommonLimit.IntValue;

    if (newLimit != oldLimit)
    {
        g_hCommonLimit.IntValue = newLimit;
        LogMessage("[MaxCommon] Players: %d → z_common_limit: %d (was %d)",
            players, newLimit, oldLimit);
    }
}

// --- Main check loop ---

Action Timer_CheckCommons(Handle timer)
{
    if (!g_hEnabled.BoolValue || g_hCommonLimit == null)
        return Plugin_Continue;

    // Update dynamic limit every tick (player count may have changed)
    UpdateCommonLimit();

    int   limit        = g_hCommonLimit.IntValue;
    int   leniency     = g_hLeniency.IntValue;
    float timerDelay   = g_hTimerDelay.FloatValue;
    float cooldownTime = g_hCooldownTime.FloatValue;
    float now          = GetGameTime();

    int threshold = limit + leniency;
    int actualCount = CountCommonInfected();

    if (actualCount > threshold)
    {
        // First time over threshold this "session"
        if (g_fOverThresholdSince == 0.0)
            g_fOverThresholdSince = now;

        // Has the timer delay elapsed?
        if (now - g_fOverThresholdSince >= timerDelay)
        {
            g_bInCleanup = true;
        }

        if (g_bInCleanup)
        {
            // Delete down TO limit (not threshold — we kill all excess)
            int toKill = actualCount - limit;
            if (toKill > 0)
            {
                KillExcessCommons(toKill);
                g_fLastDeleteTime = now;
            }
        }
    }
    else
    {
        // Count is below threshold — reset the "over threshold" timer
        g_fOverThresholdSince = 0.0;

        // If in cleanup but no recent deletions, exit cleanup mode
        if (g_bInCleanup && (now - g_fLastDeleteTime) >= cooldownTime)
        {
            g_bInCleanup = false;
        }
    }

    return Plugin_Continue;
}

// --- Counting ---

stock int CountCommonInfected()
{
    int count = 0;
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "infected")) != -1)
        count++;
    return count;
}

// --- Deletion ---

stock void KillExcessCommons(int toKill)
{
    // Collect all common infected entity indices and their dist to nearest survivor
    int  ents[256];   // up to 256 common infected tracked
    float dists[256];
    int  num = 0;

    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "infected")) != -1 && num < 256)
    {
        float pos[3];
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);

        // Find nearest survivor
        float minDist = 999999.0;
        for (int j = 1; j <= MaxClients; j++)
        {
            if (!IsClientInGame(j) || IsFakeClient(j))
                continue;
            if (GetClientTeam(j) != 2)
                continue;

            float sp[3];
            GetClientAbsOrigin(j, sp);
            float d = GetVectorDistance(pos, sp);
            if (d < minDist) minDist = d;
        }

        ents[num]  = EntIndexToEntRef(ent);
        dists[num] = minDist;
        num++;
    }

    // Sort by distance descending (furthest first)
    for (int a = 0; a < num - 1; a++)
    {
        for (int b = 0; b < num - a - 1; b++)
        {
            if (dists[b] < dists[b + 1])
            {
                float td = dists[b]; dists[b] = dists[b + 1]; dists[b + 1] = td;
                int   te = ents[b];  ents[b]  = ents[b + 1];  ents[b + 1]  = te;
            }
        }
    }

    int killed = 0;
    for (int i = 0; i < num && killed < toKill; i++)
    {
        int e = EntRefToEntIndex(ents[i]);
        if (e != -1 && IsValidEntity(e))
        {
            AcceptEntityInput(e, "Kill");
            killed++;
        }
    }
}

// --- Admin command ---

Action Cmd_CommonLimit(int client, int args)
{
    int limit      = (g_hCommonLimit != null) ? g_hCommonLimit.IntValue : -1;
    int leniency   = g_hLeniency.IntValue;
    int count      = CountCommonInfected();
    int threshold  = limit + leniency;
    int players    = CountRealPlayers();
    int base       = g_hBaseCount.IntValue;
    int extra      = g_hExtraPerPlayer.IntValue;
    int cap        = g_hCap.IntValue;
    int extraP     = (players > 4) ? (players - 4) : 0;

    char dynamicInfo[128];
    Format(dynamicInfo, sizeof(dynamicInfo),
        "%d base + %d×%d extra (cap %d)", base, extraP, extra, cap);

    ReplyToCommand(client,
        "[MaxCommon] Commons: %d  |  z_common_limit: %d  |  Threshold: %d (+%d)  |  Players: %d  |  Formula: %s  |  Cleanup: %s  |  Enabled: %s",
        count, limit, threshold, leniency, players, dynamicInfo,
        g_bInCleanup ? "ACTIVE" : "idle",
        g_hEnabled.BoolValue ? "YES" : "NO");

    if (client > 0)
    {
        PrintToChat(client,
            "\x04[MaxCommon]\x01 %d commons | limit \x05%d\x01 (+%d) | \x05%d\x01 players | formula \x05%d + %dx%d\x01 | cleanup \x05%s",
            count, limit, leniency, players, base, extraP, extra,
            g_bInCleanup ? "ON" : "off");
    }

    return Plugin_Handled;
}
