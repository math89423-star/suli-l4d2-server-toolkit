#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

#define PLUGIN_VERSION "1.0"

ConVar g_hCvarEnable;
ConVar g_hCvarFuel;

public Plugin myinfo =
{
    name        = "[L4D2] Chainsaw Fuel Fix",
    author      = "suli",
    description = "Set chainsaw fuel directly via m_iClip1 when equipped.",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    g_hCvarEnable = CreateConVar("l4d2_chainsaw_fuel_enable", "1",
        "0=OFF, 1=ON.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hCvarFuel = CreateConVar("l4d2_chainsaw_fuel", "90",
        "Chainsaw fuel amount (default 30, 90 = 3x).", FCVAR_NOTIFY, true, 1.0, true, 999.0);

    AutoExecConfig(true, "l4d2_chainsaw_fuel");

    HookEvent("player_use", Event_PlayerUse);
    HookEvent("item_pickup", Event_ItemPickup);
}

// When a player picks up or uses a chainsaw, force fuel to configured value
void Event_PlayerUse(Event event, const char[] name, bool dontBroadcast)
{
    CheckChainsaw(GetClientOfUserId(event.GetInt("userid")));
}

void Event_ItemPickup(Event event, const char[] name, bool dontBroadcast)
{
    char item[64];
    event.GetString("item", item, sizeof(item));
    if (strcmp(item, "chainsaw") != 0) return;
    CheckChainsaw(GetClientOfUserId(event.GetInt("userid")));
}

void CheckChainsaw(int client)
{
    if (!g_hCvarEnable.BoolValue) return;
    if (client < 1 || client > MaxClients || !IsClientInGame(client)) return;
    if (GetClientTeam(client) != 2) return;

    int weapon = GetPlayerWeaponSlot(client, 0); // primary slot (chainsaw replaces primary)
    if (weapon == -1 || !IsValidEntity(weapon)) return;

    char classname[64];
    if (!GetEntityClassname(weapon, classname, sizeof(classname))) return;
    if (strcmp(classname, "weapon_chainsaw") != 0) return;

    int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
    int target = g_hCvarFuel.IntValue;
    if (clip < target)
        SetEntProp(weapon, Prop_Send, "m_iClip1", target);
}
