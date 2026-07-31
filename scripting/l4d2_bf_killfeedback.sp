/**
 * [L4D2] Battlefield Kill Feedback  v4.1.0
 *
 * SOUND-ONLY: Battlefield-style kill sounds per kill type.
 * Uses game sound scripts (game_sounds_battlefield.txt) instead of
 * PrecacheSound, which is unreliable on Linux dedicated servers.
 *
 * v4.1.0 — sound script rewrite:
 *   - PrecacheSound removed entirely (engine auto-precaches sound scripts)
 *   - Cvars now accept game sound script entry names (e.g. "BfKill.SI_Kill")
 *   - EmitSoundToClient uses script entry name — no file extension or path
 *   - File downloads still handled in OnMapStart via AddFileToDownloadsTable
 *
 * v4.0.x — PrecacheSound-based (BROKEN on Linux ds)
 * v3.x   — HUD + chat + sound (deprecated, split to l4d2_si_hud)
 *
 * Pure server-side.  No client files needed.
 * Requires: game_sounds_battlefield.txt in left4dead2/scripts/
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "4.1.0"

// ============================================================================
// ConVars — store sound SCRIPT entry names, not file paths
// ============================================================================

ConVar g_cvEnabled;
ConVar g_cvSoundSIKill;
ConVar g_cvSoundSIHeadshot;
ConVar g_cvSoundTankKill;
ConVar g_cvSoundWitchKill;
ConVar g_cvSoundMeleeKill;
ConVar g_cvSoundCommonHS;
ConVar g_cvVolume;
ConVar g_cvCooldown;

// ============================================================================
// State
// ============================================================================

float g_fLastKillTime[MAXPLAYERS + 1];

// ============================================================================
// Sound files to download (actual mp3 files, relative to sound/)
// ============================================================================

static const char SOUND_FILES[][] = {
    "battlefield/si_kill.mp3",
    "battlefield/si_headshot_kill.mp3",
    "battlefield/tank_kill.mp3",
    "battlefield/witch_kill.mp3",
    "battlefield/melee_kill.mp3",
    "battlefield/common_headshot.mp3"
};

// ============================================================================
// Plugin Info
// ============================================================================

public Plugin myinfo =
{
    name        = "[L4D2] Battlefield Kill Feedback (sound only)",
    author      = "Claude (for suli's server)",
    description = "BF kill sounds via game sound scripts — HUD/chat handled by l4d2_si_hud",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
// Init
// ============================================================================

public void OnPluginStart()
{
    CreateConVar("l4d2_bf_killfeedback_version", PLUGIN_VERSION,
        "[L4D2] Battlefield Kill Feedback version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_cvEnabled = CreateConVar("bf_kill_enabled", "1",
        "Enable/disable kill sounds.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // Cvars now hold GAME SOUND SCRIPT entry names (e.g. "BfKill.SI_Kill"),
    // NOT file paths. The engine resolves them via game_sounds_battlefield.txt.
    g_cvSoundSIKill = CreateConVar("bf_kill_sound_si", "BfKill.SI_Kill",
        "SI kill sound (game sound script name).", FCVAR_NOTIFY);
    g_cvSoundSIHeadshot = CreateConVar("bf_kill_sound_headshot", "BfKill.SI_Headshot",
        "SI headshot sound (game sound script name).", FCVAR_NOTIFY);
    g_cvSoundTankKill = CreateConVar("bf_kill_sound_tank", "BfKill.Tank",
        "Tank kill sound (game sound script name).", FCVAR_NOTIFY);
    g_cvSoundWitchKill = CreateConVar("bf_kill_sound_witch", "BfKill.Witch",
        "Witch kill sound (game sound script name).", FCVAR_NOTIFY);
    g_cvSoundMeleeKill = CreateConVar("bf_kill_sound_melee", "BfKill.Melee",
        "Melee kill sound (game sound script name).", FCVAR_NOTIFY);
    g_cvSoundCommonHS = CreateConVar("bf_kill_sound_common_hs", "",
        "Common headshot sound (game sound script name, empty=off).", FCVAR_NOTIFY);

    g_cvVolume = CreateConVar("bf_kill_volume", "0.8",
        "Sound volume.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvCooldown = CreateConVar("bf_kill_cooldown", "0.1",
        "Min seconds between sounds.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    AutoExecConfig(true, "l4d2_bf_killfeedback");

    HookEvent("player_death",   Event_PlayerDeath);
    HookEvent("infected_death", Event_InfectedDeath);
}

// ============================================================================
// OnMapStart — only download files. NO PrecacheSound needed.
// Sound scripts in scripts/game_sounds_battlefield.txt are auto-precached
// by the engine at server start.
// ============================================================================

public void OnMapStart()
{
    if (!g_cvEnabled.BoolValue) return;
    for (int i = 0; i < sizeof(SOUND_FILES); i++)
    {
        char dl[PLATFORM_MAX_PATH];
        Format(dl, sizeof(dl), "sound/%s", SOUND_FILES[i]);
        AddFileToDownloadsTable(dl);
    }
}

public void OnClientDisconnect(int client)
{
    g_fLastKillTime[client] = 0.0;
}

// ============================================================================
// player_death — SI kill detection (SOUND ONLY)
// ============================================================================

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnabled.BoolValue) return Plugin_Continue;

    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    // ── SI player death → sound for killer ──────────────

    if (victim >= 1 && victim <= MaxClients
        && IsClientInGame(victim) && GetClientTeam(victim) == 3)
    {
        if (attacker >= 1 && attacker <= MaxClients
            && IsClientInGame(attacker) && GetClientTeam(attacker) == 2)
        {
            float now = GetGameTime();
            if (now - g_fLastKillTime[attacker] < g_cvCooldown.FloatValue)
                return Plugin_Continue;

            g_fLastKillTime[attacker] = now;

            bool headshot = event.GetBool("headshot");
            char weaponEnt[64];
            event.GetString("weapon", weaponEnt, sizeof(weaponEnt));
            bool melee = (StrEqual(weaponEnt, "melee") || StrEqual(weaponEnt, "chainsaw"));

            char sound[PLATFORM_MAX_PATH];
            if (IsTank(victim))
                PickSound(sound, sizeof(sound), g_cvSoundTankKill, g_cvSoundSIKill);
            else if (headshot)
                PickSound(sound, sizeof(sound), g_cvSoundSIHeadshot, g_cvSoundSIKill);
            else if (melee)
                PickSound(sound, sizeof(sound), g_cvSoundMeleeKill, g_cvSoundSIKill);
            else
                g_cvSoundSIKill.GetString(sound, sizeof(sound));

            PlayClientSound(attacker, sound);
        }
        return Plugin_Continue;
    }

    // ── Witch death → sound for killer ───────────────────

    int entityid = event.GetInt("entityid");
    if (entityid > 0 && IsWitchEntity(entityid))
    {
        if (attacker >= 1 && attacker <= MaxClients
            && IsClientInGame(attacker) && GetClientTeam(attacker) == 2)
        {
            float now = GetGameTime();
            if (now - g_fLastKillTime[attacker] < g_cvCooldown.FloatValue)
                return Plugin_Continue;

            g_fLastKillTime[attacker] = now;

            char sound[PLATFORM_MAX_PATH];
            PickSound(sound, sizeof(sound), g_cvSoundWitchKill, g_cvSoundSIKill);
            PlayClientSound(attacker, sound);
        }
        return Plugin_Continue;
    }

    return Plugin_Continue;
}

// ============================================================================
// infected_death — common infected headshot sound
// ============================================================================

public Action Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnabled.BoolValue) return Plugin_Continue;
    if (!event.GetBool("headshot")) return Plugin_Continue;
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker)) return Plugin_Continue;
    if (GetClientTeam(attacker) != 2) return Plugin_Continue;

    char sound[PLATFORM_MAX_PATH];
    g_cvSoundCommonHS.GetString(sound, sizeof(sound));
    if (sound[0] == '\0') return Plugin_Continue;
    if (GetGameTime() - g_fLastKillTime[attacker] < g_cvCooldown.FloatValue) return Plugin_Continue;

    g_fLastKillTime[attacker] = GetGameTime();
    PlayClientSound(attacker, sound);
    return Plugin_Continue;
}

// ============================================================================
// Helpers
// ============================================================================

void PickSound(char[] buffer, int maxlen, ConVar primary, ConVar fallback)
{
    primary.GetString(buffer, maxlen);
    if (buffer[0] == '\0') fallback.GetString(buffer, maxlen);
}

void PlayClientSound(int client, const char[] sound)
{
    // sound is a game sound SCRIPT entry name (e.g. "BfKill.SI_Kill"),
    // NOT a file path. No extension stripping needed — the engine
    // resolves it via the sound script to the actual wave file.
    if (sound[0] == '\0') return;
    float vol = g_cvVolume.FloatValue;
    if (vol <= 0.0) return;

    EmitSoundToClient(client, sound, 0, SNDCHAN_STATIC, SNDLEVEL_NORMAL,
        SND_NOFLAGS, vol >= 1.0 ? 1.0 : vol);
}

bool IsTank(int client)
{
    return GetEntProp(client, Prop_Send, "m_zombieClass") == 8;
}

bool IsWitchEntity(int entity)
{
    if (entity <= 0 || !IsValidEntity(entity)) return false;
    char cls[32]; GetEntityClassname(entity, cls, sizeof(cls));
    return StrContains(cls, "witch") != -1;
}
