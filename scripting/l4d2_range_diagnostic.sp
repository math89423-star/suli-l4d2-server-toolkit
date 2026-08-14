/**
 * l4d2_range_diagnostic.sp
 *
 * 诊断工具：测试武器实际有效射程与远距离伤害
 *
 * !rangetest  - 开关命中播报（显示距离/伤害/武器）
 * !checkdist  - 显示准星指向目标的距离
 *
 * 覆盖范围：小僵尸(infected) / 特感与玩家(client) / Witch
 */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.1.0"

bool g_bTestMode[MAXPLAYERS+1];

public Plugin myinfo =
{
	name = "L4D2 Weapon Range Diagnostic",
	author = "Claude",
	description = "Diagnose actual weapon effective range",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	RegConsoleCmd("sm_rangetest", Command_RangeTest, "Toggle hit distance reporting");
	RegConsoleCmd("sm_checkdist", Command_CheckDist, "Check distance to crosshair target");

	// 补挂已在场的玩家（热加载）
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			SDKHook(i, SDKHook_OnTakeDamage, OnTakeDamage);
	}

	// 补挂已在场的小僵尸/Witch
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "infected")) != -1)
		SDKHook(ent, SDKHook_OnTakeDamage, OnTakeDamage);
	ent = -1;
	while ((ent = FindEntityByClassname(ent, "witch")) != -1)
		SDKHook(ent, SDKHook_OnTakeDamage, OnTakeDamage);
}

public void OnClientPutInServer(int client)
{
	g_bTestMode[client] = false;
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

public void OnEntityCreated(int entity, const char[] classname)
{
	// 小僵尸和 Witch 不是 client，必须单独挂 hook
	if (StrEqual(classname, "infected") || StrEqual(classname, "witch"))
		SDKHook(entity, SDKHook_OnTakeDamage, OnTakeDamage);
}

public Action Command_RangeTest(int client, int args)
{
	if (client == 0)
		return Plugin_Handled;

	g_bTestMode[client] = !g_bTestMode[client];

	if (g_bTestMode[client])
		PrintToChat(client, "\x04[射程测试] \x01已开启 — 命中目标时显示距离和伤害");
	else
		PrintToChat(client, "\x04[射程测试] \x01已关闭");

	return Plugin_Handled;
}

public Action Command_CheckDist(int client, int args)
{
	if (client == 0)
		return Plugin_Handled;

	float eyePos[3], eyeAngles[3], endPos[3];
	GetClientEyePosition(client, eyePos);
	GetClientEyeAngles(client, eyeAngles);

	// 单次无限射线：引擎会一直追到命中为止，用来量准星距离
	Handle trace = TR_TraceRayFilterEx(eyePos, eyeAngles, MASK_SHOT, RayType_Infinite, TraceFilter_DontHitSelf, client);

	if (TR_DidHit(trace))
	{
		TR_GetEndPosition(endPos, trace);
		float distance = GetVectorDistance(eyePos, endPos);

		char hitWhat[64];
		int hitEntity = TR_GetEntityIndex(trace);

		if (hitEntity > 0 && hitEntity <= MaxClients && IsClientInGame(hitEntity))
			GetClientName(hitEntity, hitWhat, sizeof(hitWhat));
		else if (hitEntity > MaxClients && IsValidEntity(hitEntity))
			GetEntityClassname(hitEntity, hitWhat, sizeof(hitWhat));
		else
			strcopy(hitWhat, sizeof(hitWhat), "世界/墙壁");

		PrintToChat(client, "\x04[射程测试] \x01准星距离 \x03%.0f\x01 单位 → \x05%s", distance, hitWhat);
	}
	else
	{
		PrintToChat(client, "\x04[射程测试] \x01准星方向无命中");
	}

	delete trace;   // 无条件释放，不会泄漏

	// 显示当前武器
	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (weapon != -1)
	{
		char classname[64];
		GetEntityClassname(weapon, classname, sizeof(classname));
		PrintToChat(client, "\x04  当前武器: \x01%s", classname);
	}

	return Plugin_Handled;
}

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if (attacker < 1 || attacker > MaxClients)
		return Plugin_Continue;

	if (!g_bTestMode[attacker])
		return Plugin_Continue;

	if (!IsClientInGame(attacker))
		return Plugin_Continue;

	// 用眼睛位置量距离，和子弹起点一致
	float attackerPos[3], victimPos[3];
	GetClientEyePosition(attacker, attackerPos);

	if (!IsValidEntity(victim))
		return Plugin_Continue;
	GetEntPropVector(victim, Prop_Send, "m_vecOrigin", victimPos);

	float distance = GetVectorDistance(attackerPos, victimPos);

	int weapon = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
	char weaponName[64] = "未知";
	if (weapon != -1)
		GetEntityClassname(weapon, weaponName, sizeof(weaponName));

	char victimName[64];
	if (victim <= MaxClients && IsClientInGame(victim))
		GetClientName(victim, victimName, sizeof(victimName));
	else
		GetEntityClassname(victim, victimName, sizeof(victimName));

	PrintToChat(attacker, "\x04[命中] \x01距离 \x03%.0f\x01 | 伤害 \x05%.1f\x01 | %s → %s",
		distance, damage, weaponName, victimName);

	return Plugin_Continue;
}

public bool TraceFilter_DontHitSelf(int entity, int contentsMask, any data)
{
	return entity != data;
}
