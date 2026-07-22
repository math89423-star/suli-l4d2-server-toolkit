/**
 * l4d2_shotgun_speed.sp
 * Shotgun fire rate and reload speed via WeaponHandling forwards.
 * sm_weapon + left4dhooks does NOT work for shotguns — they use different code paths.
 */

#include <sourcemod>
#include <weaponhandling>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.1.0"

ConVar g_cvPumpReload;
ConVar g_cvPumpFireRate;
ConVar g_cvAutoReload;
ConVar g_cvAutoFireRate;

public Plugin myinfo =
{
    name = "L4D2 Shotgun Speed",
    author = "claude",
    description = "Per-shotgun fire rate and reload speed via WeaponHandling",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    g_cvPumpReload   = CreateConVar("sm_shotgun_pump_reload", "1.2",  "Pump shotguns reload speed multiplier", _, true, 0.1, true, 10.0);
    g_cvPumpFireRate = CreateConVar("sm_shotgun_pump_fire",   "1.15", "Pump shotguns fire rate multiplier",    _, true, 0.1, true, 10.0);
    g_cvAutoReload   = CreateConVar("sm_shotgun_auto_reload", "1.1",  "Auto shotguns reload speed multiplier", _, true, 0.1, true, 10.0);
    g_cvAutoFireRate = CreateConVar("sm_shotgun_auto_fire",   "1.0",  "Auto shotguns fire rate multiplier",    _, true, 0.1, true, 10.0);
    AutoExecConfig(true, "l4d2_shotgun_speed");
}

public void WH_OnReloadModifier(int client, int weapon, L4D2WeaponType weapontype, float &speedmodifier)
{
    if (weapontype == L4D2WeaponType_Pumpshotgun || weapontype == L4D2WeaponType_PumpshotgunChrome)
        speedmodifier = g_cvPumpReload.FloatValue;
    else if (weapontype == L4D2WeaponType_Autoshotgun || weapontype == L4D2WeaponType_AutoshotgunSpas)
        speedmodifier = g_cvAutoReload.FloatValue;
}

public void WH_OnGetRateOfFire(int client, int weapon, L4D2WeaponType weapontype, float &speedmodifier)
{
    if (weapontype == L4D2WeaponType_Pumpshotgun || weapontype == L4D2WeaponType_PumpshotgunChrome)
        speedmodifier = g_cvPumpFireRate.FloatValue;
    else if (weapontype == L4D2WeaponType_Autoshotgun || weapontype == L4D2WeaponType_AutoshotgunSpas)
        speedmodifier = g_cvAutoFireRate.FloatValue;
}
