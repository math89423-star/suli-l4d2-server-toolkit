#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.5"
#define ZOMBIECLASS_TANK 8

ConVar g_cvGLDamage;
ConVar g_cvGLRadius;
ConVar g_cvGLFF;
ConVar g_cvGLTankMult;
ConVar g_cvGLWitchMult;

public Plugin myinfo = {
    name = "GL Splash Damage Fix",
    author = "claude",
    description = "Fix grenade launcher explosion damage + FF + Tank/Witch multiplier",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    g_cvGLDamage    = CreateConVar("sm_gl_splash_damage", "750", "Grenade launcher explosion damage", _, true, 1.0);
    g_cvGLRadius    = CreateConVar("sm_gl_splash_radius", "350", "Grenade launcher explosion radius", _, true, 1.0);
    g_cvGLFF        = CreateConVar("sm_gl_ff_factor", "0.4", "GL friendly fire multiplier (0=disable)", _, true, 0.0, true, 1.0);
    g_cvGLTankMult  = CreateConVar("sm_gl_tank_mult", "2.5", "GL damage multiplier vs Tank", _, true, 0.0);
    g_cvGLWitchMult = CreateConVar("sm_gl_witch_mult", "1.5", "GL damage multiplier vs Witch", _, true, 0.0);
    AutoExecConfig(true, "l4d2_gl_splash_fix");
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (StrEqual(classname, "grenade_launcher_projectile"))
    {
        SDKHook(entity, SDKHook_SpawnPost, OnGLProjectileSpawnPost);
    }
}

void OnGLProjectileSpawnPost(int entity)
{
    DataPack dp = new DataPack();
    dp.WriteCell(EntIndexToEntRef(entity));
    dp.WriteFloat(g_cvGLDamage.FloatValue);
    dp.WriteFloat(g_cvGLRadius.FloatValue);
    RequestFrame(FrameSetDamage, dp);
}

void FrameSetDamage(any data)
{
    DataPack dp = view_as<DataPack>(data);
    dp.Reset();
    int ref = dp.ReadCell();
    float dmg = dp.ReadFloat();
    float radius = dp.ReadFloat();
    delete dp;

    int entity = EntRefToEntIndex(ref);
    if (entity == INVALID_ENT_REFERENCE || !IsValidEntity(entity))
        return;

    SetEntPropFloat(entity, Prop_Data, "m_flDamage", dmg);
    SetEntPropFloat(entity, Prop_Data, "m_DmgRadius", radius);
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

public void OnConfigsExecuted()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
            SDKHook(i, SDKHook_OnTakeDamage, OnTakeDamage);
    }
}

Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon,
                    float damageForce[3], float damagePosition[3], int damagecustom)
{
    if (inflictor <= 0 || !IsValidEntity(inflictor))
        return Plugin_Continue;

    char cls[64];
    GetEntityClassname(inflictor, cls, sizeof(cls));
    if (!StrEqual(cls, "grenade_launcher_projectile"))
        return Plugin_Continue;

    // Is this blast damage from GL?
    if (!(damagetype & DMG_BLAST))
        return Plugin_Continue;

    // Friendly fire: multiply engine's already-FF-adjusted damage
    if (victim >= 1 && victim <= MaxClients && attacker >= 1 && attacker <= MaxClients)
    {
        if (IsClientInGame(victim) && IsClientInGame(attacker) && GetClientTeam(victim) == GetClientTeam(attacker))
        {
            damage *= g_cvGLFF.FloatValue;
            return Plugin_Changed;
        }
    }

    // Base splash damage = 75% of weapon damage
    float baseDamage = g_cvGLDamage.FloatValue * 0.75;

    // Tank multiplier (player entity on team 3, zombie class 8)
    if (victim >= 1 && victim <= MaxClients && IsClientInGame(victim) && GetClientTeam(victim) == 3)
    {
        if (GetEntProp(victim, Prop_Send, "m_zombieClass") == ZOMBIECLASS_TANK)
        {
            baseDamage *= g_cvGLTankMult.FloatValue;
        }
    }

    // Witch multiplier (NPC entity, classname "witch")
    if (victim > MaxClients && IsValidEntity(victim))
    {
        GetEntityClassname(victim, cls, sizeof(cls));
        if (StrEqual(cls, "witch"))
        {
            baseDamage *= g_cvGLWitchMult.FloatValue;
        }
    }

    damage = baseDamage;
    return Plugin_Changed;
}
