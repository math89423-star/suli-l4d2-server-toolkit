#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "4.0.0"

ConVar g_cvEnable;
ConVar g_cvMultiplier;

public Plugin myinfo =
{
    name = "[L4D2] Pills Heal Boost",
    author = "suli",
    description = "止痛药服用后额外回复60%的临时生命值",
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

    g_cvEnable     = CreateConVar("l4d2_pills_noslow_enable",     "1",       "0=OFF, 1=ON.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvMultiplier = CreateConVar("l4d2_pills_noslow_multiplier", "1.6",     "回复量倍率（1.6=增加60%，2.0=翻倍）", FCVAR_NOTIFY, true, 1.0, true, 5.0);

    HookEvent("pills_used",   Event_PillsUsed,   EventHookMode_Post);
    HookEvent("round_start",  Event_RoundStart,  EventHookMode_PostNoCopy);

    AutoExecConfig(true, "l4d2_pills_noslow");
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    // 回合开始时无需特殊处理
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

    float mult = g_cvMultiplier.FloatValue;
    if (mult <= 1.0)
        return Plugin_Stop;

    // 获取当前临时生命值（止痛药已经加好的基础值）
    float currentTemp = L4D_GetTempHealth(client);

    if (currentTemp <= 0.0)
        return Plugin_Stop;

    // 计算额外回复量：当前临时生命值 * (倍率 - 1)
    // 例如倍率1.6，当前50HP，额外加 50 * 0.6 = 30HP，最终80HP
    float extraHealth = currentTemp * (mult - 1.0);
    float newTemp = currentTemp + extraHealth;

    // 设置新的临时生命值
    L4D_SetTempHealth(client, newTemp);

    return Plugin_Stop;
}
