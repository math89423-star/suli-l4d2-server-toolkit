#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#pragma semicolon 1
#pragma newdecls required

#define TANK_CLASS 8
#define MAX_RANK_DISPLAY 10
#define CHAT_PREFIX "\x04[Tank伤害]\x01"

ConVar g_cvRankCount;
int g_iTankHealth[MAXPLAYERS + 1];       // max HP when tank spawned
int g_iTankDamage[MAXPLAYERS + 1][MAXPLAYERS + 1];  // [tank][attacker] = damage dealt
int g_iTankTotalMaxHP[MAXPLAYERS + 1];  // total agreed-upon max HP (for total display)

public Plugin myinfo = {
    name = "l4d2_tank_ranking",
    author = "claude",
    description = "Accurate tank damage ranking using SDKHooks (includes fire/env damage)",
    version = "2.0",
    url = ""
};

public void OnPluginStart()
{
    g_cvRankCount = CreateConVar("l4d2_tank_ranking", "5", "Number of players to show in tank damage ranking");
    HookEvent("tank_spawn", Event_TankSpawn);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
    HookEvent("map_transition", Event_RoundEnd, EventHookMode_PostNoCopy);
    AutoExecConfig(true, "l4d2_tank_ranking");
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int tank = GetClientOfUserId(event.GetInt("userid"));
    if (tank <= 0 || !IsClientInGame(tank)) return;

    // Reset damage tracking for this tank
    int tankHP = GetEntProp(tank, Prop_Send, "m_iMaxHealth");
    g_iTankHealth[tank] = tankHP;
    g_iTankTotalMaxHP[tank] = tankHP;
    for (int i = 1; i <= MaxClients; i++)
        g_iTankDamage[tank][i] = 0;
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim <= 0 || !IsClientInGame(victim)) return;

    // Only handle tank deaths
    if (GetClientTeam(victim) != 3) return;
    if (GetEntProp(victim, Prop_Send, "m_zombieClass") != TANK_CLASS) return;

    DisplayRanking(victim);
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    // Clean up
    for (int i = 1; i <= MaxClients; i++)
    {
        g_iTankHealth[i] = 0;
        g_iTankTotalMaxHP[i] = 0;
        for (int j = 1; j <= MaxClients; j++)
            g_iTankDamage[i][j] = 0;
    }
}

// SDKHooks captures ALL damage types: bullets, melee, fire, explosions, etc.
public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3], int damagecustom)
{
    // Only track damage TO tanks
    if (victim < 1 || victim > MaxClients || !IsClientInGame(victim)) return Plugin_Continue;
    if (GetClientTeam(victim) != 3) return Plugin_Continue;
    if (GetEntProp(victim, Prop_Send, "m_zombieClass") != TANK_CLASS) return Plugin_Continue;

    // Determine the actual attacker (handle fire/env damage attribution)
    int realAttacker = attacker;
    if (realAttacker < 1 || realAttacker > MaxClients || !IsClientInGame(realAttacker))
    {
        // Try to find the owner of the inflictor (e.g., molotov → thrower)
        if (inflictor > 0 && IsValidEntity(inflictor))
        {
            realAttacker = GetEntPropEnt(inflictor, Prop_Send, "m_hOwnerEntity");
        }
    }

    if (realAttacker < 1 || realAttacker > MaxClients || !IsClientInGame(realAttacker))
        return Plugin_Continue;
    if (GetClientTeam(realAttacker) != 2)
        return Plugin_Continue;

    int dmg = RoundToCeil(damage);
    if (dmg <= 0) return Plugin_Continue;

    g_iTankDamage[victim][realAttacker] += dmg;

    return Plugin_Continue;
}

void DisplayRanking(int tank)
{
    // Use actual spawned max HP (not announce value which may be inflated)
    int maxHP = g_iTankTotalMaxHP[tank];
    if (maxHP <= 0)
        maxHP = GetEntProp(tank, Prop_Send, "m_iMaxHealth");
    int totalTracked = 0;

    // Build sorted player list
    int players[MAXPLAYERS + 1];
    int damages[MAXPLAYERS + 1];
    int count = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        int dmg = g_iTankDamage[tank][i];
        if (dmg > 0)
        {
            players[count] = i;
            damages[count] = dmg;
            count++;
            totalTracked += dmg;
        }
    }

    // Bubble sort descending
    for (int i = 0; i < count - 1; i++)
    {
        for (int j = i + 1; j < count; j++)
        {
            if (damages[j] > damages[i])
            {
                int tmp = damages[i]; damages[i] = damages[j]; damages[j] = tmp;
                tmp = players[i]; players[i] = players[j]; players[j] = tmp;
            }
        }
    }

    // Announce
    PrintToChatAll("%s 坦克死亡，总血量: \x05%d\x01 HP", CHAT_PREFIX, maxHP);

    int show = g_cvRankCount.IntValue;
    if (show > count) show = count;
    if (show > MAX_RANK_DISPLAY) show = MAX_RANK_DISPLAY;

    for (int i = 0; i < show; i++)
    {
        int client = players[i];
        float pct = (float(damages[i]) / float(maxHP)) * 100.0;
        char nameBuf[64];
        GetClientName(client, nameBuf, sizeof(nameBuf));

        // Medal marker
        char medal[12];
        if (i == 0) medal = "[1st]";
        else if (i == 1) medal = "[2nd]";
        else if (i == 2) medal = "[3rd]";
        else FormatEx(medal, sizeof(medal), "#%d", i + 1);

        PrintToChatAll("  %s \x03%s\x01 — \x04%d\x01 伤害 (\x05%.1f%%\x01)", medal, nameBuf, damages[i], pct);
    }

    // Summary
    if (count == 0)
    {
        PrintToChatAll("  无人造成伤害（环境击杀？）");
    }
    else if (totalTracked < maxHP)
    {
        int untracked = maxHP - totalTracked;
        float trackedPct = (float(totalTracked) / float(maxHP)) * 100.0;
        PrintToChatAll("  [总计] 玩家伤害合计: \x04%d\x01 / \x05%d\x01 (\x03%.1f%%\x01) | 未追踪: \x07%d\x01 HP",
                       totalTracked, maxHP, trackedPct, untracked);
    }

    // Clean up
    g_iTankHealth[tank] = 0;
    g_iTankTotalMaxHP[tank] = 0;
    for (int i = 1; i <= MaxClients; i++)
        g_iTankDamage[tank][i] = 0;
}
