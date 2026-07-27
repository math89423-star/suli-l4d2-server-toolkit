#include <sourcemod>
#include <sdktools>

#define TANK_CLASS 8
#define ZOMBIE_TEAM 3

public Plugin myinfo = {
    name = "Tank HP Scaler",
    author = "claude",
    description = "Scale tank HP based on alive survivor count",
    version = "1.1",
    url = ""
};

ConVar g_cvHPPerSurvivor;

public void OnPluginStart()
{
    g_cvHPPerSurvivor = CreateConVar("sm_tank_hp_per_survivor", "3000", "Tank HP per alive survivor");
    HookEvent("player_spawn", Event_PlayerSpawn);
    AutoExecConfig(true, "l4d2_tank_hp_scaler");
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
        return;

    // Only care about infected team
    if (GetClientTeam(client) != ZOMBIE_TEAM)
        return;

    // Only care about Tanks
    if (GetEntProp(client, Prop_Send, "m_zombieClass") != TANK_CLASS)
        return;

    // Update announce cvars IMMEDIATELY so Tank Announcer reads them
    int survivors = AliveSurvivorCount();
    int hp = survivors * g_cvHPPerSurvivor.IntValue;
    SyncAnnounceCvars(hp);

    // Delay HP set by 0.1s to let the game fully init the Tank
    CreateTimer(0.1, Timer_SetTankHP, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_SetTankHP(Handle timer, int userid)
{
    int tank = GetClientOfUserId(userid);
    if (tank <= 0 || tank > MaxClients || !IsClientInGame(tank))
        return Plugin_Stop;

    if (!IsPlayerAlive(tank))
        return Plugin_Stop;

    int survivors = AliveSurvivorCount();
    int hp = survivors * g_cvHPPerSurvivor.IntValue;

    SetEntProp(tank, Prop_Send, "m_iMaxHealth", hp);
    SetEntProp(tank, Prop_Send, "m_iHealth", hp);

    if (!IsPlayerAlive(tank))
        return Plugin_Stop;

    return Plugin_Stop;
}

void SyncAnnounceCvars(int hp)
{
    // Tank Announcer uses l4d2_tank_minimum as the base displayed value
    // Set it to actual HP so announcement shows correct number
    ConVar hMin = FindConVar("l4d2_tank_minimum");
    if (hMin != null)
        hMin.IntValue = hp;
}

int AliveSurvivorCount()
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i))
            count++;
    }
    return count;
}
