#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>

#define PLUGIN_VERSION "1.1"

ConVar g_hCvarEnable;
ConVar g_hCvarMinigunMult;
ConVar g_hCvarHMG50Mult;
ConVar g_hCvarOverheatEnable;
ConVar g_hCvarOverheatRate;

ArrayList g_MinigunEntities;
Handle g_hOverheatTimer;

public Plugin myinfo =
{
    name        = "[L4D2] Mounted Gun Damage & Overheat",
    author      = "suli",
    description = "Modify damage and overheat of prop_minigun / prop_mounted_machine_gun.",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    g_hCvarEnable = CreateConVar("l4d2_mg_enable", "1",
        "0=OFF, 1=ON.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hCvarMinigunMult = CreateConVar("l4d2_mg_minigun_damage", "1.0",
        "Damage multiplier for 7.62mm rotary minigun (prop_minigun). 1.0 = default.",
        FCVAR_NOTIFY, true, 0.1, true, 50.0);

    g_hCvarHMG50Mult = CreateConVar("l4d2_mg_50cal_damage", "1.0",
        "Damage multiplier for 12.7mm heavy MG (prop_mounted_machine_gun). 1.0 = default.",
        FCVAR_NOTIFY, true, 0.1, true, 50.0);

    g_hCvarOverheatEnable = CreateConVar("l4d2_mg_overheat_enable", "1",
        "0=OFF (vanilla overheat), 1=ON (use rate below).", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hCvarOverheatRate = CreateConVar("l4d2_mg_overheat_rate", "1.0",
        "Minigun overheat rate. 1.0=normal, 0.5=2x slower, 0.0=never overheat.",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    AutoExecConfig(true, "l4d2_mounted_gun_damage");

    g_MinigunEntities = new ArrayList();
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (entity < 1) return;

    // Hook damage for infected targets
    if (strcmp(classname, "infected")      == 0 ||
        strcmp(classname, "witch")         == 0 ||
        strcmp(classname, "tank")          == 0 ||
        strcmp(classname, "hunter")        == 0 ||
        strcmp(classname, "smoker")        == 0 ||
        strcmp(classname, "boomer")        == 0 ||
        strcmp(classname, "spitter")       == 0 ||
        strcmp(classname, "jockey")        == 0 ||
        strcmp(classname, "charger")       == 0)
    {
        SDKHook(entity, SDKHook_OnTakeDamage, OnTakeDamage);
    }

    // Track minigun entities for overheat control
    if (strcmp(classname, "prop_minigun") == 0)
    {
        g_MinigunEntities.Push(EntIndexToEntRef(entity));
        if (g_hOverheatTimer == null)
            g_hOverheatTimer = CreateTimer(0.2, Timer_OverheatControl, _, TIMER_REPEAT);
    }
}

public void OnEntityDestroyed(int entity)
{
    if (entity < 1 || !IsValidEntity(entity)) return;
    char classname[64];
    if (!GetEntityClassname(entity, classname, sizeof(classname))) return;
    if (strcmp(classname, "prop_minigun") != 0) return;

    int ref = EntIndexToEntRef(entity);
    int idx = g_MinigunEntities.FindValue(ref);
    if (idx >= 0)
        g_MinigunEntities.Erase(idx);

    if (g_MinigunEntities.Length == 0 && g_hOverheatTimer != null)
    {
        KillTimer(g_hOverheatTimer);
        g_hOverheatTimer = null;
    }
}

Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (!g_hCvarEnable.BoolValue) return Plugin_Continue;
    if (damage <= 0.0) return Plugin_Continue;

    if (inflictor < 1 || !IsValidEntity(inflictor)) return Plugin_Continue;

    char classname[64];
    if (!GetEntityClassname(inflictor, classname, sizeof(classname))) return Plugin_Continue;

    float mult = 1.0;

    if (strcmp(classname, "prop_minigun") == 0)
    {
        mult = g_hCvarMinigunMult.FloatValue;
    }
    else if (strcmp(classname, "prop_mounted_machine_gun") == 0)
    {
        mult = g_hCvarHMG50Mult.FloatValue;
    }
    else
    {
        return Plugin_Continue;
    }

    if (mult == 1.0) return Plugin_Continue;

    damage *= mult;
    return Plugin_Changed;
}

// Periodically reduce m_iShotsFired on miniguns to slow/disable overheat.
// rate=1.0 → no change; rate=0.5 → half-speed overheat; rate=0.0 → never overheat.
Action Timer_OverheatControl(Handle timer)
{
    if (!g_hCvarOverheatEnable.BoolValue) return Plugin_Continue;

    float rate = g_hCvarOverheatRate.FloatValue;
    if (rate >= 1.0) return Plugin_Continue;

    for (int i = g_MinigunEntities.Length - 1; i >= 0; i--)
    {
        int entity = EntRefToEntIndex(g_MinigunEntities.Get(i));
        if (entity == INVALID_ENT_REFERENCE || !IsValidEntity(entity))
        {
            g_MinigunEntities.Erase(i);
            continue;
        }

        int shots = GetEntProp(entity, Prop_Send, "m_iShotsFired");
        if (shots <= 0) continue;

        if (rate <= 0.0)
        {
            SetEntProp(entity, Prop_Send, "m_iShotsFired", 0);
        }
        else
        {
            int newShots = RoundToCeil(float(shots) * rate);
            if (newShots < shots)
                SetEntProp(entity, Prop_Send, "m_iShotsFired", newShots);
        }
    }

    if (g_MinigunEntities.Length == 0)
    {
        g_hOverheatTimer = null;
        return Plugin_Stop;
    }

    return Plugin_Continue;
}
