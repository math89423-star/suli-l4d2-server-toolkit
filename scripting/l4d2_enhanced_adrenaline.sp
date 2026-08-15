#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <left4dhooks_lux_library>

#define PLUGIN_VERSION "1.0.0"

ConVar g_cvAdrenalineDuration;
ConVar g_cvMeleeSpeedBoost;

public Plugin myinfo =
{
	name = "[L4D2] Enhanced Adrenaline",
	author = "Suli",
	description = "Extends adrenaline duration and adds melee speed boost",
	version = PLUGIN_VERSION,
	url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if(GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 2");
		return APLRes_SilentFailure;
	}
	return APLRes_Success;
}

public void OnPluginStart()
{
	CreateConVar("l4d2_enhanced_adrenaline_version", PLUGIN_VERSION, "Enhanced Adrenaline version", FCVAR_NOTIFY|FCVAR_DONTRECORD);

	g_cvAdrenalineDuration = CreateConVar("l4d2_adrenaline_duration", "45.0", "Adrenaline effect duration in seconds", FCVAR_NOTIFY, true, 1.0, true, 120.0);
	g_cvMeleeSpeedBoost = CreateConVar("l4d2_adrenaline_melee_boost", "1.25", "Melee attack speed multiplier when on adrenaline (1.25 = 25% faster)", FCVAR_NOTIFY, true, 1.0, true, 3.0);

	HookEvent("adrenaline_used", Event_AdrenalineUsed, EventHookMode_Post);

	AutoExecConfig(true, "l4d2_enhanced_adrenaline");
}

public void Event_AdrenalineUsed(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if(!client || !IsClientInGame(client) || GetClientTeam(client) != 2)
		return;

	float duration = g_cvAdrenalineDuration.FloatValue;

	// Set custom adrenaline duration
	Terror_SetAdrenalineTime(client, duration);
}

// WeaponHandling forward - called when melee weapon swings
public Action WH_OnMeleeSwing(int client, int weapon, float &speedmodifier)
{
	// Check if player has adrenaline active
	if(GetEntProp(client, Prop_Send, "m_bAdrenalineActive", 1) > 0)
	{
		// Apply melee speed boost
		speedmodifier *= g_cvMeleeSpeedBoost.FloatValue;
		return Plugin_Changed;
	}

	return Plugin_Continue;
}
