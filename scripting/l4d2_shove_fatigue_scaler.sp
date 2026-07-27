#include <sourcemod>
#include <left4dhooks>

public Plugin myinfo = {
    name = "Shove Fatigue Scaler",
    author = "claude",
    description = "Catch all shoves (air+hit) and reduce penalty to 1/2",
    version = "2.0",
    url = ""
};

int g_iPrevButtons[MAXPLAYERS+1];

public void OnClientPutInServer(int client)
{
    g_iPrevButtons[client] = 0;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if (!IsClientInGame(client) || IsFakeClient(client))
        return Plugin_Continue;

    int prev = g_iPrevButtons[client];
    g_iPrevButtons[client] = buttons;

    // Shove button (IN_ATTACK2) newly pressed
    if ((buttons & IN_ATTACK2) && !(prev & IN_ATTACK2))
    {
        CreateTimer(0.1, Timer_ReduceShovePenalty, GetClientUserId(client));
    }

    return Plugin_Continue;
}

// Also catch shoves that hit infected (left4dhooks reliable forward)
public void L4D_OnShovedBySurvivor_Post(int client, int victim, const float vecDir[3])
{
    if (client > 0 && IsClientInGame(client) && !IsFakeClient(client))
    {
        CreateTimer(0.1, Timer_ReduceShovePenalty, GetClientUserId(client));
    }
}

public Action Timer_ReduceShovePenalty(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && IsClientInGame(client) && !IsFakeClient(client))
    {
        int penalty = GetEntProp(client, Prop_Send, "m_iShovePenalty");
        if (penalty > 1)
        {
            SetEntProp(client, Prop_Send, "m_iShovePenalty", penalty / 2);
        }
        else if (penalty == 1)
        {
            SetEntProp(client, Prop_Send, "m_iShovePenalty", 0);
        }
    }
    return Plugin_Stop;
}
