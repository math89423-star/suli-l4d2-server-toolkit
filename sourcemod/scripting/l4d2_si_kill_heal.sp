#include <sourcemod>
#include <sdkhooks>
#include <left4dhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.4"

public Plugin myinfo =
{
    name        = "L4D2 SI Kill Heal",
    author      = "Claude",
    description = "Heal temp health (虚血) for X% of killed SI/Witch max HP; extends bleed-out if incapacitated",
    version     = PLUGIN_VERSION,
    url         = ""
};

ConVar g_cvHealPercent;
ConVar g_cvMaxHP;
ConVar g_cvMaxBuffer;

public void OnPluginStart()
{
    g_cvHealPercent = CreateConVar("sm_si_kill_heal_percent", "1.0", "Percentage of SI max HP to heal on kill", _, true, 0.0, true, 100.0);
    g_cvMaxHP       = CreateConVar("sm_si_kill_heal_max",     "100", "Maximum effective HP (real + temp) after heal (standing)", _, true, 1.0, true, 9999.0);
    g_cvMaxBuffer   = CreateConVar("sm_si_kill_heal_buffer",  "300", "Maximum health buffer when incapacitated", _, true, 1.0, true, 9999.0);

    HookEvent("player_death",  Event_PlayerDeath);
    HookEvent("witch_killed",  Event_WitchKilled);

    AutoExecConfig(true, "l4d2_si_kill_heal");
}

void HealSurvivor(int client, int maxHealth)
{
    float healPercent = g_cvHealPercent.FloatValue;
    if (healPercent <= 0.0)
        return;

    float healAmount = float(maxHealth) * (healPercent / 100.0);
    if (healAmount <= 0.0)
        return;

    float curBuffer = GetEntPropFloat(client, Prop_Send, "m_healthBuffer");

    // Incapacitated: add to health buffer to slow bleed-out
    if (GetEntProp(client, Prop_Send, "m_isIncapacitated"))
    {
        float maxBuffer = g_cvMaxBuffer.FloatValue;
        float newBuffer = curBuffer + healAmount;
        if (newBuffer > maxBuffer)
            newBuffer = maxBuffer;
        SetEntPropFloat(client, Prop_Send, "m_healthBuffer", newBuffer);
        return;
    }

    // Standing: add to temp health (虚血) instead of real HP
    // Cap EFFECTIVE total (real HP + temp buffer) at g_cvMaxHP — was only capping buffer before (bug: could reach 200)
    float curHealth = float(GetClientHealth(client));
    float curTotal  = curHealth + curBuffer;
    float maxTotal  = g_cvMaxHP.FloatValue;

    if (curTotal >= maxTotal)
        return;

    float newTotal = curTotal + healAmount;
    if (newTotal > maxTotal)
        newTotal = maxTotal;

    float newBuffer = newTotal - curHealth;
    if (newBuffer < 0.0)
        newBuffer = 0.0;

    SetEntPropFloat(client, Prop_Send, "m_healthBuffer", newBuffer);
    // Start decay from now — temp health will decay at the standard L4D2 rate (pain_pills_decay_rate)
    SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime());
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    if (victim == 0 || attacker == 0)
        return;
    if (victim == attacker)
        return;
    if (!IsClientInGame(attacker) || GetClientTeam(attacker) != 2)
        return;

    int victimTeam = GetClientTeam(victim);
    if (victimTeam != 3)
        return;

    int siMaxHP = GetEntProp(victim, Prop_Data, "m_iMaxHealth");
    if (siMaxHP <= 0)
        return;

    HealSurvivor(attacker, siMaxHP);
}

void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(event.GetInt("userid"));
    if (attacker == 0 || !IsClientInGame(attacker) || GetClientTeam(attacker) != 2)
        return;

    int witchid = event.GetInt("witchid");
    if (witchid <= 0 || !IsValidEntity(witchid))
        return;

    int maxHP = GetEntProp(witchid, Prop_Data, "m_iMaxHealth");
    if (maxHP <= 0)
        return;

    HealSurvivor(attacker, maxHP);
}
