#include <sourcemod>
#include <sdktools>

#define TANK_CLASS 8
#define ZOMBIE_TEAM 3

public Plugin myinfo = {
    name = "Tank HP Scaler",
    author = "claude",
    description = "Scale tank HP based on alive survivor count",
    version = "1.3",
    url = ""
};

ConVar g_cvHPPerSurvivor;

public void OnPluginStart()
{
    g_cvHPPerSurvivor = CreateConVar("sm_tank_hp_per_survivor", "3000", "Tank HP per alive survivor");
    // Pre-hook tank_spawn: update announce cvars BEFORE l4d2_tank_announce reads them
    HookEvent("tank_spawn",   Event_TankSpawn,   EventHookMode_Pre);
    HookEvent("player_spawn", Event_PlayerSpawn);
    AutoExecConfig(true, "l4d2_tank_hp_scaler");
}

// Pre-hook on tank_spawn — fires before tank_announce plugin reads l4d2_tank_minimum
// This ensures the announcement shows the correct (survivors * 3000) value
public void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int survivors = AliveSurvivorCount();
    int hp = survivors * g_cvHPPerSurvivor.IntValue;
    SyncAnnounceCvars(hp);
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

    // Update announce cvars (fallback — tank_spawn pre-hook covers the normal path)
    int survivors = AliveSurvivorCount();
    int hp = survivors * g_cvHPPerSurvivor.IntValue;
    SyncAnnounceCvars(hp);

    // Delay HP set — 0.3s ensures we fire AFTER tank_announce plugin finishes its own HP logic
    CreateTimer(0.3, Timer_SetTankHP, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    // Retry at 1.0s in case first attempt was too early (tank not fully spawned)
    CreateTimer(1.0, Timer_SetTankHP_Retry, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_SetTankHP(Handle timer, int userid)
{
    SetTankHP(userid);
    return Plugin_Stop;
}

public Action Timer_SetTankHP_Retry(Handle timer, int userid)
{
    int tank = GetClientOfUserId(userid);
    if (tank <= 0 || tank > MaxClients || !IsClientInGame(tank) || !IsPlayerAlive(tank))
        return Plugin_Stop;

    // Only retry if HP wasn't set correctly the first time
    int expectedHP = AliveSurvivorCount() * g_cvHPPerSurvivor.IntValue;
    int currentHP = GetEntProp(tank, Prop_Send, "m_iMaxHealth");
    if (currentHP != expectedHP)
        SetTankHP(userid);

    return Plugin_Stop;
}

void SetTankHP(int userid)
{
    int tank = GetClientOfUserId(userid);
    if (tank <= 0 || tank > MaxClients || !IsClientInGame(tank))
        return;

    if (!IsPlayerAlive(tank))
        return;

    int survivors = AliveSurvivorCount();
    int hp = survivors * g_cvHPPerSurvivor.IntValue;

    SetEntProp(tank, Prop_Send, "m_iMaxHealth", hp);
    SetEntProp(tank, Prop_Send, "m_iHealth", hp);

    // Re-sync announce after actually setting HP
    SyncAnnounceCvars(hp);
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
