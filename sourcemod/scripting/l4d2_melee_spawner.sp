#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "2.2"

ConVar g_cvEnabled;
bool g_bSpawnedThisRound;

// All 13 L4D2 melee weapons
char g_MeleeList[][] = {
    "fireaxe",
    "baseball_bat",
    "cricket_bat",
    "crowbar",
    // "electric_guitar",  // 部分战役/三方图不认此武器
    "frying_pan",
    "katana",
    "machete",
    "tonfa",
    "golfclub",
    "knife",
    "shovel",
    "pitchfork"
};

public Plugin myinfo = {
    name = "Melee Spawner",
    author = "claude",
    description = "Drops all melee weapons in the safe room on round start",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    g_cvEnabled = CreateConVar("sm_melee_spawner_enable", "1", "Enable (1=on)");
    AutoExecConfig(true, "l4d2_melee_spawner");
    HookEvent("round_start", Event_RoundStart);
    LogMessage("[MeleeSpawner] v%s ready", PLUGIN_VERSION);
}

public void OnMapStart()
{
    LogMessage("[MeleeSpawner] >>> OnMapStart <<<");
    if (g_cvEnabled.BoolValue)
        CreateTimer(4.0, Timer_DoSpawn);
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    LogMessage("[MeleeSpawner] >>> round_start <<<");
    if (!g_cvEnabled.BoolValue) return;

    CreateTimer(2.0, Timer_DoSpawn);
}

Action Timer_DoSpawn(Handle timer)
{
    if (g_bSpawnedThisRound)
    {
        LogMessage("[MeleeSpawner] Timer_DoSpawn: already spawned, skipping");
        return Plugin_Continue;
    }

    LogMessage("[MeleeSpawner] Timer_DoSpawn: EXECUTING DoSpawn");
    g_bSpawnedThisRound = true;
    DoSpawn();
    return Plugin_Continue;
}

// =====================================================================
// Core spawn logic
// =====================================================================
void DoSpawn()
{
    // Get one reliable spawn point — first alive survivor is most reliable
    float base[3];
    if (!GetSpawnBase(base))
    {
        LogMessage("[MeleeSpawner] ERROR: no spawn base found");
        return;
    }

    // Grid layout: 5x3, spacing 50, all at same Z as base
    float spacing = 50.0;
    int cols = 5;
    int spawned = 0;

    for (int i = 0; i < sizeof(g_MeleeList); i++)
    {
        int row = i / cols;
        int col = i % cols;

        float pos[3];
        pos[0] = base[0] + (col - cols/2) * spacing;
        pos[1] = base[1] + (row - 1) * spacing;
        pos[2] = base[2];

        LogMessage("[MeleeSpawner] [%d/%d] '%s' @ (%.0f,%.0f,%.0f)",
                   i+1, sizeof(g_MeleeList), g_MeleeList[i], pos[0], pos[1], pos[2]);

        if (SpawnMeleeWeapon(g_MeleeList[i], pos) != -1)
            spawned++;
        else
            LogMessage("[MeleeSpawner] FAIL: '%s'", g_MeleeList[i]);
    }

    LogMessage("[MeleeSpawner] %d/%d weapons spawned", spawned, sizeof(g_MeleeList));
    PrintToChatAll("\x04[近战]\x01 安全屋已投放 \x03%d\x01 种近战武器", spawned);
}

// =====================================================================
// Get the spawn base position — prefer alive survivors (same as test cmd)
// =====================================================================
bool GetSpawnBase(float base[3])
{
    // 1st: alive survivor position (most reliable, same as sm_spawnmelee)
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i))
        {
            GetClientAbsOrigin(i, base);
            LogMessage("[MeleeSpawner] Base: survivor #%d @ (%.0f,%.0f,%.0f)", i, base[0], base[1], base[2]);
            return true;
        }
    }

    // 2nd: first info_survivor_position
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "info_survivor_position")) != -1)
    {
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", base);
        LogMessage("[MeleeSpawner] Base: info_survivor_position @ (%.0f,%.0f,%.0f)", base[0], base[1], base[2]);
        return true;
    }

    // 3rd: info_player_start
    entity = -1;
    while ((entity = FindEntityByClassname(entity, "info_player_start")) != -1)
    {
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", base);
        LogMessage("[MeleeSpawner] Base: info_player_start @ (%.0f,%.0f,%.0f)", base[0], base[1], base[2]);
        return true;
    }

    return false;
}

// =====================================================================
// Spawn a single melee weapon entity (physics object, falls to ground)
// =====================================================================
int SpawnMeleeWeapon(const char[] meleeName, float pos[3])
{
    // Use weapon_melee_spawn — confirmed working by sm_spawnmelee test
    int ent = CreateEntityByName("weapon_melee_spawn");
    if (ent == -1)
        return -1;

    DispatchKeyValue(ent, "melee_weapon", meleeName);
    TeleportEntity(ent, pos, NULL_VECTOR, NULL_VECTOR);
    DispatchSpawn(ent);

    return ent;
}
