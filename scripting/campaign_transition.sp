#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <l4d2_mission_manager>

#define PLUGIN_VERSION "1.3"

// Official L4D2 campaign rotation (first maps only)
char g_szOfficialCampaigns[][] = {
    "c1m1_hotel", "c2m1_highway", "c3m1_plankcountry",
    "c4m1_milltown_a", "c5m1_waterfront", "c6m1_riverbank",
    "c7m1_docks", "c8m1_apartment", "c9m1_alleys",
    "c10m1_caves", "c11m1_greenhouse", "c12m1_hilltop",
    "c13m1_alpinecreek", "c14m1_junkyard"
};

public Plugin myinfo =
{
    name = "Campaign Finale Auto Transition",
    author = "claude",
    description = "After finale win, advance to next campaign (official→official, custom→c1m1)",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    HookEvent("finale_win", Event_FinaleWin);
    CreateConVar("sm_campaign_transition_version", PLUGIN_VERSION, "", FCVAR_NOTIFY|FCVAR_DONTRECORD);
}

// Check if map is an official campaign starter
bool IsOfficialCampaign(const char[] map, int &index)
{
    for (int i = 0; i < sizeof(g_szOfficialCampaigns); i++)
    {
        if (StrEqual(map, g_szOfficialCampaigns[i], false))
        {
            index = i;
            return true;
        }
    }
    return false;
}

public Action Event_FinaleWin(Event event, const char[] name, bool dontBroadcast)
{
    // If mapchooser already set sm_nextmap (vote result), don't override
    ConVar hNextMap = FindConVar("sm_nextmap");
    if (hNextMap != null)
    {
        char votedMap[64];
        hNextMap.GetString(votedMap, sizeof(votedMap));
        if (strlen(votedMap) > 0)
        {
            PrintToChatAll("\x04[战役结束] \x01投票已选定: \x05%s\x01，跳过自动换图", votedMap);
            return Plugin_Continue;
        }
    }

    char currentMap[64];
    GetCurrentMap(currentMap, sizeof(currentMap));

    char gamemode[32];
    GetConVarString(FindConVar("mp_gamemode"), gamemode, sizeof(gamemode));
    LMM_GAMEMODE mode = LMM_StringToGamemode(gamemode);

    int missionIndex;
    int mapIndex = LMM_FindMapIndexByName(mode, missionIndex, currentMap);
    if (mapIndex == -1)
        return Plugin_Continue;

    // Get current campaign's first map
    char firstMap[64];
    LMM_GetMapName(mode, missionIndex, 0, firstMap, sizeof(firstMap));

    char nextMap[64];
    int officialIdx;

    if (IsOfficialCampaign(firstMap, officialIdx))
    {
        // Official → next official (cycle)
        int nextIdx = (officialIdx + 1) % sizeof(g_szOfficialCampaigns);
        strcopy(nextMap, sizeof(nextMap), g_szOfficialCampaigns[nextIdx]);
        PrintToChatAll("\x04[战役结束] \x01下一官方战役: \x05%s", nextMap);
    }
    else
    {
        // Custom campaign finished → back to c1m1, then official rotation continues
        strcopy(nextMap, sizeof(nextMap), "c1m1_hotel");
        PrintToChatAll("\x04[战役结束] \x01三方图战役结束，切回官方战役: \x05c1m1_hotel");
    }

    DataPack pack = new DataPack();
    pack.WriteString(nextMap);
    CreateTimer(8.0, Timer_ChangeLevel, pack);

    return Plugin_Continue;
}

public Action Timer_ChangeLevel(Handle timer, DataPack pack)
{
    pack.Reset();
    char nextMap[64];
    pack.ReadString(nextMap, sizeof(nextMap));
    delete pack;

    // FIX (2026-08-01): ForceChangeLevel kicks ALL clients (it is the `map`
    // command equivalent) — after a finale win that drops every player.
    // Engine `changelevel` keeps the connection (client auto-reconnects).
    ServerCommand("changelevel %s", nextMap);
    return Plugin_Stop;
}
