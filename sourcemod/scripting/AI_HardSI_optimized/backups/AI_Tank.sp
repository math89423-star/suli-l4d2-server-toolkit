#pragma semicolon 1

#define BoostForward 60.0      // Bhop base push force
#define BHOP_COOLDOWN 0.8      // Base minimum seconds between bhops
#define STREAK_TIMEOUT 1.2     // Seconds without bhop before streak resets
#define DEBUG_TANK 0

// Velocity
enum VelocityOverride {
	VelocityOvr_None = 0,
	VelocityOvr_Velocity,
	VelocityOvr_OnlyWhenNegative,
	VelocityOvr_InvertReuseVelocity
};

// --- ConVar handles ---
new Handle:hCvarTankBhop;
new Handle:hCvarTankRock;
new Handle:hCvarBhopMinDist;
new Handle:hCvarBhopMaxDist;
new Handle:hCvarBhopWallDist;

// v2.2 new cvars
new Handle:hCvarBhopAdaptive;
new Handle:hCvarBhopMomentum;
new Handle:hCvarBhopEvade;
new Handle:hCvarPunchJump;
new Handle:hCvarRageMultiplier;
new Handle:hCvarPunchInstakill;
new Handle:hCvarPunchDamage;
new Handle:hCvarAggroBhop;

// --- Per-tank state ---
new Float:fLastBhopTime[MAXPLAYERS];    // per-tank bhop cooldown tracker
new iBhopStreak[MAXPLAYERS];            // consecutive bhop count for momentum
new Float:fLastStreakTime[MAXPLAYERS];  // last bhop time for streak tracking

// Bibliography:
// TGMaster, Chanz - Infinite Jumping

public Tank_OnModuleStart() {
	hCvarTankBhop   = CreateConVar("ai_tank_bhop", "1", "Flag to enable bhop facsimile on AI tanks");
	hCvarTankRock   = CreateConVar("ai_tank_rock", "1", "Flag to enable rocks on AI tanks");

	// Smart bhop tuning
	hCvarBhopMinDist  = CreateConVar("ai_tank_bhop_min_dist", "150",
		"Minimum distance to nearest survivor for bhop. Closer than this = just punch, don't bhop.");
	hCvarBhopMaxDist  = CreateConVar("ai_tank_bhop_max_dist", "500",
		"Maximum distance to nearest survivor for bhop. Farther than this = close the gap normally first.");
	hCvarBhopWallDist = CreateConVar("ai_tank_bhop_wall_dist", "200",
		"Trace distance ahead for wall/obstacle check. Tank won't bhop if a wall is within this range. Set to 0 to disable.");

	// v2.2: Advanced Tank AI
	hCvarBhopAdaptive  = CreateConVar("ai_tank_bhop_adaptive", "1",
		"Adaptive bhop cooldown: faster speed = shorter cooldown. 0=use fixed 0.6s.");
	hCvarBhopMomentum  = CreateConVar("ai_tank_bhop_momentum", "1",
		"Momentum building: consecutive bhops get progressively stronger. 0=constant.");
	hCvarBhopEvade     = CreateConVar("ai_tank_bhop_evade", "1",
		"Obstacle evasion: when wall blocks path, try to bhop sideways around it. 0=just stop.");
	hCvarPunchJump     = CreateConVar("ai_tank_punch_jump", "1",
		"Punch-jump combo: Tank jumps while punching for hard-to-dodge aerial hits. 0=disable.");
	hCvarRageMultiplier = CreateConVar("ai_tank_rage_multiplier", "1.5",
		"Multiplier when Tank is on fire: reduces cooldown and increases push force.");
	hCvarPunchInstakill = CreateConVar("ai_tank_punch_instakill", "1",
		"v2.2 Instakill: Tank melee punch instantly incapacitates survivors. 0=vanilla damage.");
	hCvarPunchDamage   = CreateConVar("ai_tank_punch_damage", "150",
		"v2.2 Damage per Tank melee punch when instakill is enabled (>100 = guaranteed incap).");
	hCvarAggroBhop     = CreateConVar("ai_tank_aggro_bhop", "1",
		"v2.2 Aggressive bhop: Tank relentlessly bhops toward target regardless of survivor facing.");

	// Hook player_hurt for instakill punch
	HookEvent("player_hurt", OnTankPunch);
}

public Tank_OnModuleEnd() {
	UnhookEvent("player_hurt", OnTankPunch);
}

/***********************************************************************************************************************************************************************************

                                                            SMART TANK BHOP v2.2

    Context-aware bhop that only engages when it actually helps the Tank:
    ✓ Open space — no walls or obstacles within trace distance ahead
    ✓ Survivor is running away — chasing, not overshooting a stationary target
    ✓ Mid-range — not so close that punching is better, not so far that it wastes time
    ✓ Adaptive cooldown — faster speed = shorter cooldown, on-fire = even faster
    ✓ Momentum — consecutive bhops get progressively stronger
    ✓ Obstacle evasion — when wall blocks, try sideways bhop
    ✗ Near walls — would bounce off, losing momentum (unless evade enabled)
    ✗ Point-blank — just punch them (or punch-jump combo if enabled)
    ✗ Survivor standing ground — bhop would overshoot (unless aggro mode)
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
			buttons &= ~IN_JUMP;    // don't jump at low speed
			return Plugin_Continue;
		}

		// LOS check
		new bool:bHasSight = bool:GetEntProp(tank, Prop_Send, "m_hasVisibleThreats");
		if ( !bHasSight ) {
			buttons &= ~IN_JUMP;
			return Plugin_Continue;
		}

		// Distance check
		new Float:tankPos[3];
		GetClientAbsOrigin(tank, tankPos);
		new target = GetClientAimTarget(tank);
		new iDist = GetSurvivorProximity(tankPos, target);
		new iMinDist = GetConVarInt(hCvarBhopMinDist);
		new iMaxDist = GetConVarInt(hCvarBhopMaxDist);

		if ( iDist > iMaxDist ) {
			// Too far — close gap normally first
			buttons &= ~IN_ATTACK2;
			buttons &= ~IN_JUMP;
			return Plugin_Continue;
		}

		if ( iDist < iMinDist ) {
			// Too close — punch is better than bhop.
			buttons &= ~IN_ATTACK2;
			buttons &= ~IN_JUMP;

			// v2.2: Punch-jump combo — jump while punching at close range for aerial hits
			if ( GetConVarBool(hCvarPunchJump) ) {
				new Float:fNow = GetGameTime();
				if ( fLastBhopTime[tank] <= 0.0 || (fNow - fLastBhopTime[tank]) >= 0.6 ) {
					fLastBhopTime[tank] = fNow;
					buttons |= IN_JUMP;
					buttons |= IN_DUCK;
					// Small forward push for the punch-jump
					new Float:eyeAng[3];
					GetClientEyeAngles(tank, eyeAng);
					Client_Push( tank, eyeAng, BoostForward * 0.4, VelocityOverride:{VelocityOvr_None,VelocityOvr_None,VelocityOvr_None} );
				}
			}
			return Plugin_Continue;
		}

		// --- Wall/obstacle check ---
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

				// v2.2: Obstacle evasion — try to bhop sideways around the wall
				if ( GetConVarBool(hCvarBhopEvade) ) {
					// Check left side for clearance
					new Float:leftDir[3], Float:leftEnd[3];
					GetAngleVectors(eyeAngles, NULL_VECTOR, leftDir, NULL_VECTOR);
					NormalizeVector(leftDir, leftDir);
					ScaleVector(leftDir, -1.0); // left = negative right vector
					leftEnd[0] = tankPos[0] + leftDir[0] * float(iWallCheck);
					leftEnd[1] = tankPos[1] + leftDir[1] * float(iWallCheck);
					leftEnd[2] = tankPos[2] + leftDir[2] * float(iWallCheck);
					TR_TraceRayFilter(tankPos, leftEnd, MASK_PLAYERSOLID, RayType_EndPoint, TankTracerayFilter, tank);
					new bool:bLeftClear = !TR_DidHit();

					// Check right side for clearance
					new Float:rightEnd[3];
					rightEnd[0] = tankPos[0] - leftDir[0] * float(iWallCheck);
					rightEnd[1] = tankPos[1] - leftDir[1] * float(iWallCheck);
					rightEnd[2] = tankPos[2] - leftDir[2] * float(iWallCheck);
					TR_TraceRayFilter(tankPos, rightEnd, MASK_PLAYERSOLID, RayType_EndPoint, TankTracerayFilter, tank);
					new bool:bRightClear = !TR_DidHit();

					if ( bLeftClear || bRightClear ) {
						// Execute sideways evade bhop
						new Float:fNow = GetGameTime();
						if ( CheckBhopCooldown(tank, fNow) ) {
							RecordBhop(tank, fNow);
							buttons |= IN_DUCK;
							buttons |= IN_JUMP;
							// Push sideways
							if ( bLeftClear && bRightClear ) {
								Client_Push( tank, leftDir, BoostForward * 0.7, VelocityOverride:{VelocityOvr_None,VelocityOvr_None,VelocityOvr_None} );
							} else if ( bLeftClear ) {
								Client_Push( tank, leftDir, BoostForward * 0.7, VelocityOverride:{VelocityOvr_None,VelocityOvr_None,VelocityOvr_None} );
							} else {
								// rightDir = -leftDir
								new Float:rightDir[3];
								rightDir[0] = -leftDir[0]; rightDir[1] = -leftDir[1]; rightDir[2] = -leftDir[2];
								Client_Push( tank, rightDir, BoostForward * 0.7, VelocityOverride:{VelocityOvr_None,VelocityOvr_None,VelocityOvr_None} );
							}
						}
						return Plugin_Continue;
					}
				}

				// No evasion or both sides blocked — wall ahead, don't bhop into it
				#if DEBUG_TANK
				PrintToChatAll("[Tank Bhop] Wall detected ahead — skipping bhop");
				#endif
				buttons &= ~IN_ATTACK2;
				buttons &= ~IN_JUMP;
				return Plugin_Continue;
			}
		}

		// --- Survivor movement check ---
		// Skip if aggro bhop mode is enabled
		if ( !GetConVarBool(hCvarAggroBhop) && IsSurvivor(target) ) {
			new Float:survivorPos[3], Float:survivorVel[3];
			GetClientAbsOrigin(target, survivorPos);
			GetEntPropVector(target, Prop_Data, "m_vecVelocity", survivorVel);

			new Float:toSurvivor[3];
			toSurvivor[0] = survivorPos[0] - tankPos[0];
			toSurvivor[1] = survivorPos[1] - tankPos[1];
			toSurvivor[2] = 0.0; // XY plane only

			// Survivor standing still?
			new Float:survivorSpeedXY = SquareRoot(Pow(survivorVel[0], 2.0) + Pow(survivorVel[1], 2.0));
			if ( survivorSpeedXY < 30.0 ) {
				buttons &= ~IN_ATTACK2;
				buttons &= ~IN_JUMP;
				return Plugin_Continue;
			}

			// Survivor moving toward Tank? (dot < 0 means toward)
			new Float:dot = toSurvivor[0] * survivorVel[0] + toSurvivor[1] * survivorVel[1];
			if ( dot < 0.0 ) {
				buttons &= ~IN_ATTACK2;
				buttons &= ~IN_JUMP;
				return Plugin_Continue;
			}
		}

		// --- Bhop cooldown (adaptive or fixed) ---
		new Float:fNow = GetGameTime();
		if ( !CheckBhopCooldown(tank, fNow) ) {
			return Plugin_Continue;
		}

		// All checks passed — execute bhop
		{
			new Float:clientEyeAngles[3];
			GetClientEyeAngles(tank, clientEyeAngles);

			RecordBhop(tank, fNow);
			buttons &= ~IN_ATTACK2; // block rock during bhop
			buttons |= IN_DUCK;
			buttons |= IN_JUMP;

			// v2.2: Calculate push force with rage + momentum
			new Float:pushForce = BoostForward;
			if ( GetConVarBool(hCvarRageMultiplier) && IsTankOnFire(tank) ) {
				pushForce *= GetConVarFloat(hCvarRageMultiplier);
			}
			if ( GetConVarBool(hCvarBhopMomentum) ) {
				// Each consecutive bhop adds 10% more force, up to 2x
				new Float:momentumMult = 1.0 + (float(iBhopStreak[tank]) * 0.1);
				if ( momentumMult > 2.0 ) momentumMult = 2.0;
				pushForce *= momentumMult;
			}

			if(buttons & IN_FORWARD) {
				Client_Push( tank, clientEyeAngles, pushForce, VelocityOverride:{VelocityOvr_None,VelocityOvr_None,VelocityOvr_None} );
			}

			if(buttons & IN_BACK) {
				clientEyeAngles[1] += 180.0;
				Client_Push( tank, clientEyeAngles, pushForce, VelocityOverride:{VelocityOvr_None,VelocityOvr_None,VelocityOvr_None} );
			}

			if(buttons & IN_MOVELEFT) {
				clientEyeAngles[1] += 90.0;
				Client_Push( tank, clientEyeAngles, pushForce, VelocityOverride:{VelocityOvr_None,VelocityOvr_None,VelocityOvr_None} );
			}

			if(buttons & IN_MOVERIGHT) {
				clientEyeAngles[1] += -90.0;
				Client_Push( tank, clientEyeAngles, pushForce, VelocityOverride:{VelocityOvr_None,VelocityOvr_None,VelocityOvr_None} );
			}

			#if DEBUG_TANK
			PrintToChatAll("[Tank Bhop v2.2] BHOP! dist=%d speed=%.0f streak=%d force=%.0f", iDist, currentspeed, iBhopStreak[tank], pushForce);
			#endif
		}
	}

	return Plugin_Continue;
}

// --- Cooldown check (adaptive or fixed) ---
stock bool:CheckBhopCooldown(tank, Float:fNow) {
	if ( fLastBhopTime[tank] <= 0.0 ) return true;

	new Float:cooldown = BHOP_COOLDOWN;

	if ( GetConVarBool(hCvarBhopAdaptive) ) {
		// Faster speed = shorter cooldown. Speed 190→cooldown full, speed 400→cooldown ~half
		new Float:fVelocity[3];
		GetEntPropVector(tank, Prop_Data, "m_vecVelocity", fVelocity);
		new Float:speed = SquareRoot(Pow(fVelocity[0], 2.0) + Pow(fVelocity[1], 2.0));
		if ( speed > 190.0 ) {
			cooldown = BHOP_COOLDOWN / (1.0 + (speed - 190.0) / 300.0);
			if ( cooldown < 0.25 ) cooldown = 0.25; // hard floor
		}
	}

	// v2.2: Rage multiplier reduces cooldown when on fire
	if ( GetConVarBool(hCvarRageMultiplier) && IsTankOnFire(tank) ) {
		cooldown /= GetConVarFloat(hCvarRageMultiplier);
		if ( cooldown < 0.15 ) cooldown = 0.15;
	}

	return (fNow - fLastBhopTime[tank]) >= cooldown;
}

// --- Record a bhop for cooldown + momentum tracking ---
stock RecordBhop(tank, Float:fNow) {
	// Streak: reset if too much time passed since last bhop
	if ( fNow - fLastStreakTime[tank] > STREAK_TIMEOUT ) {
		iBhopStreak[tank] = 0;
	}
	iBhopStreak[tank]++;
	fLastStreakTime[tank] = fNow;
	fLastBhopTime[tank] = fNow;
}

// --- Check if Tank is on fire ---
stock bool:IsTankOnFire(tank) {
	return bool:GetEntProp(tank, Prop_Data, "m_bIsOnFire");
}

/***********************************************************************************************************************************************************************************

                                                        PUNCH INSTAKILL (v2.2)

***********************************************************************************************************************************************************************************/

public Action:OnTankPunch(Handle:event, const String:name[], bool:dontBroadcast) {
	if ( !GetConVarBool(hCvarPunchInstakill) ) return Plugin_Continue;

	// Get victim and attacker
	new victim = GetClientOfUserId(GetEventInt(event, "userid"));
	new attacker = GetClientOfUserId(GetEventInt(event, "attacker"));

	if ( victim <= 0 || attacker <= 0 ) return Plugin_Continue;
	if ( !IsSurvivor(victim) ) return Plugin_Continue;
	if ( !IsTank(attacker) || !IsFakeClient(attacker) ) return Plugin_Continue;

	// Only apply instakill to melee (Tank punch), not rock hits
	new weaponid = GetEventInt(event, "weaponid");
	// weaponid 23 = tank_claw, we only want melee hits
	if ( weaponid != 23 ) return Plugin_Continue;

	new damage = GetConVarInt(hCvarPunchDamage);
	new currentHealth = GetClientHealth(victim);
	if ( currentHealth <= damage ) {
		// Instakill — damage exceeds remaining health, instant incap
		SetEntProp(victim, Prop_Send, "m_iHealth", 0);
	} else {
		SetEntityHealth(victim, currentHealth - damage);
	}

	#if DEBUG_TANK
	PrintToChatAll("[Tank Instakill] Tank punched %N for %d damage", victim, damage);
	#endif

	return Plugin_Continue;
}

/***********************************************************************************************************************************************************************************

                                                        UTILITY FUNCTIONS

***********************************************************************************************************************************************************************************/

public bool:TankTracerayFilter( impactEntity, contentMask, any:rayOriginEntity ) {
	return impactEntity != rayOriginEntity;
}

stock Client_Push(client, Float:clientEyeAngle[3], Float:power, VelocityOverride:override[3]=VelocityOvr_None) {
	new Float:forwardVector[3];
	new Float:newVel[3];

	GetAngleVectors(clientEyeAngle, forwardVector, NULL_VECTOR, NULL_VECTOR);
	NormalizeVector(forwardVector, forwardVector);
	ScaleVector(forwardVector, power);

	GetEntPropVector(client, Prop_Send, "m_vecVelocity", newVel);

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
