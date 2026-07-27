/**
 * [L4D2] Headshot Sound Feedback (Sound-Only)
 *
 * Plays distinct sounds when you:
 *   - Land a headshot on any infected (hurt sound)
 *   - Kill any infected with a headshot (kill sound)
 *
 * Works on both common infected and special infected.
 * No buffs, no health rewards, no particle effects — pure audio feedback.
 *
 * Based on the cvar naming convention from NoroHime's Headshot Reward plugin,
 * but stripped down to sound-only functionality.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

#define PLUGIN_VERSION "1.0.0"

// ============================================================================
// ConVars
// ============================================================================

ConVar g_cvEnabled;
ConVar g_cvSoundHurt;
ConVar g_cvSoundKill;
ConVar g_cvVolume;
ConVar g_cvCooldownHurt;
ConVar g_cvDeathOnly;

// ============================================================================
// State
// ============================================================================

// Last hurt sound time per client (global cooldown to avoid spam from autos)
float g_fLastHurtTime[MAXPLAYERS + 1];

// ============================================================================
// Plugin Info
// ============================================================================

public Plugin myinfo =
{
    name        = "[L4D2] Headshot Sound Feedback",
    author      = "suli (sound-only fork from NoroHime concept)",
    description = "Plays sounds on headshot hits and headshot kills — no buffs, no HP, no particles",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
// Init
// ============================================================================

public void OnPluginStart()
{
    CreateConVar("l4d2_headshot_sound_version", PLUGIN_VERSION,
        "[L4D2] Headshot Sound Feedback version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_cvEnabled = CreateConVar("headshot_sound_enabled", "1",
        "Enable/disable headshot sound feedback (1=on, 0=off)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvSoundHurt = CreateConVar("headshot_sound_hurt", "ui/littlereward.wav",
        "Sound played on headshot hit (non-lethal). Leave empty to disable.",
        FCVAR_NOTIFY);

    g_cvSoundKill = CreateConVar("headshot_sound_kill", "level/bell_normal.wav",
        "Sound played on headshot kill. Leave empty to disable.",
        FCVAR_NOTIFY);

    g_cvVolume = CreateConVar("headshot_sound_volume", "1.0",
        "Sound volume (0.0 = silent, 1.0 = full)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvCooldownHurt = CreateConVar("headshot_sound_cooldown", "0.05",
        "Minimum seconds between hurt sounds per client (prevents spam from rapid fire)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvDeathOnly = CreateConVar("headshot_sound_death_only", "0",
        "Only play sounds on headshot kills, not on headshot hits (1=on, 0=off)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // Auto-generate config
    AutoExecConfig(true, "l4d2_headshot_sound");

    // Hook events
    HookEvent("player_hurt",     Event_PlayerHurt);
    HookEvent("player_death",    Event_PlayerDeath);
    HookEvent("infected_death",  Event_InfectedDeath);

    // Hook late-spawning infected
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
            SDKHook(i, SDKHook_TraceAttack, OnTraceAttack);
    }
}

public void OnClientPutInServer(int client)
{
    // Hook special infected (player-controlled) for TraceAttack
    SDKHook(client, SDKHook_TraceAttack, OnTraceAttack);
}

public void OnEntityCreated(int entity, const char[] classname)
{
    // Hook common infected for TraceAttack
    if (StrEqual(classname, "infected"))
        SDKHook(entity, SDKHook_TraceAttack, OnTraceAttack);
}

// ============================================================================
// Precache sounds
// ============================================================================

public void OnMapStart()
{
    PrecacheSound2("ui/littlereward.wav");
    PrecacheSound2("level/bell_normal.wav");
}

void PrecacheSound2(const char[] sound)
{
    if (sound[0] == '\0')
        return;

    char buffer[PLATFORM_MAX_PATH];
    Format(buffer, sizeof(buffer), "sound/%s", sound);
    AddFileToDownloadsTable(buffer);

    // Precache for EmitSound
    PrecacheSound(sound, true);
}

// ============================================================================
// TraceAttack — Used for common infected headshot detection
// (infected_hurt event doesn't include hitgroup)
// ============================================================================

public Action OnTraceAttack(int victim, int &attacker, int &inflictor, float &damage,
    int &damagetype, int &ammotype, int hitbox, int hitgroup)
{
    if (!g_cvEnabled.BoolValue || g_cvDeathOnly.BoolValue)
        return Plugin_Continue;

    // Only process headshots
    if (hitgroup != 1) // HITGROUP_HEAD
        return Plugin_Continue;

    // Attacker must be a valid survivor client
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
        return Plugin_Continue;

    // Skip if victim is a survivor (friendly fire)
    if (1 <= victim <= MaxClients && GetClientTeam(victim) == 2)
        return Plugin_Continue;

    // Cooldown check
    float now = GetGameTime();
    if (now - g_fLastHurtTime[attacker] < g_cvCooldownHurt.FloatValue)
        return Plugin_Continue;

    // Special infected (player clients): skip TraceAttack sound,
    // let player_hurt event handle it (more accurate, won't duplicate).
    if (1 <= victim <= MaxClients)
        return Plugin_Continue;

    // Common infected: play hurt sound via TraceAttack
    g_fLastHurtTime[attacker] = now;
    PlayClientSound(attacker, g_cvSoundHurt);

    return Plugin_Continue;
}

// ============================================================================
// player_hurt — Special infected headshot hit detection
// ============================================================================

public Action Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnabled.BoolValue || g_cvDeathOnly.BoolValue)
        return Plugin_Continue;

    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int hitgroup = event.GetInt("hitgroup");

    // Headshot check
    if (hitgroup != 1)
        return Plugin_Continue;

    // Attacker must be a valid survivor
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
        return Plugin_Continue;

    // Victim must be special infected (player client on team 3)
    if (victim < 1 || victim > MaxClients || GetClientTeam(victim) != 3)
        return Plugin_Continue;

    // Cooldown check
    float now = GetGameTime();
    if (now - g_fLastHurtTime[attacker] < g_cvCooldownHurt.FloatValue)
        return Plugin_Continue;

    g_fLastHurtTime[attacker] = now;
    PlayClientSound(attacker, g_cvSoundHurt);

    return Plugin_Continue;
}

// ============================================================================
// player_death — Special infected + Witch headshot kill detection
// ============================================================================

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnabled.BoolValue)
        return Plugin_Continue;

    bool headshot = event.GetBool("headshot");
    if (!headshot)
        return Plugin_Continue;

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
        return Plugin_Continue;

    PlayClientSound(attacker, g_cvSoundKill);
    return Plugin_Continue;
}

// ============================================================================
// infected_death — Common infected headshot kill detection
// ============================================================================

public Action Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnabled.BoolValue)
        return Plugin_Continue;

    bool headshot = event.GetBool("headshot");
    if (!headshot)
        return Plugin_Continue;

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
        return Plugin_Continue;

    PlayClientSound(attacker, g_cvSoundKill);
    return Plugin_Continue;
}

// ============================================================================
// Helpers
// ============================================================================

void PlayClientSound(int client, ConVar cvar)
{
    char sound[PLATFORM_MAX_PATH];
    cvar.GetString(sound, sizeof(sound));

    if (sound[0] == '\0')
        return;

    float vol = g_cvVolume.FloatValue;

    if (vol <= 0.0)
        return;

    if (vol >= 1.0)
        EmitSoundToClient(client, sound);
    else
        EmitSoundToClient(client, sound, _, _, _, _, vol);
}
