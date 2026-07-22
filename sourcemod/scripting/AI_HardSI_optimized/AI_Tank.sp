#pragma semicolon 1

#define BoostForward 60.0 // Bhop push force
#define BHOP_COOLDOWN 0.8 // Minimum seconds between bhops
#define DEBUG_TANK 0

// Velocity
enum VelocityOverride {
	VelocityOvr_None = 0,
	VelocityOvr_Velocity,
	VelocityOvr_OnlyWhenNegative,
	VelocityOvr_InvertReuseVelocity
};

new Handle:hCvarTankBhop;
new Handle:hCvarTankRock;
new Handle:hCvarBhopMinDist;
new Handle:hCvarBhopMaxDist;
new Handle:hCvarBhopWallDist;

new Float:fLastBhopTime[MAXPLAYERS]; // per-tank bhop cooldown tracker

// Bibliography:
// TGMaster, Chanz - Infinite Jumping

public Tank_OnModuleStart() {
	hCvarTankBhop = CreateConVar("ai_tank_bhop", "1", "Flag to enable bhop facsimile on AI tanks");
	hCvarTankRock = CreateConVar("ai_tank_rock", "1", "Flag to enable rocks on AI tanks");

	// Smart bhop tuning
	hCvarBhopMinDist = CreateConVar("ai_tank_bhop_min_dist", "150",
		"Minimum distance to nearest survivor for bhop. Closer than this = just punch, don't bhop.");
	hCvarBhopMaxDist = CreateConVar("ai_tank_bhop_max_dist", "500",
		"Maximum distance to nearest survivor for bhop. Farther than this = close the gap normally first.");
	hCvarBhopWallDist = CreateConVar("ai_tank_bhop_wall_dist", "200",
		"Trace distance ahead for wall/obstacle check. Tank won't bhop if a wall is within this range. Set to 0 to disable.");
}

public Tank_OnModuleEnd() {
}

/***********************************************************************************************************************************************************************************

															SMART TANK BHOP

	Context-aware bhop that only engages when it actually helps the Tank:
	✓ Open space — no walls or obstacles within trace distance ahead
	✓ Survivor is running away — chasing, not overshooting a stationary target
	✓ Mid-range — not so close that punching is better, not so far that it wastes time
	✓ Cooldown — doesn't spam jump every tick, respects bhop rhythm
	✗ Near walls — would bounce off, losing momentum
	✗ Point-blank — just punch them
	✗ Survivor standing ground — bhop would overshoot
	✗ Ladders — blocked anyway

***********************************************************************************************************************************************************************************/

public Action:Tank_OnPlayerRunCmd( tank, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon ) {
	// Block rock throws if disabled
	if ( !GetConVarBool(hCvarTankRock) ) {
		buttons &= ~IN_ATTACK2;
	}

	if( GetConVarBool(hCvarTankBhop) ) {
		new flags = GetEntityFlags(tank);

		// Skip if not on ground or on ladder
		if ( !(flags & FL_ONGROUND) || (GetEntityMoveType(tank) & MOVETYPE_LADDER) ) {
			buttons &= ~IN_JUMP;
			buttons &= ~IN_DUCK;
			return Plugin_Continue;
		}

		// --- Gather data ---
		new Float:fVelocity[3];
		GetEntPropVector(tank, Prop_Data, "m_vecVelocity", fVelocity);
		new Float:currentspeed = SquareRoot(Pow(fVelocity[0], 2.0) + Pow(fVelocity[1], 2.0));
		// Not enough momentum — bhop needs speed to chain
		if ( currentspeed < 190.0 ) {
			buttons &= ~IN_ATTACK2; // block rock when chasing
			return Plugin_Continue;
		}

		// LOS check
		new bool:bHasSight = bool:GetEntProp(tank, Prop_Send, "m_hasVisibleThreats");
		if ( !bHasSight ) {
			return Plugin_Continue;
		}

		// Distance check
		new Float:tankPos[3];
		GetClientAbsOrigin(tank, tankPos);
		new target = GetClientAimTarget(tank);
		new iDist = GetSurvivorProximity(tankPos, target);
		new iMinDist = GetConVarInt(hCvarBhopMinDist);
		new iMaxDist = GetConVarInt(hCvarBhopMaxDist);

		if ( iDist < iMinDist || iDist > iMaxDist ) {
			// Too close → punch is better; too far → close gap normally
			buttons &= ~IN_ATTACK2;
			return Plugin_Continue;
		}

		// --- Wall/obstacle check ---
		// Trace forward to see if there's a wall or obstacle ahead.
		// If the path is blocked, bhop is counterproductive (Tank bounces off wall).
		new iWallCheck = GetConVarInt(hCvarBhopWallDist);
		if ( iWallCheck > 0 ) {
			new Float:eyeAngles[3];
			GetClientEyeAngles(tank, eyeAngles);
			new Float:fwd[3];
			GetAngleVectors(eyeAngles, fwd, NULL_VECTOR, NULL_VECTOR);
			NormalizeVector(fwd, fwd);

			new Float:endPos[3];
			endPos[0] = tankPos[0] + fwd[0] * float(iWallCheck);
			endPos[1] = tankPos[1] + fwd[1] * float(iWallCheck);
			endPos[2] = tankPos[2] + fwd[2] * float(iWallCheck);

			TR_TraceRayFilter(tankPos, endPos, MASK_PLAYERSOLID, RayType_EndPoint, TankTracerayFilter, tank);
			if ( TR_DidHit() ) {
				// Wall ahead — don't bhop into it
				#if DEBUG_TANK
				PrintToChatAll("[Tank Bhop] Wall detected ahead — skipping bhop");
				#endif
				buttons &= ~IN_ATTACK2;
				return Plugin_Continue;
			}
		}

		// --- Survivor movement check ---
		// If the target survivor is NOT running away (standing ground / approaching),
		// bhop is detrimental — it would overshoot them.
		// Check: dot product of (Tank→Survivor) and (Survivor velocity).
		// Positive = survivor moving away from Tank → bhop to chase.
		// Negative/zero = survivor holding ground or coming at Tank → punch instead.
		if ( IsSurvivor(target) ) {
			new Float:survivorPos[3], Float:survivorVel[3];
			GetClientAbsOrigin(target, survivorPos);
			GetEntPropVector(target, Prop_Data, "m_vecVelocity", survivorVel);

			new Float:toSurvivor[3];
			toSurvivor[0] = survivorPos[0] - tankPos[0];
			toSurvivor[1] = survivorPos[1] - tankPos[1];
			// Use XY plane only — Z doesn't matter for chase decisions
			toSurvivor[2] = 0.0;

			// Survivor standing still?
			new Float:survivorSpeedXY = SquareRoot(Pow(survivorVel[0], 2.0) + Pow(survivorVel[1], 2.0));
			if ( survivorSpeedXY < 30.0 ) {
				// Survivor is nearly stationary — bhop would overshoot. Just punch.
				buttons &= ~IN_ATTACK2;
				return Plugin_Continue;
			}

			// Survivor moving toward Tank? (dot < 0 means toward)
			new Float:dot = toSurvivor[0] * survivorVel[0] + toSurvivor[1] * survivorVel[1];
			if ( dot < 0.0 ) {
				// Survivor is approaching the Tank — DON'T bhop, close distance and punch
				buttons &= ~IN_ATTACK2;
				return Plugin_Continue;
			}
		}

		// --- Bhop cooldown ---
		new Float:fNow = GetGameTime();
		if ( fLastBhopTime[tank] > 0.0 && (fNow - fLastBhopTime[tank]) < BHOP_COOLDOWN ) {
			// Still on cooldown from last bhop
			return Plugin_Continue;
		}

		// All checks passed — execute bhop
		{
			new Float:clientEyeAngles[3];
			GetClientEyeAngles(tank, clientEyeAngles);

			fLastBhopTime[tank] = fNow;
			buttons &= ~IN_ATTACK2; // block rock during bhop
			buttons |= IN_DUCK;
			buttons |= IN_JUMP;

			if(buttons & IN_FORWARD) {
				Client_Push( tank, clientEyeAngles, BoostForward, VelocityOverride:{VelocityOvr_None,VelocityOvr_None,VelocityOvr_None} );
			}

			if(buttons & IN_BACK) {
				clientEyeAngles[1] += 180.0;
				Client_Push( tank, clientEyeAngles, BoostForward, VelocityOverride:{VelocityOvr_None,VelocityOvr_None,VelocityOvr_None} );
			}

			if(buttons & IN_MOVELEFT) {
				clientEyeAngles[1] += 90.0;
				Client_Push( tank, clientEyeAngles, BoostForward, VelocityOverride:{VelocityOvr_None,VelocityOvr_None,VelocityOvr_None} );
			}

			if(buttons & IN_MOVERIGHT) {
				clientEyeAngles[1] += -90.0;
				Client_Push( tank, clientEyeAngles, BoostForward, VelocityOverride:{VelocityOvr_None,VelocityOvr_None,VelocityOvr_None} );
			}

			#if DEBUG_TANK
			PrintToChatAll("[Tank Bhop] BHOP! dist=%d speed=%.0f", iDist, currentspeed);
			#endif
		}
	}

	return Plugin_Continue;
}

public bool:TankTracerayFilter( impactEntity, contentMask, any:rayOriginEntity ) {
	return impactEntity != rayOriginEntity;
}

stock Client_Push(client, Float:clientEyeAngle[3], Float:power, VelocityOverride:override[3]=VelocityOvr_None) {
	new Float:forwardVector[3];
	new Float:newVel[3];

	GetAngleVectors(clientEyeAngle, forwardVector, NULL_VECTOR, NULL_VECTOR);
	NormalizeVector(forwardVector, forwardVector);
	ScaleVector(forwardVector, power);

	GetEntPropVector(client, Prop_Send, "m_vecVelocity", newVel);  // FIXED: was m_vecOrigin (wrong netprop)

	for( new i = 0; i < 3; i++ ) {
		switch( override[i] ) {
			case VelocityOvr_Velocity: {
				newVel[i] = 0.0;
			}
			case VelocityOvr_OnlyWhenNegative: {
				if( newVel[i] < 0.0 ) {
					newVel[i] = 0.0;
				}
			}
			case VelocityOvr_InvertReuseVelocity: {
				if( newVel[i] < 0.0 ) {
					newVel[i] *= -1.0;
				}
			}
		}

		newVel[i] += forwardVector[i];
	}

	TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, newVel);
}

// Prevent AI Tank from using rock-throw (sequence 50) which makes them stationary and vulnerable.
// Replace with either punch sequence (49 or 51).
public Action:L4D2_OnSelectTankAttack(client, &sequence) {
	if (IsFakeClient(client) && sequence == 50) {
		sequence = GetRandomInt(0, 1) ? 49 : 51;
		return Plugin_Handled;
	}
	return Plugin_Changed;
}