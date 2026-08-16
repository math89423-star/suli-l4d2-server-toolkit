// Thanks to L4D2Util for many stock functions and enumerations
// Optimized: fixed bugs, replaced decl→new, added safety checks

#pragma semicolon 1
#include <sourcemod>

#if defined HARDCOOP_UTIL_included
#endinput
#endif

#define HARDCOOP_UTIL_included

#define DEBUG_FLOW 0

#define TEAM_CLASS(%1) (%1 == ZC_SMOKER ? "smoker" : (%1 == ZC_BOOMER ? "boomer" : (%1 == ZC_HUNTER ? "hunter" :(%1 == ZC_SPITTER ? "spitter" : (%1 == ZC_JOCKEY ? "jockey" : (%1 == ZC_CHARGER ? "charger" : (%1 == ZC_WITCH ? "witch" : (%1 == ZC_TANK ? "tank" : "None"))))))))
#define MAX(%0,%1) (((%0) > (%1)) ? (%0) : (%1))
#define MIN(%0,%1) (((%0) < (%1)) ? (%0) : (%1))
#define CLAMP(%0,%1,%2) (((%0) < (%1)) ? (%1) : (((%0) > (%2)) ? (%2) : (%0)))

enum L4D2_Team {
	L4D2Team_None = 0,
	L4D2Team_Spectator = 1,
	L4D2Team_Survivor,
	L4D2Team_Infected
};

enum L4D2_Infected {
	L4D2Infected_Smoker = 1,
	L4D2Infected_Boomer,
	L4D2Infected_Hunter,
	L4D2Infected_Spitter,
	L4D2Infected_Jockey,
	L4D2Infected_Charger,
	L4D2Infected_Witch,
	L4D2Infected_Tank
};

// alternative enumeration
// Special infected classes
enum ZombieClass {
	ZC_NONE = 0,
	ZC_SMOKER,
	ZC_BOOMER,
	ZC_HUNTER,
	ZC_SPITTER,
	ZC_JOCKEY,
	ZC_CHARGER,
	ZC_WITCH,
	ZC_TANK,
	ZC_NOTINFECTED
};

// 0=Anywhere, 1=Behind, 2=IT, 3=Specials in front, 4=Specials anywhere, 5=Far Away, 6=Above
enum SpawnDirection {
	ANYWHERE = 0,
	BEHIND,
	IT,
	SPECIALS_IN_FRONT,
	SPECIALS_ANYWHERE,
	FAR_AWAY,
	ABOVE
};

/***********************************************************************************************************************************************************************************

																		SURVIVORS

***********************************************************************************************************************************************************************************/

/**
 * Returns true if the player is currently on the survivor team.
 *
 * @param client: client ID
 * @return bool
 */
stock bool:IsSurvivor(client) {
	if( IsValidClient(client) && L4D2_Team:GetClientTeam(client) == L4D2Team_Survivor ) {
		return true;
	} else {
		return false;
	}
}

stock bool:IsPinned(client) {
	new bool:bIsPinned = false;
	if (IsSurvivor(client)) {
		// check if held by:
		if( GetEntPropEnt(client, Prop_Send, "m_tongueOwner") > 0 ) bIsPinned = true; // smoker
		if( GetEntPropEnt(client, Prop_Send, "m_pounceAttacker") > 0 ) bIsPinned = true; // hunter
		if( GetEntPropEnt(client, Prop_Send, "m_carryAttacker") > 0 ) bIsPinned = true; // charger carry
		if( GetEntPropEnt(client, Prop_Send, "m_pummelAttacker") > 0 ) bIsPinned = true; // charger pound
		if( GetEntPropEnt(client, Prop_Send, "m_jockeyAttacker") > 0 ) bIsPinned = true; // jockey
	}
	return bIsPinned;
}


stock bool:IsPinningASurvivor(client) {
	new bool:isPinning = false;
	if( IsBotInfected(client) && IsPlayerAlive(client) ) {
		if( GetEntPropEnt(client, Prop_Send, "m_tongueVictim") > 0 ) isPinning = true; // smoker
		if( GetEntPropEnt(client, Prop_Send, "m_pounceVictim") > 0 ) isPinning = true; // hunter
		if( GetEntPropEnt(client, Prop_Send, "m_carryVictim") > 0 ) isPinning = true; // charger carrying
		if( GetEntPropEnt(client, Prop_Send, "m_pummelVictim") > 0 ) isPinning = true; // charger pounding
		if( GetEntPropEnt(client, Prop_Send, "m_jockeyVictim") > 0 ) isPinning = true; // jockey
	}
	return isPinning;
}

/**
 * @return: The highest %map completion held by a survivor at the current point in time
 */
stock GetMaxSurvivorCompletion() {
	new flow;
	new tmp_flow;
	new Float:origin[3];
	for ( new client = 1; client <= MaxClients; client++ ) {
		if ( IsSurvivor(client) && IsPlayerAlive(client) ) {
			GetClientAbsOrigin(client, origin);
			tmp_flow = GetFlow(origin);
			flow = MAX(flow, tmp_flow);
		}
	}

	new current = RoundToNearest(flow * 100 / L4D2Direct_GetMapMaxFlowDistance());

		#if DEBUG_FLOW
			PrintToChatAll( "Current: {blue}%d%%", current );
		#endif

	return current;
}

/**
 * @return: the farthest flow distance currently held by a survivor
 */
stock Float:GetFarthestSurvivorFlow() {
	new farthest_flow = 0;
	new Float:origin[3];
	for (new client = 1; client <= MaxClients; client++) {
		if ( IsSurvivor(client) && IsPlayerAlive(client) ) {
			GetClientAbsOrigin(client, origin);
			new flow = GetFlow(origin);
			if ( flow > farthest_flow ) {
				farthest_flow = flow;
			}
		}
	}
	return float(farthest_flow);  // FIXED: was "farthestFlow" (typo); now correct tag
}

/**
 * Returns the average flow distance covered by each survivor
 */
stock Float:GetAverageSurvivorFlow() {
	new survivor_count = 0;
	new total_flow = 0;
	new Float:origin[3];
	for (new client = 1; client <= MaxClients; client++) {
		if ( IsSurvivor(client) && IsPlayerAlive(client) ) {
			survivor_count++;
			GetClientAbsOrigin(client, origin);
			new client_flow = GetFlow(origin);
			if ( client_flow != -1 ) {
				total_flow += client_flow;  // FIXED: was "total_flow++" (bumped by 1, not flow value)
			}
		}
	}
	return (survivor_count > 0) ? (float(total_flow) / float(survivor_count)) : 0.0;
}

/**
 * Returns the flow distance from given point to closest alive survivor.
 * Returns -1.0 if either the given point or the survivors as a whole are not upon a valid nav mesh
 */
stock GetFlowDistToSurvivors(const Float:pos[3]) {
	new spawnpoint_flow;
	new lowest_flow_dist = -1;

	spawnpoint_flow = GetFlow(pos);
	if ( spawnpoint_flow == -1) {
		return -1;
	}

	for ( new j = 1; j <= MaxClients; j++ ) {
		if ( IsSurvivor(j) && IsPlayerAlive(j) ) {
			new Float:origin[3];
			new flow_dist;

			GetClientAbsOrigin(j, origin);
			flow_dist = GetFlow(origin);

			// FIXED: properly compare absolute flow difference
			if ( flow_dist != -1 ) {
				new abs_diff = RoundToNearest(FloatAbs(float(flow_dist) - float(spawnpoint_flow)));
				if ( lowest_flow_dist == -1 || abs_diff < lowest_flow_dist ) {
					lowest_flow_dist = abs_diff;
				}
			}
		}
	}

	return lowest_flow_dist;
}

/**
 * Returns the flow distance of a given point
 */
 stock GetFlow(const Float:o[3]) {
	new Float:origin[3]; //non constant var
	origin[0] = o[0];
	origin[1] = o[1];
	origin[2] = o[2];
	new Address:pNavArea;
	pNavArea = L4D2Direct_GetTerrorNavArea(origin);
	if ( pNavArea != Address_Null ) {
		return RoundToNearest(L4D2Direct_GetTerrorNavAreaFlow(pNavArea));
	} else {
		return -1;
	}
 }

/**
 * Returns true if the player is incapacitated.
 *
 * @param client client ID
 * @return bool
 */
stock bool:IsIncapacitated(client) {
	return bool:GetEntProp(client, Prop_Send, "m_isIncapacitated");
}

/**
 * Finds the closest survivor excluding a given survivor
 * @param referencePos: compares survivor distances to this position
 * @param excludeSurvivor: ignores this survivor
 * @return: the entity index of the closest survivor, or -1 if none found
**/
stock GetClosestSurvivor( Float:referencePos[3], excludeSurvivor = -1 ) {
	new Float:survivorPos[3];
	new closestSurvivor = -1;  // FIXED: start at -1 instead of random survivor
	new iClosestAbsDisplacement = -1;

	for (new client = 1; client <= MaxClients; client++) {  // FIXED: was < MaxClients (missed last client)
		if( IsSurvivor(client) && IsPlayerAlive(client) && client != excludeSurvivor ) {
			GetClientAbsOrigin( client, survivorPos );
			new iAbsDisplacement = RoundToNearest( GetVectorDistance(referencePos, survivorPos) );
			if( iClosestAbsDisplacement < 0 || iAbsDisplacement < iClosestAbsDisplacement ) {
				iClosestAbsDisplacement = iAbsDisplacement;
				closestSurvivor = client;
			}
		}
	}

	// Fallback: if no survivor found (empty server edge case), return random survivor or -1
	if ( closestSurvivor == -1 ) {
		closestSurvivor = GetRandomSurvivor(1, 0);  // left4dhooks: alive=1, non-bots
	}
	return closestSurvivor;
}

/**
 * Returns the distance of the closest survivor or a specified survivor
 * @param rp: the reference position from which to measure distance to survivor
 * @param specificSurvivor: the index of the survivor to be measured, -1 to search for distance to closest survivor
 * @return: the distance
 */
stock GetSurvivorProximity( const Float:rp[3], specificSurvivor = -1 ) {

	new targetSurvivor;
	new Float:targetSurvivorPos[3];
	new Float:referencePos[3]; // non constant var
	referencePos[0] = rp[0];
	referencePos[1] = rp[1];
	referencePos[2] = rp[2];


	if( specificSurvivor > 0 && IsSurvivor(specificSurvivor) ) { // specified survivor
		targetSurvivor = specificSurvivor;
	} else { // closest survivor
		targetSurvivor = GetClosestSurvivor( referencePos );
	}

	if ( targetSurvivor > 0 ) {
		GetClientAbsOrigin( targetSurvivor, targetSurvivorPos );
		return RoundToNearest( GetVectorDistance(referencePos, targetSurvivorPos) );
	}
	return 999999;  // FIXED: return large value instead of crashing on invalid survivor
}

// GetRandomSurvivor() is provided by left4dhooks.inc — use GetRandomSurvivor(1, 0) for alive non-bots

/***********************************************************************************************************************************************************************************

																	SPECIAL INFECTED

***********************************************************************************************************************************************************************************/

/**
 * @return: the special infected class of the client
 */
stock L4D2_Infected:GetInfectedClass(client) {
	return L4D2_Infected:GetEntProp(client, Prop_Send, "m_zombieClass");
}

// FIXED: was comparing team to _:L4D2_Infected (enum tag = 0) instead of _:L4D2Team_Infected (3)
stock bool IsInfected(int client) {
	if (!IsValidClient(client)) return false;
	if (GetClientTeam(client) == _:L4D2Team_Infected) return true;
	return false;
}

/**
 * @return: true if client is a special infected bot
 */
stock bool:IsBotInfected(client) {
	// Check the input is valid
	if (!IsValidClient(client))return false;

	// Check if player is a bot on the infected team
	if (IsInfected(client) && IsFakeClient(client)) {
		return true;
	}
	return false; // otherwise
}

stock bool:IsBotHunter(client) {
	return (IsBotInfected(client) && GetInfectedClass(client) == L4D2_Infected:L4D2Infected_Hunter);
}

stock bool:IsBotCharger(client) {
	return (IsBotInfected(client) && GetInfectedClass(client) == L4D2_Infected:L4D2Infected_Charger);
}

stock bool:IsBotJockey(client) {
	return (IsBotInfected(client) && GetInfectedClass(client) == L4D2_Infected:L4D2Infected_Jockey);
}

// @return: the number of a particular special infected class alive in the game
stock CountSpecialInfectedClass(ZombieClass:targetClass) {
	new count = 0;
	for (new i = 1; i <= MaxClients; i++) {
		if ( IsBotInfected(i) && IsPlayerAlive(i) && !IsClientInKickQueue(i) ) {
			new playerClass = GetEntProp(i, Prop_Send, "m_zombieClass");
			if (playerClass == _:targetClass) {
				count++;
			}
		}
	}
	return count;
}

// @return: the total special infected bots alive in the game
stock CountSpecialInfectedBots() {
	new count = 0;
	for (new i = 1; i <= MaxClients; i++) {
		if (IsBotInfected(i) && IsPlayerAlive(i)) {
			count++;
		}
	}
	return count;
}

/***********************************************************************************************************************************************************************************

																			TANK

***********************************************************************************************************************************************************************************/

/**
 *@return: true if client is a tank
 */
stock bool:IsTank(client) {
	return IsClientConnected(client)
		&& L4D2_Team:GetClientTeam(client) == L4D2Team_Infected
		&& GetInfectedClass(client) == L4D2Infected_Tank;
}

/**
 * Searches for a player who is in control of a tank.
 *
 * @param iTankClient client index to begin searching from
 * @return client ID or -1 if not found
 */
stock FindTankClient(iTankClient) {
	for (new i = iTankClient < 0 ? 1 : iTankClient+1; i <= MaxClients; i++) {
		if (IsTank(i)) {
			return i;
		}
	}

	return -1;
}

/**
 * Is there a tank currently in play?
 *
 * @return bool
 */
stock bool:IsTankInPlay() {
	return bool:(FindTankClient(-1) != -1);
}

stock bool:IsBotTank(client) {
	// Check the input is valid
	if (!IsValidClient(client)) return false;
	// Check if player is on the infected team, a hunter, and a bot
	if (L4D2_Team:GetClientTeam(client) == L4D2Team_Infected) {
		new L4D2_Infected:zombieClass = GetInfectedClass(client);
		if (zombieClass == L4D2Infected_Tank) {
			if(IsFakeClient(client)) {
				return true;
			}
		}
	}
	return false; // otherwise
}

/***********************************************************************************************************************************************************************************

																			MISC

***********************************************************************************************************************************************************************************/

/**
 * Executes a cheat command through a dummy client
 *
 * @param command: The command to execute
 * @param argument1: Optional argument for command
 * @param argument2: Optional argument for command
 * @param dummyName: The name to use for the dummy client
 *
**/
// Shared traceray filter — used by multiple AI modules
public bool:TracerayFilter(impactEntity, contentMask, any:rayOriginEntity) {
	return impactEntity != rayOriginEntity;
}

stock CheatCommand( String:commandName[], String:argument1[] = "", String:argument2[] = "", bool:doUseCommandBot = false ) {
	new flags = GetCommandFlags(commandName);
	if ( flags != INVALID_FCVAR_FLAGS ) {
		new commandDummy = -1;
		if( doUseCommandBot ) {
			// Search for an existing bot named '[CommandBot]'
			for( new i = 1; i <= MaxClients; i++ ) {
				if( IsValidClient(i) && IsClientInGame(i) && IsFakeClient(i) ) {
					new String:clientName[32];
					GetClientName( i, clientName, sizeof(clientName) );
					if( StrContains( clientName, "[CommandBot]", true ) != -1 ) {
						commandDummy = i;
					}
				}
			}
			// Create a command bot if necessary
			if ( !IsValidClient(commandDummy) || IsClientInKickQueue(commandDummy) ) { // Command bot may have been kicked by SMAC_Antispam.smx
				commandDummy = CreateFakeClient("[CommandBot]");
				if( IsValidClient(commandDummy) ) {
					ChangeClientTeam(commandDummy, _:L4D2Team_Spectator);
				} else {
					commandDummy = GetRandomSurvivor(); // wanted to use a bot, but failed; last resort
				}
			}
		} else {
			commandDummy = GetRandomSurvivor();
		}

		// Execute command
		if ( IsValidClient(commandDummy) ) {
			new originalUserFlags = GetUserFlagBits(commandDummy);
			new originalCommandFlags = GetCommandFlags(commandName);
			SetUserFlagBits(commandDummy, ADMFLAG_ROOT);
			SetCommandFlags(commandName, originalCommandFlags ^ FCVAR_CHEAT);
			FakeClientCommand(commandDummy, "%s %s %s", commandName, argument1, argument2);
			SetCommandFlags(commandName, originalCommandFlags);
			SetUserFlagBits(commandDummy, originalUserFlags);
		} else {
			new String:pluginName[128];
			GetPluginFilename( INVALID_HANDLE, pluginName, sizeof(pluginName) );
			LogError( "%s could not find or create a client through which to execute cheat command %s", pluginName, commandName );
		}
	}
}

// Executes vscript code through the "script" console command
stock ScriptCommand(const String:arguments[], any:...) {
	// format vscript input
	new String:vscript[PLATFORM_MAX_PATH];
	VFormat(vscript, sizeof(vscript), arguments, 2);

	// Execute vscript input
	CheatCommand("script", vscript, "");
}

// Sets the spawn direction for SI, relative to the survivors
stock SetSpawnDirection(SpawnDirection:direction) {
	ScriptCommand("g_ModeScript.DirectorOptions.PreferredSpecialDirection<-%i", _:direction);
}

/**
 * Returns true if the client ID is valid
 *
 * @param client: client ID
 * @return bool
 */

stock bool IsValidClient(int client, bool replaycheck = true) {
	if (client <= 0 || client > MaxClients) return false;
	if (!IsClientInGame(client)) return false;
	//if (GetEntProp(client, Prop_Send, "m_bIsCoaching")) return false;
	if (replaycheck) {
		if (IsClientSourceTV(client) || IsClientReplay(client)) return false;
	}
	return true;
}

stock bool:IsGenericAdmin(client) {
	return CheckCommandAccess(client, "generic_admin", ADMFLAG_GENERIC, false);
}

// ===================================================================================
// SI COORDINATION SYSTEM v2.1
// ===================================================================================

enum SI_AttackState {
	SI_IDLE = 0,
	SI_APPROACHING = 1,
	SI_COMMITTED = 2,
	SI_RECOVERING = 3
};

SI_AttackState g_iSIAttackState[MAXPLAYERS+1];
int g_iSIAttackTarget[MAXPLAYERS+1];
float g_fSILastAttackTime[MAXPLAYERS+1];
float g_fSIWindowEndTime;
bool g_bSIBoomerHit;
float g_fSIBoomerHitExpire;

// v4.0: 语义化集火信号 —— 某 SI 刚 pin 住人时广播目标，队友据此集火
int g_iSIPinTarget;              // 当前被 pin 的集火目标 (survivor index)
float g_fSIPinTargetExpire;      // 集火目标过期时刻 (3s)
bool g_bSIPreviouslyPinning[MAXPLAYERS+1];  // 上一轮是否处于 pin 状态（边沿检测）

// v4.0: 战术模式（si_composition_manager 写入 si_comp_active_mode）
// 0-5 = 6 种普通模式, 6 = Tank 巨兽协同, -1 = 未激活/未知
int g_iActiveMode = -1;

new Handle:g_hCvarCoordEnable;
new Handle:g_hCvarCoordWindow;
new Handle:g_hCvarTerrainEnable;  // v3.2: terrain detection toggle
new Handle:g_hCvarActiveMode;     // v4.0: tactical mode from si_composition_manager

stock SI_UpdateCoordination() {
	g_bSIBoomerHit = (g_fSIBoomerHitExpire > 0.0 && GetGameTime() < g_fSIBoomerHitExpire);

	// v5.0: 谁控谁映射更新（Boomer 补刀/Hunter 补压的感知层）
	SI_UpdatePinMap();

	// v4.0: 战术模式读取（si_composition_manager 写入，1s 粒度足够）
	// 加载时序兜底：AI_HardSI 比 si_composition_manager 先加载时，
	// OnPluginStart 的 FindConVar 拿不到句柄 —— 这里每秒重试一次。
	if (g_hCvarActiveMode == INVALID_HANDLE) {
		g_hCvarActiveMode = FindConVar("si_comp_active_mode");
	}
	if (g_hCvarActiveMode != INVALID_HANDLE) {
		g_iActiveMode = GetConVarInt(g_hCvarActiveMode);
	}

	new Float:window = (g_hCvarCoordWindow != INVALID_HANDLE) ?
		GetConVarFloat(g_hCvarCoordWindow) : 5.5;

	// v4.0: 集结计数 —— 距离生还者 < 900 且未 pin 的 SI 数量
	new rallyCount = 0;

	for (new client = 1; client <= MaxClients; client++) {
		if (!IsBotInfected(client) || !IsPlayerAlive(client)) {
			g_iSIAttackState[client] = SI_IDLE;
			g_iSIAttackTarget[client] = -1;
			g_bSIPreviouslyPinning[client] = false;
			continue;
		}
		if (IsPinningASurvivor(client)) {
			// v4.0: pin 边沿检测 —— 刚进入 pin 状态的瞬间广播集火目标
			if (!g_bSIPreviouslyPinning[client]) {
				new victim = GetEntPropEnt(client, Prop_Send, "m_tongueVictim");
				if (victim <= 0) victim = GetEntPropEnt(client, Prop_Send, "m_pounceVictim");
				if (victim <= 0) victim = GetEntPropEnt(client, Prop_Send, "m_carryVictim");
				if (victim <= 0) victim = GetEntPropEnt(client, Prop_Send, "m_pummelVictim");
				if (victim <= 0) victim = GetEntPropEnt(client, Prop_Send, "m_jockeyVictim");
				if (IsSurvivor(victim) && IsPlayerAlive(victim)) {
					g_iSIPinTarget = victim;
					g_fSIPinTargetExpire = GetGameTime() + 3.0;
					g_fSIWindowEndTime = GetGameTime() + window;
				}
			}
			g_bSIPreviouslyPinning[client] = true;
			g_iSIAttackState[client] = SI_COMMITTED;
			g_iSIAttackTarget[client] = GetClientAimTarget(client);
			g_fSILastAttackTime[client] = GetGameTime();
		} else {
			g_bSIPreviouslyPinning[client] = false;
			new Float:sinceAttack = (g_fSILastAttackTime[client] > 0.0) ?
				GetGameTime() - g_fSILastAttackTime[client] : 999.0;
			if (sinceAttack < 3.0) {
				g_iSIAttackState[client] = SI_RECOVERING;
			} else {
				new target = GetClientAimTarget(client);
				g_iSIAttackState[client] = (IsSurvivor(target)) ? SI_APPROACHING : SI_IDLE;
				g_iSIAttackTarget[client] = target;
			}
			// v4.0: 集结计数
			if (g_iSIAttackState[client] >= SI_APPROACHING) {
				new Float:siPos[3];
				GetClientAbsOrigin(client, siPos);
				if (GetSurvivorProximity(siPos) < 900) {
					rallyCount++;
				}
			}
		}
	}

	// v4.0: 集结进攻 —— 3+ SI 已到位且无窗口时，主动开攻击窗口
	if (g_fSIWindowEndTime > 0.0 && GetGameTime() >= g_fSIWindowEndTime && rallyCount >= 3) {
		g_fSIWindowEndTime = GetGameTime() + window;
	}

	// 集火目标过期清理
	if (g_fSIPinTargetExpire > 0.0 && GetGameTime() > g_fSIPinTargetExpire) {
		g_iSIPinTarget = -1;
		g_fSIPinTargetExpire = 0.0;
	}
}

stock bool:SI_IsAttackWindow() {
	if (g_hCvarCoordEnable != INVALID_HANDLE && !GetConVarBool(g_hCvarCoordEnable))
		return false;
	return (g_fSIWindowEndTime > 0.0 && GetGameTime() < g_fSIWindowEndTime);
}

stock bool:SI_IsBoomerActive() {
	return g_bSIBoomerHit;
}

stock SI_SignalBoomerHit() {
	g_bSIBoomerHit = true;
	g_fSIBoomerHitExpire = GetGameTime() + 5.0;
	new Float:window = (g_hCvarCoordWindow != INVALID_HANDLE) ?
		GetConVarFloat(g_hCvarCoordWindow) : 3.0;
	g_fSIWindowEndTime = GetGameTime() + window;

	// v2.4: VScript coordination — trigger full assault on boomer hit
	if (g_hCvarCoordEnable != INVALID_HANDLE && GetConVarBool(g_hCvarCoordEnable))
	{
		// All SI enter assault mode (no hiding/dithering)
		// —— 保留：全特感恐慌模式 vscript，无个体意图冲突（任务书 §13.2 例外项）
		L4D2_StartAssault();

		// 任务书 §13：协同 = shared intent，不是直接命令接管。
		// 旧实现（v2.4）曾对所有未 COMMITTED 的 SI bot 直接调用
		//   L4D2_CommandABot(si, cmdTarget, BOT_CMD_ATTACK) —— 已移除。
		// 理由：所有 SI bot 均由 AI_HardSI 行为树（BT）管理，Valve 原版 AI 的
		// attack intent 会与 BT 决策（flank/hold/pounce）逐帧互抢，产生振荡。
		// Boomer 命中的协同意图只通过共享状态转发，每只 SI 的 BT 自行消费决策：
		//   - g_bSIBoomerHit（Boomer 命中） → BT 的 CND_IsBoomerActive
		//   - g_fSIWindowEndTime（攻击窗口）→ BT 的 CND_IsAttackWindow
		//   - SI_GetCoordinatedTarget()（分散目标，被胆汁覆盖者优先）
		//     → BT 的 ACT_AcquireCoordTarget
		new bestTarget = GetRandomSurvivor();
		if (bestTarget > 0)
		{
			// Common infected rush toward the affected survivor
			// —— 保留：尸潮 rush（L4D2_RushVictim），非个体 SI 决策（任务书 §13.2 例外项）
			L4D2_RushVictim(bestTarget, 1000.0);
		}
	}
}

stock SI_GetCoordinatedTarget(si, preferClass = -1) {
	// v4.0: 攻击窗口内优先集火被 pin 目标（拉→骑→吐 连锁的核心）。
	// 分散型模式除外：
	//   mode 4 (猎手集群) —— 多 Hunter 必须分散扑不同目标，不 dogpile
	//   mode 6 (巨兽协同) —— Tank 已锁定一个目标，其他 SI 分散控制更多
	//                        生还者，减轻 Tank 被集火压力
	//（下方 candidates 逻辑会排除已 pin 者，自然分散。）
	if (SI_IsAttackWindow() && g_iActiveMode != 4 && g_iActiveMode != 6 && g_iSIPinTarget > 0
		&& IsSurvivor(g_iSIPinTarget) && IsPlayerAlive(g_iSIPinTarget)) {
		return g_iSIPinTarget;
	}

	new Float:siPos[3];
	GetClientAbsOrigin(si, siPos);

	new candidates[MAXPLAYERS+1];
	new candidateCount = 0;
	new Float:candidateDist[MAXPLAYERS+1];

	for (new client = 1; client <= MaxClients; client++) {
		if (!IsSurvivor(client) || !IsPlayerAlive(client)) continue;
		if (IsIncapacitated(client)) continue;
		if (IsPinned(client)) continue;

		candidates[candidateCount] = client;
		new Float:survPos[3];
		GetClientAbsOrigin(client, survPos);
		candidateDist[candidateCount] = GetVectorDistance(siPos, survPos);
		candidateCount++;
	}

	if (candidateCount == 0) {
		return GetClosestSurvivor(siPos);
	}

	if (preferClass == _:ZC_SMOKER) {
		new farthest = candidates[0];
		new Float:farthestDist = candidateDist[0];
		for (new i = 1; i < candidateCount; i++) {
			if (candidateDist[i] > farthestDist) {
				farthest = candidates[i];
				farthestDist = candidateDist[i];
			}
		}
		return farthest;
	}

	if (preferClass == _:ZC_JOCKEY) {
		new lowestHP = candidates[0];
		new lowestHPVal = GetClientHealth(candidates[0]);
		for (new i = 1; i < candidateCount; i++) {
			new hp = GetClientHealth(candidates[i]);
			if (hp < lowestHPVal) {
				lowestHP = candidates[i];
				lowestHPVal = hp;
			}
		}
		return lowestHP;
	}

	new bestTarget = -1;
	new Float:bestDist = -1.0;
	for (new i = 0; i < candidateCount; i++) {
		new bool:alreadyTargeted = false;
		for (new other = 1; other <= MaxClients; other++) {
			if (other == si) continue;
			if (g_iSIAttackTarget[other] == candidates[i] && g_iSIAttackState[other] >= SI_APPROACHING) {
				alreadyTargeted = true;
				break;
			}
		}
		if (alreadyTargeted && candidateCount > 1) continue;
		if (SI_IsBoomerActive() && SI_IsSurvivorBoomed(candidates[i])) {
			return candidates[i];
		}
		if (bestDist < 0.0 || candidateDist[i] < bestDist) {
			bestDist = candidateDist[i];
			bestTarget = candidates[i];
		}
	}
	return (bestTarget > 0) ? bestTarget : GetClosestSurvivor(siPos);
}

// v4.0: 当前有效集火目标（pin 广播），过期/无效返回 -1
stock SI_GetPinTarget() {
	if (g_fSIPinTargetExpire > 0.0 && GetGameTime() < g_fSIPinTargetExpire
		&& g_iSIPinTarget > 0 && IsSurvivor(g_iSIPinTarget) && IsPlayerAlive(g_iSIPinTarget)) {
		return g_iSIPinTarget;
	}
	return -1;
}

// v4.0: 当前战术模式（0-5 普通, 6 Tank, -1 未知）
stock int SI_GetActiveMode() {
	return g_iActiveMode;
}

stock SI_SignalAttack(si) {
	g_fSILastAttackTime[si] = GetGameTime();
	g_iSIAttackState[si] = SI_COMMITTED;
	if (g_hCvarCoordEnable != INVALID_HANDLE && GetConVarBool(g_hCvarCoordEnable)) {
		new Float:window = (g_hCvarCoordWindow != INVALID_HANDLE) ?
			GetConVarFloat(g_hCvarCoordWindow) : 3.0;
		g_fSIWindowEndTime = GetGameTime() + window;

		// 任务书 §13：协同 = shared intent，不是直接命令接管。
		// 旧实现（v2.4）曾对 2000u 内、攻击状态 < SI_COMMITTED 的队友 SI bot
		// 直接调用 L4D2_CommandABot(other, target, BOT_CMD_ATTACK) —— 已移除。
		// 理由：所有 SI bot 均由 AI_HardSI 行为树（BT）管理，Valve 原版 AI 的
		// attack intent 会与 BT 决策（flank/hold/pounce）逐帧互抢，产生振荡。
		// 攻击意图只通过共享状态广播，每只 SI 的 BT 自行读取并决定是否改优先级：
		//   - g_fSIWindowEndTime（攻击窗口）→ BT 的 CND_IsAttackWindow（SI_IsAttackWindow）
		//   - g_iSIAttackTarget / g_iSIAttackState（per-SI 目标/状态）
		//     → SI_GetCoordinatedTarget / BT 的 ACT_AcquireCoordTarget
		//   - g_iSIPinTarget（集火广播）→ BT 的 ACT_AcquirePinTarget
		// 本函数只负责把"本 SI 发起进攻"这一事实写入共享状态，不做任何 bot 命令接管。
	}
}

// v4.1.2: m_hasBeenBoomed 在本游戏版本（2.2.4.3）不存在于网络数据表（sm_dump_netprops
// 实测全表无此属性）——v4.0.2 的 Prop_Data→Prop_Send 只换了失败方式，GetEntProp 依旧
// 每次抛异常（每晚数万条，BT tick 全中止）。改用引擎事件 L4D_OnVomitedUpon_Post
// 跟踪"被胆汁覆盖"状态（CTerrorPlayer::OnVomitedUpon 后置钩子，语义与 prop 一致）。
// 胆汁持续 ≈10s 自动失效；玩家重生时清零（Event_PlayerSpawn Pre）。
#define SI_BOOMED_DURATION 10.0
float g_fSurvivorBoomedUntil[MAXPLAYERS + 1];

public L4D_OnVomitedUpon_Post(victim, attacker, bool:boomerExplosion) {
	if (victim > 0 && victim <= MaxClients && IsClientInGame(victim))
		g_fSurvivorBoomedUntil[victim] = GetGameTime() + SI_BOOMED_DURATION;
}

stock bool:SI_IsSurvivorBoomed(client) {
	return client > 0 && client <= MaxClients
		&& g_fSurvivorBoomedUntil[client] > GetGameTime();
}

stock bool:SI_AnySurvivorBoomaBiled() {
	for (new client = 1; client <= MaxClients; client++) {
		if (IsSurvivor(client) && IsPlayerAlive(client)) {
			if (SI_IsSurvivorBoomed(client)) return true;
		}
	}
	return false;
}

// Kick dummy bot
public Action:Timer_KickBot(Handle:timer, any:client) {
	if ( IsClientConnected(client) && !IsClientInKickQueue(client) && IsFakeClient(client) ) {
		KickClient(client);
	}
	return Plugin_Handled;  // FIXED: missing return
}

// ===================================================================================
// v5.0: 战场感知基础设施 —— 身份定位系统的数据层
// 用户拍板"每个特感明确进攻身份"（Charger 突破手/Boomer 补刀/Spitter 区域毒压/
// Jockey 拖人进酸/Hunter 打乱枪线/Smoker 控制链/Tank 开团）。
// 身份分支需要的感知接口全部在此：
//   1. 酸液锚点 —— 哪里有酸（Spitter 的产出，Jockey/Smoker/Charger 的消费）
//   2. 谁控谁映射 —— 谁被控制、被谁控制、控了多久（Boomer 补刀/Hunter 补压）
//   3. 阵型分析 —— 密集区中心/散布度（Charger 突破目标、Spitter 封锁目标）
//   4. 孤立度公共化 —— 原 Smoker 私有，提为全员可用
//   5. 火力威胁评估 —— 输出核心识别（Charger/Hunter 打枪手）
// ===================================================================================

// ---------------------------------------------------------------------------
// 1. 酸液锚点（SPIT ACID ANCHOR）
//    Spitter 的酸液是特感阵营的"地形锚点"。实现：直接扫描 spit_acid 实体
//    （实体存在 = 酸液有效，被删 = 失效，天然准确无需事件/过期计时；
//    Charger 的 acidCharge 早已这么用）。
// ---------------------------------------------------------------------------

// 距 pos 最近的酸液池：落点写 acidPos；返回距离，无酸液返回 -1.0。
stock float SI_GetNearestAcid(const float pos[3], float acidPos[3], float maxRange = 0.0) {
	// native 要求非 const 数组，复制一份
	float center[3];
	center[0] = pos[0];
	center[1] = pos[1];
	center[2] = pos[2];
	int acid = L4D_FindEntityByClassnameNearest("spit_acid", center, maxRange > 0.0 ? maxRange : 99999.0);
	if (acid > 0) {
		GetEntPropVector(acid, Prop_Send, "m_vecOrigin", acidPos);
		return GetVectorDistance(pos, acidPos);
	}
	return -1.0;
}

// ---------------------------------------------------------------------------
// 2. 谁控谁映射（PIN OWNER MAP）
//    SI_UpdateCoordination 的 pin 边沿检测已广播集火目标，但缺"谁控谁 +
//    控了多久"——Boomer 补刀、Hunter 补压需要知道目标正被哪类特感控制。
// ---------------------------------------------------------------------------

int g_iPinOwnerOf[MAXPLAYERS + 1];   // survivor → 控制他的 SI（0 = 无）
int g_iPinVictimOf[MAXPLAYERS + 1];  // SI → 他控制的 survivor（0 = 无）
float g_fPinSince[MAXPLAYERS + 1];   // 控制开始时刻（SI_GetPinDuration 用）

// 更新映射（SI_UpdateCoordination 每 tick 调用，幂等）
stock void SI_UpdatePinMap() {
	for (int s = 1; s <= MaxClients; s++) {
		if (!IsSurvivor(s) || !IsPlayerAlive(s) || !IsPinned(s)) {
			if (g_iPinOwnerOf[s] > 0) {
				g_iPinVictimOf[g_iPinOwnerOf[s]] = 0;
				g_iPinOwnerOf[s] = 0;
			}
			continue;
		}
		// 被控者：查五类 pin 表找控制者
		int owner = GetEntPropEnt(s, Prop_Send, "m_tongueOwner");
		if (owner <= 0) owner = GetEntPropEnt(s, Prop_Send, "m_pounceAttacker");
		if (owner <= 0) owner = GetEntPropEnt(s, Prop_Send, "m_carryAttacker");
		if (owner <= 0) owner = GetEntPropEnt(s, Prop_Send, "m_pummelAttacker");
		if (owner <= 0) owner = GetEntPropEnt(s, Prop_Send, "m_jockeyAttacker");
		if (owner <= 0 || owner > MaxClients) continue;
		if (g_iPinOwnerOf[s] != owner) {
			g_iPinOwnerOf[s] = owner;
			g_iPinVictimOf[owner] = s;
			g_fPinSince[s] = GetGameTime();
		}
	}
}

// 被控者的控制者 SI（无/失效返回 0）
stock int SI_GetPinOwner(int survivor) {
	if (survivor <= 0 || survivor > MaxClients) return 0;
	return g_iPinOwnerOf[survivor];
}

// 控制时长（秒）
stock float SI_GetPinDuration(int survivor) {
	if (survivor <= 0 || survivor > MaxClients || g_iPinOwnerOf[survivor] <= 0) return 0.0;
	return GetGameTime() - g_fPinSince[survivor];
}

// 最近的被控者（Boomer 补刀/Hunter 补压用），距离 ≤ maxDist 才返回
stock int SI_GetNearestPinnedSurvivor(const float pos[3], float maxDist = 99999.0) {
	int best = -1;
	float bestDist = 0.0;
	for (int s = 1; s <= MaxClients; s++) {
		if (!IsSurvivor(s) || !IsPlayerAlive(s) || !IsPinned(s)) continue;
		float sPos[3];
		GetClientAbsOrigin(s, sPos);
		float d = GetVectorDistance(pos, sPos);
		if (d > maxDist) continue;
		if (best < 0 || d < bestDist) {
			best = s;
			bestDist = d;
		}
	}
	return best;
}

// ---------------------------------------------------------------------------
// 3. 阵型分析（FORMATION ANALYSIS）
//    Charger 突破需要"哪里人最密"（冲密集区撕火力网），Spitter 封锁需要
//    "队伍重心"。O(n²) 距离矩阵，n ≤ 24，调用方自限频。
// ---------------------------------------------------------------------------

// 密集区分析：对每个站立幸存者统计 radius 内邻居数，返回邻居最多的簇心
// 成员索引（-1 = 无密集区），center 写簇中心坐标（邻居平均位置）。
// 语义：簇总人数（含簇心）= 邻居数 + 1，≥ minCount 才算密集区。
stock int SI_GetDenseCluster(const float radius, int minCount, float center[3]) {
	int survivors[MAXPLAYERS + 1];
	int sCount = 0;
	float pos[MAXPLAYERS + 1][3];

	for (int s = 1; s <= MaxClients; s++) {
		if (IsSurvivor(s) && IsPlayerAlive(s) && !IsIncapacitated(s)) {
			survivors[sCount] = s;
			GetClientAbsOrigin(s, pos[sCount]);
			sCount++;
		}
	}
	if (sCount < minCount) return -1;

	int bestMember = -1;
	int bestCount = 0;
	for (int i = 0; i < sCount; i++) {
		int cnt = 0;
		float cx = 0.0, cy = 0.0, cz = 0.0;
		for (int j = 0; j < sCount; j++) {
			if (i == j) continue;
			if (GetVectorDistance(pos[i], pos[j]) <= radius) {
				cnt++;
				cx += pos[j][0]; cy += pos[j][1]; cz += pos[j][2];
			}
		}
		if (cnt > bestCount) {
			bestCount = cnt;
			bestMember = survivors[i];
			if (cnt > 0) {
				center[0] = cx / float(cnt);
				center[1] = cy / float(cnt);
				center[2] = cz / float(cnt);
			} else {
				center = pos[i];
			}
		}
	}
	return (bestCount >= minCount - 1) ? bestMember : -1;
}

// 队伍散布度：全队两两平均距离（越大 = 队伍拉得越散）
stock float SI_GetSurvivorSpread() {
	int survivors[MAXPLAYERS + 1];
	int sCount = 0;
	float pos[MAXPLAYERS + 1][3];
	for (int s = 1; s <= MaxClients; s++) {
		if (IsSurvivor(s) && IsPlayerAlive(s) && !IsIncapacitated(s)) {
			survivors[sCount] = s;
			GetClientAbsOrigin(s, pos[sCount]);
			sCount++;
		}
	}
	if (sCount < 2) return 0.0;
	float total = 0.0;
	int pairs = 0;
	for (int i = 0; i < sCount; i++) {
		for (int j = i + 1; j < sCount; j++) {
			total += GetVectorDistance(pos[i], pos[j]);
			pairs++;
		}
	}
	return total / float(pairs);
}

// ---------------------------------------------------------------------------
// 4. 孤立度公共化（原 Smoker 私有逻辑 bt_smoker.inc:38 提为公共 API）——
//    队伍中离队友最远的人（≥ minIsolation 才认为孤立）
// ---------------------------------------------------------------------------

stock int SI_GetLoneliestSurvivor(float minIsolation = 350.0) {
	int best = -1;
	float bestDist = 0.0;
	for (int s = 1; s <= MaxClients; s++) {
		if (!IsSurvivor(s) || !IsPlayerAlive(s) || IsPinned(s) || IsIncapacitated(s)) continue;
		float sPos[3];
		GetClientAbsOrigin(s, sPos);
		float nearest = 999999.0;
		for (int o = 1; o <= MaxClients; o++) {
			if (o == s || !IsSurvivor(o) || !IsPlayerAlive(o) || IsIncapacitated(o)) continue;
			float oPos[3];
			GetClientAbsOrigin(o, oPos);
			float d = GetVectorDistance(sPos, oPos);
			if (d < nearest) nearest = d;
		}
		if (nearest >= minIsolation && nearest > bestDist) {
			best = s;
			bestDist = nearest;
		}
	}
	return best;
}

// ---------------------------------------------------------------------------
// 5. 火力威胁评估（WEAPON THREAT）—— 输出核心识别
//    Charger 突破目标 = 高威胁枪手（撕火力网），Hunter 枪线目标同理。
//    武器权重（社区共识火力输出排序）：
//    榴弹 3.0 > 狙击 2.5 > 霰弹 2.0 > 冲锋 1.5 > 步枪 1.2 > 手枪 0.5 > 近战 0.3
// ---------------------------------------------------------------------------

stock float SI_GetWeaponThreat(int survivor) {
	int slot = GetPlayerWeaponSlot(survivor, 0);  // 主武器槽
	if (slot <= 0) return 0.3;  // 无主武器 = 近战/空手
	char cls[32];
	GetEntityClassname(slot, cls, sizeof(cls));
	if (StrEqual(cls, "weapon_grenade_launcher")) return 3.0;
	if (StrEqual(cls, "weapon_sniper_scout") || StrEqual(cls, "weapon_sniper_military")
		|| StrEqual(cls, "weapon_sniper_awp")) return 2.5;
	if (StrContains(cls, "shotgun") != -1) return 2.0;
	if (StrContains(cls, "smg") != -1) return 1.5;
	if (StrEqual(cls, "weapon_rifle") || StrEqual(cls, "weapon_rifle_ak47")
		|| StrEqual(cls, "weapon_rifle_desert") || StrEqual(cls, "weapon_rifle_sg552")
		|| StrEqual(cls, "weapon_rifle_m60")) return 1.2;
	if (StrEqual(cls, "weapon_pistol") || StrEqual(cls, "weapon_pistol_magnum")) return 0.5;
	return 0.3;
}

// 距 siPos 高威胁目标（含距离衰减：score = 权重 / (1 + dist/1000)）
stock int SI_GetHighestThreatSurvivor(const float siPos[3], float maxDist = 0.0) {
	int best = -1;
	float bestScore = -1.0;
	for (int s = 1; s <= MaxClients; s++) {
		if (!IsSurvivor(s) || !IsPlayerAlive(s) || IsPinned(s) || IsIncapacitated(s)) continue;
		float sPos[3];
		GetClientAbsOrigin(s, sPos);
		float d = GetVectorDistance(siPos, sPos);
		if (maxDist > 0.0 && d > maxDist) continue;
		float score = SI_GetWeaponThreat(s) / (1.0 + d / 1000.0);
		if (score > bestScore) {
			bestScore = score;
			best = s;
		}
	}
	return best;
}

// ============================================================================
// v5.18 功能 2：挂边状态工具
// ----------------------------------------------------------------------------
// 挂边（m_isHangingFromLedge）时 m_isIncapacitated 也为 1，所以既有的
// IsIncapacitated() 已把挂边算进去。这里拆出三态以便行为树区分：
//   挂边     = 一击落地即死，白给目标，但控制技能打上去是空转
//   地面倒地 = 可被补刀，控制技能同样空转
//   站立     = 正常目标
// ============================================================================

// 挂边中（吊在边缘等人拉）
stock bool SI_IsHangingFromLedge(int client) {
	if (!IsSurvivor(client) || !IsPlayerAlive(client)) return false;
	return view_as<bool>(GetEntProp(client, Prop_Send, "m_isHangingFromLedge"));
}

// 地面倒地（倒地但不是挂边）
stock bool SI_IsIncappedOnGround(int client) {
	if (!IsSurvivor(client) || !IsPlayerAlive(client)) return false;
	if (!GetEntProp(client, Prop_Send, "m_isIncapacitated")) return false;
	return !GetEntProp(client, Prop_Send, "m_isHangingFromLedge");
}

// 可作为控制技能（扑/拉/骑/冲）目标：站立且未被控
// 挂边/倒地的人对控制技能免疫或无意义 —— 打上去纯浪费冷却
stock bool SI_IsPinnable(int client) {
	if (!IsSurvivor(client) || !IsPlayerAlive(client)) return false;
	if (IsPinned(client)) return false;
	return !GetEntProp(client, Prop_Send, "m_isIncapacitated");
}

// v5.19: 最近的【可扑/可骑】生还者（优先站立未控，兜底任意存活）
// 用途：Jockey/Hunter/Charger 等扑咬类目标选择——倒地者不可扑骑，持续锁定
// 倒地者会原地跳（Jockey "倒地后徘徊" bug，2026-08-15 修复）。优先可扑者 →
// 存在站立目标时不锁倒地者；全倒地时退回最近存活者（树自然 FAIL）。
stock int GetClosestPinnableSurvivor(const float referencePos[3], int excludeSurvivor = -1) {
	float survivorPos[3];
	int closestPinnable = -1;
	int closestAny = -1;
	float distPinnable = -1.0;
	float distAny = -1.0;

	for (int client = 1; client <= MaxClients; client++) {
		if (!IsSurvivor(client) || !IsPlayerAlive(client) || client == excludeSurvivor)
			continue;

		GetClientAbsOrigin(client, survivorPos);
		float d = GetVectorDistance(referencePos, survivorPos);

		// 跟踪最近的【任意】存活者（兜底）
		if (distAny < 0.0 || d < distAny) {
			distAny = d;
			closestAny = client;
		}

		// 跟踪最近的【可扑】者（优先）
		if (SI_IsPinnable(client)) {
			if (distPinnable < 0.0 || d < distPinnable) {
				distPinnable = d;
				closestPinnable = client;
			}
		}
	}

	// 优先返回可扑者；无可扑者时退回任意存活者（全倒地 = 无目标，树 FAIL）
	return (closestPinnable > 0) ? closestPinnable : closestAny;
}

// 最近的挂边幸存者（Tank/Charger 的优先击落目标）
stock int SI_GetHangingSurvivor(const float siPos[3], float maxDist = 0.0) {
	int best = -1;
	float bestDist = -1.0;
	for (int s = 1; s <= MaxClients; s++) {
		if (!SI_IsHangingFromLedge(s)) continue;
		float sPos[3];
		GetClientAbsOrigin(s, sPos);
		float d = GetVectorDistance(siPos, sPos);
		if (maxDist > 0.0 && d > maxDist) continue;
		if (bestDist < 0.0 || d < bestDist) {
			bestDist = d;
			best = s;
		}
	}
	return best;
}

// ============================================================================
// v5.18 功能 1：flow（逃跑路线）感知
// ----------------------------------------------------------------------------
// flow = nav 区域到战役出口的弧长递增值。领队 flow 就是"队伍推进到哪了"，
// flow 更大的位置 = 玩家还没走到但必经的前方。用它做前置埋伏，
// 把特感从"追着打"变成"等着打"。
// GetFlow() 定义见本文件上方，-1 表示点不在 nav 上。
// ============================================================================

// 领队 flow（缓存 0.25s，避免每 tick 重算全队）
static int  s_iLeadFlowCache    = -1;
static float s_fLeadFlowCacheAt = 0.0;

stock int SI_GetLeadFlow() {
	float now = GetGameTime();
	if (s_iLeadFlowCache >= 0 && now - s_fLeadFlowCacheAt < 0.25) {
		return s_iLeadFlowCache;
	}
	int lead = -1;
	float origin[3];
	for (int s = 1; s <= MaxClients; s++) {
		if (!IsSurvivor(s) || !IsPlayerAlive(s)) continue;
		GetClientAbsOrigin(s, origin);
		int f = GetFlow(origin);
		if (f > lead) lead = f;
	}
	s_iLeadFlowCache    = lead;
	s_fLeadFlowCacheAt  = now;
	return lead;
}

// 自身 flow（-1 = 不在 nav 上，调用方须放弃 flow 逻辑走原分支）
stock int SI_GetOwnFlow(int client) {
	if (!IsClientInGame(client) || !IsPlayerAlive(client)) return -1;
	float origin[3];
	GetClientAbsOrigin(client, origin);
	return GetFlow(origin);
}

// 相对领队的 flow 偏移：>0 在队伍前方（路线上游），<0 在后方
// 返回 SI_FLOW_INVALID 表示任一端不在 nav 上
#define SI_FLOW_INVALID -99999

stock int SI_GetFlowOffset(int client) {
	int own  = SI_GetOwnFlow(client);
	if (own < 0) return SI_FLOW_INVALID;
	int lead = SI_GetLeadFlow();
	if (lead < 0) return SI_FLOW_INVALID;
	return own - lead;
}

// 探测 flow 增大的方向（朝出口/玩家前方）。8 向采样半径 probeRadius，
// 取 flow 最大的方向写入 outDir（单位化的水平向量）。
// 返回 false = 无有效 nav 采样点，调用方须退回原行为。
stock bool SI_ProbeForwardRouteDir(int client, float outDir[3], float probeRadius = 220.0) {
	float origin[3];
	GetClientAbsOrigin(client, origin);
	int baseFlow = GetFlow(origin);
	if (baseFlow < 0) return false;

	int   bestFlow = baseFlow;
	float bestDir[3];
	bool  found = false;

	for (int i = 0; i < 8; i++) {
		float ang = float(i) * 45.0;
		float rad = DegToRad(ang);
		float probe[3];
		probe[0] = origin[0] + Cosine(rad) * probeRadius;
		probe[1] = origin[1] + Sine(rad)   * probeRadius;
		probe[2] = origin[2];

		int f = GetFlow(probe);
		if (f < 0) continue;
		if (f > bestFlow) {
			bestFlow = f;
			bestDir[0] = Cosine(rad);
			bestDir[1] = Sine(rad);
			bestDir[2] = 0.0;
			found = true;
		}
	}

	if (!found) return false;
	outDir[0] = bestDir[0];
	outDir[1] = bestDir[1];
	outDir[2] = bestDir[2];
	return true;
}