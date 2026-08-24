#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "4.0.0"

ConVar g_cvEnable;
ConVar g_cvHealAmount;

public Plugin myinfo =
{
    name = "[L4D2] Pills Heal Boost",
    author = "suli",
    description = "止痛药服用后回复指定量的临时生命值（默认80，原版50）",
    version = PLUGIN_VERSION,
    url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    if (GetEngineVersion() != Engine_Left4Dead2)
    {
        strcopy(error, err_max, "Plugin only supports Left 4 Dead 2");
        return APLRes_SilentFailure;
    }
    return APLRes_Success;
}

public void OnPluginStart()
{
    CreateConVar("l4d2_pills_noslow_version", PLUGIN_VERSION, "Pills Heal Boost version", FCVAR_NOTIFY|FCVAR_DONTRECORD);

    g_cvEnable    = CreateConVar("l4d2_pills_noslow_enable",    "1",    "0=OFF, 1=ON.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvHealAmount = CreateConVar("l4d2_pills_noslow_heal",     "80.0", "止痛药回复的临时生命值（原版50）", FCVAR_NOTIFY, true, 1.0, true, 200.0);

    HookEvent("pills_used",   Event_PillsUsed,   EventHookMode_Post);

    AutoExecConfig(true, "l4d2_pills_noslow");
}

void Event_PillsUsed(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue)
        return;

    int subject = GetClientOfUserId(event.GetInt("subject"));
    if (subject < 1 || subject > MaxClients || !IsClientInGame(subject))
        return;
    if (GetClientTeam(subject) != 2)
        return;
    if (!IsPlayerAlive(subject))
        return;

    // 延迟一帧，确保游戏引擎已经完成了止痛药的基础治疗
    CreateTimer(0.1, Timer_BoostHeal, GetClientUserId(subject), TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_BoostHeal(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return Plugin_Stop;
    if (!IsPlayerAlive(client) || GetClientTeam(client) != 2)
        return Plugin_Stop;

    int curHP = GetClientHealth(client);
    float curBuf = L4D_GetTempHealth(client);
    int curBufInt = RoundToNearest(curBuf);
    int add = RoundToNearest(g_cvHealAmount.FloatValue);
    int newBuf = curBufInt + add;
    if( curHP + newBuf > 100 ) newBuf = 100 - curHP;
    if( newBuf < 0 ) newBuf = 0;
    if( newBuf > 100 ) newBuf = 100;
    L4D_SetTempHealth(client, float(newBuf));
    LogMessage("[Pills] %N curHP %d curBuf %.1f add %d newBuf %d total %d", client, curHP, curBuf, add, newBuf, curHP+newBuf);
    DataPack dp = new DataPack();
    dp.WriteCell(GetClientUserId(client));
    dp.WriteCell(newBuf);
    CreateTimer(0.2, Timer_CheckHealth, dp, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_CheckHealth(Handle timer, DataPack dp)
{
    dp.Reset();
    int client = GetClientOfUserId(dp.ReadCell());
    int want = dp.ReadCell();
    delete dp;
    if( client <1 || !IsClientInGame(client) ) return Plugin_Stop;
    int curHP = GetClientHealth(client);
    float curBuf = L4D_GetTempHealth(client);
    LogMessage("[Pills-Check] %N after 0.2s curHP %d curBuf %.1f total %.1f want %d", client, curHP, curBuf, curHP+curBuf, want);
    return Plugin_Stop;
}
