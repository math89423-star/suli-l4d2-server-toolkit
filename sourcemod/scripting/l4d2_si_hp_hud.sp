#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "1.0"

ConVar g_cvEnable, g_cvDuration, g_cvShowWitch;

// Per-player: last target entity reference + timer
int g_iLastTarget[MAXPLAYERS+1];
Handle g_hHideTimer[MAXPLAYERS+1];
float g_fLastDamageTime[MAXPLAYERS+1];

public Plugin myinfo = {
    name = "[L4D2] SI HP HUD",
    author = "claude",
    description = "Show special infected HP on HUD when damaging them",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    HookEvent("player_hurt", Event_PlayerHurt);
    HookEvent("infected_death", Event_InfectedDeath);
    HookEvent("player_death", Event_PlayerDeath);

    g_cvEnable    = CreateConVar("si_hp_enable",    "1",   "Enable SI HP HUD (0=off, 1=on)");
    g_cvDuration  = CreateConVar("si_hp_duration",  "3.0", "HUD display duration in seconds");
    g_cvShowWitch = CreateConVar("si_hp_show_witch", "0",  "Show Witch HP (0=off, 1=on)");

    AutoExecConfig(true, "l4d2_si_hp_hud");
}

public void OnClientDisconnect(int client)
{
    KillHPHideTimer(client);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim > 0 && victim <= MaxClients) {
        KillHPHideTimer(victim);
    }
}

public void Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
    int entity = event.GetInt("entityid");
    if (entity <= 0) return;

    // Find players tracking this entity and show "DEAD"
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == 2) {
            int ref = EntIndexToEntRef(g_iLastTarget[i]);
            if (ref > 0 && ref == entity) {
                PrintHintText(i, "✔ 已击杀");
                g_iLastTarget[i] = INVALID_ENT_REFERENCE;
                KillHPHideTimer(i);
            }
        }
    }
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue) return;

    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    if (!IsValidSI(victim)) return;
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker)) return;
    if (GetClientTeam(attacker) != 2) return;

    // Skip Witch if disabled
    if (!g_cvShowWitch.BoolValue) {
        char cls[32];
        GetEntityClassname(victim, cls, sizeof(cls));
        if (StrEqual(cls, "witch")) return;
    }

    ShowSIHP(attacker, victim);
}

bool IsValidSI(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client)) return false;

    int team = GetClientTeam(client);
    if (team != 3) return false; // only infected team

    return true;
}

void ShowSIHP(int attacker, int victim)
{
    int hp    = GetClientHealth(victim);
    int maxHp = GetEntProp(victim, Prop_Data, "m_iMaxHealth");
    if (maxHp <= 0) maxHp = 1;

    char cls[32], name[64];
    GetEntityClassname(victim, cls, sizeof(cls));
    Format(name, sizeof(name), GetSIName(cls));

    // Build HP bar (20 chars max)
    float ratio = float(hp) / float(maxHp);
    int barLen  = RoundToFloor(ratio * 20.0);
    if (barLen < 0) barLen = 0;
    if (barLen > 20) barLen = 20;

    char bar[64];
    for (int i = 0; i < 20; i++) {
        if (i < barLen)
            bar[i] = '|';
        else
            bar[i] = ' ';
    }
    bar[20] = '\0';

    char msg[256];
    if (hp <= 0) {
        Format(msg, sizeof(msg), "%s\n[%s] ✔ 已击杀", name, bar);
    } else {
        Format(msg, sizeof(msg), "%s\n[%s] %d / %d", name, bar, hp, maxHp);
    }

    PrintHintText(attacker, msg);
    g_iLastTarget[attacker] = EntIndexToEntRef(victim);
    g_fLastDamageTime[attacker] = GetGameTime();

    // Reset hide timer
    KillHPHideTimer(attacker);
    g_hHideTimer[attacker] = CreateTimer(g_cvDuration.FloatValue, Timer_HideHP, attacker, TIMER_FLAG_NO_MAPCHANGE);
}

char[] GetSIName(const char[] classname)
{
    if (StrContains(classname, "smoker")  != -1) return "Smoker  烟鬼";
    if (StrContains(classname, "boomer")  != -1) return "Boomer  胖子";
    if (StrContains(classname, "hunter")  != -1) return "Hunter  猎人";
    if (StrContains(classname, "spitter") != -1) return "Spitter 口水";
    if (StrContains(classname, "jockey")  != -1) return "Jockey  猴子";
    if (StrContains(classname, "charger") != -1) return "Charger 牛";
    if (StrContains(classname, "tank")    != -1) return "Tank  坦克";
    if (StrContains(classname, "witch")   != -1) return "Witch  女巫";
    return "特感";
}

Action Timer_HideHP(Handle timer, any client)
{
    g_hHideTimer[client] = null;
    if (IsClientInGame(client) && !IsFakeClient(client)) {
        g_iLastTarget[client] = INVALID_ENT_REFERENCE;
    }
    return Plugin_Stop;
}

void KillHPHideTimer(int client)
{
    if (g_hHideTimer[client] != null) {
        KillTimer(g_hHideTimer[client]);
        g_hHideTimer[client] = null;
    }
    g_iLastTarget[client] = INVALID_ENT_REFERENCE;
}
