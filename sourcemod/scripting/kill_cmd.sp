#include <sourcemod>
#include <sdkhooks>

#define PLUGIN_VERSION "1.1"

public Plugin myinfo =
{
    name = "Suicide Command",
    author = "claude",
    description = "Adds !kill and !zs chat commands for suicide",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    RegConsoleCmd("sm_kill", Cmd_Kill, "Suicide - kill yourself");
    RegConsoleCmd("sm_zs", Cmd_Kill, "Suicide (!zs alias)");

    // Also hook chat triggers
    AddCommandListener(ChatListener, "say");
    AddCommandListener(ChatListener, "say_team");
}

public Action ChatListener(int client, const char[] command, int argc)
{
    if (client == 0 || !IsClientInGame(client))
        return Plugin_Continue;

    char text[256];
    GetCmdArgString(text, sizeof(text));

    // Strip quotes
    StripQuotes(text);

    // Trim leading/trailing spaces
    TrimString(text);

    if (StrEqual(text, "!kill", false) || StrEqual(text, "/kill", false) ||
        StrEqual(text, "!zs", false) || StrEqual(text, "/zs", false))
    {
        PerformSuicide(client);
        return Plugin_Handled;
    }

    return Plugin_Continue;
}

public Action Cmd_Kill(int client, int args)
{
    if (client == 0)
    {
        PrintToServer("[kill_cmd] Must be used in-game");
        return Plugin_Handled;
    }

    PerformSuicide(client);
    return Plugin_Handled;
}

void PerformSuicide(int client)
{
    if (!IsClientInGame(client))
        return;

    if (!IsPlayerAlive(client))
    {
        PrintToChat(client, "\x04[粟藜]\x01 你已经死了...");
        return;
    }

    if (GetClientTeam(client) != 2)
    {
        PrintToChat(client, "\x04[粟藜]\x01 只有生还者可以使用自杀");
        return;
    }

    // Kill the player by dealing massive damage
    // ForcePlayerSuicide can be blocked by InputKill hooks
    // Use SDKHooks_TakeDamage with massive fall damage as workaround
    SDKHooks_TakeDamage(client, 0, 0, 9999.0, DMG_GENERIC);
}
