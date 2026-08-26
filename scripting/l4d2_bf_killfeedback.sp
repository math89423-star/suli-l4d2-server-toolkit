/**
 * [L4D2] Battlefield Kill Feedback  v4.4.0
 *
 * SOUND-ONLY: Battlefield-style kill sounds per kill type.
 *
 * v4.4.7 — Tank/Witch/melee kill sound = si_kill.mp3 (user 拍板, 2026-08-02):
 *   - v4.4.6 logs proved the witch play path executes end-to-end
 *     (PLAY 'battlefield/witch_kill.mp3'), yet the client hears nothing
 *     while si_kill.mp3 works — witch_kill.mp3 never reached this client.
 *   - User decision: drop the per-type sound files (tank_kill.mp3 /
 *     witch_kill.mp3 / melee_kill.mp3 were never verified on clients);
 *     Tank, Witch and melee kills all play the same si_kill.mp3 as regular
 *     SI. bf_kill_sound_tank/_witch/_melee now default to
 *     battlefield/si_kill.mp3; cfg updated too. Headshot keeps
 *     si_headshot_kill.mp3.
 *   - v4.4.6 debug logs removed.
 *
 * v4.4.5 — FIX Witch kill sound silent (user 实测, 2026-08-02):
 *   - Event order for a Witch kill (verified by the v4.4.4 symptom):
 *     infected_death fires BEFORE player_death, gap < 0.1s. v4.4.4's guard
 *     returned without sound and the player_death witch branch then hit the
 *     shared 0.1s cooldown -> completely silent.
 *   - Fix: the witch guard now PLAYS witch_kill.mp3 itself (player_death
 *     branch kept as a fallback; the shared cooldown guarantees no double
 *     play in either order).
 *
 * v4.4.4 — FIX Witch death plays the common-kill sound (2026-08-02):
 *   - The engine fires infected_death for NPC Witch kills too (she lives in
 *     the infected event system). This plugin had no witch guard on
 *     Event_InfectedDeath, so killing a Witch played csgo_kill_common.mp3
 *     (and the shared 0.1s cooldown could swallow the real witch_kill.mp3
 *     from Event_PlayerDeath).
 *   - Fix: track the killer's last-hit infected entity (new infected_hurt
 *     hook, witch entities included — same approach as si_hud) and skip
 *     Event_InfectedDeath when that entity is a witch. Witch death sound
 *     then comes ONLY from Event_PlayerDeath's witch branch.
 *
 * v4.4.0 — CS:GO kill sounds for common infected (2026-08-01):
 *   - Common-infected kills now play CS:GO original sounds (extracted
 *     from the game files): every common kill plays
 *     "battlefield/csgo_kill_common.mp3" (player/headshot2.wav),
 *     headshots play "battlefield/csgo_kill_headshot.mp3"
 *     (player/headshot1.wav) instead (previously OFF).
 *   - BF sounds keep SI/Tank/Witch/melee duty; CS:GO sounds own commons.
 *   - New cvar bf_kill_sound_common (plain kill); bf_kill_sound_common_hs
 *     (headshot) default "battlefield/csgo_kill_headshot.mp3".
 *   - SOUND_FILES gains both mp3s (download table + precache). Legacy
 *     common_headshot.mp3 entry kept so admins can switch cvars back
 *     without a map change.
 *
 * v4.3.2 — VPK distribution ABANDONED (2026-07-31):
 *   - maps/bf_sounds.vpk CRASHED the server on every boot: the engine scans
 *     every maps\*.vpk as a map container at startup; a non-map vpk segfaults
 *     srcds into a restart loop (hibernating -> SIGSEGV -> 10s restart).
 *     First crash at 22:58:32 after the first restart with the vpk present.
 *   - addons/ path (v4.3.0) was already proven dead: clients ignore
 *     download-table entries under addons/ (0 requests in nginx log).
 *   - Conclusion: NO server-side sound.cache distribution works on this
 *     setup. Custom sounds need a client-side cache entry — either loose
 *     sound/sound.cache in the client's left4dead2/sound/ or the client
 *     building one with snd_buildsoundcachefordirectory.
 *
 * v4.3.1 — distribute via maps/ path instead of addons/ (2026-07-31,
 *           SUPERSEDED by v4.3.2 — maps/ vpk crashes the server):
 *   - PROVEN FAILURE of v4.3.0: clients IGNORE download-table entries under
 *     addons/ (nginx log: 0 requests for addons/bf_sounds.vpk even though the
 *     mp3 entries in the same table downloaded fine). addons/ is not a
 *     legal client download path.
 *   - Fix: AddFileToDownloadsTable("maps/bf_sounds.vpk") — this is the
 *     third-party-map distribution channel (clients download maps/xxx.vpk and
 *     relocate them into local addons/, which the engine mounts at launch,
 *     merging its sound.cache into the sound dictionary).
 *
 * v4.3.0 — distribute bf_sounds.vpk instead of loose sound.cache (2026-07-31,
 *           SUPERSEDED by v4.3.1 — addons/ path rejected by clients):
 *   - PROVEN FAILURE of v4.2.1: every map vpk ships its own sound/sound.cache,
 *     so clients consider the file "already present" and NEVER download the
 *     loose one (nginx access log: 0 requests for sound/sound.cache all day).
 *   - Package sound/sound.cache into bf_sounds.vpk and distribute.
 *   - bf_sounds.vpk built with: mkdir bfvpk/sound && vpk -c bfvpk bf_sounds.vpk.
 *
 * v4.2.1 — ship sound/sound.cache (2026-07-31, SUPERSEDED by v4.3.0):
 *   - CONFIRMED in game: custom sounds only play once the CLIENT has a
 *     sound.cache entry (official Valve mechanism — the client builds it
 *     with snd_buildsoundcachefordirectory; the server must distribute it).
 *   - AddFileToDownloadsTable("sound/sound.cache") — clients never download
 *     it (map vpk shadowing). Kept for history; NOT the mechanism in use.
 *
 * v4.2.0 — back to PrecacheSound + file paths (2026-07-31):
 *   - Sound-script approach (v4.1.x) abandoned: PrecacheScriptSound is
 *     BROKEN on this L4D2 Linux build (returns false even for engine
 *     scripts like "Player.Jump"), and clients would need the script file.
 *   - PrecacheSound("battlefield/si_kill.mp3", true) verified working on
 *     this server WITHOUT sound.cache.
 *   - Cvars hold plain file paths (relative to sound/), e.g. "battlefield/si_kill.mp3".
 *   - EmitSoundToClient sends the full path; the client plays the mp3
 *     downloaded via HTTP fastdl (AddFileToDownloadsTable in OnMapStart).
 *   - Distribution: AddFileToDownloadsTable for the 6 mp3s in
 *     sound/battlefield/, served via sv_downloadurl (nginx /l4d2_fastdl/).
 *
 * v4.1.x — sound script rewrite (ABANDONED, see above)
 * v4.0.x — PrecacheSound-based
 * v3.x   — HUD + chat + sound (deprecated, split to l4d2_si_hud)
 *
 * Clients need: the mp3s under sound/battlefield/ (HTTP fastdl) — and the
 * sound.cache dictionary via addons/bf_sounds.vpk (auto-downloaded once).
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "4.4.7"

// ============================================================================
// ConVars — hold file paths relative to sound/ (WITH extension)
// ============================================================================

ConVar g_cvEnabled;
ConVar g_cvSoundSIKill;
ConVar g_cvSoundSIHeadshot;
ConVar g_cvSoundTankKill;
ConVar g_cvSoundWitchKill;
ConVar g_cvSoundMeleeKill;
ConVar g_cvSoundCommon;
ConVar g_cvSoundCommonHS;
ConVar g_cvVolume;
ConVar g_cvCooldown;

// ============================================================================
// State
// ============================================================================

float g_fLastKillTime[MAXPLAYERS + 1];

// v4.4.4: killer's last-hit infected entity (commons AND witch) — infected_death
// carries no entity id, so witch kills are detected via this back-reference.
// Witch hurt fires infected_hurt (NPC entity in the infected event system).
int   g_iLastCommonEnt[MAXPLAYERS + 1];

// ============================================================================
// Sound files to download (actual mp3 files, relative to sound/)
// ============================================================================

static const char SOUND_FILES[][] = {
    "battlefield/si_kill.mp3",
    "battlefield/si_headshot_kill.mp3",
    "battlefield/tank_kill.mp3",
    "battlefield/witch_kill.mp3",
    "battlefield/melee_kill.mp3",
    "battlefield/common_headshot.mp3",   // legacy BF common sound (cvar-switchable)
    "battlefield/csgo_kill_common.mp3",  // CS:GO headshot2.wav — plain common kill (v4.4.0)
    "battlefield/csgo_kill_headshot.mp3" // CS:GO headshot1.wav — common headshot kill (v4.4.0)
};

// ============================================================================
// Plugin Info
// ============================================================================

public Plugin myinfo =
{
    name        = "[L4D2] Battlefield Kill Feedback (sound only)",
    author      = "Claude (for suli's server)",
    description = "BF kill sounds — HUD/chat handled by l4d2_score_core",
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

    g_cvSoundSIKill = CreateConVar("bf_kill_sound_si", "battlefield/si_kill.mp3",
        "SI kill sound (file path relative to sound/).", FCVAR_NOTIFY);
    g_cvSoundSIHeadshot = CreateConVar("bf_kill_sound_headshot", "battlefield/si_headshot_kill.mp3",
        "SI headshot sound (file path relative to sound/).", FCVAR_NOTIFY);
    g_cvSoundTankKill = CreateConVar("bf_kill_sound_tank", "battlefield/si_kill.mp3",
        "Tank kill sound (file path relative to sound/).", FCVAR_NOTIFY);   // v4.4.7: = SI sound (user)
    g_cvSoundWitchKill = CreateConVar("bf_kill_sound_witch", "battlefield/si_kill.mp3",
        "Witch kill sound (file path relative to sound/).", FCVAR_NOTIFY);   // v4.4.7: = SI sound (user)
    g_cvSoundMeleeKill = CreateConVar("bf_kill_sound_melee", "battlefield/si_kill.mp3",
        "Melee kill sound (file path relative to sound/).", FCVAR_NOTIFY);   // v4.4.7: = SI sound (user)
    g_cvSoundCommon = CreateConVar("bf_kill_sound_common", "battlefield/csgo_kill_common.mp3",
        "Common infected kill sound (file path relative to sound/, empty=off).", FCVAR_NOTIFY);
    g_cvSoundCommonHS = CreateConVar("bf_kill_sound_common_hs", "battlefield/csgo_kill_headshot.mp3",
        "Common infected headshot sound (file path relative to sound/, empty=off).", FCVAR_NOTIFY);

    g_cvVolume = CreateConVar("bf_kill_volume", "1.0",
        "Sound volume (0.0 – 1.0). Keep ≤ 1.0 — engine handles >1.0 unpredictably.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    // v4.4.1 FIX (engine-residue cvar): if a cfg exec auto-created this cvar
    // before the plugin loaded, CreateConVar returns it WITHOUT updating
    // bounds — force them so the configured value actually passes through.
    g_cvVolume.SetBounds(ConVarBound_Upper, true, 1.0);
    g_cvCooldown = CreateConVar("bf_kill_cooldown", "0.1",
        "Min seconds between sounds.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    AutoExecConfig(true, "l4d2_bf_killfeedback");

    // VPK distribution ABANDONED (2026-07-31 v4.3.2): addons/ path is ignored
    // by clients (0 requests), and maps/ path CRASHES the server at startup —
    // the engine scans maps/*.vpk as map containers; a non-map vpk there
    // segfaults srcds on every boot (crash loop). See l4d2-bf-killfeedback
    // memory. Custom sounds therefore require a client-side cache entry
    // (loose sound/sound.cache) — no server-side distribution works.

    HookEvent("player_death",   Event_PlayerDeath);
    HookEvent("infected_death", Event_InfectedDeath);
    HookEvent("infected_hurt",  Event_InfectedHurt);   // v4.4.4: last-hit ent for the witch guard
}

// ============================================================================
// infected_hurt — track the killer's last-hit infected entity (v4.4.4).
// Witches are NPCs in the infected event system: hurting her fires
// infected_hurt (verified) — record her entity too so her death can be told
// apart from a common kill in Event_InfectedDeath.
// ============================================================================

public Action Event_InfectedHurt(Event event, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
        return Plugin_Continue;
    if (GetClientTeam(attacker) != 2)
        return Plugin_Continue;

    int ent = event.GetInt("entityid");
    if (ent >= 1 && ent < 2048)
        g_iLastCommonEnt[attacker] = ent;
    return Plugin_Continue;
}

// ============================================================================
// OnMapStart — distribute mp3s + precache them.
// PrecacheSound with a full file path is verified working on this Linux
// build without sound.cache (sound scripts are NOT used; PrecacheScriptSound
// is broken on this build).
// ============================================================================

public void OnMapStart()
{
    if (!g_cvEnabled.BoolValue) return;

    // VPK distribution abandoned — see OnPluginStart note (v4.3.2).
    // No server-side sound.cache distribution works on this setup.

    for (int i = 0; i < sizeof(SOUND_FILES); i++)
    {
        char dl[PLATFORM_MAX_PATH];
        Format(dl, sizeof(dl), "sound/%s", SOUND_FILES[i]);
        AddFileToDownloadsTable(dl);

        if (PrecacheSound(SOUND_FILES[i], true))
            LogMessage("[BF] Precached: %s", SOUND_FILES[i]);
        else
            LogError("[BF] FAILED to precache: %s — check file exists in sound/", SOUND_FILES[i]);
    }
}

public void OnClientDisconnect(int client)
{
    g_fLastKillTime[client] = 0.0;
    g_iLastCommonEnt[client] = 0;   // v4.4.4
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
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker)) return Plugin_Continue;
    if (GetClientTeam(attacker) != 2) return Plugin_Continue;

    // v4.4.4/4.4.5 (bug): Witch death also fires infected_death — if the
    // killer's last-hit infected entity is a Witch, this is HER death.
    // v4.4.5: event order for a Witch kill is infected_death FIRST,
    // player_death later (gap < 0.1s, verified by the v4.4.4 symptom) — the
    // player_death witch branch gets swallowed by the shared cooldown, so
    // PLAY the witch sound right here instead of returning silently.
    // (The player_death branch stays as a fallback; the shared cooldown
    // guarantees no double play in either event order.)
    int lastEnt = g_iLastCommonEnt[attacker];
    if (lastEnt >= 1 && lastEnt < 2048)
    {
        char cls[16];
        GetEntityClassname(lastEnt, cls, sizeof(cls));
        if (StrContains(cls, "witch") != -1)
        {
            g_iLastCommonEnt[attacker] = 0;
            float now = GetGameTime();
            if (now - g_fLastKillTime[attacker] >= g_cvCooldown.FloatValue)
            {
                g_fLastKillTime[attacker] = now;
                char sound[PLATFORM_MAX_PATH];
                PickSound(sound, sizeof(sound), g_cvSoundWitchKill, g_cvSoundSIKill);
                PlayClientSound(attacker, sound);
            }
            return Plugin_Continue;
        }
    }

    if (GetGameTime() - g_fLastKillTime[attacker] < g_cvCooldown.FloatValue) return Plugin_Continue;

    // Headshot -> headshot sound, plain kill -> plain sound (CS2 style).
    char sound[PLATFORM_MAX_PATH];
    if (event.GetBool("headshot"))
        g_cvSoundCommonHS.GetString(sound, sizeof(sound));
    else
        g_cvSoundCommon.GetString(sound, sizeof(sound));
    if (sound[0] == '\0') return Plugin_Continue;

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
    // sound is a file path relative to sound/ (e.g. "battlefield/si_kill.mp3").
    if (sound[0] == '\0') return;
    float vol = g_cvVolume.FloatValue;
    if (vol <= 0.0) return;

    // v4.4.3 SPATIAL TEST: SOUND_FROM_PLAYER (non-spatialized) → entity=client
    // (spatialized). Engine sounds that players hear as LOUD (e.g. the incap
    // thud) are spatialized from entities — non-spatialized UI sounds suffer a
    // fixed attenuation. Listener = source (distance 0) → attenuation ≈ 1.0.
    // volume stays ≤ 1.0: engine handles >1.0 unpredictably (实测, user-confirmed).
    EmitSoundToClient(client, sound, client, SNDCHAN_AUTO,
        SNDLEVEL_NORMAL, SND_NOFLAGS, vol);
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
