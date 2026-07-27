/**
 * [L4D2] Battlefield Kill Feedback  v3.5
 *
 * Battlefield-style kill confirmation:
 *   - PrintToChatAll: global kill feed (all players, stacked, colored)
 *   - PrintHintText: attacker personal kill confirm (center-lower area, above weapon bar)
 *   - Kill sounds: battlefield-style per kill type
 *   - Weapon name display (24+ weapons mapped)
 *   - SI name via m_zombieClass (correct for bot players)
 *   - System-killed SI display (suicide, fall damage, fire, etc.)
 *
 * Pure server-side.  No client files needed.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "3.5.0"

// ============================================================================
// ConVars
// ============================================================================

ConVar g_cvEnabled;
ConVar g_cvChatEnabled;
ConVar g_cvCenterTextEnabled;
ConVar g_cvCenterTextTimeout;
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
// Plugin Info
// ============================================================================

public Plugin myinfo =
{
    name        = "[L4D2] Battlefield Kill Feedback",
    author      = "Claude (for suli's server)",
    description = "BF-style kill sound + global chat kill feed + center text",
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
        "Enable/disable all kill feedback.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvChatEnabled = CreateConVar("bf_kill_chat_enabled", "1",
        "Global kill feed via PrintToChatAll (all players, stacked, colored).",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvCenterTextEnabled = CreateConVar("bf_kill_hinttext_enabled", "1",
        "Hint text for attacker kill confirm (center-lower area, above weapon bar).",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvCenterTextTimeout = CreateConVar("bf_kill_hinttext_timeout", "2.0",
        "Seconds before hint text clears.", FCVAR_NOTIFY, true, 0.5, true, 5.0);

    g_cvSoundSIKill = CreateConVar("bf_kill_sound_si", "battlefield/si_kill.wav",
        "SI kill sound.", FCVAR_NOTIFY);
    g_cvSoundSIHeadshot = CreateConVar("bf_kill_sound_headshot", "battlefield/si_headshot_kill.wav",
        "SI headshot sound.", FCVAR_NOTIFY);
    g_cvSoundTankKill = CreateConVar("bf_kill_sound_tank", "battlefield/tank_kill.wav",
        "Tank kill sound.", FCVAR_NOTIFY);
    g_cvSoundWitchKill = CreateConVar("bf_kill_sound_witch", "battlefield/witch_kill.wav",
        "Witch kill sound.", FCVAR_NOTIFY);
    g_cvSoundMeleeKill = CreateConVar("bf_kill_sound_melee", "battlefield/melee_kill.wav",
        "Melee kill sound.", FCVAR_NOTIFY);
    g_cvSoundCommonHS = CreateConVar("bf_kill_sound_common_hs", "",
        "Common headshot sound (empty=off).", FCVAR_NOTIFY);

    g_cvVolume = CreateConVar("bf_kill_volume", "0.8",
        "Sound volume.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvCooldown = CreateConVar("bf_kill_cooldown", "0.1",
        "Min seconds between sounds.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    AutoExecConfig(true, "l4d2_bf_killfeedback");

    HookEvent("player_death",   Event_PlayerDeath);
    HookEvent("infected_death", Event_InfectedDeath);
}

public void OnMapStart()
{
    PrecacheSound2("battlefield/si_kill.wav");
    PrecacheSound2("battlefield/si_headshot_kill.wav");
    PrecacheSound2("battlefield/tank_kill.wav");
    PrecacheSound2("battlefield/witch_kill.wav");
    PrecacheSound2("battlefield/melee_kill.wav");
    PrecacheSound2("battlefield/common_headshot.wav");
}

void PrecacheSound2(const char[] sound)
{
    if (sound[0] == '\0') return;
    char buffer[PLATFORM_MAX_PATH];
    Format(buffer, sizeof(buffer), "sound/%s", sound);
    AddFileToDownloadsTable(buffer);
    PrecacheSound(sound, true);
}

Action Timer_ClearCenterText(Handle timer, int userId)
{
    int client = GetClientOfUserId(userId);
    if (client > 0 && IsClientInGame(client))
        PrintHintText(client, " ");
    return Plugin_Stop;
}

public void OnClientDisconnect(int client)
{
}

// ============================================================================
// player_death — SI kill detection
// ============================================================================

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnabled.BoolValue) return Plugin_Continue;

    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    // ── SI player death ──────────────────────────────────

    if (victim >= 1 && victim <= MaxClients && GetClientTeam(victim) == 3)
    {
        bool validAttacker = (attacker >= 1 && attacker <= MaxClients
                           && IsClientInGame(attacker)
                           && GetClientTeam(attacker) == 2);

        if (validAttacker)
        {
            // Survivor killed SI → full sound + display
            float now = GetGameTime();
            if (now - g_fLastKillTime[attacker] < g_cvCooldown.FloatValue)
                return Plugin_Continue;

            g_fLastKillTime[attacker] = now;
            bool headshot = event.GetBool("headshot");

            char siName[32], weaponEnt[64], weaponDisplay[64], playerName[64];
            GetSIName(victim, siName, sizeof(siName));
            event.GetString("weapon", weaponEnt, sizeof(weaponEnt));
            GetWeaponDisplayName(weaponEnt, weaponDisplay, sizeof(weaponDisplay));
            GetClientName(attacker, playerName, sizeof(playerName));

            bool melee = IsMeleeWeapon(weaponEnt);

            char sound[PLATFORM_MAX_PATH];
            if (IsTank(victim))
                GetSoundPath(sound, sizeof(sound), g_cvSoundTankKill, g_cvSoundSIKill);
            else if (headshot)
                GetSoundPath(sound, sizeof(sound), g_cvSoundSIHeadshot, g_cvSoundSIKill);
            else if (melee)
                GetSoundPath(sound, sizeof(sound), g_cvSoundMeleeKill, g_cvSoundSIKill);
            else
                g_cvSoundSIKill.GetString(sound, sizeof(sound));
            PlayClientSound(attacker, sound);

            ShowKillDisplay(attacker, playerName, weaponDisplay, siName,
                headshot, melee, IsTank(victim), false);
        }
        else
        {
            // System-killed SI (suicide, fall, fire, drown, etc.)
            // Chat + hint notification for all survivors
            char siName[32], victimName[64];
            GetSIName(victim, siName, sizeof(siName));
            GetClientName(victim, victimName, sizeof(victimName));

            int rawAttacker = event.GetInt("attacker");
            bool suicide = (rawAttacker == event.GetInt("userid"));

            if (g_cvChatEnabled.BoolValue)
            {
                char chatMsg[256];
                if (suicide)
                    Format(chatMsg, sizeof(chatMsg),
                        "\x04%s\x01  [\x03%s\x01]  \x05自杀了", victimName, siName);
                else
                    Format(chatMsg, sizeof(chatMsg),
                        "\x04%s\x01  [\x03%s\x01]  \x05死于意外", victimName, siName);
                PrintToChatAll(chatMsg);
            }

            if (g_cvCenterTextEnabled.BoolValue)
            {
                char hintMsg[128];
                if (suicide)
                    Format(hintMsg, sizeof(hintMsg), "%s  自杀了", siName);
                else
                    Format(hintMsg, sizeof(hintMsg), "%s  死于意外", siName);

                for (int i = 1; i <= MaxClients; i++)
                {
                    if (IsClientInGame(i) && GetClientTeam(i) == 2)
                        PrintHintText(i, hintMsg);
                }
            }
        }
        return Plugin_Continue;
    }

    // ── Non-SI death (Witch / common) ─────────────────────

    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
        return Plugin_Continue;
    if (GetClientTeam(attacker) != 2)
        return Plugin_Continue;

    float now = GetGameTime();
    if (now - g_fLastKillTime[attacker] < g_cvCooldown.FloatValue)
        return Plugin_Continue;

    bool headshot = event.GetBool("headshot");

    int entityid = event.GetInt("entityid");
    if (entityid > 0 && IsWitchEntity(entityid))
    {
        g_fLastKillTime[attacker] = now;

        char weaponEnt[64], weaponDisplay[64], playerName[64];
        event.GetString("weapon", weaponEnt, sizeof(weaponEnt));
        GetWeaponDisplayName(weaponEnt, weaponDisplay, sizeof(weaponDisplay));
        GetClientName(attacker, playerName, sizeof(playerName));

        char sound[PLATFORM_MAX_PATH];
        GetSoundPath(sound, sizeof(sound), g_cvSoundWitchKill, g_cvSoundSIKill);
        PlayClientSound(attacker, sound);

        ShowKillDisplay(attacker, playerName, weaponDisplay, "WITCH 女巫",
            headshot, false, false, true);
    }
    return Plugin_Continue;
}

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
// Kill display
// ============================================================================

void ShowKillDisplay(int client, const char[] playerName, const char[] weaponDisplay,
                     const char[] siName, bool headshot, bool melee,
                     bool isTank, bool isWitch)
{
    char chatMsg[256], suffix[32] = "";

    if (isTank && headshot)       suffix = "  爆头 ★";
    else if (isTank && melee)     suffix = "  近战 ★";
    else if (isTank)              suffix = " ★";
    else if (isWitch && headshot) suffix = "  爆头";
    else if (isWitch)             suffix = "";
    else if (headshot && melee)   suffix = "  爆头近战";
    else if (headshot)            suffix = "  爆头";
    else if (melee)               suffix = "  近战";

    Format(chatMsg, sizeof(chatMsg), "\x04%s\x01  [%s]  ☠  \x03%s%s",
        playerName, weaponDisplay, siName, suffix);

    if (g_cvChatEnabled.BoolValue) PrintToChatAll(chatMsg);

    // Center text: weapon ☠ SI only, no player name
    if (g_cvCenterTextEnabled.BoolValue)
    {
        char centerMsg[128];
        Format(centerMsg, sizeof(centerMsg), "[%s]  ☠  %s%s", weaponDisplay, siName, suffix);
        PrintHintText(client, centerMsg);
        CreateTimer(g_cvCenterTextTimeout.FloatValue, Timer_ClearCenterText,
            GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }
}

// ============================================================================
// Helpers
// ============================================================================

void GetSoundPath(char[] buffer, int maxlen, ConVar primary, ConVar fallback)
{
    primary.GetString(buffer, maxlen);
    if (buffer[0] == '\0') fallback.GetString(buffer, maxlen);
}

void PlayClientSound(int client, const char[] sound)
{
    if (sound[0] == '\0') return;
    float vol = g_cvVolume.FloatValue;
    if (vol <= 0.0) return;
    EmitSoundToClient(client, sound, client, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS,
        vol >= 1.0 ? 1.0 : vol);
}

void GetSIName(int client, char[] buffer, int maxlen)
{
    int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");
    switch (zombieClass)
    {
        case 1:  strcopy(buffer, maxlen, "SMOKER  烟鬼");
        case 2:  strcopy(buffer, maxlen, "BOOMER  胖子");
        case 3:  strcopy(buffer, maxlen, "HUNTER  猎人");
        case 4:  strcopy(buffer, maxlen, "SPITTER 口水");
        case 5:  strcopy(buffer, maxlen, "JOCKEY  猴子");
        case 6:  strcopy(buffer, maxlen, "CHARGER 牛");
        case 7:  strcopy(buffer, maxlen, "WITCH  女巫");
        case 8:  strcopy(buffer, maxlen, "TANK  坦克");
        default: strcopy(buffer, maxlen, "特感");
    }
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

bool IsMeleeWeapon(const char[] weapon)
{
    return StrEqual(weapon, "melee") || StrEqual(weapon, "chainsaw");
}

void GetWeaponDisplayName(const char[] weapon, char[] buffer, int maxlen)
{
    if (StrEqual(weapon, "pistol"))              { strcopy(buffer, maxlen, "手枪");     return; }
    if (StrEqual(weapon, "dual_pistols"))        { strcopy(buffer, maxlen, "手枪");     return; }
    if (StrEqual(weapon, "pistol_magnum"))       { strcopy(buffer, maxlen, "马格南");   return; }
    if (StrEqual(weapon, "smg"))                 { strcopy(buffer, maxlen, "UZI");      return; }
    if (StrEqual(weapon, "smg_silenced"))        { strcopy(buffer, maxlen, "MAC-10");   return; }
    if (StrEqual(weapon, "smg_mp5"))             { strcopy(buffer, maxlen, "MP5");      return; }
    if (StrEqual(weapon, "pumpshotgun"))         { strcopy(buffer, maxlen, "木喷");     return; }
    if (StrEqual(weapon, "shotgun_chrome"))      { strcopy(buffer, maxlen, "铁喷");     return; }
    if (StrEqual(weapon, "autoshotgun"))         { strcopy(buffer, maxlen, "M1014");    return; }
    if (StrEqual(weapon, "shotgun_spas"))        { strcopy(buffer, maxlen, "SPAS");     return; }
    if (StrEqual(weapon, "rifle"))               { strcopy(buffer, maxlen, "M16");      return; }
    if (StrEqual(weapon, "rifle_sg552"))         { strcopy(buffer, maxlen, "SG552");    return; }
    if (StrEqual(weapon, "rifle_desert"))        { strcopy(buffer, maxlen, "SCAR");     return; }
    if (StrEqual(weapon, "rifle_ak47"))          { strcopy(buffer, maxlen, "AK47");     return; }
    if (StrEqual(weapon, "hunting_rifle"))       { strcopy(buffer, maxlen, "猎枪");     return; }
    if (StrEqual(weapon, "sniper_military"))     { strcopy(buffer, maxlen, "军狙");     return; }
    if (StrEqual(weapon, "sniper_awp"))          { strcopy(buffer, maxlen, "AWP");      return; }
    if (StrEqual(weapon, "sniper_scout"))        { strcopy(buffer, maxlen, "SCOUT");    return; }
    if (StrEqual(weapon, "melee"))               { strcopy(buffer, maxlen, "近战");     return; }
    if (StrEqual(weapon, "chainsaw"))            { strcopy(buffer, maxlen, "电锯");     return; }
    if (StrEqual(weapon, "pipe_bomb"))           { strcopy(buffer, maxlen, "土制");     return; }
    if (StrEqual(weapon, "molotov"))             { strcopy(buffer, maxlen, "燃烧瓶");   return; }
    if (StrEqual(weapon, "vomitjar"))            { strcopy(buffer, maxlen, "胆汁");     return; }
    if (StrEqual(weapon, "grenade_launcher"))    { strcopy(buffer, maxlen, "榴弹");     return; }
    if (StrEqual(weapon, "prop_minigun"))        { strcopy(buffer, maxlen, "固定机枪"); return; }
    if (StrEqual(weapon, "prop_mounted_machine_gun")) { strcopy(buffer, maxlen, "固定机枪"); return; }
    if (StrEqual(weapon, "rifle_m60"))           { strcopy(buffer, maxlen, "M60");      return; }
    if (StrEqual(weapon, "inferno") || StrEqual(weapon, "entityflame"))
        { strcopy(buffer, maxlen, "火焰"); return; }
    strcopy(buffer, maxlen, weapon);
}
