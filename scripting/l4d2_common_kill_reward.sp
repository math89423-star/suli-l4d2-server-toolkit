#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>

#define PLUGIN_VERSION "1.0"

ConVar g_hCvarEnable;
ConVar g_hCvarThreshold;
ConVar g_hCvarHPAmount;
ConVar g_hCvarMaxHP;

int g_iCommonKills[MAXPLAYERS+1];

public Plugin myinfo =
{
    name        = "[L4D2] Common Kill Reward",
    author      = "suli",
    description = "Reward HP for killing common infected, cumulative per survivor.",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    g_hCvarEnable    = CreateConVar("l4d2_common_kill_reward_enable", "1",
        "0=OFF, 1=ON.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hCvarThreshold = CreateConVar("l4d2_common_kill_reward_threshold", "20",
        "Common infected kills required per HP reward.", FCVAR_NOTIFY, true, 1.0, true, 1000.0);

    g_hCvarHPAmount  = CreateConVar("l4d2_common_kill_reward_hp", "2",
        "HP rewarded each time threshold is reached.", FCVAR_NOTIFY, true, 1.0, true, 100.0);

    g_hCvarMaxHP     = CreateConVar("l4d2_common_kill_reward_max", "100",
        "Maximum permanent HP after reward (won't heal past this).", FCVAR_NOTIFY, true, 1.0, true, 9999.0);

    AutoExecConfig(true, "l4d2_common_kill_reward");

    HookEvent("infected_death",  Event_InfectedDeath);
    HookEvent("round_start",    Event_RoundStart);
    HookEvent("map_transition", Event_RoundStart);
}

public void OnClientDisconnect(int client)
{
    g_iCommonKills[client] = 0;
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
        g_iCommonKills[i] = 0;
}

void Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_hCvarEnable.BoolValue) return;

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
        return;
    if (GetClientTeam(attacker) != 2)
        return;
    if (!IsPlayerAlive(attacker))
        return;

    int threshold = g_hCvarThreshold.IntValue;
    int hpAmount  = g_hCvarHPAmount.IntValue;
    int maxHP     = g_hCvarMaxHP.IntValue;

    g_iCommonKills[attacker]++;

    if (g_iCommonKills[attacker] >= threshold)
    {
        g_iCommonKills[attacker] = 0;

        int curHP = GetClientHealth(attacker);
        if (curHP >= maxHP) return;

        int newHP = curHP + hpAmount;
        if (newHP > maxHP) newHP = maxHP;

        SetEntProp(attacker, Prop_Send, "m_iHealth", newHP);

        PrintToChat(attacker, "\x04[奖励]\x01 击杀 %d 只普通感染者，恢复 %d HP！", threshold, hpAmount);
    }
}
