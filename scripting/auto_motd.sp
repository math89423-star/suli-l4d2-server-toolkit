#include <sourcemod>

#define PLUGIN_VERSION "1.2"

public Plugin myinfo =
{
    name = "Welcome Message on Connect",
    author = "claude",
    description = "Show welcome chat messages when players join",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    CreateConVar("sm_welcome_version", PLUGIN_VERSION, "", FCVAR_NOTIFY|FCVAR_DONTRECORD);
}

public void OnClientPostAdminCheck(int client)
{
    if (!IsFakeClient(client))
        CreateTimer(6.0, Timer_Welcome, GetClientUserId(client));
}

public Action Timer_Welcome(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientInGame(client))
        return Plugin_Stop;

    PrintToChat(client, "\x04[粟藜L4D2] \x0124人困难多特战役服 · 60tick · 6特 · 45-60s波次");
    PrintToChat(client, "\x05直连 \x03connect 81.71.101.135:27015");
    PrintToChat(client, "\x05输入 \x04!motd\x05 查看完整服务器公告");
    PrintToChat(client, "\x01QQ群: \x05873133645  · Steam组: \x05suli-l4d2-server");
    PrintToChat(client, "\x05击杀掉落: Tank必掉3件 | Witch必掉1件 | 特感约4% | 小僵尸1%");

    return Plugin_Stop;
}
