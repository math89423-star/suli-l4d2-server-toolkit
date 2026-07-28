// ============================================================================
// AI_HardSI.sp — L4D2 Special Infected AI (Behavior Tree v3.2)
// ============================================================================
// Original v2.4 by Breezy — flat if-then-else per-SI logic.
// v3.0 refactored with composable Behavior Tree framework for hierarchical,
// reactive, and maintainable AI decision-making.
//
// Include order is critical:
//   1. Core SM/left4dhooks SDK
//   2. hardcoop_util (shared utilities, coordination system)
//   3. bt_core       (BT node framework)
//   4. bt_common     (shared game-specific condition/action nodes)
//   5. bt_*          (per-SI behavior trees)
// ============================================================================

#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

// Shared utilities + coordination system (preserved from v2.4)
#include "hardcoop_util.sp"

// BT framework + shared nodes
#include "bt_core.inc"
#include "bt_common.inc"

// Per-SI behavior trees
#include "bt_hunter.inc"
#include "bt_charger.inc"
#include "bt_jockey.inc"
#include "bt_smoker.inc"
#include "bt_boomer.inc"
#include "bt_spitter.inc"
#include "bt_tank.inc"
#include "bt_witch.inc"

// ============================================================================
// Plugin Info
// ============================================================================

public Plugin:myinfo = {
    name = "AI: Hard SI (Behavior Tree v3.3)",
    author = "Breezy, refactored by Claude",
    description = "Improves the AI of special infected — BT-driven terrain-aware decision engine",
    version = "3.3",
    url = "github.com/breezyplease"
};

// ============================================================================
// Global State
// ============================================================================

// Tick throttling — evaluate AI every N frames
int   g_iTickCounter[MAXPLAYERS + 1];
#define TICK_INTERVAL 4

// Shove tracking
bool  g_bHasBeenShoved[MAXPLAYERS + 1];

// BT root node IDs (built once in OnPluginStart, shared across clients)
int   g_iBTHunterRoot   = -1;
int   g_iBTChargerRoot  = -1;
int   g_iBTJockeyRoot   = -1;
int   g_iBTSmokerRoot   = -1;
int   g_iBTBoomerRoot   = -1;
int   g_iBTSpitterRoot  = -1;
int   g_iBTTankRoot     = -1;
int   g_iBTWitchRoot    = -1;

// Cached ConVar handles (avoid FindConVar per-tick)
ConVar g_hCvarTankAggroBhop = null;

// ============================================================================
// OnPluginStart
// ============================================================================

public OnPluginStart() {
    // --- Event hooks (preserved from v2.4) ---
    HookEvent("player_spawn",      Event_PlayerSpawn,      EventHookMode_Pre);
    HookEvent("ability_use",       Event_AbilityUse,       EventHookMode_Pre);
    HookEvent("player_shoved",     Event_PlayerShoved,     EventHookMode_Pre);
    HookEvent("player_jump",       Event_PlayerJump,       EventHookMode_Pre);
    // v3.2: tongue_release suicide REMOVED — Smoker BT now handles re-engagement naturally

    // --- v3.2: Terrain detection cvar ---
    g_hCvarTerrainEnable = CreateConVar("ai_terrain_enable", "1",
        "Enable terrain-aware AI strategies (narrow/open/ledge detection): 0=OFF, 1=ON",
        FCVAR_NONE, true, 0.0, true, 1.0);

    // --- Coordination cvars ---
    g_hCvarCoordEnable = CreateConVar("ai_coordination_enable", "1",
        "Enable SI coordination system: 0=OFF, 1=ON",
        FCVAR_NONE, true, 0.0, true, 1.0);
    g_hCvarCoordWindow = CreateConVar("ai_coordination_window", "4.0",
        "Duration (seconds) of the coordination attack window",
        FCVAR_NONE, true, 0.5, true, 10.0);

    // --- Per-SI module initialization (cvars + game tuning) ---
    Smoker_OnModuleStart();
    Hunter_OnModuleStart();
    Spitter_OnModuleStart();
    Boomer_OnModuleStart();
    Charger_OnModuleStart();
    Jockey_OnModuleStart();
    Tank_OnModuleStart();
    Witch_OnModuleStart();

    // Cache frequently-read cvars (avoid FindConVar per tick)
    g_hCvarTankAggroBhop = FindConVar("ai_tank_aggro_bhop");

    // --- Build all Behavior Trees ---
    g_iBTHunterRoot  = BT_CreateHunterTree();
    g_iBTChargerRoot = BT_CreateChargerTree();
    g_iBTJockeyRoot  = BT_CreateJockeyTree();
    g_iBTSmokerRoot  = BT_CreateSmokerTree();
    g_iBTBoomerRoot  = BT_CreateBoomerTree();
    g_iBTSpitterRoot = BT_CreateSpitterTree();
    g_iBTTankRoot    = BT_CreateTankTree();
    g_iBTWitchRoot   = BT_CreateWitchTree();

    // --- Coordination timer ---
    CreateTimer(1.0, Timer_UpdateCoordination, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

// ============================================================================
// Per-SI Module Start/End functions are defined in their respective bt_*.inc files.
// These register custom cvars and modify vanilla game cvars.
// The BT framework replaces only the decision logic, not the game tuning.

public OnPluginEnd() {
    // Cleanup (if needed)
}

// ============================================================================
// Player Spawn: bind BT tree to SI bot
// ============================================================================

public Action:Event_PlayerSpawn(Handle:event, String:name[], bool:dontBroadcast) {
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (!IsBotInfected(client)) return Plugin_Handled;

    g_bHasBeenShoved[client] = false;
    g_iTickCounter[client] = 0;

    // Bind the appropriate behavior tree
    int rootId = -1;
    switch (L4D2_Infected:GetInfectedClass(client)) {
        case L4D2Infected_Hunter:  rootId = g_iBTHunterRoot;
        case L4D2Infected_Charger: rootId = g_iBTChargerRoot;
        case L4D2Infected_Jockey:  rootId = g_iBTJockeyRoot;
        case L4D2Infected_Smoker:  rootId = g_iBTSmokerRoot;
        case L4D2Infected_Boomer:  rootId = g_iBTBoomerRoot;
        case L4D2Infected_Spitter: rootId = g_iBTSpitterRoot;
        case L4D2Infected_Tank:    rootId = g_iBTTankRoot;
        case L4D2Infected_Witch:   rootId = g_iBTWitchRoot;
        default:                   rootId = -1;
    }

    if (rootId >= 0) {
        BT_Bind(client, rootId);
    }

    // Per-SI spawn initialization (reset per-SI state)
    switch (L4D2_Infected:GetInfectedClass(client)) {
        case L4D2Infected_Hunter: {
            g_bHunterJustLunged[client] = false;
            g_fHunterMissEscapeCooldown[client] = 0.0;
        }
        case L4D2Infected_Tank: {
            g_fTankLastBhop[client] = 0.0;
            g_iTankBhopChain[client] = 0;
            g_fTankLastGround[client] = 0.0;
            g_fTankLastPunchJump[client] = 0.0;
        }
    }

    return Plugin_Handled;
}

// ============================================================================
// OnPlayerRunCmd — main AI tick entry point
// ============================================================================

public Action:OnPlayerRunCmd(int client, int &buttons, int &impulse,
    float vel[3], float angles[3], int &weapon) {

    if (!IsBotInfected(client) || !IsPlayerAlive(client)) {
        return Plugin_Continue;
    }

    // --- v3.2 FIX: per-frame Tank jump/duck suppression (v2.2 first-layer defense) ---
    // The vanilla Tank AI presses IN_JUMP on its own. Without per-frame clearing,
    // TICK_INTERVAL=4 means 75% of frames pass through unmodified, letting the
    // vanilla AI jump freely at close range. This runs BEFORE the tick throttle.
    if (GetInfectedClass(client) == L4D2Infected_Tank) {
        buttons &= ~IN_JUMP;
        buttons &= ~IN_DUCK;
    }

    // Tick throttle
    g_iTickCounter[client]++;
    if (g_iTickCounter[client] < TICK_INTERVAL) {
        // For Tanks: we already suppressed jump/duck above → must return Changed
        if (GetInfectedClass(client) == L4D2Infected_Tank) {
            return Plugin_Changed;
        }
        return Plugin_Continue;
    }
    g_iTickCounter[client] = 0;

    // Skip if not bound to a BT
    if (!BT_IsBound(client)) {
        return Plugin_Continue;
    }

    // Reset BT movement accumulators
    BT_ResetMovement(client);

    // Set tank aggression mode on blackboard (cached handle, no FindConVar per tick)
    BB_SetBool(client, "tank_aggro", g_hCvarTankAggroBhop != null && GetConVarBool(g_hCvarTankAggroBhop));

    // Execute Behavior Tree
    // The BT modifies buttons/angles via BT_AddButton/BT_RemoveButton/BT_SetAimAngles.
    // OnPlayerRunCmd then applies these modifications.
    BT_Tick(client);

    // Apply accumulated movement changes
    BT_ApplyMovement(client, buttons);
    BT_ApplyAngles(client, angles);

    // Handle teleport (used by Tank bhop for velocity override)
    if (g_bBT_Teleport[client]) {
        TeleportEntity(client, NULL_VECTOR, g_fBT_Angles[client], NULL_VECTOR);
    }

    return Plugin_Changed;
}

// ============================================================================
// Event Hooks (preserved from v2.4 — game events, not BT logic)
// ============================================================================

// On ability use: handle pounce angle modification, coordination signals
// v3.2: removed suicide logic — all SI now have BT post-ability behaviors
public Action:Event_AbilityUse(Handle:event, String:name[], bool:dontBroadcast) {
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (!IsBotInfected(client)) return Plugin_Handled;

    g_bHasBeenShoved[client] = false;

    char abilityName[32];
    GetEventString(event, "ability", abilityName, sizeof(abilityName));

    if (StrEqual(abilityName, "ability_lunge")) {
        // Hunter pounce: mark for missed-pounce detection, signal coordination
        g_bHunterJustLunged[client] = true;
        g_fHunterMissEscapeCooldown[client] = GetGameTime() + 0.3;
        SI_SignalAttack(client);
        return Plugin_Handled;

    } else if (StrEqual(abilityName, "ability_charge")) {
        // Charger charge: signal coordination
        SI_SignalAttack(client);
        return Plugin_Handled;

    } else if (StrEqual(abilityName, "ability_spit")) {
        // Spitter post-spit behavior handled by BT (approach/retreat).
        // No suicide — Spitter re-engages after spit cooldown.
        return Plugin_Handled;
    }
    return Plugin_Handled;
}

public Action:Event_PlayerShoved(Handle:event, String:name[], bool:dontBroadcast) {
    int shovedPlayer = GetClientOfUserId(GetEventInt(event, "userid"));
    if (IsBotInfected(shovedPlayer)) {
        g_bHasBeenShoved[shovedPlayer] = true;
    }
    return Plugin_Continue;
}

public Action:Event_PlayerJump(Handle:event, String:name[], bool:dontBroadcast) {
    int jumpingPlayer = GetClientOfUserId(GetEventInt(event, "userid"));
    if (IsBotInfected(jumpingPlayer)) {
        g_bHasBeenShoved[jumpingPlayer] = false;
    }
    return Plugin_Continue;
}

// ============================================================================
// Suicide frame (called via RequestFrame after ability use)
// ============================================================================

public void SuicideFrame(any:client) {
    if (IsValidClient(client) && IsBotInfected(client) && IsPlayerAlive(client)) {
        ForcePlayerSuicide(client);
    }
}

// ============================================================================
// Coordination timer callback
// ============================================================================

public Action:Timer_UpdateCoordination(Handle:timer) {
    SI_UpdateCoordination();
    return Plugin_Continue;
}
