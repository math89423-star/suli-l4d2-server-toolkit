/**
 * [L4D2] Battlefield Kill Feedback
 *
 * Battlefield-style kill confirmation:
 *   - Kill a Special Infected → "ching" sound + skull icon (☠) on screen
 *   - Headshot kill → enhanced sound + [HS] tag
 *   - Tank / Witch kill → special celebration sound
 *   - Melee kill → distinct sound
 *
 * Pure server-side plugin — no client mods required.
 * Sound files are configurable; drop Battlefield .wav/.mp3 rips into
 * left4dead2/sound/battlefield/ and set the ConVars.
 *
 * Battlefield audio sources:
 *   https://modworkshop.net/mod/46718 (BF1 Kill & Hit Sounds, .ogg)
 *   https://www.nexusmods.com/newvegas/mods/94052 (BF1/BFV kill sounds)
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
ConVar g_cvSoundSIKill;
ConVar g_cvSoundSIHeadshot;
ConVar g_cvSoundTankKill;
ConVar g_cvSoundWitchKill;
ConVar g_cvSoundMeleeKill;
ConVar g_cvSoundCommonHS;
ConVar g_cvVolume;
ConVar g_cvHudEnabled;
ConVar g_cvKillStreak;
ConVar g_cvCooldown;

// ============================================================================
// State
// ============================================================================

int   g_iKillStreak[MAXPLAYERS + 1];
float g_fLastKillTime[MAXPLAYERS + 1];

// ============================================================================
// Plugin Info
// ============================================================================

public Plugin myinfo =
{
    name        = "[L4D2] Battlefield Kill Feedback",
    author      = "Claude (for suli's server)",
    description = "Battlefield-style kill sound + skull icon on SI kills",
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
        "Enable/disable Battlefield kill feedback (1=on, 0=off)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvSoundSIKill = CreateConVar("bf_kill_sound_si", "battlefield/si_kill.mp3",
        "Sound played when killing a Special Infected. Leave empty to disable.",
        FCVAR_NOTIFY);

    g_cvSoundSIHeadshot = CreateConVar("bf_kill_sound_headshot", "battlefield/si_headshot_kill.mp3",
        "Sound played when killing a Special Infected with a headshot. Leave empty for same as SI kill.",
        FCVAR_NOTIFY);

    g_cvSoundTankKill = CreateConVar("bf_kill_sound_tank", "battlefield/tank_kill.mp3",
        "Sound played when killing a Tank. Leave empty to use default SI kill sound.",
        FCVAR_NOTIFY);

    g_cvSoundWitchKill = CreateConVar("bf_kill_sound_witch", "battlefield/witch_kill.mp3",
        "Sound played when killing a Witch. Leave empty to use default SI kill sound.",
        FCVAR_NOTIFY);

    g_cvSoundMeleeKill = CreateConVar("bf_kill_sound_melee", "battlefield/melee_kill.mp3",
        "Sound played on melee kill. Leave empty to use default SI kill sound.",
        FCVAR_NOTIFY);

    g_cvSoundCommonHS = CreateConVar("bf_kill_sound_common_hs", "",
        "Sound played on common infected headshot kill. Leave empty to disable.",
        FCVAR_NOTIFY);

    g_cvVolume = CreateConVar("bf_kill_volume", "0.8",
        "Sound volume (0.0 = silent, 1.0 = full)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvHudEnabled = CreateConVar("bf_kill_hud_enabled", "1",
        "Show skull icon HUD notification on kill (1=on, 0=off)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);


    g_cvKillStreak = CreateConVar("bf_kill_streak_threshold", "3",
        "Show streak counter when consecutive SI kills reach this number. 0=off.",
        FCVAR_NOTIFY, true, 0.0, true, 99.0);

    g_cvCooldown = CreateConVar("bf_kill_cooldown", "0.1",
        "Minimum seconds between kill sounds (prevents overlap).",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    AutoExecConfig(true, "l4d2_bf_killfeedback");

    HookEvent("player_death",   Event_PlayerDeath);
    HookEvent("infected_death", Event_InfectedDeath);

    // Reset streaks on round end
    HookEvent("round_end",      Event_RoundEnd);
}

// ============================================================================
// Precache sounds
// ============================================================================

public void OnMapStart()
{
    // Precache all configured sounds
    PrecacheSound2("battlefield/si_kill.mp3");
    PrecacheSound2("battlefield/si_headshot_kill.mp3");
    PrecacheSound2("battlefield/tank_kill.mp3");
    PrecacheSound2("battlefield/witch_kill.mp3");
    PrecacheSound2("battlefield/melee_kill.mp3");
    PrecacheSound2("battlefield/common_headshot.mp3");
}

void PrecacheSound2(const char[] sound)
{
    if (sound[0] == '\0')
        return;

    char buffer[PLATFORM_MAX_PATH];
    Format(buffer, sizeof(buffer), "sound/%s", sound);

    // Make sure clients download the file
    AddFileToDownloadsTable(buffer);

    // Precache for EmitSound
    PrecacheSound(sound, true);
}

// ============================================================================
// Reset state
// ============================================================================

public void OnClientDisconnect(int client)
{
    g_iKillStreak[client] = 0;
    g_fLastKillTime[client] = 0.0;
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_iKillStreak[i] = 0;
        g_fLastKillTime[i] = 0.0;
    }
}

// ============================================================================
// player_death — Special Infected kill detection
// ============================================================================

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnabled.BoolValue)
        return Plugin_Continue;

    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    // Attacker must be a valid survivor
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
        return Plugin_Continue;

    if (GetClientTeam(attacker) != 2)
        return Plugin_Continue;

    // Cooldown check
    float now = GetGameTime();
    if (now - g_fLastKillTime[attacker] < g_cvCooldown.FloatValue)
        return Plugin_Continue;

    bool headshot = event.GetBool("headshot");

    // Check if victim is a Special Infected or Witch
    if (victim >= 1 && victim <= MaxClients && GetClientTeam(victim) == 3)
    {
        // ---- Special Infected Kill ----
        g_fLastKillTime[attacker] = now;

        // Kill streak
        g_iKillStreak[attacker]++;
        int streakThreshold = g_cvKillStreak.IntValue;

        char siName[32];
        GetSIName(victim, siName, sizeof(siName));

        // Detect melee kill
        char weapon[64];
        event.GetString("weapon", weapon, sizeof(weapon));
        bool melee = IsMeleeWeapon(weapon);

        // Determine sound
        char sound[PLATFORM_MAX_PATH];

        if (IsTank(victim))
        {
            // Tank kill — special celebration
            GetSoundPath(sound, sizeof(sound), g_cvSoundTankKill, g_cvSoundSIKill);
        }
        else if (headshot)
        {
            // Headshot kill on SI
            GetSoundPath(sound, sizeof(sound), g_cvSoundSIHeadshot, g_cvSoundSIKill);
        }
        else if (melee)
        {
            // Melee kill on SI
            GetSoundPath(sound, sizeof(sound), g_cvSoundMeleeKill, g_cvSoundSIKill);
        }
        else
        {
            // Default SI kill
            g_cvSoundSIKill.GetString(sound, sizeof(sound));
        }

        PlayClientSound(attacker, sound);

        // Show HUD notification
        if (g_cvHudEnabled.BoolValue)
        {
            ShowKillHud(attacker, siName, headshot, melee, IsTank(victim), false, g_iKillStreak[attacker], streakThreshold);
        }
    }
    else
    {
        // ---- Witch kill (witch is an entity, not a player client) ----
        // The witch death is caught via the "entityid" field
        int entityid = event.GetInt("entityid");
        if (entityid > 0 && IsWitchEntity(entityid))
        {
            g_fLastKillTime[attacker] = now;
            g_iKillStreak[attacker]++;

            int streakThreshold = g_cvKillStreak.IntValue;
            char sound[PLATFORM_MAX_PATH];
            GetSoundPath(sound, sizeof(sound), g_cvSoundWitchKill, g_cvSoundSIKill);

            PlayClientSound(attacker, sound);

            if (g_cvHudEnabled.BoolValue)
            {
                ShowKillHud(attacker, "Witch", headshot, false, false, true, g_iKillStreak[attacker], streakThreshold);
            }
        }
    }

    return Plugin_Continue;
}

// ============================================================================
// infected_death — Common infected headshot kill
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

    if (GetClientTeam(attacker) != 2)
        return Plugin_Continue;

    // Only play sound if a common headshot sound is configured
    char sound[PLATFORM_MAX_PATH];
    g_cvSoundCommonHS.GetString(sound, sizeof(sound));
    if (sound[0] == '\0')
        return Plugin_Continue;

    float now = GetGameTime();
    if (now - g_fLastKillTime[attacker] < g_cvCooldown.FloatValue)
        return Plugin_Continue;

    g_fLastKillTime[attacker] = now;
    PlayClientSound(attacker, sound);

    return Plugin_Continue;
}

// ============================================================================
// HUD notification — skull icon + kill info
// ============================================================================

void ShowKillHud(int client, const char[] siName, bool headshot, bool melee, bool isTank, bool isWitch, int streak, int streakThreshold)
{
    char msg[256];

    // Tier-based visual: Tank ★★ > Witch ★ > Headshot ☠☠ > Melee > Normal
    if (isTank)
    {
        if (headshot)
            Format(msg, sizeof(msg), "★★  ☠  %s  爆头击杀  ☠  ★★", siName);
        else if (melee)
            Format(msg, sizeof(msg), "★★  ☠  %s  近战击杀  ☠  ★★", siName);
        else
            Format(msg, sizeof(msg), "★★  ☠  %s  击杀  ☠  ★★", siName);
    }
    else if (isWitch)
    {
        if (headshot)
            Format(msg, sizeof(msg), "★  ☠  %s  爆头击杀  ☠  ★", siName);
        else
            Format(msg, sizeof(msg), "★  ☠  %s  击杀  ☠  ★", siName);
    }
    else if (headshot && melee)
    {
        Format(msg, sizeof(msg), "☠☠  %s  爆头近战击杀", siName);
    }
    else if (headshot)
    {
        Format(msg, sizeof(msg), "☠☠  %s  爆头击杀", siName);
    }
    else if (melee)
    {
        Format(msg, sizeof(msg), "☠  %s  近战击杀", siName);
    }
    else
    {
        Format(msg, sizeof(msg), "☠  %s  击杀", siName);
    }

    // Streak counter
    if (streakThreshold > 0 && streak >= streakThreshold)
        Format(msg, sizeof(msg), "%s  x%d", msg, streak);

    // Center-screen for Battlefield-style positioning
    PrintCenterText(client, msg);

    // Note: PrintCenterText auto-fades after ~4 seconds.
    // For a BF5-style kill feed on the side, a VScript HUD can be added later.
}

// ============================================================================
// Helpers — Get sound path (fallback chain)
// ============================================================================

void GetSoundPath(char[] buffer, int maxlen, ConVar primary, ConVar fallback)
{
    primary.GetString(buffer, maxlen);
    if (buffer[0] == '\0')
        fallback.GetString(buffer, maxlen);
}

void PlayClientSound(int client, const char[] sound)
{
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

// ============================================================================
// Helpers — SI detection
// ============================================================================

void GetSIName(int client, char[] buffer, int maxlen)
{
    char cls[32];
    GetEntityClassname(client, cls, sizeof(cls));
    GetSINameByClass(cls, buffer, maxlen);
}

void GetSINameByClass(const char[] classname, char[] buffer, int maxlen)
{
    if (StrContains(classname, "smoker")  != -1) { strcopy(buffer, maxlen, "SMOKER  烟鬼");   return; }
    if (StrContains(classname, "boomer")  != -1) { strcopy(buffer, maxlen, "BOOMER  胖子");   return; }
    if (StrContains(classname, "hunter")  != -1) { strcopy(buffer, maxlen, "HUNTER  猎人");   return; }
    if (StrContains(classname, "spitter") != -1) { strcopy(buffer, maxlen, "SPITTER 口水");   return; }
    if (StrContains(classname, "jockey")  != -1) { strcopy(buffer, maxlen, "JOCKEY  猴子");   return; }
    if (StrContains(classname, "charger") != -1) { strcopy(buffer, maxlen, "CHARGER 牛");     return; }
    if (StrContains(classname, "tank")    != -1) { strcopy(buffer, maxlen, "TANK  坦克");      return; }
    if (StrContains(classname, "witch")   != -1) { strcopy(buffer, maxlen, "WITCH  女巫");     return; }

    strcopy(buffer, maxlen, "特感");
}

bool IsTank(int client)
{
    char cls[32];
    GetEntityClassname(client, cls, sizeof(cls));
    return (StrContains(cls, "tank") != -1);
}

bool IsWitchEntity(int entity)
{
    if (entity <= 0 || !IsValidEntity(entity))
        return false;

    char cls[32];
    GetEntityClassname(entity, cls, sizeof(cls));
    return (StrContains(cls, "witch") != -1);
}

bool IsMeleeWeapon(const char[] weapon)
{
    // In L4D2, melee kills always report weapon as "melee"
    if (StrEqual(weapon, "melee"))
        return true;

    // Also check for chainsaw (technically not melee but close-range)
    if (StrEqual(weapon, "chainsaw"))
        return true;

    return false;
}
