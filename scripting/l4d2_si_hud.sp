/**
 * [L4D2] SI HUD — Unified Special Infected HP + Kill Display  v1.7.0
 *
 * Replaces:
 *   - l4d2_bf_killfeedback    (was kill sounds + center text + chat; now bf does sound only)
 *   - L4D_All_Infected_HUD_HP (persistent SI HP HUD)
 *   - l4d2_si_hp_hud          (per-SI HP bar on hit)
 *
 * Three display channels — no conflicts:
 *   - PrintCenterText  (upper-center):        kill banner ☠ (skulls + points) + SI HP on-hit
 *   - PrintToChatAll   (chat area):           colored kill feed
 *   - PrintHintText    (lower-center):        BF1-style kill card "[weapon] ☠ SI name" (v1.6.4)
 *
 * Changelog v1.7.0:
 *   - REAL FIX (user retested v1.6.9: garble STILL there, ~10s straight):
 *     the "" purge was the root cause all along. PrintHintText("") destroys
 *     the client's hint display list and resets the channel to its initial
 *     empty state; the next CJK hint sent on the channel — no matter how it
 *     is preceded by a " " prime — renders garbled. (v1.6.8/1.6.9 only
 *     removed same-frame collisions BETWEEN the purge and other messages,
 *     which is why they changed nothing.) Proof from history: the card was
 *     never garbled before v1.6.6 introduced the purge (v1.6.4/1.6.5 used
 *     natural fade-out). Fix: REMOVE ALL ACTIVE CLEARING. The card now fades
 *     out with the engine's fixed ~4s hint timer — text and shadow box are
 *     one element and fade together, nothing lingers. si_hud_killcard_time
 *     is DEPRECATED (the engine hint duration is fixed at ~4s and cannot be
 *     shortened; the cvar is kept only so existing cfg files don't error).
 *
 * Changelog v1.6.9:
 *   - FIX (v1.6.8 did NOT fix the user's garble): v1.6.8's guard only blocked
 *     the "prime + purge same frame" race. The OTHER collision — a card being
 *     displayed and purged in the SAME frame — was left open: Frame_ShowKillCard
 *     runs at frame start and resets g_bKillCardQueued, so when an expiry
 *     deadline lands in the card's display frame the timer still sends "" ,
 *     and card + "" hit the client in one tick. Any same-tick display+purge
 *     can corrupt the hint render state (same family as the v3.5.1 CJK-tear
 *     fix — two PrintHintText messages in one frame resizing the box).
 *     Fix: a perpetual RequestFrame chain keeps a per-frame counter; the card
 *     records the frame it was displayed in, and Timer_HideKillCard skips the
 *     clear when it expires in that same frame (the newer card's own timer
 *     clears it). This is order-independent — no reliance on event-vs-timer
 *     sequencing inside a frame. Also fixed the si_hud_version ConVar never
 *     updating (CreateConVar doesn't overwrite existing cvars — the runtime
 *     value still said 1.6.5; plugin Version field was already correct).
 *
 * Changelog v1.6.8:
 *   - FIX (user feedback): kill card text shows GARBLED (乱码) when
 *     si_hud_killcard_time is reduced. Root cause: a frame race between the
 *     hide timer and the card prime. Timer_HideKillCard fires at END of the
 *     frame its deadline falls in and sends PrintHintText("") which PURGES
 *     the client's whole hint list. If a kill lands in that same frame, the
 *     kill's " " prime was already sent mid-frame — the wire order becomes
 *     " " → "" → card, the purge deletes the prime, and the card becomes the
 *     FIRST hint on an idle channel → CJK renders garbled (priming bug).
 *     Smaller killcard_time → kills collide with expiry frames more often.
 *     Fix: Timer_HideKillCard now skips the clear while g_bKillCardQueued is
 *     set (a newer kill's prime is in flight — its own hide timer will clear
 *     the card). The prime survives, so the card always replaces a live hint.
 *
 * Changelog v1.6.7:
 *   - ADD: BF1-style rolling score counter — the kill banner now shows the
 *     ACCUMULATED streak score (100 → 250 → 400 …) instead of the single
 *     kill's points, so the number visibly grows with every kill inside the
 *     window (BF1's "animated score counter" feel). Resets when the streak
 *     settles (with the award sound), on round_end, map end and disconnect.
 *
 * Changelog v1.6.6:
 *   - FIX (user feedback): kill card lingered ~4s despite the v1.6.5 clear.
 *     Root cause: the KeyHintText count=0 clear is IGNORED by the L4D2 client
 *     (card waited out the engine's fixed ~4s hint timer). Replacement:
 *     CHudHintDisplay::AddHint treats an EMPTY-STRING hint as "clear the whole
 *     display list" (PurgeAndDeleteElements) — so ClearHintBox now sends
 *     PrintHintText(""). Note " " (space) does NOT work — a space is a
 *     non-empty hint that lingers 4s (v1.4.1 finding). Card now hides after
 *     si_hud_killcard_time (2.0s) for real.
 *   - ADD: BF1 streak award sounds (Step 1 of the score system). When a kill
 *     streak settles (window si_hud_bf_window ends with streak >= 2), the
 *     killer hears the BF1 award sound for their streak tier:
 *       streak 2-3   → bf_streak_spotting.mp3   (UI_SpottingIcon_PickUp)
 *       streak 4-5   → bf_streak_purchase.mp3   (UI_PurchaseSuccess)
 *       streak 6-8   → bf_streak_war_bonds.mp3  (UI_Award_WarBonds)
 *       streak 9-11  → bf_streak_dogtag.mp3     (UI_Award_DogTag)
 *       streak 12-14 → bf_streak_medal.mp3      (UI_Award_Medal)
 *       streak 15+   → bf_streak_rankup.mp3     (UI_Award_RankUp)
 *     Per-client one-shot settle timer; window-gap re-checks on fire. Streak
 *     resets on settle and on round_end. Sounds distributed via
 *     AddFileToDownloadsTable + PrecacheSound (same channel as v4.4.0 mode,
 *     no sound.cache needed). New cvars si_hud_streak_sound_enable/_volume/
 *     _l2/_l4/_l6/_l9/_l12/_l15 (empty path = tier silent).
 *
 * Changelog v1.6.5:
 *   - TIMING (user feedback): kill card hides after si_hud_killcard_time
 *     (2.0s) and the center banner after si_hud_banner_time (1.0s).
 *   - Card clear via KeyHintText count=0 (protocol-level, EXPERIMENTAL):
 *     HintText and KeyHintText share the client's hint display list
 *     (CHudHintDisplay), so sending an empty KeyHintText removes the card
 *     AND its shadow box immediately — no 4s engine hint timer, no empty
 *     box. If this proves ineffective on this build, the card simply falls
 *     back to natural fade-out (harmless, just stays ~4s).
 *   - New cvar si_hud_banner_time (default 1.0) — center banner duration.
 *
 * Changelog v1.6.4:
 *   - REWORK (user feedback): kill card back on PrintHintText — the hint's
 *     dark shadow box IS the BF1-style card background the user wants
 *     (lower-center, shadowed box). Never actively clear it: v1.4.1 proved
 *     PrintHintText(" ") leaves an EMPTY BOX on screen — the "clear" message
 *     is itself a 4s single-slot hint whose empty text keeps the box alive.
 *     Natural fade-out is the only clean end: text + box fade together
 *     (same element). The ☠ skull banner stays on PrintCenterText.
 *   - Kill card is single-slot REPLACE on the engine side: every new hint
 *     resets the fixed 4s display timer, so rapid kills refresh instantly
 *     (no queue lag). First-hint priming bug handled per card: prime " "
 *     (invisible) then show the real card next frame (v1.6.0 pattern).
 *   - Removed: killcard clear timer / KillKillHintTimer (no active clear).
 *   - BuildKillDisplay → BuildKillCard (card line only; streak skulls and
 *     points live in the center banner via BuildBFBanner).
 *
 * Changelog v1.6.0:
 *   - ADD: BF1-style kill card on PrintHintText (lower-center) — big type
 *     word (KILL / HEADSHOT / MELEE / TANK / WITCH) + SI name + points.
 *     The hint's dark shadow box doubles as the card background (that's the
 *     BF1 look); we NEVER actively clear it (v1.4.1: even " " leaves the box
 *     for seconds) — natural fade-out only. First-hint priming bug handled
 *     by sending an invisible space prime, then the real card next frame.
 *   - The ☠ skull banner on PrintCenterText (upper-center) is kept as-is.
 *
 * Changelog v1.6.1:
 *   - REWORK kill card format (user feedback): single line
 *     "[weapon] ☠ SI name" (headshot: "[weapon] ☠ SI name(head shot)")
 *     — dropped the big type word + points line.
 *   - ADD auto-clear: card hides after si_hud_killcard_time (default 2.5s)
 *     via PrintHintText(" ") — text vanishes immediately; the shadow box
 *     lingers until its natural fade (engine limitation, v1.4.1).
 *
 * Changelog v1.6.2:
 *   - FIX: shadow box lingering after card text cleared — PrintHintText
 *     CANNOT be cleanly cleared on this engine (v1.4.1 finding: even " "
 *     leaves the dark box until natural fade). Migrated the kill card onto
 *     the PrintCenterText channel, merged with the ☠ skull banner as ONE
 *     multi-line message (skull row on the upper line, card on the lower
 *     line). PrintCenterText has no shadow box and clears instantly with
 *     " " (already proven v1.4.1). Kill card timer reuses Timer_HideHP.
 *
 * Changelog v1.4.1:
 *   - FIX: kill confirm reverted from PrintHintText to PrintCenterText.
 *     PrintHintText shadow box cannot be truly cleared — even " " (space)
 *     keeps the dark background box visible, and the engine only fades it
 *     after several seconds. PrintCenterText has no shadow → clean clear.
 *   - FIX: SoundCooldownOK no longer blocks HUD/chat display. Sound cooldown
 *     now only gates the EmitSoundToClient call, not the entire kill handler.
 *
 * Changelog v1.5.0:
 *   - BF-style kill banner replaces the plain "☠ 特感名" kill confirm:
 *     line 1 = ☠ skull row, one skull per kill inside the streak window
 *     (BF5-style side-by-side, capped at 6); line 2 = kill type · SI name
 *     + points. Points: SI 100 / headshot +50 / melee +50 / Tank 500 /
 *     Witch 500, all cvar-tunable. Same gate: si_hud_kill_hint_enable.
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

#define PLUGIN_VERSION "1.7.0"

// ============================================================================
// ConVar handles
// ============================================================================

ConVar g_cvEnable;
ConVar g_cvHPEnable;
ConVar g_cvHPInterval;
ConVar g_cvHPShowWitch;
ConVar g_cvChatEnable;
ConVar g_cvKillHintEnable;
ConVar g_cvKillCardEnable;
ConVar g_cvKillCardTime;
ConVar g_cvBannerTime;
ConVar g_cvBFWindow;
ConVar g_cvBFPointsSI;
ConVar g_cvBFPointsHeadshot;
ConVar g_cvBFPointsMelee;
ConVar g_cvBFPointsTank;
ConVar g_cvBFPointsWitch;
ConVar g_cvSoundSI;
ConVar g_cvSoundHeadshot;
ConVar g_cvSoundTank;
ConVar g_cvSoundWitch;
ConVar g_cvSoundMelee;
ConVar g_cvSoundCommonHS;
ConVar g_cvSoundVolume;
ConVar g_cvSoundCooldown;

// ── BF1 streak award sounds (v1.6.6) ───────────────────────

ConVar g_cvStreakEnable;
ConVar g_cvStreakVol;
ConVar g_cvStreakSnd2;
ConVar g_cvStreakSnd4;
ConVar g_cvStreakSnd6;
ConVar g_cvStreakSnd9;
ConVar g_cvStreakSnd12;
ConVar g_cvStreakSnd15;

// ============================================================================
// Global state
// ============================================================================

Handle    g_hHPHideTimer[MAXPLAYERS + 1];             // per-client HP/banner hide timer
Handle    g_hStreakTimer[MAXPLAYERS + 1];            // per-client streak settle timer (v1.6.6)
float     g_fLastKillSoundTime[MAXPLAYERS + 1];       // sound cooldown
int       g_iKillStreak[MAXPLAYERS + 1];              // BF banner: kills in current streak
int       g_iStreakScore[MAXPLAYERS + 1];             // BF banner: rolling score in current streak (v1.6.7)
float     g_fLastStreakKillTime[MAXPLAYERS + 1];      // BF banner: last streak-kill time
ArrayList g_hHurtVictims[MAXPLAYERS + 1];             // per-client victims hit this frame (AoE batch)
bool      g_bFrameQueued[MAXPLAYERS + 1];             // per-client: RequestFrame already pending
bool      g_bKillCardQueued[MAXPLAYERS + 1];          // per-client: kill card frame pending
char      g_sKillCardText[MAXPLAYERS + 1][192];       // per-client: kill card text (shown next frame)

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
        "PrintCenterText kill banner for attacker (☠ skulls + type + points).", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvKillCardEnable = CreateConVar("si_hud_killcard_enable", "1",
        "Kill card on PrintHintText (lower-center shadow box): [weapon] ☠ SI name. Natural fade-out only (no active clear — v1.6.4).", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvKillCardTime = CreateConVar("si_hud_killcard_time", "2.0",
        "DEPRECATED (v1.7.0): the engine hint duration is fixed at ~4s and cannot be shortened. Kept so existing cfg files don't error; has no effect.", FCVAR_NOTIFY, true, 0.0, true, 10.0);

    g_cvBannerTime = CreateConVar("si_hud_banner_time", "1.0",
        "Center banner (skulls + points) display duration in seconds before PrintCenterText clear.", FCVAR_NOTIFY, true, 0.0, true, 10.0);

    // ── BF-style kill banner (skulls + points) ─────────

    g_cvBFWindow = CreateConVar("si_hud_bf_window", "4.0",
        "Kill streak window (s): kills within this time stack side-by-side skulls.", FCVAR_NOTIFY, true, 1.0, true, 10.0);

    g_cvBFPointsSI = CreateConVar("si_hud_bf_points_si", "100",
        "BF banner points: SI kill.", FCVAR_NOTIFY, true, 0.0, true, 10000.0);
    g_cvBFPointsHeadshot = CreateConVar("si_hud_bf_points_headshot", "50",
        "BF banner points: headshot bonus.", FCVAR_NOTIFY, true, 0.0, true, 10000.0);
    g_cvBFPointsMelee = CreateConVar("si_hud_bf_points_melee", "50",
        "BF banner points: melee bonus.", FCVAR_NOTIFY, true, 0.0, true, 10000.0);
    g_cvBFPointsTank = CreateConVar("si_hud_bf_points_tank", "500",
        "BF banner points: Tank kill.", FCVAR_NOTIFY, true, 0.0, true, 10000.0);
    g_cvBFPointsWitch = CreateConVar("si_hud_bf_points_witch", "500",
        "BF banner points: Witch kill.", FCVAR_NOTIFY, true, 0.0, true, 10000.0);

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

    // ── BF1 streak award sounds (v1.6.6) ────────────────

    g_cvStreakEnable = CreateConVar("si_hud_streak_sound_enable", "1",
        "Play the BF1 award sound when a kill streak settles (streak >= 2).", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvStreakVol = CreateConVar("si_hud_streak_sound_volume", "0.9",
        "Streak award sound volume, independent of si_hud_sound_volume.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvStreakSnd2 = CreateConVar("si_hud_streak_sound_l2", "battlefield/bf_streak_spotting.mp3",
        "Streak 2-3 award sound (file path relative to sound/, empty=off).", FCVAR_NOTIFY);
    g_cvStreakSnd4 = CreateConVar("si_hud_streak_sound_l4", "battlefield/bf_streak_purchase.mp3",
        "Streak 4-5 award sound (file path relative to sound/, empty=off).", FCVAR_NOTIFY);
    g_cvStreakSnd6 = CreateConVar("si_hud_streak_sound_l6", "battlefield/bf_streak_war_bonds.mp3",
        "Streak 6-8 award sound (file path relative to sound/, empty=off).", FCVAR_NOTIFY);
    g_cvStreakSnd9 = CreateConVar("si_hud_streak_sound_l9", "battlefield/bf_streak_dogtag.mp3",
        "Streak 9-11 award sound (file path relative to sound/, empty=off).", FCVAR_NOTIFY);
    g_cvStreakSnd12 = CreateConVar("si_hud_streak_sound_l12", "battlefield/bf_streak_medal.mp3",
        "Streak 12-14 award sound (file path relative to sound/, empty=off).", FCVAR_NOTIFY);
    g_cvStreakSnd15 = CreateConVar("si_hud_streak_sound_l15", "battlefield/bf_streak_rankup.mp3",
        "Streak 15+ award sound (file path relative to sound/, empty=off).", FCVAR_NOTIFY);

    AutoExecConfig(true, "l4d2_si_hud");

    // ── Events ──────────────────────────────────────────

    HookEvent("player_hurt",    Event_PlayerHurt);
    HookEvent("player_death",   Event_PlayerDeath);
    HookEvent("infected_death", Event_InfectedDeath);
    HookEvent("round_end",      Event_RoundEnd);
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
    PrecacheCvarSound(g_cvStreakSnd2);
    PrecacheCvarSound(g_cvStreakSnd4);
    PrecacheCvarSound(g_cvStreakSnd6);
    PrecacheCvarSound(g_cvStreakSnd9);
    PrecacheCvarSound(g_cvStreakSnd12);
    PrecacheCvarSound(g_cvStreakSnd15);

    // HP display is now on-hit only (player_hurt → RefreshHPForClient → 0.5s hide).
    // Persistent timer is no longer started — SI HP only shows when you damage them.
}

public void OnMapEnd()
{
    // HP hide timers are TIMER_FLAG_NO_MAPCHANGE — auto-cleaned on map end.
    // Clean up per-client AoE batch state and streak settle timers
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bFrameQueued[i] = false;
        delete g_hHurtVictims[i];
        KillStreakTimer(i);
        g_iKillStreak[i] = 0;
        g_iStreakScore[i] = 0;
        g_fLastStreakKillTime[i] = 0.0;
    }
}

// ============================================================================
// round_end — reset streak state (matches the documented "streak resets
// per round" behavior; kills after the round ends must not settle an award)
// ============================================================================

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        KillStreakTimer(i);
        g_iKillStreak[i] = 0;
        g_iStreakScore[i] = 0;
        g_fLastStreakKillTime[i] = 0.0;
    }
    return Plugin_Continue;
}

// ============================================================================
// OnClientDisconnect
// ============================================================================

public void OnClientDisconnect(int client)
{
    g_fLastKillSoundTime[client] = 0.0;
    g_iKillStreak[client] = 0;
    g_iStreakScore[client] = 0;
    g_fLastStreakKillTime[client] = 0.0;
    KillHPHideTimer(client);
    KillStreakTimer(client);
    g_bFrameQueued[client] = false;
    g_bKillCardQueued[client] = false;
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

    int points = g_cvBFPointsSI.IntValue;
    if (isTank) points = g_cvBFPointsTank.IntValue;
    else if (headshot) points += g_cvBFPointsHeadshot.IntValue;
    if (melee) points += g_cvBFPointsMelee.IntValue;

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

    // ── Kill display (v1.6.4) ──
    // Center banner (☠ skulls + points) on PrintCenterText — cleared after
    // si_hud_killcard_time (center text has no shadow box, " " clears it).
    // Kill card on PrintHintText (lower-center, shadow box = the BF1-style
    // background) — NEVER actively cleared: the engine's hint is single-slot
    // and every message resets its fixed ~4s timer, so an active "clear"
    // (PrintHintText " ") is itself a 4s empty hint and its box lingers
    // (v1.4.1 finding). Natural fade-out removes text + box together.

    if (g_cvKillHintEnable.BoolValue)
    {
        char banner[192];
        BuildBFBanner(banner, sizeof(banner), attacker, points,
            isTank ? "坦克击杀" : headshot ? "爆头击杀" : melee ? "近战击杀" : "击杀",
            siName);

        KillHPHideTimer(attacker);
        delete g_hHurtVictims[attacker];
        PrintCenterText(attacker, banner);
        g_hHPHideTimer[attacker] = CreateTimer(g_cvBannerTime.FloatValue, Timer_HideHP,
            GetClientUserId(attacker), TIMER_FLAG_NO_MAPCHANGE);

        if (g_cvKillCardEnable.BoolValue)
        {
            char card[192];
            BuildKillCard(card, sizeof(card), weaponDisplay, siName, headshot);
            QueueKillCard(attacker, card);
        }
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

    // [v1.6.4] Same two-channel layout as SurvivorKilledSI.

    if (g_cvKillHintEnable.BoolValue)
    {
        char banner[192];
        BuildBFBanner(banner, sizeof(banner), attacker, g_cvBFPointsWitch.IntValue,
            "女巫击杀", "WITCH 女巫");

        KillHPHideTimer(attacker);
        delete g_hHurtVictims[attacker];
        PrintCenterText(attacker, banner);
        g_hHPHideTimer[attacker] = CreateTimer(g_cvBannerTime.FloatValue, Timer_HideHP,
            GetClientUserId(attacker), TIMER_FLAG_NO_MAPCHANGE);

        if (g_cvKillCardEnable.BoolValue)
        {
            char card[192];
            BuildKillCard(card, sizeof(card), weaponDisplay, "WITCH 女巫", headshot);
            QueueKillCard(attacker, card);
        }
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
                delete g_hHurtVictims[i];
                PrintCenterText(i, killMsg);
                g_hHPHideTimer[i] = CreateTimer(2.5, Timer_HideHP,
                    GetClientUserId(i), TIMER_FLAG_NO_MAPCHANGE);
            }
        }
    }
}

// ============================================================================
// Kill card — PrintHintText (lower-center, shadow box = BF1-style
// background), v1.6.4. Card line only: "[weapon] ☠ SI name" (+ "(head shot)").
// Streak skulls and points live in the center banner (BuildBFBanner).
// ☠ = U+2620 (3-byte BMP; the 4-byte 💀 does not render on Source).
// ============================================================================

void BuildKillCard(char[] buffer, int maxlen,
                   const char[] weapon, const char[] siName, bool headshot)
{
    if (headshot)
        Format(buffer, maxlen, "[%s] ☠ %s(head shot)", weapon, siName);
    else
        Format(buffer, maxlen, "[%s] ☠ %s", weapon, siName);
}

// ============================================================================
// QueueKillCard — prime the hint channel, show the real card next frame.
// The engine's hint is single-slot: every new message replaces the current
// one and resets its fixed ~4s display timer (rapid kills refresh instantly).
// The first hint on a freshly-purged channel renders broken (priming bug),
// so prime with an invisible " " and show the card one frame later. Card
// text is buffered per client so a same-frame second kill just overwrites
// the pending card.
// v1.7.0: NO ACTIVE CLEAR. The "" purge was the root cause of the garble —
// it destroyed the hint display list and left the channel in its initial
// state, so the next CJK hint (the card) always rendered garbled regardless
// of the prime. The card now fades out naturally when the engine's fixed
// ~4s hint timer expires; text and shadow box are one element and fade
// together, so nothing lingers on screen.
// ============================================================================

void QueueKillCard(int client, const char[] card)
{
    strcopy(g_sKillCardText[client], sizeof(g_sKillCardText[]), card);
    PrintHintText(client, " ");   // prime: invisible, activates the channel
    if (!g_bKillCardQueued[client])
    {
        g_bKillCardQueued[client] = true;
        RequestFrame(Frame_ShowKillCard, GetClientUserId(client));
    }
}

void Frame_ShowKillCard(any userId)
{
    int client = GetClientOfUserId(userId);
    g_bKillCardQueued[client] = false;
    if (client < 1 || !IsClientInGame(client) || GetClientTeam(client) != 2)
        return;
    PrintHintText(client, g_sKillCardText[client]);
}

// ============================================================================
// BF-style kill banner — "☠☠☠" skull row (one skull per kill in the streak
// window, BF5-style side-by-side) + type line with points
// ============================================================================

void BuildBFBanner(char[] buffer, int maxlen, int client, int points,
                   const char[] type, const char[] siName)
{
    // Streak: kills inside the window stack skulls; window gap resets
    float now = GetGameTime();
    if (now - g_fLastStreakKillTime[client] > g_cvBFWindow.FloatValue)
    {
        g_iKillStreak[client] = 0;
        g_iStreakScore[client] = 0;          // v1.6.7: rolling score resets with the streak
    }
    g_iKillStreak[client]++;
    g_fLastStreakKillTime[client] = now;

    // v1.6.7: BF1-style rolling score counter — the banner shows the
    // ACCUMULATED streak score (100 → 250 → 400 …), not the single kill's
    // points. Resets when the streak settles (Timer_StreakSettle) or on
    // round_end. This is the "animated score counter" feedback BF1 is known
    // for — the number visibly grows with every kill in the window.
    g_iStreakScore[client] += points;

    // v1.6.6: schedule the streak settle — when the window closes with
    // streak >= 2, the killer hears the BF1 award sound for their tier.
    ScheduleStreakSettle(client);

    char skulls[24];
    skulls[0] = '\0';
    int n = g_iKillStreak[client];
    if (n > 6) n = 6;                    // cap the row
    for (int k = 0; k < n; k++)
        StrCat(skulls, sizeof(skulls), "☠");   // BMP U+2620 — renders (emoji pitfall)

    Format(buffer, maxlen, "%s\n%s · %s  +%d", skulls, type, siName, g_iStreakScore[client]);
}

// ============================================================================
// BF1 streak award sounds (v1.6.6)
// ============================================================================

void ScheduleStreakSettle(int client)
{
    if (!g_cvStreakEnable.BoolValue)
        return;
    KillStreakTimer(client);
    g_hStreakTimer[client] = CreateTimer(g_cvBFWindow.FloatValue, Timer_StreakSettle,
        GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_StreakSettle(Handle timer, int userId)
{
    int client = GetClientOfUserId(userId);
    g_hStreakTimer[client] = null;
    if (client < 1 || !IsClientInGame(client) || GetClientTeam(client) != 2)
        return Plugin_Stop;

    float now = GetGameTime();
    // The window did not close yet (a kill landed near the fire time) — wait
    // another full window. Negative now-last means a map change reset the
    // game time: give up (OnMapEnd already reset streak state).
    if (now < g_fLastStreakKillTime[client]
        || now - g_fLastStreakKillTime[client] < g_cvBFWindow.FloatValue)
    {
        if (now < g_fLastStreakKillTime[client])
            return Plugin_Stop;
        g_hStreakTimer[client] = CreateTimer(g_cvBFWindow.FloatValue, Timer_StreakSettle,
            GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
        return Plugin_Stop;
    }

    int streak = g_iKillStreak[client];
    g_iKillStreak[client] = 0;            // settle: reset for the next run
    g_iStreakScore[client] = 0;           // v1.6.7: rolling score resets on settle
    g_fLastStreakKillTime[client] = 0.0;
    if (streak < 2)
        return Plugin_Stop;

    char sound[PLATFORM_MAX_PATH];
    ConVar cv;
    if (streak >= 15)      cv = g_cvStreakSnd15;
    else if (streak >= 12) cv = g_cvStreakSnd12;
    else if (streak >= 9)  cv = g_cvStreakSnd9;
    else if (streak >= 6)  cv = g_cvStreakSnd6;
    else if (streak >= 4)  cv = g_cvStreakSnd4;
    else                   cv = g_cvStreakSnd2;
    cv.GetString(sound, sizeof(sound));
    if (sound[0] == '\0')
        return Plugin_Stop;

    PlayStreakSound(client, sound);
    return Plugin_Stop;
}

void PlayStreakSound(int client, const char[] sound)
{
    float vol = g_cvStreakVol.FloatValue;
    if (vol <= 0.0)
        return;

    char name[PLATFORM_MAX_PATH];
    strcopy(name, sizeof(name), sound);
    int len = strlen(name);
    if (len > 4 && name[len - 4] == '.')
        name[len - 4] = '\0';

    // Same UI channel as kill sounds (SNDCHAN_STATIC) — never competes with
    // game audio; only the killer hears it (EmitSoundToClient).
    EmitSoundToClient(client, name, 0, SNDCHAN_STATIC, SNDLEVEL_NORMAL,
        SND_NOFLAGS, vol >= 1.0 ? 1.0 : vol);
}

void KillStreakTimer(int client)
{
    if (g_hStreakTimer[client] != null)
    {
        KillTimer(g_hStreakTimer[client]);
        g_hStreakTimer[client] = null;
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
