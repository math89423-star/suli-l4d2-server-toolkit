// TEST 3: spawn c2m5 firework at player position
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

float g_fExplodePos[3];

public Plugin myinfo =
{
    name = "[L4D2] Flare TEST3",
    author = "suli",
    description = "Test c2m5 firework particles",
    version = "1.0",
    url = ""
};

public void OnPluginStart()
{
    RegAdminCmd("sm_fwork", Cmd_Firework, ADMFLAG_ROOT, "Test firework");
}

public void OnMapStart()
{
    PrecacheParticleName("fireworks_01");
    PrecacheParticleName("fireworks_flare_trail_01");
    PrecacheParticleName("fireworks_explosion_01");
    PrecacheParticleName("fireworks_explosion_glow_01");
    PrecacheParticleName("fireworks_sparkshower_01");
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

Action Cmd_Firework(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client)) return Plugin_Handled;

    float pos[3];
    GetClientEyePosition(client, pos);
    pos[2] -= 50.0; // slightly below eye level

    // 1. Launch particle (fireworks_01) — the upward launch effect
    int launch = CreateEntityByName("info_particle_system");
    if (launch > 0 && IsValidEntity(launch))
    {
        DispatchKeyValue(launch, "effect_name", "fireworks_01");
        DispatchKeyValue(launch, "start_active", "1");
        TeleportEntity(launch, pos, NULL_VECTOR, NULL_VECTOR);
        DispatchSpawn(launch);
        ActivateEntity(launch);
        AcceptEntityInput(launch, "Start");
        PrintToChat(client, "[TEST3] fireworks_01 (launch) spawned");
    }

    // 2. Trail particle — follows upward
    float trailPos[3];
    trailPos[0] = pos[0];
    trailPos[1] = pos[1];
    trailPos[2] = pos[2] + 100.0;

    int trail = CreateEntityByName("info_particle_system");
    if (trail > 0 && IsValidEntity(trail))
    {
        DispatchKeyValue(trail, "effect_name", "fireworks_flare_trail_01");
        DispatchKeyValue(trail, "start_active", "1");
        TeleportEntity(trail, trailPos, NULL_VECTOR, NULL_VECTOR);
        DispatchSpawn(trail);
        ActivateEntity(trail);
        AcceptEntityInput(trail, "Start");
        PrintToChat(client, "[TEST3] fireworks_flare_trail_01 (trail) spawned");
    }

    // 3. After 1.5s, spawn explosion at apex
    float apexPos[3];
    apexPos[0] = pos[0];
    apexPos[1] = pos[1];
    apexPos[2] = pos[2] + 500.0;

    CreateTimer(1.5, Timer_Explode, _, TIMER_FLAG_NO_MAPCHANGE);
    g_fExplodePos = apexPos;

    PrintToChat(client, "[TEST3] Firework launched! Explosion in 1.5s at apex.");
    return Plugin_Handled;
}

Action Timer_Explode(Handle timer, any data)
{
    // Explosion
    int explosion = CreateEntityByName("info_particle_system");
    if (explosion > 0 && IsValidEntity(explosion))
    {
        DispatchKeyValue(explosion, "effect_name", "fireworks_explosion_01");
        DispatchKeyValue(explosion, "start_active", "1");
        TeleportEntity(explosion, g_fExplodePos, NULL_VECTOR, NULL_VECTOR);
        DispatchSpawn(explosion);
        ActivateEntity(explosion);
        AcceptEntityInput(explosion, "Start");
    }

    // Glow
    int glow = CreateEntityByName("info_particle_system");
    if (glow > 0 && IsValidEntity(glow))
    {
        DispatchKeyValue(glow, "effect_name", "fireworks_explosion_glow_01");
        DispatchKeyValue(glow, "start_active", "1");
        TeleportEntity(glow, g_fExplodePos, NULL_VECTOR, NULL_VECTOR);
        DispatchSpawn(glow);
        ActivateEntity(glow);
        AcceptEntityInput(glow, "Start");
    }

    // Sparks
    int sparks = CreateEntityByName("info_particle_system");
    if (sparks > 0 && IsValidEntity(sparks))
    {
        DispatchKeyValue(sparks, "effect_name", "fireworks_sparkshower_01");
        DispatchKeyValue(sparks, "start_active", "1");
        TeleportEntity(sparks, g_fExplodePos, NULL_VECTOR, NULL_VECTOR);
        DispatchSpawn(sparks);
        ActivateEntity(sparks);
        AcceptEntityInput(sparks, "Start");
    }

    return Plugin_Continue;
}
