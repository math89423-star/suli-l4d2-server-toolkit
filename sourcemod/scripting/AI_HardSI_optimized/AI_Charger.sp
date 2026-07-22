#pragma semicolon 1

#define DEBUG_CHARGER_TARGET 0

// custom convar
new Handle:hCvarChargeProximity;
new Handle:hCvarAimOffsetSensitivityCharger;
new Handle:hCvarHealthThresholdCharger;
new bShouldCharge[MAXPLAYERS]; // manual tracking of charge cooldown

public Charger_OnModuleStart() {
	// Charge proximity
	hCvarChargeProximity = CreateConVar("ai_charge_proximity", "300", "How close a charger will approach before charging");
	// Aim offset sensitivity
	hCvarAimOffsetSensitivityCharger = CreateConVar("ai_aim_offset_sensitivity_charger",
									"20",
									"If the charger has a target, it will not straight pounce if the target's aim on the horizontal axis is within this radius",
									FCVAR_NONE,
									true, 0.0, true, 179.0);
	// Health threshold
	hCvarHealthThresholdCharger = CreateConVar("ai_health_threshold_charger", "300", "Charger will charge if its health drops to this level");
}

public Charger_OnModuleEnd() {
}

/***********************************************************************************************************************************************************************************

																KEEP CHARGE ON COOLDOWN UNTIL WITHIN PROXIMITY

***********************************************************************************************************************************************************************************/

// Initialise spawned chargers
public Action:Charger_OnSpawn(botCharger) {
	bShouldCharge[botCharger] = false;
	return Plugin_Handled;
}

public Action:Charger_OnPlayerRunCmd(charger, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon) {
	// prevent charge until survivors are within the defined proximity
	new Float:chargerPos[3];
	GetClientAbsOrigin(charger, chargerPos);
	new target = GetClientAimTarget(charger);
	new iSurvivorProximity = GetSurvivorProximity(chargerPos, target);
	new chargerHealth = GetEntProp(charger, Prop_Send, "m_iHealth");
	if( chargerHealth > GetConVarInt(hCvarHealthThresholdCharger) && iSurvivorProximity > GetConVarInt(hCvarChargeProximity) ) {
		if( !bShouldCharge[charger] ) {
			BlockCharge(charger);
			return Plugin_Changed;
		}
	} else {
		bShouldCharge[charger] = true;
	}
	return Plugin_Continue;
}

BlockCharge(charger) {
	new chargeEntity = GetEntPropEnt(charger, Prop_Send, "m_customAbility");
	if (chargeEntity > 0) {  // charger entity persists for a short while after death; check ability entity is valid
		SetEntPropFloat(chargeEntity, Prop_Send, "m_timestamp", GetGameTime() + 0.1); // keep extending end of cooldown period
	}
}

Charger_OnCharge(charger) {
	// Assign charger a new survivor target if they are not specifically targetting anybody with their charge or their target is watching
	new aimTarget = GetClientAimTarget(charger);
	if( !IsSurvivor(aimTarget) || IsTargetWatchingAttacker(charger, GetConVarInt(hCvarAimOffsetSensitivityCharger)) ) {
		new Float:chargerPos[3];
		GetClientAbsOrigin(charger, chargerPos);
		new newTarget = GetClosestSurvivor(chargerPos, aimTarget);	// try and find another closeby survivor
		if( newTarget > 0 && newTarget != -1 && GetSurvivorProximity(chargerPos, newTarget) <= GetConVarInt(hCvarChargeProximity) ) {
			aimTarget = newTarget;

			#if DEBUG_CHARGER_TARGET
				new String:targetName[32];
				GetClientName(newTarget, targetName, sizeof(targetName));
				PrintToChatAll("Charger forced to charge survivor %s", targetName);
			#endif

		}
	}

	ChargePrediction(charger, aimTarget);
}

// OPTIMIZED: Added basic velocity-based prediction to lead the target
ChargePrediction(charger, survivor) {
	if( !IsBotCharger(charger) || !IsSurvivor(survivor) ) {
		return;
	}
	new Float:survivorPos[3];
	new Float:chargerPos[3];
	new Float:attackDirection[3];
	new Float:attackAngle[3];

	GetClientAbsOrigin(charger, chargerPos);
	GetClientAbsOrigin(survivor, survivorPos);

	// Lead the target: predict where survivor will be based on their velocity
	new Float:survivorVel[3];
	GetEntPropVector(survivor, Prop_Data, "m_vecVelocity", survivorVel);

	// Simple prediction: lead by ~0.3 seconds (charger charge speed is roughly 500-600 units/s)
	// Scale lead by distance (more lead when farther away)
	new Float:dist = GetVectorDistance(chargerPos, survivorPos);
	new Float:leadTime = dist / 600.0 * 0.3; // roughly 0.3s lead at charge range
	if ( leadTime > 0.5 ) leadTime = 0.5; // cap lead time
	if ( leadTime < 0.0 ) leadTime = 0.0;

	survivorPos[0] += survivorVel[0] * leadTime;
	survivorPos[1] += survivorVel[1] * leadTime;
	// Don't predict Z (survivors can't fly)

	MakeVectorFromPoints( chargerPos, survivorPos, attackDirection );
	GetVectorAngles(attackDirection, attackAngle);
	TeleportEntity(charger, NULL_VECTOR, attackAngle, NULL_VECTOR);
}