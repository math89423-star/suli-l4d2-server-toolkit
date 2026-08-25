// ============================================================================
// L4D2 Aerial Flare — v5.0
// Buy from !shop, shoot from gun. Projectile flies on aim direction.
// After 2.5s fuse, detonates → white light sphere appears at that point,
// slowly falls with gravity while illuminating, then fades.
// ============================================================================

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "5.0.0"

#define FLARE_FUSE_TIME     2.5
#define FLARE_DESCENT_RATE  40.0   // units per second falling speed
#define FLARE_HAMMERID      2467737  // Matches shop flare skip check — prevents shop flare from processing our projectile
#define FLARE_DEBOUNCE      0.5

ConVar g_cvEnable;
ConVar g_cvDuration;
ConVar g_cvMaxFlares;
ConVar g_cvFuseTime;
ConVar g_cvLightDist;
ConVar g_cvCooldown;
ConVar g_cvDescentRate;

bool g_bEnabled;
float g_fDuration;
int g_iMaxFlares;
float g_fFuseTime;
float g_fLightDist;
float g_fCooldown;
float g_fDescentRate;

// Per-player
bool g_bHasFlare[MAXPLAYERS + 1];
float g_fLastBuy[MAXPLAYERS + 1];
float g_fLastFire[MAXPLAYERS + 1];

// Active flares (light phase)
#define MAX_FLARES 5
bool g_bFlareActive[MAX_FLARES];
int g_iFlareCarrier[MAX_FLARES];    // info_target as carrier
int g_iFlareLight[MAX_FLARES];      // light_dynamic
int g_iFlareSprite[MAX_FLARES];     // env_sprite
float g_fFlareGroundZ[MAX_FLARES];  // ground level for descent stop

public Plugin myinfo =
{
    name = "[L4D2] Aerial Flare",
    author = "suli",
    description = "Shoot from gun, 2.5s fuse, white light falls slowly",
    version = PLUGIN_VERSION,
    url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    if (GetEngineVersion() != Engine_Left4Dead2)
    {
        strcopy(error, err_max, "Plugin only supports Left 4 Dead 2");
        return APLRes_SilentFailure;
    }
    CreateNative("AerialFlare_Buy", Native_AerialFlareBuy);
    CreateNative("AerialFlare_IsAiming", Native_AerialFlareIsAiming);
    CreateNative("AerialFlare_GetCount", Native_AerialFlareGetCount);
    CreateNative("AerialFlare_HasFlare", Native_AerialFlareHasFlare);
    CreateNative("AerialFlare_Cancel", Native_AerialFlareCancel);   // v1.1: 商店 5s 未发射退款用
    RegPluginLibrary("l4d2_aerial_flare");
    return APLRes_Success;
}

public void OnPluginStart()
{
    CreateConVar("l4d2_aerial_flare_version", PLUGIN_VERSION, "Aerial Flare version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
    g_cvEnable      = CreateConVar("l4d2_aerial_flare_enable", "1", "0=OFF, 1=ON", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvDuration    = CreateConVar("l4d2_aerial_flare_duration", "18.0", "Seconds of illumination", FCVAR_NOTIFY, true, 3.0, true, 60.0);
    g_cvMaxFlares   = CreateConVar("l4d2_aerial_flare_max", "5", "Max simultaneous flares", FCVAR_NOTIFY, true, 1.0, true, 10.0);
    g_cvFuseTime    = CreateConVar("l4d2_aerial_flare_fuse", "2.5", "Fuse time in seconds before detonation", FCVAR_NOTIFY, true, 0.5, true, 10.0);
    g_cvLightDist   = CreateConVar("l4d2_aerial_flare_light_dist", "1600.0", "Light radius", FCVAR_NOTIFY, true, 300.0, true, 3000.0);
    g_cvCooldown    = CreateConVar("l4d2_aerial_flare_cooldown", "0.0", "Purchase cooldown", FCVAR_NOTIFY, true, 0.0, true, 120.0);
    g_cvDescentRate = CreateConVar("l4d2_aerial_flare_descent", "40.0", "Descent rate (units/sec) for the light sphere", FCVAR_NOTIFY, true, 5.0, true, 200.0);

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("player_death", Event_PlayerDeath);
    GetCvars();
    AutoExecConfig(true, "l4d2_aerial_flare");
}

void OnConVarChanged(ConVar c, const char[] o, const char[] n) { GetCvars(); }
void GetCvars()
{
    g_bEnabled = g_cvEnable.BoolValue; g_fDuration = g_cvDuration.FloatValue;
    g_iMaxFlares = g_cvMaxFlares.IntValue; g_fFuseTime = g_cvFuseTime.FloatValue;
    g_fLightDist = g_cvLightDist.FloatValue; g_fCooldown = g_cvCooldown.FloatValue;
    g_fDescentRate = g_cvDescentRate.FloatValue;
}

public void OnMapStart()
{
    PrecacheModel("models/w_models/weapons/w_HE_grenade.mdl", true);
    PrecacheModel("sprites/glow01.spr", true);
    PrecacheParticle("fireworks_flare_trail_01");
    PrecacheParticle("flare_burning");
    PrecacheSound("weapons/grenade_launcher/grenadefire/grenade_launcher_fire_1.wav", true);
    PrecacheSound("weapons/grenade_launcher/grenadefire/grenade_launcher_explode_2.wav", true);
    PrecacheSound("ambient/objects/tv_damage_fuzz.wav", true);
}

void PrecacheParticle(const char[] name)
{
    static int tbl = INVALID_STRING_TABLE;
    if (tbl == INVALID_STRING_TABLE) tbl = FindStringTable("ParticleEffectNames");
    if (FindStringIndex(tbl, name) == INVALID_STRING_INDEX)
    {
        bool save = LockStringTables(false);
        AddToStringTable(tbl, name);
        LockStringTables(save);
    }
}

public void OnMapEnd() { CleanupAllFlares(); }

void Event_RoundStart(Event e, const char[] n, bool b)
{
    for (int i = 1; i <= MaxClients; i++) { g_bHasFlare[i] = false; g_fLastBuy[i] = 0.0; }
    CleanupAllFlares();
}

public void OnClientDisconnect(int c) { g_bHasFlare[c] = false; g_fLastBuy[c] = 0.0; }
void Event_PlayerDeath(Event e, const char[] n, bool b) { int c = GetClientOfUserId(e.GetInt("userid")); if (c > 0) g_bHasFlare[c] = false; }

// ============================================================================
// Helpers
// ============================================================================

int GetActiveFlareCount() { int c = 0; for (int i = 0; i < MAX_FLARES; i++) if (g_bFlareActive[i]) c++; return c; }
int FindFreeSlot() { for (int i = 0; i < MAX_FLARES; i++) if (!g_bFlareActive[i]) return i; return -1; }

// ============================================================================
// Natives
// ============================================================================

int Native_AerialFlareBuy(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (!g_bEnabled || client < 1 || client > MaxClients || !IsClientInGame(client)) return 0;
    if (GetClientTeam(client) != 2 || !IsPlayerAlive(client)) { PrintToChat(client, "\x04[照明弹]\x01 必须是存活的幸存者"); return 0; }
    if (GetActiveFlareCount() >= g_iMaxFlares) { PrintToChat(client, "\x04[照明弹]\x01 已达最大数量"); return 0; }
    if (g_bHasFlare[client]) { PrintToChat(client, "\x04[照明弹]\x01 已有待发射照明弹"); return 0; }
    float now = GetGameTime();
    if (now - g_fLastBuy[client] < g_fCooldown) { PrintToChat(client, "\x04[照明弹]\x01 冷却中 %.0fs", g_fCooldown - (now - g_fLastBuy[client])); return 0; }

    g_bHasFlare[client] = true;
    g_fLastBuy[client] = now;
    PrintToChat(client, "\x04[照明弹]\x01 已购买！\x05开枪\x01即发射（%.1f秒引信）", g_fFuseTime);
    return 1;
}

int Native_AerialFlareIsAiming(Handle p, int n) { return 0; }
int Native_AerialFlareGetCount(Handle p, int n) { return GetActiveFlareCount(); }
int Native_AerialFlareHasFlare(Handle p, int n) { int c = GetNativeCell(1); if (c < 1 || c > MaxClients) return 0; return g_bHasFlare[c] ? 1 : 0; }
public int Native_AerialFlareCancel(Handle p, int n) {
    int c = GetNativeCell(1);
    if (c < 1 || c > MaxClients) return 0;
    int had = g_bHasFlare[c] ? 1 : 0;
    g_bHasFlare[c] = false;
    return had;
}

// ============================================================================
// OnPlayerRunCmd — shoot on IN_ATTACK
// ============================================================================

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
    if (!g_bEnabled || !g_bHasFlare[client]) return Plugin_Continue;
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client)) return Plugin_Continue;
    if (GetClientTeam(client) != 2) return Plugin_Continue;

    float now = GetGameTime();
    if (now - g_fLastFire[client] < FLARE_DEBOUNCE) return Plugin_Continue;

    if (buttons & IN_ATTACK)
    {
        g_bHasFlare[client] = false;
        g_fLastFire[client] = now;
        FireAerialFlare(client);
    }

    return Plugin_Continue;
}

// ============================================================================
// Fire — create projectile, hook touch for fuse
// ============================================================================

void FireAerialFlare(int client)
{
    float vPos[3], vAng[3], fwd[3];
    GetClientEyePosition(client, vPos);
    GetClientEyeAngles(client, vAng);
    GetAngleVectors(vAng, fwd, NULL_VECTOR, NULL_VECTOR);

    // Spawn position: forward from eye
    vPos[0] += fwd[0] * 30.0;
    vPos[1] += fwd[1] * 30.0;
    vPos[2] += fwd[2] * 10.0;

    // Velocity: same direction as aim, grenade launcher speed
    float speed = 1000.0;
    float vVel[3];
    vVel[0] = fwd[0] * speed;
    vVel[1] = fwd[1] * speed;
    vVel[2] = fwd[2] * speed;

    LogMessage("[aerial_flare] client %d firing at (%.1f,%.1f,%.1f) dir=(%.2f,%.2f,%.2f)", client, vPos[0], vPos[1], vPos[2], fwd[0], fwd[1], fwd[2]);

    // Create projectile
    int ent = CreateEntityByName("grenade_launcher_projectile");
    if (ent == -1 || !IsValidEntity(ent)) { LogError("[aerial_flare] create failed"); return; }

    SetEntProp(ent, Prop_Data, "m_iHammerID", FLARE_HAMMERID);
    SetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity", client);
    SetEntPropFloat(ent, Prop_Data, "m_flGravity", 0.15); // low gravity = parabolic arc, reaches good height
    DispatchSpawn(ent);
    TeleportEntity(ent, vPos, vAng, vVel);

    // Sound
    EmitAmbientSound("weapons/grenade_launcher/grenadefire/grenade_launcher_fire_1.wav", vPos, SOUND_FROM_WORLD, SNDLEVEL_NORMAL);

    // Attach trail particle
    int trail = CreateEntityByName("info_particle_system");
    if (trail > 0 && IsValidEntity(trail))
    {
        DispatchKeyValue(trail, "effect_name", "fireworks_flare_trail_01");
        DispatchKeyValue(trail, "start_active", "1");
        DispatchSpawn(trail);
        ActivateEntity(trail);
        AcceptEntityInput(trail, "Start");
        SetVariantString("!activator");
        AcceptEntityInput(trail, "SetParent", ent);
        TeleportEntity(trail, view_as<float>({0.0, 0.0, 0.0}), NULL_VECTOR, NULL_VECTOR);
    }

    // Apex detection timer — check Z velocity each tick, detonate when falling
    DataPack dp = new DataPack();
    dp.WriteCell(EntIndexToEntRef(ent));
    dp.WriteCell(client);
    CreateTimer(0.05, Timer_CheckApex, dp, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);

    // Safety timeout — force detonate after 2s if apex not detected
    CreateTimer(2.0, Timer_SafetyTimeout, EntIndexToEntRef(ent), TIMER_FLAG_NO_MAPCHANGE);
}

// ============================================================================
// Apex detection — check Z velocity, detonate when falling
// ============================================================================

Action Timer_CheckApex(Handle timer, DataPack dp)
{
    dp.Reset();
    int entRef = dp.ReadCell();
    int client = dp.ReadCell();

    int ent = EntRefToEntIndex(entRef);
    if (ent <= 0 || !IsValidEntity(ent))
    {
        // Projectile gone (hit something), just stop
        return Plugin_Stop;
    }

    // Get Z velocity
    float vel[3];
    GetEntPropVector(ent, Prop_Send, "m_vInitialVelocity", vel);
    // Also try m_vecVelocity
    float vel2[3];
    GetEntPropVector(ent, Prop_Data, "m_vecVelocity", vel2);

    // Use the larger of the two
    float zVel = vel2[2]; // m_vecVelocity is the actual current velocity

    // Detonate when projectile starts falling (Z velocity <= 0 and has been going up)
    if (zVel <= 0.0)
    {
        float detPos[3];
        GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", detPos);

        // Kill projectile
        AcceptEntityInput(ent, "Kill");

        // Find ground Z
        float groundZ = detPos[2];
        float down[3] = {90.0, 0.0, 0.0};
        Handle trace = TR_TraceRayFilterEx(detPos, down, MASK_PLAYERSOLID, RayType_Infinite, TraceFilter_NoSelf, client);
        if (TR_DidHit(trace))
        {
            float endPos[3];
            TR_GetEndPosition(endPos, trace);
            groundZ = endPos[2];
        }
        delete trace;

        LogMessage("[aerial_flare] apex at (%.1f,%.1f,%.1f) ground=%.1f zVel=%.1f", detPos[0], detPos[1], detPos[2], groundZ, zVel);

        // Sound
        EmitAmbientSound("weapons/grenade_launcher/grenadefire/grenade_launcher_explode_2.wav", detPos, SOUND_FROM_WORLD, SNDLEVEL_GUNFIRE);

        // Create light sphere
        SpawnLightSphere(detPos, groundZ);
        return Plugin_Stop;
    }

    return Plugin_Continue;
}

// ============================================================================
// Safety timeout — force detonate if apex detection missed
// ============================================================================

Action Timer_SafetyTimeout(Handle timer, any entRef)
{
    int ent = EntRefToEntIndex(entRef);
    if (ent <= 0 || !IsValidEntity(ent)) return Plugin_Stop;

    float detPos[3];
    GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", detPos);
    int client = GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity");

    float groundZ = detPos[2];
    float down[3] = {90.0, 0.0, 0.0};
    Handle trace = TR_TraceRayFilterEx(detPos, down, MASK_PLAYERSOLID, RayType_Infinite, TraceFilter_NoSelf, client);
    if (TR_DidHit(trace))
    {
        float endPos[3];
        TR_GetEndPosition(endPos, trace);
        groundZ = endPos[2];
    }
    delete trace;

    AcceptEntityInput(ent, "Kill");
    LogMessage("[aerial_flare] safety timeout at (%.1f,%.1f,%.1f)", detPos[0], detPos[1], detPos[2]);
    EmitAmbientSound("weapons/grenade_launcher/grenadefire/grenade_launcher_explode_2.wav", detPos, SOUND_FROM_WORLD, SNDLEVEL_GUNFIRE);
    SpawnLightSphere(detPos, groundZ);
    return Plugin_Stop;
}

void SpawnLightSphere(float pos[3], float groundZ)
{
    int slot = FindFreeSlot();
    if (slot < 0) return;

    g_bFlareActive[slot] = true;
    g_fFlareGroundZ[slot] = groundZ;

    // === Carrier entity (info_target) — light and sprite parented to this ===
    int carrier = CreateEntityByName("info_target");
    if (carrier > 0 && IsValidEntity(carrier))
    {
        DispatchSpawn(carrier);
        TeleportEntity(carrier, pos, NULL_VECTOR, NULL_VECTOR);
        g_iFlareCarrier[slot] = EntIndexToEntRef(carrier);
    }

    // === White light_dynamic (parented to carrier) ===
    int light = CreateEntityByName("light_dynamic");
    if (light > 0 && IsValidEntity(light))
    {
        char sDist[16];
        FloatToString(g_fLightDist, sDist, sizeof(sDist));
        DispatchKeyValue(light, "_light", "255 255 255 255");
        DispatchKeyValue(light, "brightness", "6");
        DispatchKeyValue(light, "spotlight_radius", sDist);
        DispatchKeyValue(light, "distance", sDist);
        DispatchKeyValue(light, "style", "0");
        DispatchSpawn(light);
        AcceptEntityInput(light, "TurnOn");
        SetVariantString("!activator");
        AcceptEntityInput(light, "SetParent", carrier);
        TeleportEntity(light, view_as<float>({0.0, 0.0, 0.0}), NULL_VECTOR, NULL_VECTOR);
        g_iFlareLight[slot] = EntIndexToEntRef(light);
    }

    // === White env_sprite (parented to carrier) ===
    int sprite = CreateEntityByName("env_sprite");
    if (sprite > 0 && IsValidEntity(sprite))
    {
        DispatchKeyValue(sprite, "model", "sprites/glow01.spr");
        DispatchKeyValue(sprite, "scale", "4.0");
        DispatchKeyValue(sprite, "spawnflags", "1");
        DispatchKeyValue(sprite, "rendercolor", "255 255 255");
        DispatchKeyValue(sprite, "rendermode", "5");
        DispatchKeyValue(sprite, "renderamt", "255");
        DispatchSpawn(sprite);
        ActivateEntity(sprite);
        SetVariantString("!activator");
        AcceptEntityInput(sprite, "SetParent", carrier);
        TeleportEntity(sprite, view_as<float>({0.0, 0.0, 5.0}), NULL_VECTOR, NULL_VECTOR);
        g_iFlareSprite[slot] = EntIndexToEntRef(sprite);
    }

    // Ambient sound
    EmitAmbientSound("ambient/objects/tv_damage_fuzz.wav", pos, SOUND_FROM_WORLD, SNDLEVEL_NONE, SND_NOFLAGS, 0.3, SNDPITCH_NORMAL, -1);

    // Start descent timer (only moves carrier, children follow automatically)
    CreateTimer(0.1, Timer_Descent, slot, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    // Fade timer
    CreateTimer(g_fDuration, Timer_FadeStart, slot, TIMER_FLAG_NO_MAPCHANGE);

    // Safety expire
    CreateTimer(g_fDuration + 5.0, Timer_Expire, slot, TIMER_FLAG_NO_MAPCHANGE);
}

// ============================================================================
// Descent — light sphere falls slowly
// ============================================================================

Action Timer_Descent(Handle timer, any slot)
{
    if (!g_bFlareActive[slot]) return Plugin_Stop;

    int carrier = EntRefToEntIndex(g_iFlareCarrier[slot]);
    if (carrier <= 0 || !IsValidEntity(carrier)) { CleanupFlare(slot); return Plugin_Stop; }

    float pos[3];
    GetEntPropVector(carrier, Prop_Data, "m_vecAbsOrigin", pos);

    if (pos[2] <= g_fFlareGroundZ[slot] + 10.0)
        return Plugin_Continue; // on ground, keep illuminating

    pos[2] -= g_fDescentRate * 0.1; // 4u per tick at 0.1s interval
    TeleportEntity(carrier, pos, NULL_VECTOR, NULL_VECTOR);

    return Plugin_Continue;
}

// ============================================================================
// Fade
// ============================================================================

Action Timer_FadeStart(Handle timer, any slot)
{
    if (!g_bFlareActive[slot]) return Plugin_Continue;
    int light = EntRefToEntIndex(g_iFlareLight[slot]);
    if (light > 0 && IsValidEntity(light)) { SetVariantInt(1); AcceptEntityInput(light, "brightness"); }
    int sprite = EntRefToEntIndex(g_iFlareSprite[slot]);
    if (sprite > 0 && IsValidEntity(sprite)) { SetVariantInt(150); AcceptEntityInput(sprite, "Alpha"); }
    CreateTimer(1.0, Timer_Fade2, slot, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Continue;
}

Action Timer_Fade2(Handle timer, any slot)
{
    if (!g_bFlareActive[slot]) return Plugin_Continue;
    int sprite = EntRefToEntIndex(g_iFlareSprite[slot]);
    if (sprite > 0 && IsValidEntity(sprite)) { SetVariantInt(60); AcceptEntityInput(sprite, "Alpha"); }
    CreateTimer(1.0, Timer_Fade3, slot, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Continue;
}

Action Timer_Fade3(Handle timer, any slot)
{
    if (!g_bFlareActive[slot]) return Plugin_Continue;
    int sprite = EntRefToEntIndex(g_iFlareSprite[slot]);
    if (sprite > 0 && IsValidEntity(sprite)) { SetVariantInt(10); AcceptEntityInput(sprite, "Alpha"); }
    int light = EntRefToEntIndex(g_iFlareLight[slot]);
    if (light > 0 && IsValidEntity(light)) AcceptEntityInput(light, "TurnOff");
    CreateTimer(1.0, Timer_FinalKill, slot, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Continue;
}

Action Timer_FinalKill(Handle timer, any slot) { if (g_bFlareActive[slot]) CleanupFlare(slot); return Plugin_Continue; }
Action Timer_Expire(Handle timer, any slot) { if (g_bFlareActive[slot]) CleanupFlare(slot); return Plugin_Continue; }
bool TraceFilter_NoSelf(int entity, int contentsMask, any data) { return entity != data; }

// ============================================================================
// Cleanup
// ============================================================================

void CleanupFlare(int slot)
{
    // Kill carrier (kills all parented children)
    int carrier = EntRefToEntIndex(g_iFlareCarrier[slot]);
    if (carrier > 0 && IsValidEntity(carrier)) AcceptEntityInput(carrier, "Kill");
    g_iFlareCarrier[slot] = 0;
    g_iFlareLight[slot] = 0; g_iFlareSprite[slot] = 0;
    g_bFlareActive[slot] = false;
}

void CleanupAllFlares() { for (int s = 0; s < MAX_FLARES; s++) if (g_bFlareActive[s]) CleanupFlare(s); }
