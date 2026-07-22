#include <sourcemod>
#include <left4dhooks>

public Plugin myinfo = {
    name = "Wipe Auto Mapchanger",
    author = "claude",
    description = "Auto-change map after 4 consecutive wipes",
    version = "1.0",
    url = ""
};

int g_iWipeCount;
bool g_bRoundActive;

public void OnPluginStart()
{
    HookEvent("round_start", Event_RoundStart);
    HookEvent("round_end", Event_RoundEnd);
    g_iWipeCount = 0;
    g_bRoundActive = false;
}

public void OnMapEnd()
{
    g_iWipeCount = 0;
    g_bRoundActive = false;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bRoundActive = true;
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bRoundActive)
        return;
    g_bRoundActive = false;

    int winner = event.GetInt("winner");
    // winner == 0 means survivors lost (all dead)
    if (winner == 0)
    {
        g_iWipeCount++;
        PrintToChatAll("\x04[提示]\x01 团灭次数: \x03%d/4\x01", g_iWipeCount);

        if (g_iWipeCount >= 4)
        {
            PrintToChatAll("\x04[提示]\x01 团灭已达4次，正在切换下一张地图...");
            CreateTimer(3.0, Timer_ChangeMap);
            g_iWipeCount = 0;
        }
    }
    else
    {
        // Survivors won, reset wipe count
        g_iWipeCount = 0;
    }
}

public Action Timer_ChangeMap(Handle timer)
{
    char nextMap[64];
    if (GetNextMap(nextMap, sizeof(nextMap)) && nextMap[0] != '\0')
    {
        ServerCommand("changelevel %s", nextMap);
    }
    else
    {
        // Fallback: try to read first map from mapcycle
        ServerCommand("changelevel c2m1_highway");
    }
    return Plugin_Stop;
}
