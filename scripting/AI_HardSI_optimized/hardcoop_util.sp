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
		L4D2_StartAssault();

		// Command idle/approaching SI to attack distributed targets
		new bestTarget = GetRandomSurvivor();
		if (bestTarget > 0)
		{
			for (new si = 1; si <= MaxClients; si++)
			{
				if (IsValidClient(si) && IsBotInfected(si) && IsPlayerAlive(si)
					&& g_iSIAttackState[si] < SI_COMMITTED)
				{
					new cmdTarget = SI_GetCoordinatedTarget(si);
					if (cmdTarget > 0)
					{
						L4D2_CommandABot(si, cmdTarget, BOT_CMD_ATTACK);
					}
				}
			}
			// Common infected rush toward the affected survivor
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
		if (SI_IsBoomerActive() && GetEntProp(candidates[i], Prop_Send, "m_hasBeenBoomed") > 0) {
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

		// v2.4: VScript command — force nearby idle SI to join the attack
		new target = g_iSIAttackTarget[si];
		if (target > 0 && IsSurvivor(target))
		{
			new Float:siPos[3];
			GetClientAbsOrigin(si, siPos);
			for (new other = 1; other <= MaxClients; other++)
			{
				if (other == si) continue;
				if (IsValidClient(other) && IsBotInfected(other) && IsPlayerAlive(other)
					&& g_iSIAttackState[other] < SI_COMMITTED)
				{
					// Only command SI that are within range
					new Float:otherPos[3];
					GetClientAbsOrigin(other, otherPos);
					if (GetVectorDistance(siPos, otherPos) < 2000.0)
					{
						L4D2_CommandABot(other, target, BOT_CMD_ATTACK);
					}
				}
			}
		}
	}
}

stock bool:SI_AnySurvivorBoomaBiled() {
	for (new client = 1; client <= MaxClients; client++) {
		if (IsSurvivor(client) && IsPlayerAlive(client)) {
			if (GetEntProp(client, Prop_Send, "m_hasBeenBoomed") > 0) return true;
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