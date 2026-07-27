#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "1.1"

public Plugin myinfo =
{
    name = "L4D2 Special Infected Ability Movement",
    author = "Claude (based on Silvers' design)",
    description = "Allows SI bots to move while using abilities (Smoker pull, Spitter spit, Tank rock)",
    version = PLUGIN_VERSION,
    url = ""
};

// CVars
ConVar g_hCvarAllow;
ConVar g_hCvarBots;
ConVar g_hCvarSmokerMode;
ConVar g_hCvarSmokerSpeed;
ConVar g_hCvarSmokerDelay;
ConVar g_hCvarSpitterSpeed;
ConVar g_hCvarTankSpeed;

// Smoker: track when tongue was fired for delay
float g_fSmokerTongueTime[MAXPLAYERS+1];

// Spitter: track spitting state via ability_use event (m_bIsSpitting is not a valid netprop)
bool g_bSpitterSpitting[MAXPLAYERS+1];

public void OnPluginStart()
{
    g_hCvarAllow = CreateConVar("l4d_infected_movement_allow", "2",
        "0=Off, 1=Players only, 2=Bots only, 3=Both",
        _, true, 0.0, true, 3.0);

    g_hCvarBots = CreateConVar("l4d_infected_movement_bots", "3",
        "Bitmask: 1=Smoker, 2=Spitter, 4=Tank. Which bot types can move during abilities.",
        _, true, 0.0, true, 7.0);

    g_hCvarSmokerMode = CreateConVar("l4d_infected_movement_smoker", "2",
        "Smoker movement mode: 0=Only while shooting tongue, 1=While pulling, 2=While pulling AND hanging",
        _, true, 0.0, true, 2.0);

    g_hCvarSmokerSpeed = CreateConVar("l4d_infected_movement_speed_smoker", "250",
        "Smoker movement speed during ability",
        _, true, 0.0, true, 450.0);

    g_hCvarSmokerDelay = CreateConVar("l4d_infected_movement_delay_smoker", "0.3",
        "Delay in seconds after tongue hit before allowing movement",
        _, true, 0.0, true, 3.0);

    g_hCvarSpitterSpeed = CreateConVar("l4d_infected_movement_speed_spitter", "220",
        "Spitter movement speed during spit",
        _, true, 0.0, true, 450.0);

    g_hCvarTankSpeed = CreateConVar("l4d_infected_movement_speed_tank", "210",
        "Tank movement speed during rock throw",
        _, true, 0.0, true, 450.0);

    // Event hooks for ability state tracking
    HookEvent("ability_use", Event_AbilityUse);
    HookEvent("tongue_release", Event_TongueRelease);
    HookEvent("spitter_spit", Event_SpitterSpit);  // fires when spit projectile lands → spitting ends

    // Auto-generate cfg
    AutoExecConfig(true, "l4d_infected_movement");
}

// ============================================================================
// Approach: Override m_flMaxspeed when SI is using ability.
// The game normally caps movement to near-zero during ability use.
// By restoring maxspeed each frame, bots can walk/strafe normally.
// ============================================================================

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
    int allow = g_hCvarAllow.IntValue;
    if (allow == 0) return Plugin_Continue;

    bool isBot = IsFakeClient(client);
    if (allow == 1 && isBot) return Plugin_Continue;      // players only
    if (allow == 2 && !isBot) return Plugin_Continue;      // bots only

    if (!IsInfectedAlive(client)) return Plugin_Continue;

    int botMask = g_hCvarBots.IntValue;

    switch (GetInfectedClass(client))
    {
        case L4D2Infected_Smoker:
        {
            if (!(botMask & 1)) return Plugin_Continue;
            SmokerMovement(client, buttons, vel);
        }
        case L4D2Infected_Spitter:
        {
            if (!(botMask & 2)) return Plugin_Continue;
            SpitterMovement(client, vel);
        }
        case L4D2Infected_Tank:
        {
            if (!(botMask & 4)) return Plugin_Continue;
            TankMovement(client, vel);
        }
    }
    return Plugin_Continue;
}

// ============================================================================
// SMOKER — move while pulling/hanging a survivor
// ============================================================================

void SmokerMovement(int client, int &buttons, float vel[3])
{
    int mode = g_hCvarSmokerMode.IntValue;
    if (mode == 0) return;

    int tongueVictim = GetEntPropEnt(client, Prop_Send, "m_tongueVictim");
    if (tongueVictim <= 0) return;

    // Mode 2: allow movement while pulling or hanging
    // Mode 1: allow movement only while pulling (not hanging)
    if (mode == 1)
    {
        // Check if victim is hanging (being dragged in air)
        if (GetEntProp(tongueVictim, Prop_Send, "m_isHangingFromTongue")) return;
    }

    // Delay: don't move immediately after tongue hit
    float now = GetGameTime();
    if (g_fSmokerTongueTime[client] > 0.0)
    {
        if ((now - g_fSmokerTongueTime[client]) < g_hCvarSmokerDelay.FloatValue)
        {
            return;
        }
    }

    // Allow forward/back/strafe movement at configured speed
    float speed = g_hCvarSmokerSpeed.FloatValue;

    // CRITICAL: The game sets m_flMaxspeed to near-zero during tongue pull.
    // Override it every frame.
    SetEntPropFloat(client, Prop_Send, "m_flMaxspeed", speed);
}

// Track when SI fires abilities
void Event_AbilityUse(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsFakeClient(client)) return;

    char abilityName[32];
    event.GetString("ability", abilityName, sizeof(abilityName));
    if (strcmp(abilityName, "ability_tongue") == 0)
    {
        g_fSmokerTongueTime[client] = GetGameTime();
    }
    else if (strcmp(abilityName, "ability_spit") == 0)
    {
        g_bSpitterSpitting[client] = true;
    }
}

// Track when tongue releases (cleanup)
void Event_TongueRelease(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsFakeClient(client))
    {
        g_fSmokerTongueTime[client] = 0.0;
    }
}

// Track when spit lands → spitting ends
void Event_SpitterSpit(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsFakeClient(client))
    {
        g_bSpitterSpitting[client] = false;
    }
}

// ============================================================================
// SPITTER — move while spitting
// ============================================================================

void SpitterMovement(int client, float vel[3])
{
    // Use event-tracked state instead of broken m_bIsSpitting netprop
    if (!g_bSpitterSpitting[client]) return;

    float speed = g_hCvarSpitterSpeed.FloatValue;
    SetEntPropFloat(client, Prop_Send, "m_flMaxspeed", speed);
}

// ============================================================================
// TANK — move while throwing rocks
// ============================================================================

void TankMovement(int client, float vel[3])
{
    // Detect rock throw ability in use
    int ability = GetEntPropEnt(client, Prop_Send, "m_customAbility");
    if (ability <= 0 || !IsValidEntity(ability)) return;

    char classname[64];
    GetEntityClassname(ability, classname, sizeof(classname));
    if (strcmp(classname, "ability_tank_rock") != 0) return;

    float speed = g_hCvarTankSpeed.FloatValue;
    SetEntPropFloat(client, Prop_Send, "m_flMaxspeed", speed);
}

// ============================================================================
// STOCKS
// ============================================================================

stock bool IsInfectedAlive(int client)
{
    return (IsClientInGame(client) && IsPlayerAlive(client) && GetClientTeam(client) == 3);
}

stock L4D2_Infected GetInfectedClass(int client)
{
    return view_as<L4D2_Infected>(GetEntProp(client, Prop_Send, "m_zombieClass"));
}

enum L4D2_Infected
{
    L4D2Infected_Smoker = 1,
    L4D2Infected_Boomer,
    L4D2Infected_Hunter,
    L4D2Infected_Spitter,
    L4D2Infected_Jockey,
    L4D2Infected_Charger,
    L4D2Infected_Witch,
    L4D2Infected_Tank
};
