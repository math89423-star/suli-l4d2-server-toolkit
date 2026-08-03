/*  
*    Fixes for gamebreaking bugs and stupid gameplay aspects
*    Copyright (C) 2019  LuxLuma		acceliacat@gmail.com
*
*    This program is free software: you can redistribute it and/or modify
*    it under the terms of the GNU General Public License as published by
*    the Free Software Foundation, either version 3 of the License, or
*    (at your option) any later version.
*
*    This program is distributed in the hope that it will be useful,
*    but WITHOUT ANY WARRANTY; without even the implied warranty of
*    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
*    GNU General Public License for more details.
*
*    You should have received a copy of the GNU General Public License
*    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>

#pragma newdecls required

#define GAMEDATA "defib_fix"

#define PLUGIN_VERSION	"2.0.2"

GlobalForward g_hForward_SurvivorDeathModelCreated;

Handle hOnActionComplete;
Handle hOnStartAction;

bool g_bFixChar;
int g_iCurrentDeathModel;
int g_iDeathModelOwner[2048+1];


public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if(GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 2");
		return APLRes_SilentFailure;
	}
	
	g_hForward_SurvivorDeathModelCreated = new GlobalForward("L4D2_OnSurvivorDeathModelCreated", ET_Event, Param_Cell, Param_Cell);

	// v2.0.2 (2026-08-03): 复活后清尸 native——复活插件（si_hud 自动复活/复活币）
	// 用 L4D_RespawnPlayer 强制复活，引擎不清理死亡模型，残留尸体可被电击器
	// 再次电击（活人错乱）。本 native 按 g_iDeathModelOwner 映射删除目标玩家尸体。
	CreateNative("L4D2_KillSurvivorDeathModel", Native_KillSurvivorDeathModel);
	return APLRes_Success;
}

public Plugin myinfo =
{
	name = "[L4D2]Defib_Fix",
	author = "Lux",
	description = "Fixes defibbing from failing when defibbing an alive character index",
	version = PLUGIN_VERSION,
	url = "forums.alliedmods.net/showthread.php?p=2647018"
};

public void OnPluginStart()
{
	Handle hGamedata = LoadGameConfigFile(GAMEDATA);
	if(hGamedata == null)
		SetFailState("Failed to load \"%s.txt\" gamedata.", GAMEDATA);

	// 2026-08-03 本地适配：SM 1.12 的 dhooks 无法从 gamedata 解析签名（引擎符号不导出、
	// 字节模式搜索失效），改用 GameConfGetAddress（Addresses 节，已验证可解析）+ 全局 detour。

	// CItemDefibrillator::OnActionComplete —— thiscall, 3 显式参数 (type, pPlayer, pDeathModel)
	hOnActionComplete = DHookCreateDetour(GameConfGetAddress(hGamedata, "CItemDefibrillator::OnActionComplete"), CallConv_THISCALL, ReturnType_Int, ThisPointer_Ignore);
	if(hOnActionComplete == null)
		SetFailState("Failed to make hook for 'CItemDefibrillator::OnActionComplete'");

	DHookAddParam(hOnActionComplete, HookParamType_Int);          // type
	DHookAddParam(hOnActionComplete, HookParamType_CBaseEntity);  // pPlayer → GetParam(2) = 死亡模型实体索引
	DHookAddParam(hOnActionComplete, HookParamType_Int);          // pEntity（不读）

	if(!DHookEnableDetour(hOnActionComplete, false, OnActionCompletePre))
		SetFailState("Failed to detour 'CItemDefibrillator::OnActionComplete'");

	if(!DHookEnableDetour(hOnActionComplete, true, OnActionCompletePost))
		SetFailState("Failed to detour 'CItemDefibrillator::OnActionComplete'");

	// CItemDefibrillator::OnStartAction —— thiscall, 回调不读参数
	hOnStartAction = DHookCreateDetour(GameConfGetAddress(hGamedata, "CItemDefibrillator::OnStartAction"), CallConv_THISCALL, ReturnType_Int, ThisPointer_Ignore);
	if(hOnStartAction == null)
		SetFailState("Failed to make hook for 'CItemDefibrillator::OnStartAction'");

	if(!DHookEnableDetour(hOnStartAction, false, OnStartActionPre))
		SetFailState("Failed to detour 'CItemDefibrillator::OnStartAction'");

	// CTerrorPlayer::GetPlayerByCharacter —— thiscall, 1 参数 (SurvivorCharacterType)
	Handle hDetour;
	hDetour = DHookCreateDetour(GameConfGetAddress(hGamedata, "CTerrorPlayer::GetPlayerByCharacter"), CallConv_THISCALL, ReturnType_CBaseEntity, ThisPointer_Ignore);
	if(!hDetour)
		SetFailState("Failed to find 'CTerrorPlayer::GetPlayerByCharacter' signature");

	DHookAddParam(hDetour, HookParamType_Int);

	if(!DHookEnableDetour(hDetour, false, GetPlayerByCharacter))
		SetFailState("Failed to detour 'CTerrorPlayer::GetPlayerByCharacter'");

	// CSurvivorDeathModel::Create —— 静态方法（CDECL），1 参数 (CTerrorPlayer*)
	hDetour = DHookCreateDetour(GameConfGetAddress(hGamedata, "CSurvivorDeathModel::Create"), CallConv_CDECL, ReturnType_CBaseEntity, ThisPointer_Ignore);
	if(!hDetour)
		SetFailState("Failed to find 'CSurvivorDeathModel::Create' signature");

	DHookAddParam(hDetour, HookParamType_CBaseEntity);

	if(!DHookEnableDetour(hDetour, false, DeathModelCreatePre))
		SetFailState("Failed to detour 'CSurvivorDeathModel::Create'");

	if(!DHookEnableDetour(hDetour, true, DeathModelCreatePost))
		SetFailState("Failed to detour 'CSurvivorDeathModel::Create'");

	delete hGamedata;

	CreateConVar("defib_fix_version", PLUGIN_VERSION, "", FCVAR_NOTIFY|FCVAR_DONTRECORD);
}

public MRESReturn OnActionCompletePre(Handle hReturn, Handle hParams)
{
	int iDeathModel = DHookGetParam(hParams, 2);
	if(!iDeathModel)
		return MRES_Ignored;
	
	if(IsAllSurvivorsAlive())//rare case
	{
		KillAllDeathModels();
		DHookSetReturn(hReturn, 0);
		return MRES_Supercede;
	}
	
	g_iCurrentDeathModel = iDeathModel;
	g_bFixChar = true;
	return MRES_Ignored;
}

public MRESReturn OnActionCompletePost(Handle hReturn, Handle hParams)
{
	if(IsAllSurvivorsAlive())
		KillAllDeathModels();
	
	g_bFixChar = false;//just incase	
	return MRES_Ignored;
}

public MRESReturn GetPlayerByCharacter(Handle hReturn, Handle hParams)
{
	if(!g_bFixChar)
		return MRES_Ignored;
	g_bFixChar = false;
	
	static int iChar[MAXPLAYERS+1];
	
	int iCurrentChar = GetClientOfUserId(g_iDeathModelOwner[g_iCurrentDeathModel]);
	if(iCurrentChar > 0 && IsClientInGame(iCurrentChar) && !IsPlayerAlive(iCurrentChar) && GetClientTeam(iCurrentChar) == 2)//check if owner of model death model is dead
	{
		DHookSetReturn(hReturn, iCurrentChar);
		return MRES_Supercede;
	}
	
	iCurrentChar = DHookGetParam(hParams, 1);
	
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && !IsPlayerAlive(i) && GetClientTeam(i) == 2)
		{
			iChar[i] = GetEntProp(i, Prop_Send, "m_survivorCharacter", 1);
			if(iCurrentChar == iChar[i])//if found player same char type
			{
				DHookSetReturn(hReturn, i);
				return MRES_Supercede;
			}
		}
		else
		{
			iChar[i] = -1;
		}
	}
	
	int iFoundPlayer;
	iCurrentChar = ConvertToInternalCharacter(iCurrentChar);
	for(int i = 1; i <= MaxClients; i++)
	{
		if(iChar[i] != -1)
			iFoundPlayer = i;//fallback incase noone matches
		
		if(iCurrentChar == iChar[i])
		{
			iFoundPlayer = i;
			break;
		}
	}
	if(!iFoundPlayer)
		return MRES_Ignored;//better safe than sorry
	
	DHookSetReturn(hReturn, iFoundPlayer);
	return MRES_Supercede;
}

public MRESReturn OnStartActionPre(Handle hReturn, Handle hParams)
{
	if(IsAllSurvivorsAlive())
	{
		KillAllDeathModels();
		DHookSetReturn(hReturn, 0);
		return MRES_Supercede;
	}
	return MRES_Ignored;
}

int g_iTempClient;
public MRESReturn DeathModelCreatePost(Handle hReturn, Handle hParams)
{
	int iDeathModel = DHookGetReturn(hReturn);
	if(!iDeathModel)
		return MRES_Ignored;

	float vPos[3];
	GetClientAbsOrigin(g_iTempClient, vPos);

	TeleportEntity(iDeathModel, vPos, NULL_VECTOR, NULL_VECTOR);

	g_iDeathModelOwner[iDeathModel] = GetClientUserId(g_iTempClient);

	Call_StartForward(g_hForward_SurvivorDeathModelCreated);
	Call_PushCell(g_iTempClient);
	Call_PushCell(iDeathModel);
	Call_Finish();

	return MRES_Ignored;
}

public MRESReturn DeathModelCreatePre(Handle hReturn, Handle hParams)
{
	g_iTempClient = DHookGetParam(hParams, 1);

	return MRES_Ignored;
}

public void OnEntityDestroyed(int iEntity)
{
	if(iEntity < 1)
		return;
	
	g_iDeathModelOwner[iEntity] = 0;
}

int ConvertToInternalCharacter(int iChar)
{
	switch(iChar)
	{
		case 4:
		{
			return 0;
		}
		case 5:
		{
			return 1;
		}
		case 6:
		{
			return 3;
		}
		case 7:
		{
			return 2;
		}
		case 9:
		{
			return 8;
		}
	}
	return iChar;// some people set survivors to 8 or 9 index so revive them too
}

bool IsAllSurvivorsAlive()
{
	for(int i = 1; i <= MaxClients; i++)// rare case it could happen
	{
		if(IsClientInGame(i) && !IsPlayerAlive(i) && GetClientTeam(i) == 2)
		{
			return false;
		}
	}
	return true;
}

void KillAllDeathModels()
{
	int i = INVALID_ENT_REFERENCE;
	while((i = FindEntityByClassname(i, "survivor_death_model")) != INVALID_ENT_REFERENCE)
	{
		AcceptEntityInput(i, "Kill");
	}
}

// v2.0.2: 删除指定玩家的死亡尸体（强制复活路径用）。返回删除数量。
public int Native_KillSurvivorDeathModel(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if(client < 1 || client > MaxClients || !IsClientInGame(client))
		return 0;

	int userId = GetClientUserId(client);
	int i = INVALID_ENT_REFERENCE;
	int killed = 0;
	while((i = FindEntityByClassname(i, "survivor_death_model")) != INVALID_ENT_REFERENCE)
	{
		if(g_iDeathModelOwner[i] == userId)
		{
			AcceptEntityInput(i, "Kill");
			g_iDeathModelOwner[i] = 0;
			killed++;
		}
	}
	return killed;
}
