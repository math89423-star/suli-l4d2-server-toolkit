/**
 * [L4D2] SI HUD — Unified Special Infected HP + Kill Display  v1.4.1
 *
 * Replaces:
 *   - l4d2_bf_killfeedback    (was kill sounds + center text + chat; now bf does sound only)
 *   - L4D_All_Infected_HUD_HP (persistent SI HP HUD)
 *   - l4d2_si_hp_hud          (per-SI HP bar on hit)
 *
 * Two display channels — no conflicts:
 *   - PrintCenterText  (upper-center):        kill confirm ☠ + SI HP on-hit display
 *   - PrintToChatAll   (chat area):           colored kill feed
 *
 * Changelog v1.4.1:
 *   - FIX: kill confirm reverted from PrintHintText to PrintCenterText.
 *     PrintHintText shadow box cannot be truly cleared — even " " (space)
 *     keeps the dark background box visible, and the engine only fades it
 *     after several seconds. PrintCenterText has no shadow → clean clear.
 *   - FIX: SoundCooldownOK no longer blocks HUD/chat display. Sound cooldown
 *     now only gates the EmitSoundToClient call, not the entire kill handler.
 *
 * Changelog v1.3.2:
 *   - FIX: Frame_ShowHurtVictims no longer clears PrintCenterText when all victims
 *     died (shown==0), which was overwriting the kill-confirm message
 *   - CHANGE: kill confirm format — "💀 特感名 后缀" instead of "[武器] KILL ..."
 *     (SI kills, Witch kills, suicide / environment deaths)
 *
 * Changelog v1.3.1:
 *   - FIX: hitting ONE SI no longer shows HP of ALL SI — only the hit victim(s)
 *   - AoE / penetration: same-frame hits are batched via RequestFrame, all hit
 *     victims shown together; duplicate hits (e.g. shotgun pellets) deduplicated
 *
 * Changelog v1.3.0:
 *   - SI HP now shows ONLY when you damage the SI (on-hit), not persistent
 *   - HP auto-hides after si_hud_hp_interval seconds (default 0.5 s)
 *   - Kill confirm moved from PrintHintText to PrintCenterText — eliminates
 *     the hint-box shadow artifact that PrintHintText leaves on clear
 *
 * Dependencies: sourcemod + sdktools
 * Pure server-side. No client files needed.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "1.4.1"

// ============================================================================
// ConVar handles
// ============================================================================

ConVar g_cvEnable;
ConVar g_cvHPEnable;
ConVar g_cvHPInterval;
ConVar g_cvHPShowWitch;
ConVar g_cvChatEnable;
ConVar g_cvKillHintEnable;
ConVar g_cvSoundSI;
ConVar g_cvSoundHeadshot;
ConVar g_cvSoundTank;
ConVar g_cvSoundWitch;
ConVar g_cvSoundMelee;
ConVar g_cvSoundCommonHS;
ConVar g_cvSoundVolume;
ConVar g_cvSoundCooldown;

// ============================================================================
// Global state
// ============================================================================

Handle    g_hHPHideTimer[MAXPLAYERS + 1];             // per-client HP hide timer
Handle    g_hKillHintTimer[MAXPLAYERS + 1];          // per-client kill hint hide timer
float     g_fLastKillSoundTime[MAXPLAYERS + 1];       // sound cooldown
ArrayList g_hHurtVictims[MAXPLAYERS + 1];             // per-client victims hit this frame (AoE batch)
bool      g_bFrameQueued[MAXPLAYERS + 1];             // per-client: RequestFrame already pending

// ============================================================================
// Plugin Info
// ============================================================================

public Plugin myinfo =
{
    name        = "[L4D2] SI HUD",
    author      = "suli",
    description = "SI HP + kill confirm (PrintCenterText) + chat feed + sounds",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ============================================================================
// OnPluginStart
// ============================================================================

public void OnPluginStart()
{
    CreateConVar("si_hud_version", PLUGIN_VERSION,
        "SI HUD version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_cvEnable = CreateConVar("si_hud_enable", "1",
        "Master switch (0=off, 1=on).", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // ── Persistent HP display (PrintCenterText) ─────────

    g_cvHPEnable = CreateConVar("si_hud_hp_enable", "1",
        "Show persistent SI HP via PrintCenterText.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvHPInterval = CreateConVar("si_hud_hp_interval", "0.5",
        "HP display duration in seconds (on-hit mode: auto-hides after this long).",
        FCVAR_NOTIFY, true, 0.2, true, 5.0);

    g_cvHPShowWitch = CreateConVar("si_hud_hp_show_witch", "0",
        "Include Witch in HP display (0=off, 1=on).", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // ── Kill feedback ───────────────────────────────────

    g_cvChatEnable = CreateConVar("si_hud_chat_enable", "1",
        "PrintToChatAll kill feed.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvKillHintEnable = CreateConVar("si_hud_kill_hint_enable", "1",
        "PrintHintText kill confirm for attacker (shadow box ☠).", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // ── Kill sounds (all empty = off by default) ────────

    g_cvSoundSI = CreateConVar("si_hud_sound_si", "",
        "Default SI kill sound (empty=off).", FCVAR_NOTIFY);

    g_cvSoundHeadshot = CreateConVar("si_hud_sound_headshot", "",
        "SI headshot kill sound (empty=off).", FCVAR_NOTIFY);

    g_cvSoundTank = CreateConVar("si_hud_sound_tank", "",
        "Tank kill sound (empty=off).", FCVAR_NOTIFY);

    g_cvSoundWitch = CreateConVar("si_hud_sound_witch", "",
        "Witch kill sound (empty=off).", FCVAR_NOTIFY);

    g_cvSoundMelee = CreateConVar("si_hud_sound_melee", "",
        "Melee SI kill sound (empty=off).", FCVAR_NOTIFY);

    g_cvSoundCommonHS = CreateConVar("si_hud_sound_common_hs", "",
        "Common infected headshot kill sound (empty=off).", FCVAR_NOTIFY);

    g_cvSoundVolume = CreateConVar("si_hud_sound_volume", "0.8",
        "Sound volume (0.0 – 1.0).", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvSoundCooldown = CreateConVar("si_hud_sound_cooldown", "0.1",
        "Min seconds between kill sounds per client.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    AutoExecConfig(true, "l4d2_si_hud");

    // ── Events ──────────────────────────────────────────

    HookEvent("player_hurt",    Event_PlayerHurt);
    HookEvent("player_death",   Event_PlayerDeath);
    HookEvent("infected_death", Event_InfectedDeath);
}

// ============================================================================
// OnMapStart / OnMapEnd
// ============================================================================

public void OnMapStart()
{
    // Precache configured sounds
    PrecacheCvarSound(g_cvSoundSI);
    PrecacheCvarSound(g_cvSoundHeadshot);
    PrecacheCvarSound(g_cvSoundTank);
    PrecacheCvarSound(g_cvSoundWitch);
    PrecacheCvarSound(g_cvSoundMelee);
    PrecacheCvarSound(g_cvSoundCommonHS);

    // HP display is now on-hit only (player_hurt → RefreshHPForClient → 0.5s hide).
    // Persistent timer is no longer started — SI HP only shows when you damage them.
}

public void OnMapEnd()
{
    // HP hide timers are TIMER_FLAG_NO_MAPCHANGE — auto-cleaned on map end.
    // Clean up per-client AoE batch state
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bFrameQueued[i] = false;
        delete g_hHurtVictims[i];
    }
}

// ============================================================================
// OnClientDisconnect
// ============================================================================

public void OnClientDisconnect(int client)
{
    g_fLastKillSoundTime[client] = 0.0;
    KillHPHideTimer(client);
    g_hKillHintTimer[client] = null;
    g_bFrameQueued[client] = false;
    delete g_hHurtVictims[client];
}

// ============================================================================
// Event: player_hurt — immediate HP refresh for the attacker
// ============================================================================

public Action Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue || !g_cvHPEnable.BoolValue)
        return Plugin_Continue;

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
        return Plugin_Continue;
    if (GetClientTeam(attacker) != 2)
        return Plugin_Continue;

    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim < 1 || victim > MaxClients || !IsClientInGame(victim))
        return Plugin_Continue;
    if (GetClientTeam(victim) != 3)
        return Plugin_Continue;

    // On-hit HP refresh — batch per-frame for AoE (multiple hits same frame)
    if (g_hHurtVictims[attacker] == null)
        g_hHurtVictims[attacker] = new ArrayList();
    g_hHurtVictims[attacker].Push(victim);

    if (!g_bFrameQueued[attacker])
    {
        g_bFrameQueued[attacker] = true;
        RequestFrame(Frame_ShowHurtVictims, GetClientUserId(attacker));
    }
    return Plugin_Continue;
}

// ============================================================================
// OnEntityCreated — hook OnTakeDamage on Witch entities
// (player_hurt never fires for NPCs like Witch)
// ============================================================================

public void OnEntityCreated(int entity, const char[] classname)
{
    if (!g_cvEnable.BoolValue || !g_cvHPEnable.BoolValue || !g_cvHPShowWitch.BoolValue)
        return;
    if (StrContains(classname, "witch") == -1)
        return;
    SDKHook(entity, SDKHook_OnTakeDamage, Witch_OnTakeDamage);
}

Action Witch_OnTakeDamage(int victim, int &attacker, int &inflictor,
                          float &damage, int &damagetype)
{
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
        return Plugin_Continue;
    if (GetClientTeam(attacker) != 2)
        return Plugin_Continue;

    ShowWitchHP(attacker, victim);
    return Plugin_Continue;
}

// ============================================================================
// Event: player_death — SI kill feedback
// ============================================================================

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue)
        return Plugin_Continue;

    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    // ── Branch A: SI player death ──────────────────────

    if (victim >= 1 && victim <= MaxClients
        && IsClientInGame(victim) && GetClientTeam(victim) == 3)
    {
        bool validAtk = (attacker >= 1 && attacker <= MaxClients
                      && IsClientInGame(attacker) && GetClientTeam(attacker) == 2);

        if (validAtk)
            SurvivorKilledSI(attacker, victim, event);
        else
            SISystemDeath(victim, event);

        return Plugin_Continue;
    }

    // ── Branch B: Witch death (detected by entityid) ───

    int entityid = event.GetInt("entityid");
    if (entityid > 0 && IsWitchEntity(entityid))
    {
        if (attacker >= 1 && attacker <= MaxClients
            && IsClientInGame(attacker) && GetClientTeam(attacker) == 2)
        {
            SurvivorKilledWitch(attacker, event);
        }
        return Plugin_Continue;
    }

    return Plugin_Continue;
}

// ============================================================================
// Event: infected_death — common infected headshot sound
// ============================================================================

public Action Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue)
        return Plugin_Continue;

    if (!event.GetBool("headshot"))
        return Plugin_Continue;

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
        return Plugin_Continue;
    if (GetClientTeam(attacker) != 2)
        return Plugin_Continue;

    char sound[PLATFORM_MAX_PATH];
    g_cvSoundCommonHS.GetString(sound, sizeof(sound));
    if (sound[0] == '\0')
        return Plugin_Continue;

    if (!SoundCooldownOK(attacker))
        return Plugin_Continue;

    PlayClientSound(attacker, sound);
    return Plugin_Continue;
}

// ============================================================================
// ============================================================================
// Frame callback: show all victims hit this frame (batched for AoE / penetration)
// ============================================================================

void Frame_ShowHurtVictims(any userId)
{
    int client = GetClientOfUserId(userId);
    g_bFrameQueued[client] = false;

    if (client < 1 || !IsClientInGame(client) || GetClientTeam(client) != 2)
    {
        delete g_hHurtVictims[client];
        return;
    }

    ArrayList list = g_hHurtVictims[client];
    if (list == null || list.Length == 0)
        return;

    // Deduplicate: same victim can be hurt multiple times in one frame
    // (e.g. shotgun pellets). Keep only the first occurrence.
    int count = list.Length;
    for (int i = count - 1; i >= 1; i--)
    {
        int v = list.Get(i);
        for (int j = 0; j < i; j++)
        {
            if (list.Get(j) == v)
            {
                list.Erase(i);
                break;
            }
        }
    }

    char msg[512];
    msg[0] = '\0';
    int shown;

    for (int i = 0; i < list.Length; i++)
    {
        int victim = list.Get(i);
        if (victim < 1 || victim > MaxClients
            || !IsClientInGame(victim) || GetClientTeam(victim) != 3
            || !IsPlayerAlive(victim))
            continue;
        if (!g_cvHPShowWitch.BoolValue && IsTankOrWitch(victim) == 2)
            continue;

        int hp    = GetClientHealth(victim);
        int maxHp = GetEntProp(victim, Prop_Data, "m_iMaxHealth");
        if (maxHp <= 0) maxHp = 1;

        char siName[64];
        GetSIName(victim, siName, sizeof(siName));

        float ratio = float(hp) / float(maxHp);
        int barLen  = RoundToFloor(ratio * 10.0);
        if (barLen < 0)  barLen = 0;
        if (barLen > 10) barLen = 10;

        char bar[16];
        int k;
        for (k = 0; k < barLen; k++) bar[k] = '|';
        for (; k < 10; k++) bar[k] = ' ';
        bar[10] = '\0';

        char line[128];
        Format(line, sizeof(line), "%s  [%s] %d/%d\n",
            siName, bar, hp, maxHp);
        StrCat(msg, sizeof(msg), line);
        shown++;
    }

    list.Clear();

    // Only show HP if at least one victim is still alive.
    // When shown==0 (all victims died this frame), do NOT clear
    // PrintCenterText — the kill-confirm message from player_death
    // is already there and would be overwritten.
    if (shown > 0)
    {
        PrintCenterText(client, msg);

        // Auto-hide HP after configured duration
        KillHPHideTimer(client);
        g_hHPHideTimer[client] = CreateTimer(g_cvHPInterval.FloatValue, Timer_HideHP,
            GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }
}

// ============================================================================
// ShowWitchHP — called when attacker directly damages a Witch entity
// ============================================================================

void ShowWitchHP(int client, int witch)
{
    if (!IsClientInGame(client) || GetClientTeam(client) != 2)
        return;
    if (!IsValidEntity(witch))
        return;

    int hp = GetEntProp(witch, Prop_Data, "m_iHealth");
    if (hp <= 0) return;
    int maxHp = GetEntProp(witch, Prop_Data, "m_iMaxHealth");
    if (maxHp <= 0) maxHp = 1;

    float ratio = float(hp) / float(maxHp);
    int barLen = RoundToFloor(ratio * 10.0);
    if (barLen < 0) barLen = 0;
    if (barLen > 10) barLen = 10;

    char bar[16];
    int k;
    for (k = 0; k < barLen; k++) bar[k] = '|';
    for (; k < 10; k++) bar[k] = ' ';
    bar[10] = '\0';

    char msg[256];
    Format(msg, sizeof(msg), "WITCH  女巫  [%s] %d/%d\n", bar, hp, maxHp);

    PrintCenterText(client, msg);
    KillHPHideTimer(client);
    g_hHPHideTimer[client] = CreateTimer(g_cvHPInterval.FloatValue, Timer_HideHP,
        GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

// ============================================================================
// Kill feedback: survivor killed SI — PrintCenterText (upper-center, no shadow)
// ============================================================================

void SurvivorKilledSI(int attacker, int victim, Event event)
{
    bool headshot = event.GetBool("headshot");

    char weaponEnt[64], weaponDisplay[64], playerName[64], siName[64];
    event.GetString("weapon", weaponEnt, sizeof(weaponEnt));
    GetWeaponDisplayName(weaponEnt, weaponDisplay, sizeof(weaponDisplay));
    GetClientName(attacker, playerName, sizeof(playerName));
    GetSIName(victim, siName, sizeof(siName));

    bool melee  = IsMeleeWeapon(weaponEnt);
    bool isTank = (IsTankOrWitch(victim) == 1);

    // ── Sound (independent cooldown, does NOT block HUD/chat) ──

    if (SoundCooldownOK(attacker))
    {
        char sound[PLATFORM_MAX_PATH];
        if (isTank)
            PickSound(sound, sizeof(sound), g_cvSoundTank, g_cvSoundSI);
        else if (headshot)
            PickSound(sound, sizeof(sound), g_cvSoundHeadshot, g_cvSoundSI);
        else if (melee)
            PickSound(sound, sizeof(sound), g_cvSoundMelee, g_cvSoundSI);
        else
            g_cvSoundSI.GetString(sound, sizeof(sound));

        PlayClientSound(attacker, sound);
    }

    // ── Suffix ──────────────────────────────────────────

    char suffix[32];
    if (isTank && headshot)       suffix = "  爆头 ★";
    else if (isTank && melee)     suffix = "  近战 ★";
    else if (isTank)              suffix = "  ★";
    else if (headshot && melee)   suffix = "  爆头近战";
    else if (headshot)            suffix = "  爆头";
    else if (melee)               suffix = "  近战";

    // ── Chat ────────────────────────────────────────────

    if (g_cvChatEnable.BoolValue)
    {
        char chatMsg[256];
        Format(chatMsg, sizeof(chatMsg),
            "\x04%s\x01  [%s] KILL \x03%s\x01%s",
            playerName, weaponDisplay, siName, suffix);
        PrintToChatAll(chatMsg);
    }

    // ── Kill confirm via PrintCenterText (upper-center, NO shadow box) ──

    // [v1.4.1] Reverted from PrintHintText back to PrintCenterText.
    // PrintHintText shadow box cannot be truly cleared — even " " (space)
    // keeps the background box visible, and the engine never removes it
    // until natural fade-out (seconds). PrintCenterText has no shadow box,
    // so PrintCenterText(" ") cleanly removes the message instantly.

    if (g_cvKillHintEnable.BoolValue)
    {
        char killMsg[128];
        Format(killMsg, sizeof(killMsg),
            "☠ %s%s", siName, suffix);
        KillHPHideTimer(attacker);
        KillKillHintTimer(attacker);
        delete g_hHurtVictims[attacker];
        PrintCenterText(attacker, killMsg);
        g_hHPHideTimer[attacker] = CreateTimer(2.5, Timer_HideHP,
            GetClientUserId(attacker), TIMER_FLAG_NO_MAPCHANGE);
    }
}

// ============================================================================
// Kill feedback: survivor killed Witch
// ============================================================================

void SurvivorKilledWitch(int attacker, Event event)
{
    bool headshot = event.GetBool("headshot");

    char weaponEnt[64], weaponDisplay[64], playerName[64];
    event.GetString("weapon", weaponEnt, sizeof(weaponEnt));
    GetWeaponDisplayName(weaponEnt, weaponDisplay, sizeof(weaponDisplay));
    GetClientName(attacker, playerName, sizeof(playerName));

    // ── Sound (independent cooldown) ────────────────────

    if (SoundCooldownOK(attacker))
    {
        char sound[PLATFORM_MAX_PATH];
        PickSound(sound, sizeof(sound), g_cvSoundWitch, g_cvSoundSI);
        PlayClientSound(attacker, sound);
    }

    char suffix[16];
    if (headshot) suffix = "  爆头";

    if (g_cvChatEnable.BoolValue)
    {
        char chatMsg[256];
        Format(chatMsg, sizeof(chatMsg),
            "\x04%s\x01  [%s] KILL \x03WITCH 女巫\x01%s",
            playerName, weaponDisplay, suffix);
        PrintToChatAll(chatMsg);
    }

    // [v1.4.1] Reverted to PrintCenterText — no shadow box to get stuck.

    if (g_cvKillHintEnable.BoolValue)
    {
        char killMsg[128];
        Format(killMsg, sizeof(killMsg),
            "☠ WITCH 女巫%s", suffix);
        KillHPHideTimer(attacker);
        KillKillHintTimer(attacker);
        delete g_hHurtVictims[attacker];
        PrintCenterText(attacker, killMsg);
        g_hHPHideTimer[attacker] = CreateTimer(2.5, Timer_HideHP,
            GetClientUserId(attacker), TIMER_FLAG_NO_MAPCHANGE);
    }
}

// ============================================================================
// System death: SI suicide / environment kill
// ============================================================================

void SISystemDeath(int victim, Event event)
{
    char siName[64], victimName[64];
    GetSIName(victim, siName, sizeof(siName));
    GetClientName(victim, victimName, sizeof(victimName));

    int rawAttacker = event.GetInt("attacker");
    bool suicide = (rawAttacker == event.GetInt("userid"));

    if (g_cvChatEnable.BoolValue)
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

    // [v1.4.1] Reverted to PrintCenterText — no shadow box to get stuck.

    if (g_cvKillHintEnable.BoolValue)
    {
        char killMsg[128];
        if (suicide)
            Format(killMsg, sizeof(killMsg), "☠ %s  自杀了", siName);
        else
            Format(killMsg, sizeof(killMsg), "☠ %s  死于意外", siName);

        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsClientInGame(i) && GetClientTeam(i) == 2)
            {
                KillHPHideTimer(i);
                KillKillHintTimer(i);
                delete g_hHurtVictims[i];
                PrintCenterText(i, killMsg);
                g_hHPHideTimer[i] = CreateTimer(2.5, Timer_HideHP,
                    GetClientUserId(i), TIMER_FLAG_NO_MAPCHANGE);
            }
        }
    }
}

// ============================================================================
// Sound helpers
// ============================================================================

void PrecacheCvarSound(ConVar cv)
{
    char path[PLATFORM_MAX_PATH];
    cv.GetString(path, sizeof(path));
    if (path[0] == '\0')
        return;

    char dl[PLATFORM_MAX_PATH];
    Format(dl, sizeof(dl), "sound/%s", path);
    AddFileToDownloadsTable(dl);

    // Strip extension — engine internal lookup uses bare sound name
    char name[PLATFORM_MAX_PATH];
    strcopy(name, sizeof(name), path);
    int len = strlen(name);
    if (len > 4 && name[len-4] == '.')
        name[len-4] = '\0';

    PrecacheSound(name, true);
}

bool SoundCooldownOK(int client)
{
    float now = GetGameTime();
    if (now - g_fLastKillSoundTime[client] < g_cvSoundCooldown.FloatValue)
        return false;
    g_fLastKillSoundTime[client] = now;
    return true;
}

void PickSound(char[] buffer, int maxlen, ConVar primary, ConVar fallback)
{
    primary.GetString(buffer, maxlen);
    if (buffer[0] == '\0')
        fallback.GetString(buffer, maxlen);
}

void PlayClientSound(int client, const char[] sound)
{
    if (sound[0] == '\0')
        return;

    float vol = g_cvSoundVolume.FloatValue;
    if (vol <= 0.0)
        return;

    char name[PLATFORM_MAX_PATH];
    strcopy(name, sizeof(name), sound);
    int len = strlen(name);
    if (len > 4 && name[len - 4] == '.')
        name[len - 4] = '\0';

    EmitSoundToClient(client, name, 0, SNDCHAN_STATIC, SNDLEVEL_NORMAL,
        SND_NOFLAGS, vol >= 1.0 ? 1.0 : vol);
}

// ============================================================================
// SI name lookup (by m_zombieClass)
// ============================================================================

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

// ============================================================================
// Weapon display name
// ============================================================================

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
    if (StrEqual(weapon, "inferno")
     || StrEqual(weapon, "entityflame"))          { strcopy(buffer, maxlen, "火焰");     return; }
    strcopy(buffer, maxlen, weapon);
}

// ============================================================================
// Entity type checks
// ============================================================================

/** Returns 1=Tank, 2=Witch, 0=other SI */
int IsTankOrWitch(int client)
{
    int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");
    if (zombieClass == 8) return 1;
    if (zombieClass == 7) return 2;
    return 0;
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
    return StrEqual(weapon, "melee") || StrEqual(weapon, "chainsaw");
}

// ============================================================================
// Center text hide timer — clears PrintCenterText (HP display & kill confirm)
// ============================================================================

Action Timer_HideHP(Handle timer, int userId)
{
    int client = GetClientOfUserId(userId);
    g_hHPHideTimer[client] = null;
    if (client > 0 && IsClientInGame(client))
        PrintCenterText(client, " ");
    return Plugin_Stop;
}

void KillHPHideTimer(int client)
{
    if (g_hHPHideTimer[client] != null)
    {
        KillTimer(g_hHPHideTimer[client]);
        g_hHPHideTimer[client] = null;
    }
}

void KillKillHintTimer(int client)
{
    if (g_hKillHintTimer[client] != null)
    {
        KillTimer(g_hKillHintTimer[client]);
        g_hKillHintTimer[client] = null;
    }
}

// [v1.4.1] Timer_ShowKillHint / Timer_HideKillHint removed — kill confirm
// now uses PrintCenterText via Timer_HideHP (no shadow-box priming needed).
