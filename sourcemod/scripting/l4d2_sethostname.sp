#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

ConVar g_cvHostname;

public Plugin myinfo = {
    name = "Set Server Name",
    author = "claude",
    description = "Set hostname from UTF-8 text file",
    version = "1.0",
    url = ""
};

public void OnPluginStart()
{
    g_cvHostname = FindConVar("hostname");
    RegAdminCmd("sm_hostname_reload", Cmd_ReloadHostname, ADMFLAG_GENERIC);
}

public void OnMapStart()
{
    SetHostname();
}

public void OnConfigsExecuted()
{
    SetHostname();
}

Action Cmd_ReloadHostname(int client, int args)
{
    SetHostname();
    ReplyToCommand(client, "[SM] Hostname reloaded.");
    return Plugin_Handled;
}

void SetHostname()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "data/hostname.txt");

    File f = OpenFile(path, "r");
    if (!f)
    {
        LogError("Cannot open %s", path);
        return;
    }

    char name[128];
    if (f.ReadLine(name, sizeof(name)))
    {
        TrimString(name);
        if (strlen(name) > 0)
        {
            g_cvHostname.SetString(name);
        }
    }
    delete f;
}
