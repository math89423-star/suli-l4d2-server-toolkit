// TEST 4: only upward trail, no explosion
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

float g_fStartPos[3];
float g_fApexZ;
int g_iTrailRef = -1;
Handle g_hMoveTimer = INVALID_HANDLE;
float g_fElapsed = 0.0;

public Plugin myinfo =
{
    name = "[L4D2] Flare TEST4",
    author = "suli",
    description = "Test upward trail only",
    version = "1.0",
    url = ""
};

public void OnMapStart()
{
    PrecacheParticleName("fireworks_flare_trail_01");
}

void PrecacheParticleName(const char[] name)
{
    int tbl = FindStringTable("ParticleEffectNames");
    if (tbl == INVALID_STRING_TABLE) return;
    int count = GetStringTableNumStrings(tbl);
    char buf[128];
    for (int i = 0; i < count; i++)
    {
        ReadStringTable(tbl, i, buf, sizeof(buf));
        if (StrEqual(buf, name, false))
            return;
    }
    bool save = LockStringTables(false);
    AddToStringTable(tbl, name);
    LockStringTables(save);
}

public void OnPluginStart()
{
    RegAdminCmd("sm_test4", Cmd_Test, ADMFLAG_ROOT, "Test upward trail");
}

Action Cmd_Test(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client)) return Plugin_Handled;

    // Spawn at player's feet
    float pos[3];
    GetClientAbsOrigin(client, pos);
    pos[2] += 10.0; // slightly above ground

    g_fStartPos = pos;
    g_fApexZ = pos[2] + 500.0;

    // Create trail
    int trail = CreateEntityByName("info_particle_system");
    if (trail > 0 && IsValidEntity(trail))
    {
        DispatchKeyValue(trail, "effect_name", "fireworks_flare_trail_01");
        DispatchKeyValue(trail, "start_active", "1");
        TeleportEntity(trail, pos, NULL_VECTOR, NULL_VECTOR);
        DispatchSpawn(trail);
        ActivateEntity(trail);
        AcceptEntityInput(trail, "Start");
        g_iTrailRef = EntIndexToEntRef(trail);
        PrintToChat(client, "[TEST4] Trail at your feet, moving up 500u...");
    }
    else
    {
        PrintToChat(client, "[TEST4] FAILED to create trail");
        return Plugin_Handled;
    }

    g_fElapsed = 0.0;
    g_hMoveTimer = CreateTimer(0.02, Timer_Move, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    return Plugin_Handled;
}

Action Timer_Move(Handle timer, any data)
{
    g_fElapsed += 0.02;
    float progress = g_fElapsed / 2.0; // 2 seconds to reach apex
    if (progress >= 1.0) progress = 1.0;

    float curZ = g_fStartPos[2] + (g_fApexZ - g_fStartPos[2]) * progress;

    float pos[3];
    pos[0] = g_fStartPos[0];
    pos[1] = g_fStartPos[1];
    pos[2] = curZ;

    int trail = EntRefToEntIndex(g_iTrailRef);
    if (trail > 0 && IsValidEntity(trail))
        TeleportEntity(trail, pos, NULL_VECTOR, NULL_VECTOR);

    if (progress >= 1.0)
    {
        // Reached apex — stop
        PrintToChatAll("[TEST4] Trail reached apex. Stopping.");
        g_fElapsed = 0.0;
        return Plugin_Stop;
    }

    return Plugin_Continue;
}

bool TraceFilter_NoSelf(int entity, int contentsMask, any data)
{
    return entity != data;
}
