/**
 * L4D2 Friendly Fire Fix
 * survivvor_friendly_fire_factor cvars are cheat-protected and ignored by engine.
 * This plugin applies FF damage directly:
 *   - TraceAttack: bullet/melee/shotgun (attacker is always a valid client)
 *   - OnTakeDamage: fire/molotov (attacker is inferno entity or world, NOT the thrower)
 *
 * Fire damage fix: molotov fire uses inflictor's m_hOwnerEntity to find the thrower.
 * Since z_friendly_fire_forgiveness zeroes fire FF before OnTakeDamage fires,
 * we re-apply fire damage via SDKHooks_TakeDamage to bypass the forgiveness check.
 */
#include <sourcemod>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.3"
#define DMG_BURN 0x00000008

ConVar g_cvFFMultiplier;
ConVar g_cvFFFireMultiplier;
ConVar g_cvInfernoDamage;
bool g_bInFireHook[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name = "L4D2 Friendly Fire Fix",
    author = "claude",
    description = "Force FF damage via TraceAttack + OnTakeDamage (fire/molotov)",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    g_cvFFMultiplier = CreateConVar("sm_ff_multiplier", "0.30", "FF damage multiplier for guns (Hard=0.30)", _, true, 0.0, true, 1.0);
    g_cvFFFireMultiplier = CreateConVar("sm_ff_fire_multiplier", "1.0", "FF damage multiplier for fire/molotov", _, true, 0.0, true, 5.0);
    AutoExecConfig(true, "l4d2_ff_fix");

    g_cvInfernoDamage = FindConVar("inferno_damage");
    if (g_cvInfernoDamage == null)
        g_cvInfernoDamage = CreateConVar("inferno_damage", "55");

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
            OnClientPutInServer(i);
    }
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_TraceAttack, OnTraceAttack);
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

public void OnClientDisconnect(int client)
{
    g_bInFireHook[client] = false;
}

// Bullet/melee/shotgun FF — attacker is always a valid client
public Action OnTraceAttack(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &ammotype, int hitbox, int hitgroup)
{
    if (victim < 1 || victim > MaxClients || attacker < 1 || attacker > MaxClients)
        return Plugin_Continue;

    if (victim == attacker)
        return Plugin_Continue;

    if (GetClientTeam(victim) != 2 || GetClientTeam(attacker) != 2)
        return Plugin_Continue;

    float ffDamage = damage * g_cvFFMultiplier.FloatValue;
    damage = 0.0;

    if (ffDamage > 0.0)
        SDKHooks_TakeDamage(victim, inflictor, attacker, ffDamage, damagetype, -1, NULL_VECTOR, NULL_VECTOR);

    return Plugin_Changed;
}

// Fire/molotov FF — attacker/inflictor is inferno/entityflame, NOT the thrower
public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3])
{
    // Only care about survivor victims
    if (victim < 1 || victim > MaxClients)
        return Plugin_Continue;
    if (GetClientTeam(victim) != 2)
        return Plugin_Continue;

    // Only handle fire/burn damage
    if (!(damagetype & DMG_BURN))
        return Plugin_Continue;

    // Prevent infinite recursion from our own SDKHooks_TakeDamage call
    if (g_bInFireHook[victim])
        return Plugin_Continue;

    // Try to find the real thrower:
    // 1. First check if attacker is a valid survivor (rare but possible)
    // 2. Otherwise check inflictor's m_hOwnerEntity (inferno/entityflame owner)
    int thrower = 0;

    if (attacker >= 1 && attacker <= MaxClients && IsClientInGame(attacker) && GetClientTeam(attacker) == 2)
    {
        thrower = attacker;
    }
    else if (inflictor > 0 && IsValidEntity(inflictor))
    {
        thrower = GetEntPropEnt(inflictor, Prop_Send, "m_hOwnerEntity");
    }

    // If we can't find a thrower, or thrower isn't a survivor teammate, skip
    if (thrower < 1 || thrower > MaxClients || !IsClientInGame(thrower))
        return Plugin_Continue;
    if (GetClientTeam(thrower) != 2)
        return Plugin_Continue;
    if (thrower == victim)
        return Plugin_Continue;

    // Calculate fire FF damage.
    // The engine may have already zeroed this via z_friendly_fire_forgiveness,
    // so we always re-apply via SDKHooks_TakeDamage to bypass that check.
    float fireDamage = damage * g_cvFFFireMultiplier.FloatValue;

    // Zero out original (forgiveness-zeroed) damage
    damage = 0.0;

    if (fireDamage > 0.0)
    {
        // Re-apply via SDKHooks_TakeDamage — this goes straight to the entity's
        // OnTakeDamage, bypassing the forgiveness check that runs at a higher level.
        g_bInFireHook[victim] = true;
        SDKHooks_TakeDamage(victim, inflictor, attacker, fireDamage, damagetype, weapon, damageForce, damagePosition);
        g_bInFireHook[victim] = false;
    }

    return Plugin_Changed;
}
