// l4d2_hand_flare.sp - L4D2 Hand Flare Plugin v1.0.0
// Hand-thrown flare with light, particle, and sprite effects

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.0.0"
#define PLUGIN_NAME "L4D2 Hand Flare"

#define MAX_FLARES 6
#define SETTLE_THRESHOLD 30.0
#define SETTLE_TIME 0.5
#define THINK_INTERVAL 0.1

#define MODEL_PIPEBOMB "models/w_models/weapons/w_eq_pipebomb.mdl"
#define PARTICLE_FLARE "fireworks_flare_trail_01"
#define PARTICLE_SMOKE "smoke_medium_01"
#define SPRITE_FLARE "effects/yellowflare.vmt"
#define SPRITE_GLOW "sprites/glow01.spr"

int g_iHFEnts[MAX_FLARES][5];
bool g_bHFSettled[MAX_FLARES];
float g_fHFSettleTime[MAX_FLARES];
float g_fHFExpire[MAX_FLARES];
int g_iHFCount;

ConVar g_cEnable;
ConVar g_cDuration;
ConVar g_cMax;
ConVar g_cSpeed;

bool g_bEnabled;
float g_fDuration;
int g_iMax;
float g_fSpeed;

// ============================================================
// Stock Helpers
// ============================================================

stock void HF_SetParent(int child, int parent)
{
    SetVariantString("!activator");
    AcceptEntityInput(child, "SetParent", parent, child);
}

stock void HF_PrecacheParticleName(const char[] name)
{
    int tbl = FindStringTable("ParticleEffectNames");
    if (tbl == INVALID_STRING_TABLE) return;
    int count = GetStringTableNumStrings(tbl);
    char buf[128];
    for (int i = 0; i < count; i++)
    {
        ReadStringTable(tbl, i, buf, sizeof(buf));
        if (StrEqual(buf, name, false))
            return;
    }
    bool save = LockStringTables(false);
    AddToStringTable(tbl, name);
    LockStringTables(save);
}

public Plugin myinfo =
{
    name = PLUGIN_NAME,
    author = "suli",
    description = "Hand-thrown flare with light, particle and sprite effects",
    version = PLUGIN_VERSION,
    url = ""
}

public void OnPluginStart()
{
    LoadTranslations("common.phrases");

    g_cEnable = CreateConVar("l4d2_hand_flare_enable", "1", "Enable hand flare plugin", _, true, 0.0, true, 1.0);
    g_cDuration = CreateConVar("l4d2_hand_flare_duration", "45.0", "Duration of hand flare in seconds", _, true, 5.0, true, 300.0);
    g_cMax = CreateConVar("l4d2_hand_flare_max", "6", "Maximum simultaneous hand flares", _, true, 1.0, true, 16.0);
    g_cSpeed = CreateConVar("l4d2_hand_flare_speed", "650", "Throw speed of hand flare", _, true, 100.0, true, 2000.0);

    g_cEnable.AddChangeHook(OnConVarChanged);
    g_cDuration.AddChangeHook(OnConVarChanged);
    g_cMax.AddChangeHook(OnConVarChanged);
    g_cSpeed.AddChangeHook(OnConVarChanged);

    RegAdminCmd("sm_handflare", Cmd_HandFlare, ADMFLAG_ROOT, "Test: throw a hand flare");
    RegConsoleCmd("sm_buy_handflare", Cmd_BuyHandFlare, "Buy a hand flare from shop");

    HookEvent("round_start", Event_RoundStart);
    HookEvent("round_end", Event_RoundEnd);
}

public void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (convar == g_cEnable) g_bEnabled = g_cEnable.BoolValue;
    else if (convar == g_cDuration) g_fDuration = g_cDuration.FloatValue;
    else if (convar == g_cMax) g_iMax = g_cMax.IntValue;
    else if (convar == g_cSpeed) g_fSpeed = g_cSpeed.FloatValue;
}

public void OnConfigsExecuted()
{
    g_bEnabled = g_cEnable.BoolValue;
    g_fDuration = g_cDuration.FloatValue;
    g_iMax = g_cMax.IntValue;
    g_fSpeed = g_cSpeed.FloatValue;
}

public void OnMapStart()
{
    PrecacheModel(MODEL_PIPEBOMB, true);
    PrecacheGeneric(SPRITE_FLARE, true);
    PrecacheGeneric(SPRITE_GLOW, true);
    HF_PrecacheParticleName(PARTICLE_FLARE);
    HF_PrecacheParticleName(PARTICLE_SMOKE);
}

public void OnPluginEnd()
{
    CleanupAllFlares();
}
// ============================================================
// Commands
// ============================================================

public Action Cmd_HandFlare(int client, int args)
{
    if (!g_bEnabled)
    {
        PrintToChat(client, "\x04[HandFlare]\x01 Plugin disabled.");
        return Plugin_Handled;
    }

    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        PrintToChat(client, "\x04[HandFlare]\x01 You must be alive to throw a flare.");
        return Plugin_Handled;
    }

    if (g_iHFCount >= g_iMax)
    {
        PrintToChat(client, "\x04[HandFlare]\x01 Maximum flares (%d) reached.", g_iMax);
        return Plugin_Handled;
    }

    ThrowFlare(client);
    PrintToChat(client, "\x04[HandFlare]\x01 Flare thrown! (%d/%d active)", g_iHFCount, g_iMax);
    return Plugin_Handled;
}

public Action Cmd_BuyHandFlare(int client, int args)
{
    if (!g_bEnabled)
    {
        PrintToChat(client, "\x04[HandFlare]\x01 Plugin disabled.");
        return Plugin_Handled;
    }

    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        PrintToChat(client, "\x04[HandFlare]\x01 You must be alive to throw a flare.");
        return Plugin_Handled;
    }

    if (g_iHFCount >= g_iMax)
    {
        PrintToChat(client, "\x04[HandFlare]\x01 Maximum flares (%d) reached.", g_iMax);
        return Plugin_Handled;
    }

    ThrowFlare(client);
    PrintToChat(client, "\x04[HandFlare]\x01 Flare thrown! (%d/%d active)", g_iHFCount, g_iMax);
    return Plugin_Handled;
}

// ============================================================
// Events
// ============================================================

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    CleanupAllFlares();
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    CleanupAllFlares();
}

public void OnClientDisconnect(int client)
{
    for (int i = 0; i < MAX_FLARES; i++)
    {
        if (g_iHFEnts[i][0] != -1 && IsValidEntity(g_iHFEnts[i][0]))
        {
            int owner = GetEntPropEnt(g_iHFEnts[i][0], Prop_Send, "m_hOwnerEntity");
            if (owner == client)
            {
                CleanupFlare(i);
            }
        }
    }
}
// ============================================================
// Core Functions
// ============================================================

void ThrowFlare(int client)
{
    int slot = FindFreeSlot();
    if (slot == -1)
    {
        PrintToChat(client, "\x04[HandFlare]\x01 No free flare slot available.");
        return;
    }

    float pos[3], ang[3], vel[3];
    GetClientEyePosition(client, pos);
    GetClientEyeAngles(client, ang);

    GetAngleVectors(ang, vel, NULL_VECTOR, NULL_VECTOR);

    // Offset spawn position slightly forward
    pos[0] += vel[0] * 30.0;
    pos[1] += vel[1] * 30.0;
    pos[2] += vel[2] * 30.0;

    // Create prop_physics
    int prop = CreateEntityByName("prop_physics");
    if (prop == -1 || !IsValidEntity(prop))
    {
        PrintToChat(client, "\x04[HandFlare]\x01 Failed to create flare entity.");
        return;
    }

    DispatchKeyValue(prop, "model", MODEL_PIPEBOMB);
    DispatchSpawn(prop);
    SetEntPropEnt(prop, Prop_Send, "m_hOwnerEntity", client);
    SetEntProp(prop, Prop_Data, "m_iHealth", 99999);

    // Set velocity - forward only, gravity handles arc
    float throwSpeed = g_fSpeed;
    vel[0] *= throwSpeed;
    vel[1] *= throwSpeed;
    vel[2] *= throwSpeed;
    TeleportEntity(prop, pos, ang, vel);

    // Create light_dynamic - community-recommended settings
    int light = CreateEntityByName("light_dynamic");
    if (light != -1 && IsValidEntity(light))
    {
        DispatchKeyValue(light, "_light", "255 220 170");
        DispatchKeyValue(light, "brightness", "1");
        DispatchKeyValue(light, "distance", "450");
        DispatchKeyValue(light, "spotlight_radius", "400");
        DispatchKeyValue(light, "style", "0");
        DispatchKeyValue(light, "spawnflags", "0");
        DispatchSpawn(light);
        HF_SetParent(light, prop);

        float lightPos[3];
        lightPos[0] = 0.0;
        lightPos[1] = 0.0;
        lightPos[2] = 10.0;
        TeleportEntity(light, lightPos, NULL_VECTOR, NULL_VECTOR);
    }

    // Create particle system
    int particle = CreateEntityByName("info_particle_system");
    if (particle != -1 && IsValidEntity(particle))
    {
        DispatchKeyValue(particle, "effect_name", PARTICLE_FLARE);
        DispatchKeyValue(particle, "start_active", "1");
        DispatchSpawn(particle);
        HF_SetParent(particle, prop);

        float partPos[3];
        partPos[0] = 0.0;
        partPos[1] = 0.0;
        partPos[2] = 0.0;
        TeleportEntity(particle, partPos, NULL_VECTOR, NULL_VECTOR);
    }

    // Create env_sprite
    int sprite = CreateEntityByName("env_sprite");
    if (sprite != -1 && IsValidEntity(sprite))
    {
        DispatchKeyValue(sprite, "model", SPRITE_FLARE);
        DispatchKeyValue(sprite, "spawnflags", "1");
        DispatchKeyValue(sprite, "scale", "1.0");
        DispatchKeyValue(sprite, "rendermode", "5");
        DispatchKeyValue(sprite, "renderamt", "255");
        DispatchKeyValue(sprite, "rendercolor", "255 220 170");
        DispatchKeyValue(sprite, "framerate", "10");
        DispatchSpawn(sprite);
        HF_SetParent(sprite, prop);

        float spritePos[3];
        spritePos[0] = 0.0;
        spritePos[1] = 0.0;
        spritePos[2] = 5.0;
        TeleportEntity(sprite, spritePos, NULL_VECTOR, NULL_VECTOR);
    }

    // Store in arrays
    g_iHFEnts[slot][0] = prop;
    g_iHFEnts[slot][1] = light;
    g_iHFEnts[slot][2] = particle;
    g_iHFEnts[slot][3] = sprite;
    g_iHFEnts[slot][4] = -1;
    g_bHFSettled[slot] = false;
    g_fHFSettleTime[slot] = 0.0;
    g_fHFExpire[slot] = GetGameTime() + g_fDuration;
    g_iHFCount++;

    // Start think timer
    CreateTimer(THINK_INTERVAL, Timer_FlareThink, slot, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    // Start expire timer
    CreateTimer(g_fDuration, Timer_FlareExpire, slot, TIMER_FLAG_NO_MAPCHANGE);

    // Emit sound
    EmitSoundToAll("weapons/pipebomb/pipebomb_jointfuse.wav", prop, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, 1.0, SNDPITCH_NORMAL, -1, pos);
}

int FindFreeSlot()
{
    for (int i = 0; i < MAX_FLARES; i++)
    {
        if (g_iHFEnts[i][0] == -1 || !IsValidEntity(g_iHFEnts[i][0]))
        {
            return i;
        }
    }
    return -1;
}
void CleanupFlare(int slot)
{
    if (slot < 0 || slot >= MAX_FLARES) return;

    for (int j = 0; j < 5; j++)
    {
        if (g_iHFEnts[slot][j] != -1 && IsValidEntity(g_iHFEnts[slot][j]))
        {
            AcceptEntityInput(g_iHFEnts[slot][j], "KillHierarchy");
            g_iHFEnts[slot][j] = -1;
        }
        else
        {
            g_iHFEnts[slot][j] = -1;
        }
    }

    g_bHFSettled[slot] = false;
    g_fHFSettleTime[slot] = 0.0;
    g_fHFExpire[slot] = 0.0;

    if (g_iHFCount > 0) g_iHFCount--;
}

void CleanupAllFlares()
{
    for (int i = 0; i < MAX_FLARES; i++)
    {
        CleanupFlare(i);
    }
}

// ============================================================
// Timers
// ============================================================

public Action Timer_FlareThink(Handle timer, any slot)
{
    if (slot < 0 || slot >= MAX_FLARES) return Plugin_Stop;

    int prop = g_iHFEnts[slot][0];
    if (prop == -1 || !IsValidEntity(prop))
    {
        CleanupFlare(slot);
        return Plugin_Stop;
    }

    // Check if flare has expired (safety)
    if (GetGameTime() >= g_fHFExpire[slot])
    {
        CleanupFlare(slot);
        return Plugin_Stop;
    }

    // Get velocity
    float vel[3];
    GetEntPropVector(prop, Prop_Data, "m_vecVelocity", vel);
    float speed = SquareRoot(vel[0] * vel[0] + vel[1] * vel[1] + vel[2] * vel[2]);

    if (!g_bHFSettled[slot])
    {
        if (speed < SETTLE_THRESHOLD)
        {
            if (g_fHFSettleTime[slot] == 0.0)
            {
                g_fHFSettleTime[slot] = GetGameTime();
            }
            else if (GetGameTime() - g_fHFSettleTime[slot] >= SETTLE_TIME)
            {
                g_bHFSettled[slot] = true;

                // Move light slightly above prop to illuminate ground better
                int light = g_iHFEnts[slot][1];
                if (light != -1 && IsValidEntity(light))
                {
                    float lightPos[3];
                    lightPos[0] = 0.0;
                    lightPos[1] = 0.0;
                    lightPos[2] = 20.0;
                    TeleportEntity(light, lightPos, NULL_VECTOR, NULL_VECTOR);
                }
            }
        }
        else
        {
            // Reset settle timer if still moving
            g_fHFSettleTime[slot] = 0.0;
        }
    }

    return Plugin_Continue;
}

public Action Timer_FlareExpire(Handle timer, any slot)
{
    if (slot < 0 || slot >= MAX_FLARES) return Plugin_Stop;

    CleanupFlare(slot);
    return Plugin_Stop;
}