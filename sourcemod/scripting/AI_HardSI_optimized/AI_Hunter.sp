#pragma semicolon 1

#include <sdktools>
#define DEBUG_HUNTER_AIM 0
#define DEBUG_HUNTER_RNG 0
#define DEBUG_HUNTER_ANGLE 0

#define POSITIVE 0
#define NEGATIVE 1
#define X 0
#define Y 1
#define Z 2

// Vanilla Cvars
new Handle:hCvarHunterCommittedAttackRange;
new Handle:hCvarHunterPounceReadyRange;
new Handle:hCvarHunterLeapAwayGiveUpRange;
new Handle:hCvarHunterPounceMaxLoftAngle;
new Handle:hCvarLungeInterval;
// Gaussian random number generator for pounce angles
new Handle:hCvarPounceAngleMean;
new Handle:hCvarPounceAngleStd; // standard deviation
// Pounce vertical angle
new Handle:hCvarPounceVerticalAngle;
// Distance at which hunter begins pouncing fast
new Handle:hCvarFastPounceProximity;
// Distance at which hunter considers pouncing straight
new Handle:hCvarStraightPounceProximity;
// Aim offset(degrees) sensitivity
new Handle:hCvarAimOffsetSensitivityHunter;
// Wall detection
new Handle:hCvarWallDetectionDistance;

new bool:bHasQueuedLunge[MAXPLAYERS];
new bool:bCanLunge[MAXPLAYERS];

// OPTIMIZATION: cached CVar values to avoid repeated GetConVarInt calls in OnPlayerRunCmd
new iCachedFastPounceProximity;
new Float:fCachedLungeInterval;

public Hunter_OnModuleStart() {
	// Set aggressive hunter cvars
	hCvarHunterCommittedAttackRange = FindConVar("hunter_committed_attack_range");
	hCvarHunterPounceReadyRange = FindConVar("hunter_pounce_ready_range");
	hCvarHunterLeapAwayGiveUpRange = FindConVar("hunter_leap_away_give_up_range");
	hCvarLungeInterval = FindConVar("z_lunge_interval");
	hCvarHunterPounceMaxLoftAngle = FindConVar("hunter_pounce_max_loft_angle");
	SetConVarInt(hCvarHunterCommittedAttackRange, 10000);
	SetConVarInt(hCvarHunterPounceReadyRange, 500);
	SetConVarInt(hCvarHunterLeapAwayGiveUpRange, 0);
	SetConVarInt(hCvarHunterPounceMaxLoftAngle, 0);

	// proximity to nearest survivor when plugin starts to force hunters to lunge ASAP
	hCvarFastPounceProximity = CreateConVar("ai_fast_pounce_proximity", "1000", "At what distance to start pouncing fast");

	// Verticality
	hCvarPounceVerticalAngle = CreateConVar("ai_pounce_vertical_angle", "7", "Vertical angle to which AI hunter pounces will be restricted");

	// Pounce angle
	hCvarPounceAngleMean = CreateConVar( "ai_pounce_angle_mean", "10", "Mean angle produced by Gaussian RNG" );
	hCvarPounceAngleStd = CreateConVar( "ai_pounce_angle_std", "20", "One standard deviation from mean as produced by Gaussian RNG" );
	hCvarStraightPounceProximity = CreateConVar( "ai_straight_pounce_proximity", "200", "Distance to nearest survivor at which hunter will consider pouncing straight");

	// Aim offset sensitivity
	hCvarAimOffsetSensitivityHunter = CreateConVar("ai_aim_offset_sensitivity_hunter",
									"30",
									"If the hunter has a target, it will not straight pounce if the target's aim on the horizontal axis is within this radius",
									FCVAR_NONE,
									true, 0.0, true, 179.0 );
	// How far in front of hunter to check for a wall
	hCvarWallDetectionDistance = CreateConVar("ai_wall_detection_distance", "-1", "How far in front of himself infected bot will check for a wall. Use '-1' to disable feature");

	SetConVarInt(FindConVar("z_pounce_damage_interrupt"), 150);

	// Init cached values
	iCachedFastPounceProximity = 1000;
	fCachedLungeInterval = GetConVarFloat(hCvarLungeInterval);

	// Hook CVar changes to update cache
	HookConVarChange(hCvarFastPounceProximity, OnHunterCvarChanged);
	HookConVarChange(hCvarLungeInterval, OnHunterCvarChanged);
}

public OnHunterCvarChanged(Handle:convar, const String:oldValue[], const String:newValue[]) {
	iCachedFastPounceProximity = GetConVarInt(hCvarFastPounceProximity);
	fCachedLungeInterval = GetConVarFloat(hCvarLungeInterval);
}

public Hunter_OnModuleEnd() {
	// Reset aggressive hunter cvars
	ResetConVar(hCvarHunterCommittedAttackRange);
	ResetConVar(hCvarHunterPounceReadyRange);
	ResetConVar(hCvarHunterLeapAwayGiveUpRange);
	ResetConVar(hCvarHunterPounceMaxLoftAngle);

	ResetConVar(FindConVar("z_pounce_damage_interrupt"));
}

public Action:Hunter_OnSpawn(botHunter) {
	bHasQueuedLunge[botHunter] = false;
	bCanLunge[botHunter] = true;
	return Plugin_Handled;
}

/***********************************************************************************************************************************************************************************

																		FAST POUNCING

***********************************************************************************************************************************************************************************/

public Action:Hunter_OnPlayerRunCmd(hunter, &buttons, &impulse, Float:vel[3], Float:eyeAngles[3], &weapon) {
	buttons &= ~IN_ATTACK2; // block scratches
	new flags = GetEntityFlags(hunter);
	//Proceed if the hunter is in a position to pounce
	if( (flags & FL_DUCKING) && (flags & FL_ONGROUND) ) {
		new Float:hunterPos[3];
		GetClientAbsOrigin(hunter, hunterPos);
		new iSurvivorsProximity = GetSurvivorProximity(hunterPos);
		new bool:bHasLOS = bool:GetEntProp(hunter, Prop_Send, "m_hasVisibleThreats");

		// Start fast pouncing if close enough to survivors
		if( bHasLOS && iSurvivorsProximity < iCachedFastPounceProximity ) {
			buttons &= ~IN_ATTACK; // release attack button; precautionary
			// Queue a pounce/lunge
			if (!bHasQueuedLunge[hunter]) {
				bCanLunge[hunter] = false;
				bHasQueuedLunge[hunter] = true;
				CreateTimer(fCachedLungeInterval, Timer_LungeInterval, any:hunter, TIMER_FLAG_NO_MAPCHANGE);
			} else if (bCanLunge[hunter]) {
				buttons |= IN_ATTACK;
				bHasQueuedLunge[hunter] = false;
			}
		}
	}
	return Plugin_Changed;
}

/***********************************************************************************************************************************************************************************

																	POUNCING AT AN ANGLE TO SURVIVORS

***********************************************************************************************************************************************************************************/

public Action:Hunter_OnPounce(botHunter) {
	new entLunge = GetEntPropEnt(botHunter, Prop_Send, "m_customAbility");
	if ( entLunge <= 0 ) return Plugin_Continue;  // FIXED: safety check
	new Float:lungeVector[3];
	GetEntPropVector(entLunge, Prop_Send, "m_queuedLunge", lungeVector);

	// Avoid pouncing straight forward if there is a wall close in front
	new iWallDist = GetConVarInt(hCvarWallDetectionDistance);
	if ( iWallDist > 0 ) {
		new Float:hunterPos[3];
		new Float:hunterAngle[3];
		GetClientAbsOrigin(botHunter, hunterPos);
		GetClientEyeAngles(botHunter, hunterAngle);
		// Fire traceray in front of hunter
		TR_TraceRayFilter( hunterPos, hunterAngle, MASK_PLAYERSOLID, RayType_Infinite, TracerayFilter, botHunter );
		new Float:impactPos[3];
		TR_GetEndPosition( impactPos );
		// Check first object hit
		if( GetVectorDistance(hunterPos, impactPos) < float(iWallDist) ) {
			if( GetRandomInt(0, 1) ) {
				AngleLunge( entLunge, 45.0 );
			} else {
				AngleLunge( entLunge, 315.0 );
			}

				#if DEBUG_HUNTER_AIM
					PrintToChatAll("Pouncing sideways to avoid wall");
				#endif

			return Plugin_Changed;
		}
	}

	// Angle pounce if survivor is watching the hunter approach
	// OPTIMIZED: removed duplicate GetClientAbsOrigin call (reused from wall detection or called once here)
	new Float:hunterPos2[3];
	GetClientAbsOrigin(botHunter, hunterPos2);
	new iSensitivity = GetConVarInt(hCvarAimOffsetSensitivityHunter);
	new iStraightProx = GetConVarInt(hCvarStraightPounceProximity);

	if( IsTargetWatchingAttacker(botHunter, iSensitivity) && GetSurvivorProximity(hunterPos2) > iStraightProx ) {
		new Float:pounceAngle = GaussianRNG( float(GetConVarInt(hCvarPounceAngleMean)), float(GetConVarInt(hCvarPounceAngleStd)) );
		AngleLunge( entLunge, pounceAngle );
		LimitLungeVerticality( entLunge );

			#if DEBUG_HUNTER_AIM
				new target = GetClientAimTarget(botHunter);
				if( IsSurvivor(target) ) {
					new String:targetName[32];
					GetClientName(target, targetName, sizeof(targetName));
					PrintToChatAll("The aim of hunter's target(%s) is %f degrees off", targetName, GetPlayerAimOffset(target, botHunter));
					PrintToChatAll("Angling pounce to throw off survivor");
				}

			#endif

		return Plugin_Changed;
	}

	return Plugin_Continue;
}

public bool:TracerayFilter( impactEntity, contentMask, any:rayOriginEntity ) {
	return impactEntity != rayOriginEntity;
}

// Credits to High Cookie and Standalone for working out the math behind hunter lunges
AngleLunge( lungeEntity, Float:turnAngle ) {
	// Get the original lunge's vector
	new Float:lungeVector[3];
	GetEntPropVector(lungeEntity, Prop_Send, "m_queuedLunge", lungeVector);
	new Float:x = lungeVector[X];
	new Float:y = lungeVector[Y];
	new Float:z = lungeVector[Z];

	// Create a new vector of the desired angle from the original
	turnAngle = DegToRad(turnAngle);
	new Float:forcedLunge[3];
	forcedLunge[X] = x * Cosine(turnAngle) - y * Sine(turnAngle);
	forcedLunge[Y] = x * Sine(turnAngle)   + y * Cosine(turnAngle);
	forcedLunge[Z] = z;

	SetEntPropVector(lungeEntity, Prop_Send, "m_queuedLunge", forcedLunge);
}

// Stop pounces being too high
LimitLungeVerticality( lungeEntity ) {
	// Get vertical angle restriction
	new Float:vertAngle = float(GetConVarInt(hCvarPounceVerticalAngle));
	// Get the original lunge's vector
	new Float:lungeVector[3];
	GetEntPropVector(lungeEntity, Prop_Send, "m_queuedLunge", lungeVector);
	new Float:x = lungeVector[X];
	new Float:y = lungeVector[Y];
	new Float:z = lungeVector[Z];

	vertAngle = DegToRad(vertAngle);
	new Float:flatLunge[3];
	// First rotation (around X axis)
	flatLunge[Y] = y * Cosine(vertAngle) - z * Sine(vertAngle);
	flatLunge[Z] = y * Sine(vertAngle)   + z * Cosine(vertAngle);
	// Second rotation (around Y axis)
	flatLunge[X] = x * Cosine(vertAngle) + z * Sine(vertAngle);
	flatLunge[Z] = x * -Sine(vertAngle)  + z * Cosine(vertAngle);

	SetEntPropVector(lungeEntity, Prop_Send, "m_queuedLunge", flatLunge);
}

/**
 * FIXED: Simplified Box-Muller Gaussian RNG.
 * Original had a broken sign-bit approach: z2 = y2*std - mean (subtracted mean instead of adding).
 * This version properly generates a single random value with the correct mean and std.
 * Also uses proper constant instead of "static Float:e = 2.71828".
*/
Float:GaussianRNG( Float:mean, Float:std ) {
	new Float:x1;
	new Float:x2;
	new Float:w;

	// Box-Muller algorithm — generate two independent uniform random variables in (0,1]
	// and transform them into standard normal distribution, then scale by std and shift by mean.
	do {
		new Float:random1 = GetRandomFloat( 0.0, 1.0 );
		new Float:random2 = GetRandomFloat( 0.0, 1.0 );

		x1 = (2.0 * random1) - 1.0;
		x2 = (2.0 * random2) - 1.0;
		w = (x1 * x1) + (x2 * x2);

	} while( w >= 1.0 || w == 0.0 );  // FIXED: added w==0 check to avoid div by zero

	// Box-Muller transform: convert uniform to standard normal
	w = SquareRoot( ( -2.0 * ( Logarithm(w) / w ) ) );

	// Use x1*w as the standard normal, scale and shift
	new Float:result = (x1 * w) * std + mean;

	// Determine sign randomly (50/50 left or right of the aim line)
	if( GetRandomFloat( 0.0, 1.0 ) >= 0.5 ) {
		result = -result;
	}

	#if DEBUG_HUNTER_RNG
		PrintToChatAll("GaussianRNG angle: %f (mean=%f, std=%f)", result, mean, std);
	#endif

	return result;
}

// FIXED: Added client validity check in timer callback
public Action:Timer_LungeInterval(Handle:timer, any:client) {
	if ( IsValidClient(client) && IsBotHunter(client) && IsPlayerAlive(client) ) {
		bCanLunge[client] = true;
	}
	return Plugin_Handled;
}