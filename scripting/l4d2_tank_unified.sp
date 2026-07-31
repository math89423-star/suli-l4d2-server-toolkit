/**
 * [L4D2] Tank Unified v1.0.0
 *
 * Single plugin replacing:
 *   - l4d2_tank_core     (Tank/Witch HP scaling + spawn announcement)
 *   - l4d2_tank_ranking   (Tank death damage report)
 *   - l4d2_tank_hp_scaler (our HP scaler, never deployed)
 *
 * Features:
 *   1. Tank HP scaling  —  per-survivor multiplier
 *   2. Tank spawn announcement — chat / center text / both
 *   3. Tank death damage ranking — sorted by damage, with percentages
 *   4. Witch HP scaling  —  optional, per-survivor multiplier
 *
 * Display channels (no conflict with l4d2_si_hud):
 *   - Tank Unified uses PrintToChatAll (chat area) for ranking
 *   - l4d2_si_hud uses PrintCenterText (upper-center) for kill confirm / HP
 *
 * Dependencies: sourcemod + sdktools + sdkhooks
 * Pure server-side. No client files needed.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "1.0.0"
#define TANK_CLASS   8
#define TEAM_SPECTATOR 1
#define TEAM_SURVIVOR  2
#define TEAM_INFECTED  3

// ============================================================================
// ConVar handles
// ============================================================================

ConVar g_cvEnable;
ConVar g_cvHPPerSurvivor;
ConVar g_cvAnnounceType;
ConVar g_cvRankingCount;
ConVar g_cvWitchSwitch;
ConVar g_cvWitchHPPerSurvivor;

// ============================================================================
// Damage tracking
// ============================================================================

// g_iTankDamage[tank][attacker] = accumulated damage
int g_iTankDamage[MAXPLAYERS + 1][MAXPLAYERS + 1];
// Per-tank max HP snapshot (set on spawn, used on death for report)
int g_iTankMaxHP[MAXPLAYERS + 1];

// ============================================================================
// Plugin Info
// ============================================================================

public Plugin myinfo =
{
    name        = "[L4D2] Tank Unified",
    author      = "suli",
    description = "Tank HP scaling, spawn announcement, death damage ranking",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
// OnPluginStart
// ============================================================================

public void OnPluginStart()
{
    CreateConVar("sm_tank_unified_version", PLUGIN_VERSION,
        "Tank Unified version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    // ── Master switch ────────────────────────────────────
    g_cvEnable = CreateConVar("sm_tank_enable", "1",
        "Master switch (0=off, 1=on).", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // ── Tank HP ──────────────────────────────────────────
    g_cvHPPerSurvivor = CreateConVar("sm_tank_hp_per_survivor", "3000",
        "Tank HP per alive survivor. Total = survivors x this value.",
        FCVAR_NOTIFY, true, 500.0, true, 10000.0);

    // ── Announcement ─────────────────────────────────────
    g_cvAnnounceType = CreateConVar("sm_tank_announce_type", "3",
        "Tank spawn announcement: 0=off, 1=chat, 2=center text, 3=both.",
        FCVAR_NOTIFY, true, 0.0, true, 3.0);

    // ── Ranking ──────────────────────────────────────────
    g_cvRankingCount = CreateConVar("sm_tank_ranking_count", "5",
        "Number of players shown in Tank death damage ranking.",
        FCVAR_NOTIFY, true, 1.0, true, 20.0);

    // ── Witch HP (optional) ──────────────────────────────
    g_cvWitchSwitch = CreateConVar("sm_witch_hp_switch", "0",
        "Enable Witch HP scaling? 0=off (game default), 1=on.",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvWitchHPPerSurvivor = CreateConVar("sm_witch_hp_per_survivor", "200",
        "Witch HP per alive survivor (only when switch=1).",
        FCVAR_NOTIFY, true, 50.0, true, 1000.0);

    AutoExecConfig(true, "l4d2_tank_unified");

    // ── Events ───────────────────────────────────────────
    HookEvent("player_spawn",   Event_PlayerSpawn);
    HookEvent("player_hurt",    Event_PlayerHurt);
    HookEvent("player_death",   Event_PlayerDeath);
}

// ============================================================================
// OnMapEnd — reset damage tracking
// ============================================================================

public void OnMapEnd()
{
    ResetAllTankDamage();
}

// ============================================================================
// OnClientDisconnect
// ============================================================================

public void OnClientDisconnect(int client)
{
    // Clear damage dealt by this client to any tank
    for (int tank = 1; tank <= MaxClients; tank++)
        g_iTankDamage[tank][client] = 0;
    // Clear damage this client (as tank) received
    for (int i = 1; i <= MaxClients; i++)
        g_iTankDamage[client][i] = 0;
    g_iTankMaxHP[client] = 0;
}

// ============================================================================
// Event: player_spawn — Tank HP scaling + announcement
// ============================================================================

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue)
        return Plugin_Continue;

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return Plugin_Continue;
    if (GetClientTeam(client) != TEAM_INFECTED)
        return Plugin_Continue;
    if (GetEntProp(client, Prop_Send, "m_zombieClass") != TANK_CLASS)
        return Plugin_Continue;

    // Reset damage tracking for this tank
    for (int i = 1; i <= MaxClients; i++)
        g_iTankDamage[client][i] = 0;

    int survivors = AliveSurvivorCount();
    int hp = survivors * g_cvHPPerSurvivor.IntValue;
    if (hp < 1) hp = g_cvHPPerSurvivor.IntValue; // fallback

    // Snapshot for death report
    g_iTankMaxHP[client] = hp;

    // Delay HP set to let game fully init the Tank entity
    DataPack dp = new DataPack();
    dp.WriteCell(GetClientUserId(client));
    dp.WriteCell(hp);
    CreateTimer(0.1, Timer_SetTankHP, dp, TIMER_FLAG_NO_MAPCHANGE);

    // ── Spawn announcement ───────────────────────────────
    AnnounceTankSpawn(hp, survivors);

    return Plugin_Continue;
}

// ============================================================================
// Timer: set Tank HP after 0.1s delay
// ============================================================================

public Action Timer_SetTankHP(Handle timer, DataPack dp)
{
    dp.Reset();
    int userid = dp.ReadCell();
    int hp     = dp.ReadCell();
    delete dp;

    int tank = GetClientOfUserId(userid);
    if (tank < 1 || tank > MaxClients || !IsClientInGame(tank))
        return Plugin_Stop;
    if (!IsPlayerAlive(tank))
        return Plugin_Stop;

    SetEntProp(tank, Prop_Send, "m_iMaxHealth", hp);
    SetEntProp(tank, Prop_Send, "m_iHealth", hp);

    return Plugin_Stop;
}

// ============================================================================
// Tank spawn announcement
// ============================================================================

void AnnounceTankSpawn(int hp, int survivors)
{
    int atype = g_cvAnnounceType.IntValue;
    if (atype == 0)
        return;

    char msg[128];
    Format(msg, sizeof(msg),
        "\x04[Tank]\x01 HP: \x05%d\x01 (%d 人存活)", hp, survivors);

    if (atype & 1)  // chat
        PrintToChatAll(msg);

    if (atype & 2)  // center text
        PrintCenterTextAll(msg);
}

// ============================================================================
// Event: player_hurt — accumulate damage to Tank
// ============================================================================

public Action Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue)
        return Plugin_Continue;

    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim < 1 || victim > MaxClients || !IsClientInGame(victim))
        return Plugin_Continue;
    if (GetClientTeam(victim) != TEAM_INFECTED)
        return Plugin_Continue;
    if (GetEntProp(victim, Prop_Send, "m_zombieClass") != TANK_CLASS)
        return Plugin_Continue;

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
        return Plugin_Continue;
    if (GetClientTeam(attacker) != TEAM_SURVIVOR)
        return Plugin_Continue;

    int dmg = event.GetInt("dmg_health");
    if (dmg > 0)
        g_iTankDamage[victim][attacker] += dmg;

    return Plugin_Continue;
}

// ============================================================================
// Event: player_death — Tank death damage ranking
// ============================================================================

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue)
        return Plugin_Continue;

    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim < 1 || victim > MaxClients || !IsClientInGame(victim))
        return Plugin_Continue;
    if (GetClientTeam(victim) != TEAM_INFECTED)
        return Plugin_Continue;
    if (GetEntProp(victim, Prop_Send, "m_zombieClass") != TANK_CLASS)
        return Plugin_Continue;

    ReportTankDamage(victim);
    return Plugin_Continue;
}

// ============================================================================
// Tank death damage report (PrintToChatAll only — PrintCenterText is reserved
// for l4d2_si_hud kill confirm)
// ============================================================================

void ReportTankDamage(int tank)
{
    int maxHp = g_iTankMaxHP[tank];
    if (maxHp <= 0)
    {
        // Fallback: read the entity's max health we set on spawn
        maxHp = GetEntProp(tank, Prop_Data, "m_iMaxHealth");
    }
    // If still 0 or negative, fall back to our ConVar × survivors
    if (maxHp <= 0)
    {
        maxHp = AliveSurvivorCount() * g_cvHPPerSurvivor.IntValue;
    }
    if (maxHp <= 0) maxHp = 1;

    // ── Collect attacker data ────────────────────────────
    int count;
    int attackers[MAXPLAYERS + 1];
    int damages[MAXPLAYERS + 1];
    char names[MAXPLAYERS + 1][64];

    int totalDmg;
    for (int i = 1; i <= MaxClients; i++)
    {
        int dmg = g_iTankDamage[tank][i];
        if (dmg > 0)
        {
            attackers[count] = i;
            damages[count]  = dmg;
            GetClientName(i, names[count], 64);
            totalDmg += dmg;
            count++;
        }
    }

    // ── Sort by damage descending (bubble, small N) ──────
    for (int i = 0; i < count - 1; i++)
    {
        for (int j = i + 1; j < count; j++)
        {
            if (damages[j] > damages[i])
            {
                int tmpAtk = attackers[i];
                attackers[i] = attackers[j];
                attackers[j] = tmpAtk;
                int tmpDmg = damages[i];
                damages[i]  = damages[j];
                damages[j]  = tmpDmg;
                char tmpName[64];
                strcopy(tmpName, 64, names[i]);
                strcopy(names[i], 64, names[j]);
                strcopy(names[j], 64, tmpName);
            }
        }
    }

    if (totalDmg <= 0) totalDmg = 1;

    // ── Print header ─────────────────────────────────────
    PrintToChatAll("\x04[Tank伤害]\x01 坦克死亡，总血量: \x05%d\x01 HP", maxHp);

    // ── Print ranking ────────────────────────────────────
    int maxRank = g_cvRankingCount.IntValue;
    for (int i = 0; i < count && i < maxRank; i++)
    {
        char rankLabel[8];
        switch (i)
        {
            case 0: rankLabel = "1st";
            case 1: rankLabel = "2nd";
            case 2: rankLabel = "3rd";
            default: Format(rankLabel, sizeof(rankLabel), "%dth", i + 1);
        }

        float pct = float(damages[i]) / float(totalDmg) * 100.0;

        PrintToChatAll("  [\x03%s\x01] \x04%s\x01 — \x05%d\x01 伤害 (\x04%.1f%%\x01)",
            rankLabel, names[i], damages[i], pct);
    }

    // ── Clean up this tank's damage data ─────────────────
    for (int i = 1; i <= MaxClients; i++)
        g_iTankDamage[tank][i] = 0;
    g_iTankMaxHP[tank] = 0;
}

// ============================================================================
// OnEntityCreated — Witch HP scaling (timer-based, no hook needed)
// ============================================================================

public void OnEntityCreated(int entity, const char[] classname)
{
    if (!g_cvEnable.BoolValue || !g_cvWitchSwitch.BoolValue)
        return;
    if (StrContains(classname, "witch") == -1)
        return;

    // Delay HP set to let game fully init the Witch entity.
    // Timer-based approach avoids the stale-array bug of OnTakeDamage tracking.
    CreateTimer(0.5, Timer_SetWitchHP, EntIndexToEntRef(entity), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_SetWitchHP(Handle timer, int ref)
{
    int witch = EntRefToEntIndex(ref);
    if (witch == INVALID_ENT_REFERENCE || !IsValidEntity(witch))
        return Plugin_Stop;

    int survivors = AliveSurvivorCount();
    int hp = survivors * g_cvWitchHPPerSurvivor.IntValue;
    if (hp < 1) hp = g_cvWitchHPPerSurvivor.IntValue;

    SetEntProp(witch, Prop_Data, "m_iMaxHealth", hp);
    SetEntProp(witch, Prop_Data, "m_iHealth", hp);

    return Plugin_Stop;
}

// ============================================================================
// Helpers
// ============================================================================

int AliveSurvivorCount()
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
            count++;
    }
    return count;
}

void ResetAllTankDamage()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_iTankMaxHP[i] = 0;
        for (int j = 1; j <= MaxClients; j++)
            g_iTankDamage[i][j] = 0;
    }
}
