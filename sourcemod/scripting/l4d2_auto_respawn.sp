#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#pragma semicolon 1
#pragma newdecls required

ConVar g_cvRespawnTime;

public Plugin myinfo = {
    name = "Auto Respawn with Countdown",
    author = "claude",
    description = "Auto respawn dead survivors with countdown notifications",
    version = "2.1",
    url = ""
};

public void OnPluginStart()
{
    g_cvRespawnTime = CreateConVar("sm_respawn_delay", "180", "Seconds before auto respawn (default 180 = 3 min)", _, true, 10.0);
    AutoExecConfig(true, "l4d2_auto_respawn");
    HookEvent("player_death", Event_PlayerDeath);
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || !IsClientInGame(client) || GetClientTeam(client) != 2)
        return;

    float delay = g_cvRespawnTime.FloatValue;
    int userid = GetClientUserId(client);

    PrintToChat(client, "\x04[复活]\x01 你已死亡，将在 \x03%.0f 秒\x01 后自动复活", delay);

    CreateTimer(delay, Timer_Respawn, userid);

    int thresholds[] = {120, 60, 30, 10, 5, 4, 3, 2, 1};
    for (int i = 0; i < sizeof(thresholds); i++)
    {
        if (delay > float(thresholds[i]))
        {
            DataPack dp = new DataPack();
            dp.WriteCell(userid);
            dp.WriteCell(thresholds[i]);
            CreateTimer(delay - float(thresholds[i]), Timer_NotifyCountdown, dp);
        }
    }
}

Action Timer_NotifyCountdown(Handle timer, DataPack dp)
{
    dp.Reset();
    int userid = dp.ReadCell();
    int seconds = dp.ReadCell();
    delete dp;

    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client) || IsPlayerAlive(client))
        return Plugin_Continue;

    PrintHintText(client, "复活倒计时: %d 秒", seconds);
    if (seconds <= 10)
        PrintToChat(client, "\x04[复活]\x01 你将在 \x03%d 秒\x01 后复活", seconds);

    return Plugin_Continue;
}

Action Timer_Respawn(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client) || GetClientTeam(client) != 2 || IsPlayerAlive(client))
        return Plugin_Continue;

    L4D_RespawnPlayer(client);
    CreateTimer(0.5, Timer_TeleportToTeammate, userid);

    return Plugin_Continue;
}

Action Timer_TeleportToTeammate(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client) || !IsPlayerAlive(client))
        return Plugin_Continue;

    // Find a living teammate to teleport to
    float origin[3];
    bool found = false;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (i != client && IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i))
        {
            GetClientAbsOrigin(i, origin);
            found = true;
            break;
        }
    }

    if (found)
    {
        TeleportEntity(client, origin, NULL_VECTOR, NULL_VECTOR);
        PrintToChat(client, "\x04[复活]\x01 你已复活在队友身边!");
    }
    else
    {
        PrintToChat(client, "\x04[复活]\x01 你已复活!");
    }

    PrintHintText(client, "你已复活!");
    return Plugin_Continue;
}
