#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.0"

ConVar g_cvM60Clip;

public Plugin myinfo = {
    name = "M60 Ammo Fix",
    author = "claude",
    description = "Set M60 clip size (sm_weapon clipsize doesn't work for M60)",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    g_cvM60Clip = CreateConVar("sm_m60_clip", "450", "M60 clip size", _, true, 150.0);
    AutoExecConfig(true, "l4d2_m60_ammo");
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (StrEqual(classname, "weapon_rifle_m60"))
    {
        SDKHook(entity, SDKHook_SpawnPost, OnM60SpawnPost);
    }
}

void OnM60SpawnPost(int entity)
{
    SetEntProp(entity, Prop_Send, "m_iClip1", g_cvM60Clip.IntValue);
}
