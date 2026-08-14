/**
 * l4d2_weapon_range_fix.sp
 *
 * 修复 L4D2 武器射程限制问题
 *
 * 问题：武器的 Range 属性只影响伤害衰减，不影响子弹实际射线追踪距离
 * 解决：通过 DHooks 拦截 FireBullets 函数，扩展射线追踪距离
 *
 * 原理：
 * - FireBullets(int, Vector, Vector, Vector, float distance, ...)
 * - 默认 distance 参数约为 3000-4000 单位
 * - 我们将其修改为更大的值（如 8192 或根据武器 Range 属性动态设置）
 */

#include <sourcemod>
#include <sdktools>
#include <dhooks>
#include <left4dhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.0.0"

// 默认扩展射程
#define DEFAULT_EXTENDED_RANGE 8192.0

ConVar g_cvEnabled;
ConVar g_cvRangeMultiplier;
ConVar g_cvMaxRange;
ConVar g_cvDebug;

DynamicHook g_hFireBullets;

public Plugin myinfo =
{
	name = "L4D2 Weapon Range Fix",
	author = "Claude",
	description = "Extends actual bullet trace distance beyond engine default",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("sm_range_fix_enable", "1", "启用武器射程修复", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvRangeMultiplier = CreateConVar("sm_range_fix_multiplier", "2.0", "射程倍率（基于武器配置的 Range）", FCVAR_NOTIFY, true, 1.0, true, 10.0);
	g_cvMaxRange = CreateConVar("sm_range_fix_max", "8192", "最大射线追踪距离", FCVAR_NOTIFY, true, 1000.0, true, 16384.0);
	g_cvDebug = CreateConVar("sm_range_fix_debug", "0", "调试模式（显示射程修改）", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	AutoExecConfig(true, "l4d2_weapon_range_fix");

	// 设置 DHooks
	GameData gamedata = LoadGameConfigFile("sdkhooks.games");
	if (gamedata == null)
	{
		SetFailState("Failed to load sdkhooks.games gamedata");
	}

	// 获取 FireBullets 偏移量
	int offset = GameConfGetOffset(gamedata, "FireBullets");
	if (offset == -1)
	{
		delete gamedata;
		SetFailState("Failed to get FireBullets offset");
	}

	delete gamedata;

	// 创建 DHook
	// CBaseCombatCharacter::FireBullets(int cShots, Vector vecSrc, Vector vecDirShooting, Vector vecSpread, float flDistance, int iBulletType, int iTracerFreq, int iDamage, CBaseEntity *pAttacker, int shared_rand)
	g_hFireBullets = new DynamicHook(offset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity);
	g_hFireBullets.AddParam(HookParamType_Int);      // cShots
	g_hFireBullets.AddParam(HookParamType_VectorPtr); // vecSrc
	g_hFireBullets.AddParam(HookParamType_VectorPtr); // vecDirShooting
	g_hFireBullets.AddParam(HookParamType_VectorPtr); // vecSpread
	g_hFireBullets.AddParam(HookParamType_Float);    // flDistance ← 这个是关键！
	g_hFireBullets.AddParam(HookParamType_Int);      // iBulletType
	g_hFireBullets.AddParam(HookParamType_Int);      // iTracerFreq
	g_hFireBullets.AddParam(HookParamType_Int);      // iDamage
	g_hFireBullets.AddParam(HookParamType_CBaseEntity); // pAttacker
	g_hFireBullets.AddParam(HookParamType_Int);      // shared_rand

	// Hook 所有现有玩家
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			g_hFireBullets.HookEntity(Hook_Pre, i, OnFireBullets_Pre);
		}
	}

	LogMessage("[WeaponRangeFix] Plugin loaded - FireBullets offset: %d", offset);
}

public void OnClientPutInServer(int client)
{
	if (g_hFireBullets != null)
	{
		g_hFireBullets.HookEntity(Hook_Pre, client, OnFireBullets_Pre);
	}
}

public MRESReturn OnFireBullets_Pre(int client, Handle hParams)
{
	if (!g_cvEnabled.BoolValue)
		return MRES_Ignored;

	// 获取当前武器
	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (weapon == -1)
		return MRES_Ignored;

	// 获取原始距离参数（第 5 个参数，索引从 1 开始）
	float originalDistance = view_as<float>(DHookGetParam(hParams, 5));

	// 获取武器类名
	char classname[64];
	GetEdictClassname(weapon, classname, sizeof(classname));

	// 获取武器的 Range 属性
	float weaponRange = L4D2_GetFloatWeaponAttribute(classname, L4D2FWA_Range);

	// 计算新的射程
	float newDistance;
	if (weaponRange > 0.0)
	{
		// 基于武器配置的 Range 属性
		newDistance = weaponRange * g_cvRangeMultiplier.FloatValue;
	}
	else
	{
		// 如果武器没有配置 Range，使用默认扩展值
		newDistance = DEFAULT_EXTENDED_RANGE;
	}

	// 限制最大值
	float maxRange = g_cvMaxRange.FloatValue;
	if (newDistance > maxRange)
		newDistance = maxRange;

	// 只有当新距离大于原始距离时才修改
	if (newDistance > originalDistance)
	{
		DHookSetParam(hParams, 5, view_as<any>(newDistance));

		if (g_cvDebug.BoolValue)
		{
			PrintToServer("[RangeFix] %N | %s | 原始: %.0f → 新: %.0f (武器Range: %.0f)",
				client, classname, originalDistance, newDistance, weaponRange);
		}

		return MRES_ChangedHandled;
	}

	return MRES_Ignored;
}

public void OnPluginEnd()
{
	// DHooks 会自动清理，无需手动 unhook
}
