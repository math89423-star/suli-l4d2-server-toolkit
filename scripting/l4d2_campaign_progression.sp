#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <l4d2_mission_manager>

#define PLUGIN_VERSION "1.3"

public Plugin myinfo =
{
    name = "L4D2 Campaign Progression Fix",
    author = "claude",
    description = "Use mission_manager API to force correct campaign progression (respects mapchooser votes)",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    HookEvent("round_end", Event_RoundEnd, EventHookMode_Pre);
    CreateConVar("sm_campaign_progression_version", PLUGIN_VERSION, "", FCVAR_NOTIFY|FCVAR_DONTRECORD);
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    // 只在战役/写实模式
    char gamemode[32];
    GetConVarString(FindConVar("mp_gamemode"), gamemode, sizeof(gamemode));
    if(StrContains(gamemode, "coop") == -1 && StrContains(gamemode, "realism") == -1)
        return Plugin_Continue;

    // reason: 0=Unknown, 1=AllSurvivorsDead, 2=SafeRoom/Escaped
    if(event.GetInt("reason") != 2)
        return Plugin_Continue;

    // ★ 如果 mapchooser 已设置 sm_nextmap（投票结果），不干预，让 mapchooser 接管
    ConVar hNextMap = FindConVar("sm_nextmap");
    if(hNextMap != null)
    {
        char nextMap[64];
        hNextMap.GetString(nextMap, sizeof(nextMap));
        if(strlen(nextMap) > 0)
        {
            PrintToChatAll("\x04[战役] \x01投票已选定下一张图: \x05%s\x01，跳过自动换图", nextMap);
            return Plugin_Continue;
        }
    }

    char currentMap[64];
    GetCurrentMap(currentMap, sizeof(currentMap));

    // 用 mission_manager API 查找当前地图
    LMM_GAMEMODE mode = LMM_StringToGamemode(gamemode);
    int missionIndex;
    int mapIndex = LMM_FindMapIndexByName(mode, missionIndex, currentMap);
    if(mapIndex == -1) return Plugin_Continue;  // 三方图未注册，不干预

    // 检查是否有下一张图
    int totalMaps = LMM_GetNumberOfMaps(mode, missionIndex);
    if(mapIndex + 1 >= totalMaps) return Plugin_Continue;  // 终局，留给 campaign_transition

    // 获取下一张图
    char nextMap[64];
    LMM_GetMapName(mode, missionIndex, mapIndex + 1, nextMap, sizeof(nextMap));

    PrintToChatAll("\x04[战役] \x01正在前往下一关: \x05%s", nextMap);
    DataPack pack = new DataPack();
    pack.WriteString(nextMap);
    CreateTimer(1.0, Timer_ChangeLevel, pack);
    return Plugin_Continue;
}

public Action Timer_ChangeLevel(Handle timer, DataPack pack)
{
    pack.Reset();
    char nextMap[64];
    pack.ReadString(nextMap, sizeof(nextMap));
    delete pack;
    ForceChangeLevel(nextMap, "Campaign Progression");
    return Plugin_Stop;
}
