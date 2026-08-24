// TEST 2: add info_particle_system to test
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

public Plugin myinfo =
{
    name = "[L4D2] Flare TEST2",
    author = "suli",
    description = "Test particles",
    version = "1.0",
    url = ""
};

public void OnPluginStart()
{
    RegAdminCmd("sm_flare_test2", Cmd_Test, ADMFLAG_ROOT, "Test");
}

Action Cmd_Test(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client)) return Plugin_Handled;
    float pos[3];
    GetClientEyePosition(client, pos);
    pos[2] += 100.0;

    // Particle 1: fireworks_flare_trail_01
    int p1 = CreateEntityByName("info_particle_system");
    if (p1 > 0 && IsValidEntity(p1))
    {
        DispatchKeyValue(p1, "effect_name", "fireworks_flare_trail_01");
        DispatchKeyValue(p1, "start_active", "1");
        TeleportEntity(p1, pos, NULL_VECTOR, NULL_VECTOR);
        DispatchSpawn(p1);
        ActivateEntity(p1);
        AcceptEntityInput(p1, "Start");
        PrintToChat(client, "[TEST2] fireworks_flare_trail_01 OK");
    }
    else
    {
        PrintToChat(client, "[TEST2] fireworks_flare_trail_01 FAILED");
    }

    // Particle 2: smoke_medium_01
    int p2 = CreateEntityByName("info_particle_system");
    if (p2 > 0 && IsValidEntity(p2))
    {
        DispatchKeyValue(p2, "effect_name", "smoke_medium_01");
        DispatchKeyValue(p2, "start_active", "1");
        TeleportEntity(p2, pos, NULL_VECTOR, NULL_VECTOR);
        DispatchSpawn(p2);
        ActivateEntity(p2);
        AcceptEntityInput(p2, "Start");
        PrintToChat(client, "[TEST2] smoke_medium_01 OK");
    }
    else
    {
        PrintToChat(client, "[TEST2] smoke_medium_01 FAILED");
    }

    // Particle 3: weapon_muzzleflash_illumination
    int p3 = CreateEntityByName("info_particle_system");
    if (p3 > 0 && IsValidEntity(p3))
    {
        DispatchKeyValue(p3, "effect_name", "weapon_muzzleflash_illumination");
        DispatchKeyValue(p3, "start_active", "1");
        TeleportEntity(p3, pos, NULL_VECTOR, NULL_VECTOR);
        DispatchSpawn(p3);
        ActivateEntity(p3);
        AcceptEntityInput(p3, "Start");
        PrintToChat(client, "[TEST2] weapon_muzzleflash_illumination OK");
    }
    else
    {
        PrintToChat(client, "[TEST2] weapon_muzzleflash_illumination FAILED");
    }

    PrintToChat(client, "[TEST2] Particles spawned. Check if server crashes.");

    CreateTimer(5.0, Timer_Kill, _, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Handled;
}

Action Timer_Kill(Handle timer, any data)
{
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "info_particle_system")) != -1)
    {
        if (IsValidEntity(ent))
        {
            AcceptEntityInput(ent, "Stop");
            AcceptEntityInput(ent, "Kill");
        }
    }
    return Plugin_Continue;
}
