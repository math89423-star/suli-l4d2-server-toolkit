#include <sourcemod>
#include <sdktools>

public Plugin myinfo = {
    name = "Medical Supply Scaler",
    author = "claude",
    description = "Spawn extra medkits, pills, and adrenaline on the ground based on player count",
    version = "3.0",
    url = ""
};

public void OnPluginStart()
{
    HookEvent("round_start", Event_RoundStart);
    CreateConVar("sm_med_enable", "1", "Enable extra medical supplies (0=off,1=on)");
    CreateConVar("sm_pills_enable", "1", "Enable extra pills (0=off,1=on)");
    CreateConVar("sm_adren_enable", "1", "Enable extra adrenaline (0=off,1=on)");
    AutoExecConfig(true, "l4d2_medical_supply_scaler");
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    CreateTimer(3.0, Timer_SpawnSupplies);
}

public Action Timer_SpawnSupplies(Handle timer)
{
    int humanCount = HumanSurvivorCount();
    if (humanCount <= 4)
        return Plugin_Stop;

    bool med   = GetConVarBool(FindConVar("sm_med_enable"));
    bool pills = GetConVarBool(FindConVar("sm_pills_enable"));
    bool adren = GetConVarBool(FindConVar("sm_adren_enable"));

    if (!med && !pills && !adren)
        return Plugin_Stop;

    // extra item count: +1 for every 2 players above 4, minimum 1
    int extraCount = (humanCount - 4 + 1) / 2;
    if (extraCount < 1) extraCount = 1;

    float origin[3];
    if (!GetSaferoomOrigin(origin))
        return Plugin_Stop;

    // Spawn items spread around the location
    float offsets[][] = {
        {0.0,   0.0,  20.0},
        {50.0,  0.0,  20.0},
        {-50.0, 0.0,  20.0},
        {0.0,   50.0, 20.0},
        {0.0,  -50.0, 20.0},
        {50.0,  50.0, 20.0},
        {-50.0,-50.0, 20.0},
        {50.0, -50.0, 20.0},
        {-50.0, 50.0, 20.0},
    };

    int spawned = 0;

    for (int i = 0; i < extraCount; i++)
    {
        float pos[3];
        pos[0] = origin[0] + offsets[i % 9][0];
        pos[1] = origin[1] + offsets[i % 9][1];
        pos[2] = origin[2] + offsets[i % 9][2];

        if (med)   spawned += SpawnItem("weapon_first_aid_kit", pos);
        if (pills) spawned += SpawnItem("weapon_pain_pills", pos);
        if (adren) spawned += SpawnItem("weapon_adrenaline", pos);
    }

    if (spawned > 0)
        PrintToChatAll("\x04[补给]\x01 已按\x03 %d人\x01 额外补充物资", humanCount);

    return Plugin_Stop;
}

int SpawnItem(const char[] classname, float pos[3])
{
    int ent = CreateEntityByName(classname);
    if (ent == -1)
        return 0;

    TeleportEntity(ent, pos, NULL_VECTOR, NULL_VECTOR);
    DispatchSpawn(ent);
    return 1;
}

int HumanSurvivorCount()
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == 2)
            count++;
    }
    return count;
}

bool GetSaferoomOrigin(float origin[3])
{
    // Try to get location from the first alive survivor
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i))
        {
            GetClientAbsOrigin(i, origin);
            return true;
        }
    }
    // Fallback: info_player_start
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "info_player_start")) != -1)
    {
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", origin);
        origin[2] += 20.0;
        return true;
    }
    return false;
}
