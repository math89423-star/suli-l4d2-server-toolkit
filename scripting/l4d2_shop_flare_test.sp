// MINIMAL TEST: only env_sprite + env_projectedtexture + light_dynamic
// No particles, no props, no sdkhooks — isolate the crash cause

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "4.0.0-test"

ConVar g_cvEnable;

public Plugin myinfo =
{
    name = "[L4D2] Shop Flare TEST",
    author = "suli",
    description = "Minimal flare test - no particles",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    g_cvEnable = CreateConVar("l4d2_flare_enable", "1", "0=OFF, 1=ON", FCVAR_NOTIFY);
    RegAdminCmd("sm_flare_test", Cmd_FlareTest, ADMFLAG_ROOT, "Test flare entities");
}

Action Cmd_FlareTest(int client, int args)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
        return Plugin_Handled;

    float pos[3];
    GetClientEyePosition(client, pos);
    pos[2] += 100.0; // slightly above head

    // 1. env_sprite (visual glow)
    int sprite = CreateEntityByName("env_sprite");
    if (sprite > 0 && IsValidEntity(sprite))
    {
        DispatchKeyValue(sprite, "model", "sprites/blueflare1.vmt");
        DispatchKeyValue(sprite, "scale", "1.5");
        DispatchKeyValue(sprite, "spawnflags", "1");
        DispatchKeyValue(sprite, "rendercolor", "255 240 220");
        DispatchKeyValue(sprite, "rendermode", "5");
        DispatchKeyValue(sprite, "renderamt", "255");
        TeleportEntity(sprite, pos, NULL_VECTOR, NULL_VECTOR);
        DispatchSpawn(sprite);
        ActivateEntity(sprite);
        PrintToChat(client, "[TEST] Sprite created OK");
    }
    else
    {
        PrintToChat(client, "[TEST] Sprite FAILED");
    }

    // 2. env_projectedtexture (flashlight-like)
    int proj = CreateEntityByName("env_projectedtexture");
    if (proj > 0 && IsValidEntity(proj))
    {
        DispatchKeyValue(proj, "targetname", "flare_test_proj");
        DispatchKeyValue(proj, "lightfov", "150");
        DispatchKeyValue(proj, "nearz", "8");
        DispatchKeyValue(proj, "farz", "1000");
        DispatchKeyValue(proj, "lightcolor", "255 240 220 255");
        DispatchKeyValue(proj, "texturename", "effects/flashlight001");
        DispatchKeyValue(proj, "enableshadows", "1");
        DispatchKeyValue(proj, "shadowquality", "0");
        DispatchKeyValue(proj, "lightworld", "1");
        DispatchKeyValue(proj, "spawnflags", "1");
        TeleportEntity(proj, pos, NULL_VECTOR, NULL_VECTOR);
        DispatchSpawn(proj);
        ActivateEntity(proj);
        SetVariantString("pitch 90");
        AcceptEntityInput(proj, "SetAngles");
        PrintToChat(client, "[TEST] ProjectedTexture created OK");
    }
    else
    {
        PrintToChat(client, "[TEST] ProjectedTexture FAILED");
    }

    // 3. light_dynamic (omnidirectional)
    int light = CreateEntityByName("light_dynamic");
    if (light > 0 && IsValidEntity(light))
    {
        DispatchKeyValue(light, "_light", "255 240 220 255");
        DispatchKeyValue(light, "brightness", "1");
        DispatchKeyValue(light, "_inner_cone", "170");
        DispatchKeyValue(light, "_cone", "180");
        DispatchKeyValue(light, "distance", "750");
        DispatchKeyValue(light, "spotlight_radius", "750");
        DispatchKeyValue(light, "style", "0");
        DispatchKeyValue(light, "spawnflags", "0");
        TeleportEntity(light, pos, NULL_VECTOR, NULL_VECTOR);
        DispatchSpawn(light);
        ActivateEntity(light);
        PrintToChat(client, "[TEST] light_dynamic created OK");
    }
    else
    {
        PrintToChat(client, "[TEST] light_dynamic FAILED");
    }

    PrintToChat(client, "[TEST] All entities spawned. Check if server crashes.");

    // Kill after 5 seconds
    CreateTimer(5.0, Timer_KillTest, _, TIMER_FLAG_NO_MAPCHANGE);

    return Plugin_Handled;
}

Action Timer_KillTest(Handle timer, any data)
{
    // Kill all test entities by name
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "env_sprite")) != -1)
    {
        if (IsValidEntity(ent))
            AcceptEntityInput(ent, "Kill");
    }
    ent = -1;
    while ((ent = FindEntityByClassname(ent, "env_projectedtexture")) != -1)
    {
        if (IsValidEntity(ent))
        {
            AcceptEntityInput(ent, "TurnOff");
            AcceptEntityInput(ent, "Kill");
        }
    }
    ent = -1;
    while ((ent = FindEntityByClassname(ent, "light_dynamic")) != -1)
    {
        if (IsValidEntity(ent))
        {
            AcceptEntityInput(ent, "TurnOff");
            AcceptEntityInput(ent, "Kill");
        }
    }
    return Plugin_Continue;
}
