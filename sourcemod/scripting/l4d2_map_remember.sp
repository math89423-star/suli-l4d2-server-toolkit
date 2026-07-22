#include <sourcemod>

public Plugin myinfo = {
    name = "Campaign Remember",
    author = "claude",
    description = "Save current map on every map change, restore campaign on server start",
    version = "2.1",
    url = ""
};

char g_sStateFile[PLATFORM_MAX_PATH];
bool g_bFirstMap = true;

public void OnPluginStart()
{
    BuildPath(Path_SM, g_sStateFile, sizeof(g_sStateFile), "data/campaign_state.txt");
}

public void OnMapStart()
{
    if (g_bFirstMap)
    {
        // First map after server start: check for saved campaign before overwriting state
        g_bFirstMap = false;
        CreateTimer(2.0, Timer_RestoreCampaign);
    }
    else
    {
        // Normal map change: persist current campaign
        SaveCurrentMap();
    }
}

public Action Timer_RestoreCampaign(Handle timer)
{
    char curMap[64];
    GetCurrentMap(curMap, sizeof(curMap));

    int curCampaign = GetCampaignNumber(curMap);

    File f = OpenFile(g_sStateFile, "r");
    if (f != null)
    {
        char savedMap[64];
        f.ReadLine(savedMap, sizeof(savedMap));
        delete f;

        int savedCampaign = GetCampaignNumber(savedMap);

        if (savedCampaign > 0 && savedCampaign != curCampaign)
        {
            char firstMap[64];
            CampaignFirstMap(savedCampaign, firstMap, sizeof(firstMap));
            PrintToChatAll("\x04[提示]\x01 恢复上次战役: \x03%s\x01", firstMap);
            ServerCommand("changelevel %s", firstMap);
        }
        else
        {
            // No restore needed, save current state now
            SaveCurrentMap();
        }
    }
    else
    {
        // No state file yet, save current
        SaveCurrentMap();
    }

    return Plugin_Stop;
}

void SaveCurrentMap()
{
    char map[64];
    GetCurrentMap(map, sizeof(map));
    int campaign = GetCampaignNumber(map);
    char firstMap[64];
    CampaignFirstMap(campaign, firstMap, sizeof(firstMap));

    File f = OpenFile(g_sStateFile, "w");
    if (f != null)
    {
        f.WriteLine(firstMap);
        delete f;
    }
}

int GetCampaignNumber(const char[] map)
{
    // Extract campaign number: c1→1, c2→2, ..., c14→14
    if (map[0] != 'c' || map[1] < '0' || map[1] > '9')
        return 0;

    int num = map[1] - '0';
    if (map[2] >= '0' && map[2] <= '9')
        num = num * 10 + (map[2] - '0');

    return num;
}

void CampaignFirstMap(int campaign, char[] buffer, int maxlen)
{
    char names[][] = {
        "c1m1_hotel",
        "c2m1_highway",
        "c3m1_plankcountry",
        "c4m1_milltown_a",
        "c5m1_waterfront",
        "c6m1_riverbank",
        "c7m1_docks",
        "c8m1_apartment",
        "c9m1_alleys",
        "c10m1_caves",
        "c11m1_greenhouse",
        "c12m1_hilltop",
        "c13m1_alpinecreek",
        "c14m1_junkyard"
    };

    if (campaign >= 1 && campaign <= 14)
        strcopy(buffer, maxlen, names[campaign - 1]);
    else
        strcopy(buffer, maxlen, "c1m1_hotel");
}
