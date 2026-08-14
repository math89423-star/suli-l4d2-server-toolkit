#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "1.0.0"
#define GSLT_TOKEN "F18404622EF86F67F587566BBC9350F5"

public Plugin myinfo =
{
	name = "GSLT Injector",
	author = "Kiro",
	description = "Inject sv_setsteamaccount at correct timing (after Steam API init, before map load)",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	// OnPluginStart 在 SourceMod 加载后、地图加载前触发
	// 此时 Steam API 已初始化，sv_setsteamaccount 命令已注册
	CreateTimer(0.1, Timer_InjectGSLT, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapStart()
{
	// 每次换图重新注入，确保 GSLT 持续生效
	CreateTimer(0.5, Timer_InjectGSLT, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_InjectGSLT(Handle timer)
{
	ServerCommand("sv_setsteamaccount %s", GSLT_TOKEN);
	LogMessage("GSLT injected: %s", GSLT_TOKEN);
	return Plugin_Stop;
}
