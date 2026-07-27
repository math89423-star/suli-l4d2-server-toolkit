/**
 * [L4D2] Loot Drop Sound
 *
 * Companion plugin for l4d2_loot_drop.smx.
 * Plays a sound when items spawn near survivors during active gameplay
 * (indicating a loot drop from killing infected).
 *
 * Design: hooks entity spawns, filters by:
 *   1. Round is active (after round_start, before round_end)
 *   2. Entity is a weapon/item type
 *   3. Entity spawns within range of a survivor (loot drop, not map spawn)
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

#define PLUGIN_VERSION "1.0.0"

// How close (Hammer units) a spawn must be to a survivor to count as a drop
#define PROXIMITY_THRESHOLD 200.0

// How long after round_start to suppress sounds (lets map-placed items settle)
#define ROUND_START_GRACE 3.0

// ============================================================================
// ConVars
// ============================================================================

ConVar g_cvEnabled;
ConVar g_cvSound;
ConVar g_cvVolume;
ConVar g_cvProximity;

// ============================================================================
// State
// ============================================================================

bool  g_bRoundActive;
float g_fRoundStartTime;

// ============================================================================
// Plugin Info
// ============================================================================

public Plugin myinfo =
{
    name        = "[L4D2] Loot Drop Sound",
    author      = "suli",
    description = "Plays a sound when loot drops from killed infected",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
// Init
// ============================================================================

public void OnPluginStart()
{
    CreateConVar("l4d2_loot_sound_version", PLUGIN_VERSION,
        "[L4D2] Loot Drop Sound version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_cvEnabled = CreateConVar("sm_loot_sound_enabled", "1",
        "Enable loot drop sound (1=on, 0=off)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvSound = CreateConVar("sm_loot_sound_path", "ui/littlereward.wav",
        "Sound played when loot drops. Leave empty to disable.",
        FCVAR_NOTIFY);

    g_cvVolume = CreateConVar("sm_loot_sound_volume", "0.7",
        "Loot drop sound volume (0.0 = silent, 1.0 = full)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvProximity = CreateConVar("sm_loot_sound_proximity", "200.0",
        "Max distance (units) from survivor to count as loot drop",
        FCVAR_NOTIFY, true, 50.0, true, 1000.0);

    AutoExecConfig(true, "l4d2_loot_sound");

    // Round lifecycle
    HookEvent("round_start",  Event_RoundStart);
    HookEvent("round_end",    Event_RoundEnd);
    HookEvent("map_transition", Event_RoundEnd);
    HookEvent("finale_win",   Event_RoundEnd);
    HookEvent("mission_lost", Event_RoundEnd);

    // Hook already-existing weapon entities (in case server started before plugin loaded)
    int iEnt = -1;
    while ((iEnt = FindEntityByClassname(iEnt, "weapon_*")) != -1)
        SDKHook(iEnt, SDKHook_SpawnPost, OnWeaponSpawnPost);
}

// ============================================================================
// Events
// ============================================================================

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bRoundActive = true;
    g_fRoundStartTime = GetGameTime();
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    g_bRoundActive = false;
}

// ============================================================================
// Precache
// ============================================================================

public void OnMapStart()
{
    char sound[PLATFORM_MAX_PATH];
    g_cvSound.GetString(sound, sizeof(sound));

    if (sound[0] != '\0')
    {
        char dlpath[PLATFORM_MAX_PATH];
        Format(dlpath, sizeof(dlpath), "sound/%s", sound);
        AddFileToDownloadsTable(dlpath);
        PrecacheSound(sound, true);
    }
}

// ============================================================================
// Entity hooks
// ============================================================================

public void OnEntityCreated(int entity, const char[] classname)
{
    if (!g_cvEnabled.BoolValue)
        return;

    // Only hook weapon/item entities
    if (StrContains(classname, "weapon_") != 0 && StrContains(classname, "item_") != 0)
        return;

    // Skip if this is the ammo/upgrade pack deploy entity (will handle the actual item)
    // weapon_spawn entities are the map-placed pickup nodes — skip those
    if (StrEqual(classname, "weapon_spawn") || StrEqual(classname, "weapon_ammo_spawn"))
        return;

    SDKHook(entity, SDKHook_SpawnPost, OnWeaponSpawnPost);
}

public void OnWeaponSpawnPost(int entity)
{
    if (!g_cvEnabled.BoolValue || !g_bRoundActive)
        return;

    // Grace period after round_start — suppress to avoid map-placed item noise
    if (GetGameTime() - g_fRoundStartTime < ROUND_START_GRACE)
        return;

    char sound[PLATFORM_MAX_PATH];
    g_cvSound.GetString(sound, sizeof(sound));
    if (sound[0] == '\0')
        return;

    // Get spawn position
    float vOrigin[3];
    if (!GetEntPropVector(entity, Prop_Send, "m_vecOrigin", vOrigin))
        return;

    // Check if any survivor is nearby (loot drops spawn near the player who got the kill)
    float proximity = g_cvProximity.FloatValue;
    bool bNearSurvivor = false;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || GetClientTeam(i) != 2 || !IsPlayerAlive(i))
            continue;

        float vClient[3];
        GetClientAbsOrigin(i, vClient);

        if (GetVectorDistance(vOrigin, vClient) <= proximity)
        {
            bNearSurvivor = true;
            break;
        }
    }

    if (!bNearSurvivor)
        return;

    // Play drop sound to all nearby survivors so they hear the loot plop
    float vol = g_cvVolume.FloatValue;
    if (vol <= 0.0)
        return;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || GetClientTeam(i) != 2 || !IsPlayerAlive(i))
            continue;

        float vClient[3];
        GetClientAbsOrigin(i, vClient);

        if (GetVectorDistance(vOrigin, vClient) <= 800.0) // audible range
        {
            if (vol >= 1.0)
                EmitSoundToClient(i, sound, entity, _, SNDLEVEL_NORMAL);
            else
                EmitSoundToClient(i, sound, entity, _, SNDLEVEL_NORMAL, _, vol);
        }
    }
}
