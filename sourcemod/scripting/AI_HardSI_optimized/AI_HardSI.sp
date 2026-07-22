#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#include "includes/hardcoop_util.sp"
#include "modules/AI_Smoker.sp"
#include "modules/AI_Boomer.sp"
#include "modules/AI_Hunter.sp"
#include "modules/AI_Spitter.sp"
#include "modules/AI_Charger.sp"
#include "modules/AI_Jockey.sp"
#include "modules/AI_Tank.sp"
#include "modules/AI_Witch.sp"

new bool:bHasBeenShoved[MAXPLAYERS]; // shoving resets SI movement

// OPTIMIZATION: Tick throttling for OnPlayerRunCmd
// OnPlayerRunCmd fires every frame (~30/sec per client) which is excessive for AI decisions.
// We only need to evaluate AI every few ticks. This dramatically reduces CPU usage with no
// perceptible change in behavior.
new iTickCounter[MAXPLAYERS];
#define TICK_INTERVAL 4  // evaluate AI every 4th tick (~7.5 decisions/sec at 30 tick)

public Plugin:myinfo =
{
	name = "AI: Hard SI (Optimized)",
	author = "Breezy, optimized by Claude",
	description = "Improves the AI behaviour of special infected - bugfixed & optimized version",
	version = "2.0",
	url = "github.com/breezyplease"
};

public OnPluginStart() {
	// Event hooks
	HookEvent("player_spawn", InitialiseSpecialInfected, EventHookMode_Pre);
	HookEvent("ability_use", OnAbilityUse, EventHookMode_Pre);
	HookEvent("player_shoved", OnPlayerShoved, EventHookMode_Pre);
	HookEvent("player_jump", OnPlayerJump, EventHookMode_Pre);
	HookEvent("tongue_release", OnTongueRelease, EventHookMode_Pre); // FIXED: was never hooked!

	// Load modules
	Smoker_OnModuleStart();
	Hunter_OnModuleStart();
	Spitter_OnModuleStart();
	Boomer_OnModuleStart();
	Charger_OnModuleStart();
	Jockey_OnModuleStart();
	Tank_OnModuleStart();
	Witch_OnModuleStart();
}

public OnPluginEnd() {
	// Unload modules
	Smoker_OnModuleEnd();
	Hunter_OnModuleEnd();
	Spitter_OnModuleEnd();
	Boomer_OnModuleEnd();
	Charger_OnModuleEnd();
	Jockey_OnModuleEnd();
	Tank_OnModuleEnd();
	Witch_OnModuleEnd();
}

/***********************************************************************************************************************************************************************************

																		SI MOVEMENT

***********************************************************************************************************************************************************************************/

// Modify SI movement
public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon) {
	if( IsBotInfected(client) && IsPlayerAlive(client) ) {
		// OPTIMIZATION: Throttle AI evaluation to every TICK_INTERVAL ticks
		iTickCounter[client]++;
		if ( iTickCounter[client] < TICK_INTERVAL ) {
			return Plugin_Continue;
		}
		iTickCounter[client] = 0;

		new botInfected = client;
		switch( L4D2_Infected:GetInfectedClass(botInfected) ) {

			case (L4D2Infected_Hunter): {
				if( !bHasBeenShoved[botInfected] ) return Hunter_OnPlayerRunCmd( botInfected, buttons, impulse, vel, angles, weapon );
			}

			case (L4D2Infected_Charger): {
				return Charger_OnPlayerRunCmd( botInfected, buttons, impulse, vel, angles, weapon );
			}

			case (L4D2Infected_Jockey): {
				return Jockey_OnPlayerRunCmd( botInfected, buttons, impulse, vel, angles, weapon, bHasBeenShoved[botInfected] );
			}

			case (L4D2Infected_Tank): {
				return Tank_OnPlayerRunCmd( botInfected, buttons, impulse, vel, angles, weapon );
			}

			default: {
				return Plugin_Continue;
			}
		}
	}
	return Plugin_Continue;
}

/***********************************************************************************************************************************************************************************

																		EVENT HOOKS

***********************************************************************************************************************************************************************************/

// Initialise relevant module flags for SI when they spawn
public Action:InitialiseSpecialInfected(Handle:event, String:name[], bool:dontBroadcast) {
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if( IsBotInfected(client) ) {
		new botInfected = client;
		bHasBeenShoved[client] = false;
		iTickCounter[client] = 0;  // Reset tick counter on spawn
		// Process for SI class
		switch( L4D2_Infected:GetInfectedClass(botInfected) ) {

			case (L4D2Infected_Hunter): {
				return Hunter_OnSpawn(botInfected);
			}

			case (L4D2Infected_Charger): {
				return Charger_OnSpawn(botInfected);
			}

			case (L4D2Infected_Jockey): {
				return Jockey_OnSpawn(botInfected);
			}

			default: {
				return Plugin_Handled;
			}
		}
	}
	return Plugin_Handled;
}

// Modify hunter lunges and block smokers/spitters from fleeing after using their ability
public Action:OnAbilityUse(Handle:event, String:name[], bool:dontBroadcast) {
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if( IsBotInfected(client) ) {
		new bot = client;
		bHasBeenShoved[bot] = false; // Reset shove status
		// Process for different SI
		new String:abilityName[32];
		GetEventString(event, "ability", abilityName, sizeof(abilityName));
		if( StrEqual(abilityName, "ability_lunge") ) {
			return Hunter_OnPounce(bot);
		} else if( StrEqual(abilityName, "ability_charge") ) {
			Charger_OnCharge(bot);
		} else if( StrEqual(abilityName, "ability_spit") ) { // stop smokers and spitters running away
			RequestFrame(SuicideFrame, any:client);  // OPTIMIZED: use RequestFrame instead of 0.5s timer
		}
	}
	return Plugin_Handled;
}

// FIXED: This event was never hooked in the original! Now properly registered.
public Action:OnTongueRelease(Handle:event, String:name[], bool:dontBroadcast) {
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if( IsBotInfected(client) ) {
		RequestFrame(SuicideFrame, any:client);  // OPTIMIZED: use RequestFrame instead of 0.5s timer
	}
	return Plugin_Continue;
}

// OPTIMIZED: Replace CreateTimer(0.5, Timer_Suicide) with RequestFrame for immediate execution
// The 0.5 second delay served no purpose — the SI should die immediately after ability use.
public SuicideFrame(any:client) {
	if ( IsValidClient(client) && IsBotInfected(client) && IsPlayerAlive(client) ) {
		ForcePlayerSuicide(client);
	}
}

// Pause behaviour modification when shoved
public Action:OnPlayerShoved(Handle:event, String:name[], bool:dontBroadcast) {
	new shovedPlayer = GetClientOfUserId(GetEventInt(event, "userid"));
	if( IsBotInfected(shovedPlayer) ) {
		bHasBeenShoved[shovedPlayer] = true;
		if( L4D2_Infected:GetInfectedClass(shovedPlayer) == L4D2Infected_Jockey ) {
			Jockey_OnShoved(shovedPlayer);
		}
	}
	return Plugin_Continue;
}

// Re-enable forced hopping when a shoved jockey leaps again naturally
public Action:OnPlayerJump(Handle:event, String:name[], bool:dontBroadcast) {
	new jumpingPlayer = GetClientOfUserId(GetEventInt(event, "userid"));
	if( IsBotInfected(jumpingPlayer) )  {
		bHasBeenShoved[jumpingPlayer] = false;
	}
}

/***********************************************************************************************************************************************************************************

																	TRACKING SURVIVORS' AIM

***********************************************************************************************************************************************************************************/

/**
	Determines whether an attacking SI is being watched by the survivor
	@return: true if the survivor's crosshair is within the specified radius
	@param attacker: the client number of the attacking SI
	@param offsetThreshold: the radius(degrees) of the cone of detection around the straight line from the attacked survivor to the SI
**/
bool:IsTargetWatchingAttacker( attacker, offsetThreshold ) {
	new bool:isWatching = true;
	if( GetClientTeam(attacker) == 3 && IsPlayerAlive(attacker) ) { // SI continue to hold on to their targets for a few seconds after death
		new target = GetClientAimTarget(attacker);
		if( IsSurvivor(target) ) {
			new aimOffset = RoundToNearest(GetPlayerAimOffset(target, attacker));
			if( aimOffset <= offsetThreshold ) {
				isWatching = true;
			} else {
				isWatching = false;
			}
		}
	}
	return isWatching;
}

/**
	Calculates how much a player's aim is off another player
	@return: aim offset in degrees
	@attacker: considers this player's eye angles
	@target: considers this player's position
	Adapted from code written by Guren with help from Javalia
**/
Float:GetPlayerAimOffset( attacker, target ) {
	if( !IsClientConnected(attacker) || !IsClientInGame(attacker) || !IsPlayerAlive(attacker) )
		ThrowError("Client is not Alive.");
	if(!IsClientConnected(target) || !IsClientInGame(target) || !IsPlayerAlive(target) )
		ThrowError("Target is not Alive.");

	new Float:attackerPos[3], Float:targetPos[3];
	new Float:aimVector[3], Float:directVector[3];
	new Float:resultAngle;

	// Get the unit vector representing the attacker's aim
	GetClientEyeAngles(attacker, aimVector);
	aimVector[0] = aimVector[2] = 0.0; // Restrict pitch and roll, consider yaw only (angles on horizontal plane)
	GetAngleVectors(aimVector, aimVector, NULL_VECTOR, NULL_VECTOR); // extract the forward vector[3]
	NormalizeVector(aimVector, aimVector); // convert into unit vector

	// Get the unit vector representing the vector between target and attacker
	GetClientAbsOrigin(target, targetPos);
	GetClientAbsOrigin(attacker, attackerPos);
	attackerPos[2] = targetPos[2] = 0.0; // Restrict to XY coordinates
	MakeVectorFromPoints(attackerPos, targetPos, directVector);
	NormalizeVector(directVector, directVector);

	// Calculate the angle between the two unit vectors
	resultAngle = RadToDeg(ArcCosine(GetVectorDotProduct(aimVector, directVector)));
	return resultAngle;
}