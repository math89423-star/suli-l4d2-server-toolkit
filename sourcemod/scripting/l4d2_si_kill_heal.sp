#include <sourcemod>
#include <sdkhooks>
#include <left4dhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.6"
#define CHAT_PREFIX "\x04[杀敌回血]\x01"

public Plugin myinfo =
{
    name        = "L4D2 SI Kill Heal",
    author      = "Claude",
    description = "Heal temp health (虚血) for X% of killed SI/Witch max HP (halved, ceil, min 1); +20 real HP on heal/revive teammate; extends bleed-out if incapacitated; chat notification",
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

    HookEvent("player_death",   Event_PlayerDeath);
    HookEvent("witch_killed",   Event_WitchKilled);
    HookEvent("heal_success",   Event_HealSuccess);
    HookEvent("revive_success", Event_ReviveSuccess);

    AutoExecConfig(true, "l4d2_si_kill_heal");
}

// ============================================================================
// SI / Witch Kill → temp health (虚血)
// ============================================================================

void HealSurvivor(int client, int maxHealth, const char[] siName)
{
    float healPercent = g_cvHealPercent.FloatValue;
    if (healPercent <= 0.0)
        return;

    // Calculate base heal amount from SI max HP
    float healAmount = float(maxHealth) * (healPercent / 100.0);

    // Halve the heal amount and round up (ceil)
    // e.g. Boomer (50HP, 2%): 50*0.02=1.0 → halved=0.5 → ceil=1.0 ✓
    // e.g. Charger (600HP, 2%): 600*0.02=12.0 → halved=6.0 → ceil=6.0
    healAmount = float(RoundToCeil(healAmount / 2.0));

    // Minimum 1 HP — guarantees killing a Boomer still gives at least 1
    if (healAmount < 1.0)
        healAmount = 1.0;

    float curBuffer = GetEntPropFloat(client, Prop_Send, "m_healthBuffer");

    // Incapacitated: add to health buffer to slow bleed-out
    if (GetEntProp(client, Prop_Send, "m_isIncapacitated"))
    {
        float maxBuffer = g_cvMaxBuffer.FloatValue;
        float newBuffer = curBuffer + healAmount;
        if (newBuffer > maxBuffer)
            newBuffer = maxBuffer;
        float added = newBuffer - curBuffer;
        SetEntPropFloat(client, Prop_Send, "m_healthBuffer", newBuffer);
        if (added > 0.0)
            PrintToChat(client, "%s 击杀 \x05%s\x01，倒地倒计时延长 \x04+%.0f\x01 秒", CHAT_PREFIX, siName, added);
        return;
    }

    // Standing: add to temp health (虚血) instead of real HP
    // Cap EFFECTIVE total (real HP + temp buffer) at g_cvMaxHP
    float curHealth = float(GetClientHealth(client));
    float curTotal  = curHealth + curBuffer;
    float maxTotal  = g_cvMaxHP.FloatValue;

    if (curTotal >= maxTotal)
    {
        PrintToChat(client, "%s 击杀 \x05%s\x01，血量已达上限 (%.0fHP)，未获得虚血", CHAT_PREFIX, siName, curTotal);
        return;
    }

    float newTotal = curTotal + healAmount;
    if (newTotal > maxTotal)
        newTotal = maxTotal;

    float newBuffer = newTotal - curHealth;
    if (newBuffer < 0.0)
        newBuffer = 0.0;

    float added = newBuffer - curBuffer;
    SetEntPropFloat(client, Prop_Send, "m_healthBuffer", newBuffer);
    // Start decay from now — temp health will decay at the standard L4D2 rate (pain_pills_decay_rate)
    SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime());

    if (added > 0.0)
        PrintToChat(client, "%s 击杀 \x05%s\x01，获得 \x04+%.0f\x01 虚血", CHAT_PREFIX, siName, added);
}

// ============================================================================
// Add real health (实体血) — used for teammate heal / revive rewards
// ============================================================================

void AddRealHealth(int client, float amount, const char[] reason)
{
    int curHealth = GetClientHealth(client);
    float maxHP = g_cvMaxHP.FloatValue;

    if (float(curHealth) >= maxHP)
    {
        PrintToChat(client, "%s %s，血量已达上限 (%dHP)，未获得实体血", CHAT_PREFIX, reason, curHealth);
        return;
    }

    float newHealth = float(curHealth) + amount;
    if (newHealth > maxHP)
        newHealth = maxHP;

    int finalHealth = RoundToCeil(newHealth);
    int added = finalHealth - curHealth;

    if (added <= 0)
        return;

    SetEntityHealth(client, finalHealth);
    PrintToChat(client, "%s %s，获得 \x04+%d\x01 实体血", CHAT_PREFIX, reason, added);
}

// ============================================================================
// Event: player_death → SI kill reward
// ============================================================================

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

    char siName[32];
    int zombieClass = GetEntProp(victim, Prop_Send, "m_zombieClass");
    switch (zombieClass)
    {
        case 1:  siName = "Smoker";
        case 2:  siName = "Boomer";
        case 3:  siName = "Hunter";
        case 4:  siName = "Spitter";
        case 5:  siName = "Jockey";
        case 6:  siName = "Charger";
        case 8:  siName = "Tank";
        default: siName = "特感";
    }

    HealSurvivor(attacker, siMaxHP, siName);
}

// ============================================================================
// Event: witch_killed → Witch kill reward
// ============================================================================

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

    HealSurvivor(attacker, maxHP, "Witch");
}

// ============================================================================
// Event: heal_success → +20 real HP for healing a teammate (pills/medkit)
// ============================================================================

void Event_HealSuccess(Event event, const char[] name, bool dontBroadcast)
{
    int healer  = GetClientOfUserId(event.GetInt("userid"));
    int subject  = GetClientOfUserId(event.GetInt("subject"));

    if (healer == 0 || subject == 0)
        return;
    if (healer == subject)
        return;  // Self-heal doesn't count
    if (!IsClientInGame(healer) || GetClientTeam(healer) != 2)
        return;

    AddRealHealth(healer, 20.0, "为队友打包");
}

// ============================================================================
// Event: revive_success → +20 real HP for rescuing a downed teammate
// ============================================================================

void Event_ReviveSuccess(Event event, const char[] name, bool dontBroadcast)
{
    int reviver = GetClientOfUserId(event.GetInt("userid"));
    int subject  = GetClientOfUserId(event.GetInt("subject"));

    if (reviver == 0 || subject == 0)
        return;
    if (!IsClientInGame(reviver) || GetClientTeam(reviver) != 2)
        return;

    AddRealHealth(reviver, 20.0, "救援倒地队友");
}
