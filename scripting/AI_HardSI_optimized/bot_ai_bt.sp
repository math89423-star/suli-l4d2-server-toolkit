#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#include "hardcoop_util.sp"
#include "bt_core.inc"
stock bool Wave_IsStrikeOrdered() { return false; }
stock bool Wave_IsStaging() { return false; }
#include "bt_common.inc"

public Plugin myinfo = {
    name = "Bot AI BT - Survivor",
    author = "Muse Spark",
    description = "Survivor bot AI via Behavior Tree (follow/scout/door/scavenge/rescue/combat + acid/mounted gun, rescue 4-branch + heal + dodge + flow + formation, priority fix 1.7.3)",
    version = "1.7.3",
    url = ""
};

// Globals
int g_iTickCounter[MAXPLAYERS+1];
float g_fBotLastCombatSeen[MAXPLAYERS+1];
#define TICK_INTERVAL 2
int g_iBotBTRoot = -1;

// ConVars for aggressive preset (mirrors ib_ settings)
ConVar g_hCvarTargetRange;
ConVar g_hCvarTargetRangeShotgun;
ConVar g_hCvarIgnoreDociles;
ConVar g_hCvarMeleeEnabled;
ConVar g_hCvarMeleeMaxTeam;
ConVar g_hCvarMeleeAttackRange;
ConVar g_hCvarAutoShove;
ConVar g_hCvarShovePumpChance;
ConVar g_hCvarGrenadeEnabled;
ConVar g_hCvarGrenadeHordeMult;

// Helpers
stock bool IsSurvivorBot(int client) {
    return IsClientInGame(client) && GetClientTeam(client) == 2 && IsFakeClient(client) && IsPlayerAlive(client);
}
stock bool IsSurvivorHuman(int client) {
    return IsClientInGame(client) && GetClientTeam(client) == 2 && !IsFakeClient(client) && IsPlayerAlive(client);
}
stock int GetClosestHumanSurvivor(float pos[3]) {
    int best = -1; float bestDist = 999999.0;
    for (int i=1;i<=MaxClients;i++) if (IsSurvivorHuman(i)) {
        float p[3]; GetClientAbsOrigin(i,p);
        float d = GetVectorDistance(pos,p);
        if (d < bestDist) { bestDist=d; best=i; }
    }
    return best;
}
stock int GetClosestIncappedTeammate(float pos[3]) {
    int best=-1; float bestDist=999999.0;
    for (int i=1;i<=MaxClients;i++) if (IsClientInGame(i) && GetClientTeam(i)==2 && IsPlayerAlive(i) && GetEntProp(i,Prop_Send,"m_isIncapacitated")) {
        float p[3]; GetClientAbsOrigin(i,p);
        float d=GetVectorDistance(pos,p);
        if (d<bestDist) {bestDist=d; best=i;}
    }
    return best;
}
stock int GetClosestPinnedTeammate(float pos[3]) {
    int best=-1; float bestDist=999999.0;
    for (int i=1;i<=MaxClients;i++) if (IsSurvivor(i) && IsPinned(i)) {
        float p[3]; GetClientAbsOrigin(i,p);
        float d = GetVectorDistance(pos,p);
        if (d < 1000.0 && d < bestDist) { bestDist=d; best=i; }
    }
    return best;
}
stock int GetClosestHangingTeammate(float pos[3]) {
    int best=-1; float bestDist=999999.0;
    for (int i=1;i<=MaxClients;i++) if (IsClientInGame(i) && GetClientTeam(i)==2 && IsPlayerAlive(i) && GetEntProp(i, Prop_Send, "m_isHangingFromLedge")) {
        float p[3]; GetClientAbsOrigin(i,p);
        float d = GetVectorDistance(pos,p);
        if (d < 800.0 && d < bestDist) { bestDist=d; best=i; }
    }
    return best;
}
stock int GetClosestDeadWithDefib(float pos[3]) {
    // 找携带电击器的 bot 附近的死亡队友
    int best=-1; float bestDist=999999.0;
    for (int i=1;i<=MaxClients;i++) if (IsClientInGame(i) && GetClientTeam(i)==2 && !IsPlayerAlive(i)) {
        // 检查是否有 bot 携带电击器且在范围内
        bool hasDefib=false;
        for(int b=1;b<=MaxClients;b++) if (IsSurvivorBot(b) && IsPlayerAlive(b)) {
            int ent = GetPlayerWeaponSlot(b, 3);
            if (ent>0) {
                char cls[32]; GetEdictClassname(ent, cls, sizeof(cls));
                if (StrContains(cls,"defibrillator")!=-1) { hasDefib=true; break; }
            }
        }
        if (!hasDefib) return -1;
        float p[3]; GetClientAbsOrigin(i,p);
        float d = GetVectorDistance(pos,p);
        if (d < 2500.0 && d < bestDist) { bestDist=d; best=i; }
    }
    return best;
}
stock bool IsTankNear(float pos[3], float radius) {
    for(int i=1;i<=MaxClients;i++) if (IsClientInGame(i) && GetClientTeam(i)==3 && IsPlayerAlive(i) && GetEntProp(i,Prop_Send,"m_zombieClass")==8) {
        float p[3]; GetClientAbsOrigin(i,p);
        if (GetVectorDistance(pos,p) < radius) return true;
    }
    return false;
}
stock bool HasMedkit(int client) {
    int ent = GetPlayerWeaponSlot(client, 3);
    if (ent>0 && IsValidEntity(ent)) {
        char cls[32]; GetEdictClassname(ent, cls, sizeof(cls));
        if (StrContains(cls, "first_aid_kit") != -1) return true;
    }
    return false;
}
stock bool HasGrenade(int client) {
    int ent = GetPlayerWeaponSlot(client, 2);
    if (ent>0 && IsValidEntity(ent)) {
        char cls[32]; GetEdictClassname(ent, cls, sizeof(cls));
        if (StrContains(cls, "pipe_bomb")!=-1 || StrContains(cls,"molotov")!=-1 || StrContains(cls,"vomitjar")!=-1) return true;
    }
    return false;
}
stock int GetClosestWeaponOnGround(float pos[3]) {
    int ent = -1;
    int best=-1; float bestDist=999999.0;
    while ((ent = FindEntityByClassname(ent, "weapon_*")) != -1) {
        if (ent <= MaxClients) continue;
        int owner = GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity");
        if (owner >0) continue;
        float p[3]; GetEntPropVector(ent, Prop_Send, "m_vecOrigin", p);
        float d = GetVectorDistance(pos,p);
        if (d < 600.0 && d < bestDist) { bestDist=d; best=ent; }
    }
    return best;
}
stock bool IsItemFlowValid(float itemPos[3]) {
    int itemFlow = GetFlow(itemPos);
    if (itemFlow < 0) return true; // no nav, allow
    int lead = SI_GetLeadFlow();
    if (lead < 0) return true;
    int diff = itemFlow - lead;
    // 允许前方 400 内或后方 150 内，防大幅回头
    if (diff > -150 && diff < 400) return true;
    return false;
}
stock int CountTeamWeaponType(const char[] typeSubstr) {
    int cnt=0;
    for(int i=1;i<=MaxClients;i++) if (IsClientInGame(i) && GetClientTeam(i)==2 && IsPlayerAlive(i)) {
        int pri = GetPlayerWeaponSlot(i, 0);
        if (pri>0) {
            char cls[32]; GetEdictClassname(pri, cls, sizeof(cls));
            if (StrContains(cls, typeSubstr)!=-1) cnt++;
        }
        int sec = GetPlayerWeaponSlot(i, 1);
        if (sec>0) {
            char cls[32]; GetEdictClassname(sec, cls, sizeof(cls));
            if (StrContains(cls, typeSubstr)!=-1) cnt++;
        }
    }
    return cnt;
}
stock int CountSpareMedkits(float pos[3], float radius) {
    int cnt=0; int ent=-1;
    while ((ent = FindEntityByClassname(ent, "weapon_first_aid_kit")) != -1) {
        if (GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity")>0) continue;
        float p[3]; GetEntPropVector(ent, Prop_Send, "m_vecOrigin", p);
        if (GetVectorDistance(pos,p) < radius) cnt++;
    }
    return cnt;
}
stock int FindVisibleSI(int client, float maxDist) {
    float myPos[3]; GetClientAbsOrigin(client, myPos);
    int best=-1; float bestDist=999999.0;
    for (int i=1;i<=MaxClients;i++) if (IsClientInGame(i) && GetClientTeam(i)==3 && IsPlayerAlive(i)) {
        float p[3]; GetClientAbsOrigin(i,p);
        float d = GetVectorDistance(myPos,p);
        if (d > maxDist) continue;
        // LOS check
        float myEye[3], tEye[3];
        GetClientEyePosition(client, myEye);
        GetClientEyePosition(i, tEye);
        TR_TraceRayFilter(myEye, tEye, MASK_SOLID, RayType_EndPoint, LOS_TraceFilter, client);
        if (TR_DidHit() && TR_GetEntityIndex() != i) continue;
        // docile check
        if (g_hCvarIgnoreDociles != null && g_hCvarIgnoreDociles.BoolValue) {
            // if SI is docile (not attacking), skip? Simple: check m_hasVisibleThreats of SI? If SI has no visible threats, it's docile
            if (!GetEntProp(i, Prop_Send, "m_hasVisibleThreats")) continue;
        }
        if (d < bestDist) { bestDist=d; best=i; }
    }
    return best;
}
stock int CountCommonInRange(float pos[3], float radius) {
    int cnt=0;
    int ent=-1;
    while ((ent = FindEntityByClassname(ent, "infected")) != -1) {
        if (!IsValidEntity(ent)) continue;
        float p[3]; GetEntPropVector(ent, Prop_Send, "m_vecOrigin", p);
        if (GetVectorDistance(pos,p) < radius) cnt++;
        if (cnt>50) break;
    }
    return cnt;
}

// BT Conditions
BT_Status BotCond_IsIncapacitated(int client) {
    return GetEntProp(client, Prop_Send, "m_isIncapacitated") ? BT_SUCCESS : BT_FAILURE;
}
BT_Status BotCond_TeammatePinnedNearby(int client) {
    float pos[3]; GetClientAbsOrigin(client,pos);
    int t = GetClosestPinnedTeammate(pos);
    if (t>0) {
        float tPos[3]; GetClientAbsOrigin(t,tPos);
        if (IsTankNear(tPos, 700.0)) return BT_FAILURE;
        BB_SetInt(client, "rescue_target", t); BB_SetInt(client, "rescue_kind", 1); return BT_SUCCESS;
    }
    return BT_FAILURE;
}
BT_Status BotCond_TeammateIncappedNearby(int client) {
    float pos[3]; GetClientAbsOrigin(client,pos);
    int t = GetClosestIncappedTeammate(pos);
    if (t>0) {
        float tPos[3]; GetClientAbsOrigin(t, tPos);
        if (GetVectorDistance(pos, tPos) < 800.0) {
            if (IsTankNear(tPos, 700.0)) return BT_FAILURE;
            if (FindVisibleSI(client, 400.0) > 0) return BT_FAILURE;
            BB_SetInt(client, "rescue_target", t); BB_SetInt(client, "rescue_kind", 2); return BT_SUCCESS;
        }
    }
    return BT_FAILURE;
}
BT_Status BotCond_TeammateHangingNearby(int client) {
    float pos[3]; GetClientAbsOrigin(client,pos);
    int t = GetClosestHangingTeammate(pos);
    if (t>0) {
        float tPos[3]; GetClientAbsOrigin(t,tPos);
        if (IsTankNear(tPos, 700.0)) return BT_FAILURE;
        if (FindVisibleSI(client, 400.0) > 0) return BT_FAILURE;
        BB_SetInt(client, "rescue_target", t); BB_SetInt(client, "rescue_kind", 0); return BT_SUCCESS;
    }
    return BT_FAILURE;
}
BT_Status BotCond_DeadWithDefibNearby(int client) {
    float pos[3]; GetClientAbsOrigin(client,pos);
    int t = GetClosestDeadWithDefib(pos);
    if (t>0) { BB_SetInt(client, "rescue_target", t); BB_SetInt(client, "rescue_kind", 3); return BT_SUCCESS; }
    return BT_FAILURE;
}
BT_Status BotCond_IsBlackAndWhite(int client) {
    if (GetEntProp(client, Prop_Send, "m_bIsOnThirdStrike")) return BT_SUCCESS;
    if (GetEntProp(client, Prop_Send, "m_currentReviveCount") >= 2) return BT_SUCCESS;
    return BT_FAILURE;
}
BT_Status BotCond_NeedsHealSelf(int client) {
    int perm = GetEntProp(client, Prop_Send, "m_iHealth");
    float pos[3]; GetClientAbsOrigin(client,pos);
    int spare = CountSpareMedkits(pos, 500.0);
    int threshold = (spare >= 2) ? 60 : 40;
    if (BotCond_IsBlackAndWhite(client)==BT_SUCCESS && HasMedkit(client)) return BT_SUCCESS;
    if (perm < threshold && HasMedkit(client)) {
        if (FindVisibleSI(client, 400.0) <=0) return BT_SUCCESS;
    }
    if (perm < 35) {
        int slot = GetPlayerWeaponSlot(client, 3);
        if (slot>0) {
            char cls[32]; GetEdictClassname(slot, cls, sizeof(cls));
            if (StrContains(cls,"pain_pills")!=-1 || StrContains(cls,"adrenaline")!=-1) return BT_SUCCESS;
        }
    }
    return BT_FAILURE;
}
BT_Status BotCond_TeammateNeedsHeal(int client) {
    float pos[3]; GetClientAbsOrigin(client,pos);
    if (!HasMedkit(client)) return BT_FAILURE;
    // 仅安全时救：400 内无 SI
    if (FindVisibleSI(client, 400.0) > 0) return BT_FAILURE;
    int best=-1; int lowest=1000;
    for(int i=1;i<=MaxClients;i++) if (IsClientInGame(i) && GetClientTeam(i)==2 && IsPlayerAlive(i) && !GetEntProp(i,Prop_Send,"m_isIncapacitated") && i!=client) {
        int hp = GetEntProp(i, Prop_Send, "m_iHealth");
        if (hp < 35 && hp < lowest) {
            float p[3]; GetClientAbsOrigin(i,p);
            if (GetVectorDistance(pos,p) < 800.0) { lowest=hp; best=i; }
        }
    }
    if (best>0) { BB_SetInt(client, "heal_target", best); return BT_SUCCESS; }
    // 递药：队友 <35 且自己有 pills/adrenaline 且备包充足
    int slot = GetPlayerWeaponSlot(client, 3);
    if (slot>0) {
        char cls[32]; GetEdictClassname(slot, cls, sizeof(cls));
        if (StrContains(cls,"pain_pills")!=-1 || StrContains(cls,"adrenaline")!=-1) {
            for(int i=1;i<=MaxClients;i++) if (IsClientInGame(i) && GetClientTeam(i)==2 && IsPlayerAlive(i) && !GetEntProp(i,Prop_Send,"m_isIncapacitated") && i!=client) {
                int hp = GetEntProp(i, Prop_Send, "m_iHealth");
                if (hp < 40) {
                    float p[3]; GetClientAbsOrigin(i,p);
                    if (GetVectorDistance(pos,p) < 270.0) { BB_SetInt(client, "heal_target", i); return BT_SUCCESS; }
                }
            }
        }
    }
    return BT_FAILURE;
}
BT_Status BotCond_NeedsWeapon(int client) {
    int pri = GetPlayerWeaponSlot(client, 0);
    if (pri<=0 || !IsValidEntity(pri)) return BT_SUCCESS;
    // 团队配比：霰弹过多则不换
    float pos[3]; GetClientAbsOrigin(client,pos);
    int nearby = GetClosestWeaponOnGround(pos);
    if (nearby<=0) return BT_FAILURE;
    float wPos[3]; GetEntPropVector(nearby, Prop_Send, "m_vecOrigin", wPos);
    if (!IsItemFlowValid(wPos)) return BT_FAILURE;
    char cls[32]; GetEdictClassname(nearby, cls, sizeof(cls));
    // 霰弹团队上限 2
    if (StrContains(cls,"shotgun")!=-1 && CountTeamWeaponType("shotgun") >= 2) return BT_FAILURE;
    // 激光保留：当前有激光则不换
    if (pri>0) {
        int upgrade = GetEntProp(pri, Prop_Send, "m_upgradeBitVec");
        if (upgrade & 4) return BT_FAILURE; // 激光
        int clip = GetEntProp(pri, Prop_Send, "m_iClip1");
        int ammoType = GetEntProp(pri, Prop_Send, "m_iPrimaryAmmoType");
        int reserve = GetEntProp(client, Prop_Send, "m_iAmmo", _, ammoType);
        float ratio = (clip + reserve) >0 ? float(clip)/float(clip+reserve) : 1.0;
        if (ratio > 0.33) return BT_FAILURE; // 备弹充足不换
    }
    return BT_SUCCESS;
}
BT_Status BotCond_HasVisibleSI(int client) {
    float maxDist = g_hCvarTargetRange != null ? g_hCvarTargetRange.FloatValue : 2500.0;
    int pri = GetPlayerWeaponSlot(client, 0);
    if (pri>0) {
        char cls[32]; GetEdictClassname(pri, cls, sizeof(cls));
        if (StrContains(cls, "shotgun")!=-1 && g_hCvarTargetRangeShotgun != null) maxDist = g_hCvarTargetRangeShotgun.FloatValue;
    }
    int si = FindVisibleSI(client, maxDist);
    if (si>0) { BB_SetInt(client, "combat_target", si); g_fBotLastCombatSeen[client]=GetGameTime(); return BT_SUCCESS; }
    // 0.5s 粘滞：LOS 瞬断不立即切走，避免战斗/跟随来回抖
    if (GetGameTime() - g_fBotLastCombatSeen[client] < 0.5) {
        int last = BB_GetInt(client, "combat_target", -1);
        if (last>0 && IsClientInGame(last) && IsPlayerAlive(last) && GetClientTeam(last)==3) {
            float myPos[3], tPos[3]; GetClientAbsOrigin(client,myPos); GetClientAbsOrigin(last,tPos);
            if (GetVectorDistance(myPos,tPos) < maxDist) return BT_SUCCESS;
        }
    }
    return BT_FAILURE;
}
BT_Status BotCond_HordeNearby(int client) {
    if (g_hCvarGrenadeEnabled==null || !g_hCvarGrenadeEnabled.BoolValue) return BT_FAILURE;
    if (!HasGrenade(client)) return BT_FAILURE;
    float pos[3]; GetClientAbsOrigin(client,pos);
    float mult = g_hCvarGrenadeHordeMult != null ? g_hCvarGrenadeHordeMult.FloatValue : 3.0;
    int need = RoundToNearest(mult * 5); // 5 survivors * mult
    int cnt = CountCommonInRange(pos, 450.0);
    return cnt >= need ? BT_SUCCESS : BT_FAILURE;
}
BT_Status BotCond_InAcid(int client) {
    float pos[3]; GetClientAbsOrigin(client,pos);
    float acidPos[3];
    int ent=-1;
    while ((ent = FindEntityByClassname(ent, "insect_swarm")) != -1) {
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", acidPos);
        if (GetVectorDistance(pos, acidPos) < 150.0) { BB_SetInt(client, "danger_pos_ent", ent); return BT_SUCCESS; }
    }
    ent=-1;
    while ((ent = FindEntityByClassname(ent, "spit_acid")) != -1) {
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", acidPos);
        if (GetVectorDistance(pos, acidPos) < 180.0) return BT_SUCCESS;
        // 路径预探：前方 300u 路径点若在酸内则提前躲
        float fwd[3];
        if (SI_ProbeForwardRouteDir(client, fwd, 300.0)) {
            float probe[3]; probe[0]=pos[0]+fwd[0]*300; probe[1]=pos[1]+fwd[1]*300; probe[2]=pos[2];
            if (GetVectorDistance(probe, acidPos) < 200.0) return BT_SUCCESS;
        }
    }
    float p[3]; GetClientAbsOrigin(client,p);
    int fire = -1;
    while ((fire = FindEntityByClassname(fire, "inferno")) != -1) {
        float fPos[3]; GetEntPropVector(fire, Prop_Send, "m_vecOrigin", fPos);
        if (GetVectorDistance(p, fPos) < 200.0) return BT_SUCCESS;
        float fwd[3];
        if (SI_ProbeForwardRouteDir(client, fwd, 300.0)) {
            float probe[3]; probe[0]=p[0]+fwd[0]*300; probe[1]=p[1]+fwd[1]*300; probe[2]=p[2];
            if (GetVectorDistance(probe, fPos) < 220.0) return BT_SUCCESS;
        }
    }
    return BT_FAILURE;
}
BT_Status BotCond_TankRockIncoming(int client) {
    float pos[3]; GetClientAbsOrigin(client,pos);
    int ent=-1;
    while ((ent = FindEntityByClassname(ent, "tank_rock")) != -1) {
        float rPos[3], rVel[3];
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", rPos);
        GetEntPropVector(ent, Prop_Data, "m_vecVelocity", rVel);
        if (GetVectorDistance(pos, rPos) > 800.0) continue;
        // 速度朝向 bot
        float toBot[3]; MakeVectorFromPoints(rPos, pos, toBot); NormalizeVector(toBot,toBot);
        NormalizeVector(rVel, rVel);
        if (GetVectorDotProduct(rVel, toBot) > 0.7) { BB_SetInt(client, "rock_ent", ent); return BT_SUCCESS; }
    }
    return BT_FAILURE;
}
BT_Status BotCond_ChargerChargingAtMe(int client) {
    float pos[3]; GetClientAbsOrigin(client,pos);
    for(int i=1;i<=MaxClients;i++) if (IsClientInGame(i) && GetClientTeam(i)==3 && IsPlayerAlive(i) && GetEntProp(i,Prop_Send,"m_zombieClass")==6) {
        // 检查是否在冲锋
        int ability = GetEntPropEnt(i, Prop_Send, "m_customAbility");
        if (ability>0) {
            float ts = GetEntPropFloat(ability, Prop_Send, "m_timestamp");
            // 冲锋中 timestamp 在未来？简化用 m_isCharging 需 left4dhooks? 用速度判断
        }
        float cPos[3]; GetClientAbsOrigin(i,cPos);
        float dist = GetVectorDistance(pos,cPos);
        if (dist > 400.0) continue;
        float vel[3]; GetEntPropVector(i, Prop_Data, "m_vecVelocity", vel);
        if (GetVectorLength(vel) < 300.0) continue;
        NormalizeVector(vel, vel);
        float toBot[3]; MakeVectorFromPoints(cPos,pos,toBot); NormalizeVector(toBot,toBot);
        if (GetVectorDotProduct(vel, toBot) > 0.7) { BB_SetInt(client, "charger_attacker", i); return BT_SUCCESS; }
    }
    return BT_FAILURE;
}
BT_Status BotCond_NeedsScavenge(int client) {
    if (GetPlayerWeaponSlot(client, 0) <=0) return BT_SUCCESS;
    // 团队药包冗余：统计 slot3 实际药包 + 地面
    if (!HasMedkit(client)) {
        int teamKits=0;
        for(int i=1;i<=MaxClients;i++) if (IsClientInGame(i) && GetClientTeam(i)==2 && IsPlayerAlive(i) && HasMedkit(i)) teamKits++;
        if (teamKits < 2) {
            float pos[3]; GetClientAbsOrigin(client,pos);
            int ent=-1;
            while ((ent = FindEntityByClassname(ent, "weapon_first_aid_kit")) != -1) {
                if (GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity")>0) continue;
                float p[3]; GetEntPropVector(ent, Prop_Send, "m_vecOrigin", p);
                if (GetVectorDistance(pos,p) < 1000.0 && IsItemFlowValid(p)) { BB_SetInt(client, "scavenge_ent", ent); return BT_SUCCESS; }
            }
            while ((ent = FindEntityByClassname(ent, "weapon_defibrillator")) != -1) {
                if (GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity")>0) continue;
                if (CountTeamWeaponType("defibrillator") >=1) continue;
                float p[3]; GetEntPropVector(ent, Prop_Send, "m_vecOrigin", p);
                if (GetVectorDistance(pos,p) < 1000.0 && IsItemFlowValid(p)) { BB_SetInt(client, "scavenge_ent", ent); return BT_SUCCESS; }
            }
        }
    }
    int pri = GetPlayerWeaponSlot(client, 0);
    if (pri>0) {
        int clip = GetEntProp(pri, Prop_Send, "m_iClip1");
        if (clip < 10) {
            float pos[3]; GetClientAbsOrigin(client,pos);
            int ent=-1;
            while ((ent = FindEntityByClassname(ent, "weapon_ammo_spawn")) != -1) {
                float p[3]; GetEntPropVector(ent, Prop_Send, "m_vecOrigin", p);
                if (GetVectorDistance(pos,p) < 1200.0 && IsItemFlowValid(p)) { BB_SetInt(client, "scavenge_ent", ent); return BT_SUCCESS; }
            }
        }
    }
    return BT_FAILURE;
}
BT_Status BotCond_MountedGunNearby(int client) {
    float pos[3]; GetClientAbsOrigin(client,pos);
    // 风控：尸潮>8/200u 或坦克400u 内不上机（送头）
    if (CountCommonInRange(pos, 200.0) > 8) return BT_FAILURE;
    if (IsTankNear(pos, 400.0)) return BT_FAILURE;
    int ent=-1;
    while ((ent = FindEntityByClassname(ent, "prop_mounted_machine_gun")) != -1) {
        float p[3]; GetEntPropVector(ent, Prop_Send, "m_vecOrigin", p);
        if (GetVectorDistance(pos,p) < 250.0) { BB_SetInt(client, "mounted_gun", ent); return BT_SUCCESS; }
    }
    while ((ent = FindEntityByClassname(ent, "weapon_minigun")) != -1) {
        float p[3]; GetEntPropVector(ent, Prop_Send, "m_vecOrigin", p);
        if (GetVectorDistance(pos,p) < 250.0) { BB_SetInt(client, "mounted_gun", ent); return BT_SUCCESS; }
    }
    return BT_FAILURE;
}
BT_Status BotCond_ShouldScout(int client) {
    // 探路：队伍空闲时主动前探触发机关/开门
    float pos[3]; GetClientAbsOrigin(client,pos);
    // 有可见 SI 则不探路，优先战斗
    if (FindVisibleSI(client, 1200.0) > 0) return BT_FAILURE;
    // 有人类在 400 内则不探路，跟随即可
    int human = GetClosestHumanSurvivor(pos);
    if (human>0) {
        float hPos[3]; GetClientAbsOrigin(human,hPos);
        if (GetVectorDistance(pos,hPos) < 400.0) return BT_FAILURE;
    }
    // 检查前方 flow 是否有路可探（有 nav）
    float dir[3];
    if (!SI_ProbeForwardRouteDir(client, dir, 250.0)) return BT_FAILURE;
    return BT_SUCCESS;
}
BT_Status BotCond_NearClosedDoor(int client) {
    if (FindVisibleSI(client, 400.0) > 0) return BT_FAILURE;
    float pos[3]; GetClientAbsOrigin(client,pos);
    bool inCheckpoint = false;
    if (HasEntProp(client, Prop_Send, "m_bInCheckpoint")) inCheckpoint = GetEntProp(client, Prop_Send, "m_bInCheckpoint") != 0;
    float searchDist = inCheckpoint ? 500.0 : 120.0;
    int ent=-1;
    while ((ent = FindEntityByClassname(ent, "prop_door_rotating")) != -1) {
        if (GetEntProp(ent, Prop_Send, "m_bLocked") == 1) continue;
        int state = GetEntProp(ent, Prop_Send, "m_eDoorState");
        if (state != 0) continue;
        float p[3]; GetEntPropVector(ent, Prop_Send, "m_vecOrigin", p);
        if (GetVectorDistance(pos,p) < searchDist) { BB_SetInt(client, "door_ent", ent); return BT_SUCCESS; }
    }
    ent=-1;
    while ((ent = FindEntityByClassname(ent, "prop_door_rotating_checkpoint")) != -1) {
        if (GetEntProp(ent, Prop_Send, "m_bLocked") == 1) continue;
        int state = GetEntProp(ent, Prop_Send, "m_eDoorState");
        if (state != 0) continue;
        float p[3]; GetEntPropVector(ent, Prop_Send, "m_vecOrigin", p);
        if (GetVectorDistance(pos,p) < searchDist) { BB_SetInt(client, "door_ent", ent); return BT_SUCCESS; }
    }
    // 出生点特化：若在检查点内且无人类已出门，则主动寻最近的检查点门
    if (inCheckpoint) {
        float bestDist=999999.0; int best=-1;
        ent=-1;
        while ((ent = FindEntityByClassname(ent, "prop_door_rotating_checkpoint")) != -1) {
            float p[3]; GetEntPropVector(ent, Prop_Send, "m_vecOrigin", p);
            float d = GetVectorDistance(pos,p);
            if (d < bestDist) { bestDist=d; best=ent; }
        }
        if (best>0 && bestDist < 800.0) {
            int state = GetEntProp(best, Prop_Send, "m_eDoorState");
            if (state==0) { BB_SetInt(client, "door_ent", best); return BT_SUCCESS; }
        }
    }
    return BT_FAILURE;
}
BT_Status BotCond_IsInChoke(int client) {
    // 咽喉：左右 200 内均有墙
    bool left = Terrain_HorzTraceHit(client, -90.0, 200.0);
    bool right = Terrain_HorzTraceHit(client, 90.0, 200.0);
    return (left && right) ? BT_SUCCESS : BT_FAILURE;
}
BT_Status BotCond_IsTankFight(int client) {
    float pos[3]; GetClientAbsOrigin(client,pos);
    for(int i=1;i<=MaxClients;i++) if (IsClientInGame(i) && GetClientTeam(i)==3 && IsPlayerAlive(i) && GetEntProp(i,Prop_Send,"m_zombieClass")==8) {
        float p[3]; GetClientAbsOrigin(i,p);
        if (GetVectorDistance(pos,p) < 1200.0) return BT_SUCCESS;
    }
    return BT_FAILURE;
}

// BT Actions
BT_Status BotAct_RescueTeammate(int client) {
    int target = BB_GetInt(client, "rescue_target", -1);
    if (target<=0 || !IsClientInGame(target) || !IsPlayerAlive(target)) return BT_FAILURE;
    bool isPinned = IsPinned(target);
    bool isIncapped = GetEntProp(target, Prop_Send, "m_isIncapacitated") != 0;
    float myPos[3], tPos[3], dir[3], ang[3];
    GetClientAbsOrigin(client, myPos);
    GetClientAbsOrigin(target, tPos);
    float dist = GetVectorDistance(myPos, tPos);
    MakeVectorFromPoints(myPos, tPos, dir);
    GetVectorAngles(dir, ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    if (dist < 80.0) {
        if (isIncapped && !isPinned) {
            // 倒地未被控 -> 长按 USE 扶起，禁止推搡（修复不断推搡 bug）
            BT_AddButton(client, IN_USE);
            BT_RemoveButton(client, IN_ATTACK);
            BT_RemoveButton(client, IN_ATTACK2);
        } else if (isPinned) {
            int attacker = GetEntPropEnt(target, Prop_Send, "m_tongueOwner");
            if (attacker<=0) attacker = GetEntPropEnt(target, Prop_Send, "m_pounceAttacker");
            if (attacker<=0) attacker = GetEntPropEnt(target, Prop_Send, "m_jockeyAttacker");
            if (attacker<=0) attacker = GetEntPropEnt(target, Prop_Send, "m_carryAttacker");
            if (attacker<=0) attacker = GetEntPropEnt(target, Prop_Send, "m_pummelAttacker");
            if (attacker>0 && IsClientInGame(attacker)) {
                float aPos[3]; GetClientAbsOrigin(attacker, aPos);
                float distAtt = GetVectorDistance(myPos, aPos);
                MakeVectorFromPoints(myPos, aPos, dir);
                GetVectorAngles(dir, ang);
                BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
                if (distAtt < 80.0) BT_AddButton(client, IN_ATTACK2);
                else BT_AddButton(client, IN_ATTACK);
            } else {
                BT_AddButton(client, IN_ATTACK2);
            }
        } else {
            BT_AddButton(client, IN_USE);
        }
        return BT_RUNNING;
    }
    BT_AddButton(client, IN_FORWARD);
    BT_AddButton(client, IN_SPEED);
    BT_BeginMovement(client);
    BT_StuckDetour(client);
    return BT_RUNNING;
}
BT_Status BotAct_DefibTeammate(int client) {
    int target = BB_GetInt(client, "rescue_target", -1);
    if (target<=0 || !IsClientInGame(target)) return BT_FAILURE;
    int ent = GetPlayerWeaponSlot(client, 3);
    bool hasDefib=false;
    if (ent>0) {
        char cls[32]; GetEdictClassname(ent, cls, sizeof(cls));
        if (StrContains(cls,"defibrillator")!=-1) hasDefib=true;
    }
    if (!hasDefib) return BT_FAILURE;
    float pos[3], tPos[3]; GetClientAbsOrigin(client,pos); GetClientAbsOrigin(target,tPos);
    float dist = GetVectorDistance(pos,tPos);
    float dir[3], ang[3]; MakeVectorFromPoints(pos,tPos,dir); GetVectorAngles(dir,ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    if (dist < 100.0) {
        BT_AddButton(client, IN_USE);
        return BT_RUNNING;
    }
    BT_AddButton(client, IN_FORWARD);
    BT_AddButton(client, IN_SPEED);
    BT_BeginMovement(client);
    BT_StuckDetour(client);
    return BT_RUNNING;
}
BT_Status BotAct_HealSelf(int client) {
    int perm = GetEntProp(client, Prop_Send, "m_iHealth");
    // 受击中断：1s 内受 25 伤害则中断
    float lastDmg = BB_GetFloat(client, "_heal_last_dmg", 0.0);
    if (GetGameTime() - lastDmg < 1.0) return BT_FAILURE;
    if (perm < 40) {
        int slot = GetPlayerWeaponSlot(client, 3);
        if (slot>0) {
            char cls[32]; GetEdictClassname(slot, cls, sizeof(cls));
            if (StrContains(cls,"pain_pills")!=-1 || StrContains(cls,"adrenaline")!=-1) {
                // 肾上腺素在拉倒地/被控时更快
                BT_AddButton(client, IN_USE);
                return BT_RUNNING;
            }
        }
    }
    if (HasMedkit(client)) {
        if (FindVisibleSI(client, 400.0) > 0) return BT_FAILURE;
        BT_AddButton(client, IN_USE);
        return BT_RUNNING;
    }
    return BT_FAILURE;
}
BT_Status BotAct_HealTeammate(int client) {
    int target = BB_GetInt(client, "heal_target", -1);
    if (target<=0 || !IsClientInGame(target) || !IsPlayerAlive(target)) return BT_FAILURE;
    if (GetEntProp(target, Prop_Send, "m_isIncapacitated")) return BT_FAILURE;
    if (GetGameTime() - BB_GetFloat(client, "_heal_last_dmg", 0.0) < 1.0) return BT_FAILURE;
    int slot = GetPlayerWeaponSlot(client, 3);
    bool hasPills = false;
    if (slot>0) {
        char cls[32]; GetEdictClassname(slot, cls, sizeof(cls));
        if (StrContains(cls,"pain_pills")!=-1 || StrContains(cls,"adrenaline")!=-1) hasPills=true;
    }
    float pos[3], tPos[3]; GetClientAbsOrigin(client,pos); GetClientAbsOrigin(target,tPos);
    if (GetVectorDistance(pos,tPos) > 270.0) {
        // 递药距离 270
        if (!hasPills) return BT_FAILURE;
    }
    if (GetVectorDistance(pos,tPos) > 150.0) {
        float dir[3], ang[3]; MakeVectorFromPoints(pos,tPos,dir); GetVectorAngles(dir,ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        BT_AddButton(client, IN_FORWARD);
        BT_BeginMovement(client);
        BT_StuckDetour(client);
        return BT_RUNNING;
    }
    float dir[3], ang[3]; MakeVectorFromPoints(pos,tPos,dir); GetVectorAngles(dir,ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_USE);
    return BT_RUNNING;
}
BT_Status BotAct_RetreatFromAcid(int client) {
    float pos[3]; GetClientAbsOrigin(client,pos);
    float safePos[3]; bool foundSafe=false;
    for(int deg=0; deg<360; deg+=45) {
        float rad = DegToRad(float(deg));
        float test[3]; test[0]=pos[0]+Cosine(rad)*350; test[1]=pos[1]+Sine(rad)*350; test[2]=pos[2];
        bool inDanger=false;
        int ent=-1; float aPos[3];
        while ((ent = FindEntityByClassname(ent, "spit_acid")) != -1) {
            GetEntPropVector(ent, Prop_Send, "m_vecOrigin", aPos);
            if (GetVectorDistance(test,aPos)<200.0) { inDanger=true; break; }
        }
        if (!inDanger) {
            ent=-1;
            while ((ent = FindEntityByClassname(ent, "insect_swarm")) != -1) {
                GetEntPropVector(ent, Prop_Send, "m_vecOrigin", aPos);
                if (GetVectorDistance(test,aPos)<150.0) { inDanger=true; break; }
            }
        }
        if (!inDanger) {
            ent=-1;
            while ((ent = FindEntityByClassname(ent, "inferno")) != -1) {
                GetEntPropVector(ent, Prop_Send, "m_vecOrigin", aPos);
                if (GetVectorDistance(test,aPos)<200.0) { inDanger=true; break; }
            }
        }
        if (!inDanger) { safePos=test; foundSafe=true; break; }
    }
    if (foundSafe) {
        float dir[3], ang[3]; MakeVectorFromPoints(pos,safePos,dir); GetVectorAngles(dir,ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        BT_AddButton(client, IN_FORWARD);
        BT_AddButton(client, IN_SPEED);
        BT_BeginMovement(client);
        BT_StuckDetour(client);
        return BT_RUNNING;
    }
    int human = GetClosestHumanSurvivor(pos);
    float targetPos[3];
    if (human>0) GetClientAbsOrigin(human, targetPos);
    else {
        float ang[3]; GetClientEyeAngles(client, ang);
        ang[1] += 180.0;
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        BT_AddButton(client, IN_FORWARD);
        BT_AddButton(client, IN_SPEED);
        BT_BeginMovement(client);
        BT_StuckDetour(client);
        return BT_RUNNING;
    }
    float dir[3], ang[3]; MakeVectorFromPoints(pos, targetPos, dir); GetVectorAngles(dir, ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_FORWARD);
    BT_AddButton(client, IN_SPEED);
    BT_BeginMovement(client);
    BT_StuckDetour(client);
    return BT_RUNNING;
}
BT_Status BotAct_DodgeRock(int client) {
    float pos[3]; GetClientAbsOrigin(client,pos);
    int rock = BB_GetInt(client, "rock_ent", -1);
    if (rock<=0 || !IsValidEntity(rock)) return BT_FAILURE;
    float rPos[3], rVel[3];
    GetEntPropVector(rock, Prop_Send, "m_vecOrigin", rPos);
    GetEntPropVector(rock, Prop_Data, "m_vecVelocity", rVel);
    float dir[3], ang[3];
    float side[3]; side[0]=-rVel[1]; side[1]=rVel[0]; side[2]=0;
    if (GetVectorLength(side) < 1.0) { side[0]=1.0; side[1]=0.0; side[2]=0.0; }
    else NormalizeVector(side,side);
    if (GetRandomInt(0,1)==0) { side[0]=-side[0]; side[1]=-side[1]; }
    float target[3]; target[0]=pos[0]+side[0]*300; target[1]=pos[1]+side[1]*300; target[2]=pos[2];
    MakeVectorFromPoints(pos,target,dir); GetVectorAngles(dir,ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_FORWARD);
    if (side[0]>0) BT_AddButton(client, IN_MOVERIGHT); else BT_AddButton(client, IN_MOVELEFT);
    // 尝试射击岩石
    float sPos[3]; GetClientAbsOrigin(client,sPos);
    float toRock[3]; MakeVectorFromPoints(sPos,rPos,toRock); GetVectorAngles(toRock,ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_ATTACK);
    BT_BeginMovement(client);
    BT_StuckDetour(client);
    return BT_RUNNING;
}
BT_Status BotAct_DodgeCharger(int client) {
    float pos[3]; GetClientAbsOrigin(client,pos);
    int charger = BB_GetInt(client, "charger_attacker", -1);
    if (charger<=0 || !IsClientInGame(charger)) return BT_FAILURE;
    float cPos[3]; GetClientAbsOrigin(charger,cPos);
    float vel[3]; GetEntPropVector(charger, Prop_Data, "m_vecVelocity", vel);
    NormalizeVector(vel,vel);
    float side[3]; side[0]=-vel[1]; side[1]=vel[0]; side[2]=0;
    NormalizeVector(side,side);
    float target[3]; target[0]=pos[0]+side[0]*400; target[1]=pos[1]+side[1]*400; target[2]=pos[2];
    float dir[3], ang[3]; MakeVectorFromPoints(pos,target,dir); GetVectorAngles(dir,ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_FORWARD);
    BT_AddButton(client, IN_SPEED);
    if (side[0]>0) BT_AddButton(client, IN_MOVERIGHT); else BT_AddButton(client, IN_MOVELEFT);
    BT_BeginMovement(client);
    BT_StuckDetour(client);
    return BT_RUNNING;
}
BT_Status BotAct_Scavenge(int client) {
    int ent = BB_GetInt(client, "scavenge_ent", -1);
    if (ent<=0 || !IsValidEntity(ent)) return BT_FAILURE;
    if (GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity")>0) return BT_FAILURE;
    float pos[3], wPos[3]; GetClientAbsOrigin(client,pos); GetEntPropVector(ent, Prop_Send, "m_vecOrigin", wPos);
    // 超时防卡死原地跳：4s 仍够不到则放弃
    float start = BB_GetFloat(client, "_scavenge_start", 0.0);
    float nowScav = GetGameTime();
    if (start <= 0.0) BB_SetFloat(client, "_scavenge_start", nowScav);
    else if (nowScav - start > 4.0) { BB_SetFloat(client, "_scavenge_start", 0.0); return BT_FAILURE; }
    float dir[3], ang[3]; MakeVectorFromPoints(pos, wPos, dir); GetVectorAngles(dir, ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    if (GetVectorDistance(pos,wPos) < 90.0) {
        BB_SetFloat(client, "_scavenge_start", 0.0);
        BT_AddButton(client, IN_USE);
        return BT_RUNNING;
    }
    BT_AddButton(client, IN_FORWARD);
    BT_BeginMovement(client);
    BT_StuckDetour(client);
    return BT_RUNNING;
}
BT_Status BotAct_UseMountedGun(int client) {
    int gun = BB_GetInt(client, "mounted_gun", -1);
    if (gun<=0 || !IsValidEntity(gun)) return BT_FAILURE;
    float pos[3], gPos[3]; GetClientAbsOrigin(client,pos); GetEntPropVector(gun, Prop_Send, "m_vecOrigin", gPos);
    float dist = GetVectorDistance(pos, gPos);
    if (dist < 80.0) {
        BT_AddButton(client, IN_USE);
        // 上机后自动射击由引擎接管，这里保持瞄准最近 SI
        int si = FindVisibleSI(client, 2500.0);
        if (si>0) {
            float sPos[3]; GetClientAbsOrigin(si, sPos);
            float dir[3], ang[3]; MakeVectorFromPoints(pos, sPos, dir); GetVectorAngles(dir, ang);
            BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
            BT_AddButton(client, IN_ATTACK);
        }
        return BT_RUNNING;
    }
    float dir[3], ang[3]; MakeVectorFromPoints(pos, gPos, dir); GetVectorAngles(dir, ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_FORWARD);
    BT_BeginMovement(client);
    BT_StuckDetour(client);
    return BT_RUNNING;
}
BT_Status BotAct_Scout(int client) {
    float dir[3];
    if (SI_ProbeForwardRouteDir(client, dir, 300.0)) {
        float yaw = RadToDeg(ArcTangent2(dir[1], dir[0]));
        BT_SetAimAngles(client, 0.0, yaw, 0.0);
        BT_AddButton(client, IN_FORWARD);
        BT_AddButton(client, IN_SPEED);
        BT_BeginMovement(client);
        BT_StuckDetour(client);
        return BT_RUNNING;
    }
    // 备用：朝人类前方探
    float pos[3]; GetClientAbsOrigin(client,pos);
    int human = GetClosestHumanSurvivor(pos);
    if (human>0) {
        float hPos[3], hAng[3], fwd[3];
        GetClientAbsOrigin(human,hPos);
        GetClientEyeAngles(human,hAng);
        GetAngleVectors(hAng, fwd, NULL_VECTOR, NULL_VECTOR);
        float target[3]; target[0]=hPos[0]+fwd[0]*400; target[1]=hPos[1]+fwd[1]*400; target[2]=hPos[2];
        float d[3], ang[3]; MakeVectorFromPoints(pos,target,d); GetVectorAngles(d,ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        BT_AddButton(client, IN_FORWARD);
        BT_BeginMovement(client);
        BT_StuckDetour(client);
        return BT_RUNNING;
    }
    return BT_FAILURE;
}
BT_Status BotAct_OpenDoor(int client) {
    int door = BB_GetInt(client, "door_ent", -1);
    if (door<=0 || !IsValidEntity(door)) return BT_FAILURE;
    float pos[3], dPos[3]; GetClientAbsOrigin(client,pos); GetEntPropVector(door, Prop_Send, "m_vecOrigin", dPos);
    float dir[3], ang[3]; MakeVectorFromPoints(pos,dPos,dir); GetVectorAngles(dir,ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    if (GetVectorDistance(pos,dPos) < 80.0) {
        BT_AddButton(client, IN_USE);
        return BT_RUNNING;
    }
    BT_AddButton(client, IN_FORWARD);
    BT_BeginMovement(client);
    BT_StuckDetour(client);
    return BT_RUNNING;
}
BT_Status BotAct_HoldChoke(int client) {
    float pos[3]; GetClientAbsOrigin(client,pos);
    int human = GetClosestHumanSurvivor(pos);
    if (human<=0) return BT_FAILURE;
    float hPos[3]; GetClientAbsOrigin(human,hPos);
    // 保持在人类身后 150-250，侧向 90u 交叉火力
    float dir[3], ang[3]; MakeVectorFromPoints(hPos,pos,dir); NormalizeVector(dir,dir);
    // 侧向偏移
    float side[3]; side[0]=-dir[1]; side[1]=dir[0]; side[2]=0;
    // 按 bot index 决定左右
    if (client %2==0) { side[0]=-side[0]; side[1]=-side[1]; }
    float target[3]; target[0]=hPos[0]+dir[0]*180+side[0]*90; target[1]=hPos[1]+dir[1]*180+side[1]*90; target[2]=hPos[2];
    float toT[3]; MakeVectorFromPoints(pos,target,toT); GetVectorAngles(toT,ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    if (GetVectorDistance(pos,target) < 30.0) {
        BT_ClearMoveDirection(client);
        // 面向咽喉方向
        float fwd[3]; GetClientEyeAngles(human, ang); GetAngleVectors(ang,fwd,NULL_VECTOR,NULL_VECTOR);
        GetVectorAngles(fwd,ang); BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        return BT_RUNNING;
    }
    BT_AddButton(client, IN_FORWARD);
    BT_BeginMovement(client);
    BT_StuckDetour(client);
    return BT_RUNNING;
}
BT_Status BotAct_TankFormation(int client) {
    float pos[3]; GetClientAbsOrigin(client,pos);
    int tank=-1;
    for(int i=1;i<=MaxClients;i++) if (IsClientInGame(i) && GetClientTeam(i)==3 && IsPlayerAlive(i) && GetEntProp(i,Prop_Send,"m_zombieClass")==8) { tank=i; break; }
    if (tank<=0) return BT_FAILURE;
    float tPos[3]; GetClientAbsOrigin(tank,tPos);
    float away[3]; MakeVectorFromPoints(tPos,pos,away); if (GetVectorLength(away) > 1.0) NormalizeVector(away,away); else { away[0]=1.0; away[1]=0.0; away[2]=0.0; }
    // 瞄坦克射击，同时用 BACK+侧移后退分散
    float toTank[3], ang[3]; MakeVectorFromPoints(pos,tPos,toTank); GetVectorAngles(toTank, ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_ATTACK);
    BT_AddButton(client, IN_BACK);
    BT_AddButton(client, IN_SPEED);
    if (client%2==0) BT_AddButton(client, IN_MOVERIGHT); else BT_AddButton(client, IN_MOVELEFT);
    BT_BeginMovement(client);
    BT_StuckDetour(client);
    return BT_RUNNING;
}
BT_Status BotAct_PickupWeapon(int client) {
    float pos[3]; GetClientAbsOrigin(client,pos);
    int ent = GetClosestWeaponOnGround(pos);
    if (ent<=0) return BT_FAILURE;
    BB_SetInt(client, "pickup_ent", ent);
    float wPos[3]; GetEntPropVector(ent, Prop_Send, "m_vecOrigin", wPos);
    float start = BB_GetFloat(client, "_pickup_start", 0.0);
    float nowPick = GetGameTime();
    if (start <= 0.0) BB_SetFloat(client, "_pickup_start", nowPick);
    else if (nowPick - start > 4.0) { BB_SetFloat(client, "_pickup_start", 0.0); return BT_FAILURE; }
    float dir[3], ang[3];
    MakeVectorFromPoints(pos, wPos, dir);
    GetVectorAngles(dir, ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    float dist = GetVectorDistance(pos, wPos);
    if (dist < 90.0) {
        BB_SetFloat(client, "_pickup_start", 0.0);
        BT_AddButton(client, IN_USE);
        return BT_RUNNING;
    }
    BT_AddButton(client, IN_FORWARD);
    BT_BeginMovement(client);
    BT_StuckDetour(client);
    return BT_RUNNING;
}
BT_Status BotAct_ShootSI(int client) {
    int target = BB_GetInt(client, "combat_target", -1);
    if (target<=0 || !IsClientInGame(target) || !IsPlayerAlive(target)) return BT_FAILURE;
    float myPos[3], tPos[3], dir[3], ang[3];
    GetClientAbsOrigin(client, myPos);
    GetClientAbsOrigin(target, tPos);
    // aim with slight prediction
    float vel[3]; GetEntPropVector(target, Prop_Data, "m_vecVelocity", vel);
    float dist = GetVectorDistance(myPos, tPos);
    float lead = dist / 1200.0;
    if (lead>0.4) lead=0.4;
    float aimPos[3]; aimPos[0]=tPos[0]+vel[0]*lead; aimPos[1]=tPos[1]+vel[1]*lead; aimPos[2]=tPos[2]+30.0;
    MakeVectorFromPoints(myPos, aimPos, dir);
    GetVectorAngles(dir, ang);
    // melee check
    float meleeRange = g_hCvarMeleeAttackRange != null ? g_hCvarMeleeAttackRange.FloatValue : 90.0;
    bool meleeEnabled = g_hCvarMeleeEnabled != null ? g_hCvarMeleeEnabled.BoolValue : true;
    int meleeCount = g_hCvarMeleeMaxTeam != null ? g_hCvarMeleeMaxTeam.IntValue : 4;
    // count team melee
    int teamMelee=0;
    for(int i=1;i<=MaxClients;i++) if (IsSurvivorBot(i)) {
        int w = GetPlayerWeaponSlot(i, 1);
        if (w>0) {
            char cls[32]; GetEdictClassname(w, cls, sizeof(cls));
            if (StrContains(cls,"melee")!=-1 || StrContains(cls,"chainsaw")!=-1) teamMelee++;
        }
    }
    bool canMelee = meleeEnabled && teamMelee < meleeCount && dist < meleeRange;
    if (canMelee) {
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        if (dist < 75.0) {
            BT_AddButton(client, IN_ATTACK);
            // 静止近战不声明移动意图，避免 StuckDetour 误判原地起跳
            return BT_RUNNING;
        } else {
            BT_AddButton(client, IN_FORWARD);
            BT_AddButton(client, IN_ATTACK);
        }
        if (g_hCvarShovePumpChance != null && g_hCvarShovePumpChance.FloatValue >= 1.0) {
            int pri = GetPlayerWeaponSlot(client, 0);
            if (pri>0) {
                char cls[32]; GetEdictClassname(pri, cls, sizeof(cls));
                if (StrContains(cls,"pumpshotgun")!=-1) BT_AddButton(client, IN_ATTACK2);
            }
        }
    } else {
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        BT_AddButton(client, IN_ATTACK);
        if (g_hCvarAutoShove != null && g_hCvarAutoShove.FloatValue>0) {
            if (dist < 120.0) BT_AddButton(client, IN_ATTACK2);
        }
    }
    // 仅移动时才声明意图并检测卡死，静止射击不跳
    if (dist >= 75.0) {
        float now = GetGameTime();
        float next = BB_GetFloat(client, "_bot_strafe_next", 0.0);
        if (next <=0 || now >= next) {
            BB_SetBool(client, "_bot_strafe_left", GetRandomInt(0,1)==0);
            BB_SetFloat(client, "_bot_strafe_next", now + GetRandomFloat(0.4,0.9));
        }
        if (BB_GetBool(client, "_bot_strafe_left", false)) BT_AddButton(client, IN_MOVELEFT);
        else BT_AddButton(client, IN_MOVERIGHT);
        BT_BeginMovement(client);
        BT_StuckDetour(client);
    }
    return BT_RUNNING;
}
BT_Status BotAct_ThrowGrenade(int client) {
    float pos[3]; GetClientAbsOrigin(client,pos);
    // find horde center via common count? just throw forward
    float ang[3]; GetClientEyeAngles(client, ang);
    // pitch up a bit for arc
    ang[0] = -15.0;
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_ATTACK);
    return BT_SUCCESS;
}
BT_Status BotAct_FollowHuman(int client) {
    float pos[3]; GetClientAbsOrigin(client,pos);
    int human = GetClosestHumanSurvivor(pos);
    if (human<=0) return BT_FAILURE;
    float hPos[3]; GetClientAbsOrigin(human,hPos);
    float dist = GetVectorDistance(pos,hPos);
    if (dist < 150.0) {
        // close enough, hold a bit
        BT_ClearMoveDirection(client);
        float dir[3], ang[3]; MakeVectorFromPoints(pos,hPos,dir); GetVectorAngles(dir,ang);
        BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
        return BT_RUNNING;
    }
    float dir[3], ang[3]; MakeVectorFromPoints(pos,hPos,dir); GetVectorAngles(dir,ang);
    BT_SetAimAngles(client, ang[0], ang[1], ang[2]);
    BT_AddButton(client, IN_FORWARD);
    BT_AddButton(client, IN_SPEED);
    BT_BeginMovement(client);
    BT_StuckDetour(client);
    return BT_RUNNING;
}
BT_Status BotAct_MoveToGoal(int client) {
    // fallback: use director flow - move to goal via MoveToRouteAhead
    return ACT_MoveToRouteAhead(client);
}

// Tree builder - 1.7.3 priority fix: pinned > BW > hanging/incapped/dead > healRest > tankForm(combat shoot+retreat) > combat > grenade > choke > door > mounted > scavenge > weapon > scout > follow
stock int BT_CreateBotTree() {
    int acidSeq = BT_CreateSequence(2, BT_CreateCondition(BotCond_InAcid), BT_CreateAction(BotAct_RetreatFromAcid));
    int rockSeq = BT_CreateSequence(2, BT_CreateCondition(BotCond_TankRockIncoming), BT_CreateAction(BotAct_DodgeRock));
    int chargerSeq = BT_CreateSequence(2, BT_CreateCondition(BotCond_ChargerChargingAtMe), BT_CreateAction(BotAct_DodgeCharger));
    int survivalSel = BT_CreateSelector(3, acidSeq, rockSeq, chargerSeq);
    int rescuePinnedSeq = BT_CreateSequence(2, BT_CreateCondition(BotCond_TeammatePinnedNearby), BT_CreateAction(BotAct_RescueTeammate));
    int rescueHangingSeq = BT_CreateSequence(2, BT_CreateCondition(BotCond_TeammateHangingNearby), BT_CreateAction(BotAct_RescueTeammate));
    int rescueIncappedSeq = BT_CreateSequence(2, BT_CreateCondition(BotCond_TeammateIncappedNearby), BT_CreateAction(BotAct_RescueTeammate));
    int rescueDeadSeq = BT_CreateSequence(2, BT_CreateCondition(BotCond_DeadWithDefibNearby), BT_CreateAction(BotAct_DefibTeammate));
    int healSelfBWSeq = BT_CreateSequence(2, BT_CreateCondition(BotCond_IsBlackAndWhite), BT_CreateAction(BotAct_HealSelf));
    int healSelfSeq = BT_CreateSequence(2, BT_CreateCondition(BotCond_NeedsHealSelf), BT_CreateAction(BotAct_HealSelf));
    int healTeammateSeq = BT_CreateSequence(2, BT_CreateCondition(BotCond_TeammateNeedsHeal), BT_CreateAction(BotAct_HealTeammate));
    int healRestSelector = BT_CreateSelector(2, healSelfSeq, healTeammateSeq);
    int scavengeSeq = BT_CreateCooldown(1.0, BT_CreateSequence(2,
        BT_CreateCondition(BotCond_NeedsScavenge),
        BT_CreateAction(BotAct_Scavenge)
    ));
    int weaponSeq = BT_CreateCooldown(1.0, BT_CreateSequence(2,
        BT_CreateCondition(BotCond_NeedsWeapon),
        BT_CreateAction(BotAct_PickupWeapon)
    ));
    int mountedSeq = BT_CreateCooldown(5.0, BT_CreateSequence(2,
        BT_CreateCondition(BotCond_MountedGunNearby),
        BT_CreateAction(BotAct_UseMountedGun)
    ));
    int doorSeq = BT_CreateSequence(2,
        BT_CreateCondition(BotCond_NearClosedDoor),
        BT_CreateAction(BotAct_OpenDoor)
    );
    int scoutSeq = BT_CreateCooldown(1.5, BT_CreateSequence(2,
        BT_CreateCondition(BotCond_ShouldScout),
        BT_CreateAction(BotAct_Scout)
    ));
    int grenadeSeq = BT_CreateSequence(2,
        BT_CreateCondition(BotCond_HordeNearby),
        BT_CreateAction(BotAct_ThrowGrenade)
    );
    int combatSeq = BT_CreateSequence(2,
        BT_CreateCondition(BotCond_HasVisibleSI),
        BT_CreateAction(BotAct_ShootSI)
    );
    int chokeSeq = BT_CreateSequence(2, BT_CreateCondition(BotCond_IsInChoke), BT_CreateAction(BotAct_HoldChoke));
    int tankFormSeq = BT_CreateSequence(2, BT_CreateCondition(BotCond_IsTankFight), BT_CreateAction(BotAct_TankFormation));
    int root = BT_Create(BTN_SELECTOR);
    BT_AddChild(root, BT_CreateSequence(2, BT_CreateCondition(BotCond_IsIncapacitated), BT_CreateAction(ACT_HoldVictim)));
    BT_AddChild(root, survivalSel);
    BT_AddChild(root, rescuePinnedSeq);
    BT_AddChild(root, BT_CreateCooldown(0.8, healSelfBWSeq));
    BT_AddChild(root, rescueHangingSeq);
    BT_AddChild(root, rescueIncappedSeq);
    BT_AddChild(root, rescueDeadSeq);
    BT_AddChild(root, BT_CreateCooldown(0.8, healRestSelector));
    BT_AddChild(root, tankFormSeq);
    BT_AddChild(root, combatSeq);
    BT_AddChild(root, grenadeSeq);
    BT_AddChild(root, chokeSeq);
    BT_AddChild(root, doorSeq);
    BT_AddChild(root, mountedSeq);
    BT_AddChild(root, scavengeSeq);
    BT_AddChild(root, weaponSeq);
    BT_AddChild(root, scoutSeq);
    BT_AddChild(root, BT_CreateAction(BotAct_FollowHuman));
    BT_AddChild(root, BT_CreateAction(ACT_Wander));
    return root;
}

public void OnPluginStart() {
    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Pre);
    HookEvent("player_hurt", Event_PlayerHurt);
    g_hCvarTargetRange = CreateConVar("bot_ai_target_range", "2500", "Bot targeting range", FCVAR_NONE, true, 0.0, true, 5000.0);
    g_hCvarTargetRangeShotgun = CreateConVar("bot_ai_target_range_shotgun", "1200", "Shotgun range", FCVAR_NONE, true, 0.0, true, 5000.0);
    g_hCvarIgnoreDociles = CreateConVar("bot_ai_ignore_dociles", "0", "Ignore docile commons", FCVAR_NONE, true, 0.0, true, 1.0);
    g_hCvarMeleeEnabled = CreateConVar("bot_ai_melee_enabled", "1", "Enable melee", FCVAR_NONE, true, 0.0, true, 1.0);
    g_hCvarMeleeMaxTeam = CreateConVar("bot_ai_melee_max_team", "4", "Max melee on team", FCVAR_NONE, true, 0.0, true, 10.0);
    g_hCvarMeleeAttackRange = CreateConVar("bot_ai_melee_attack_range", "90", "Melee attack range", FCVAR_NONE, true, 0.0, true, 500.0);
    g_hCvarAutoShove = CreateConVar("bot_ai_autoshove", "1", "Auto shove", FCVAR_NONE, true, 0.0, true, 2.0);
    g_hCvarShovePumpChance = CreateConVar("bot_ai_shove_pump_chance", "1", "Pump shove chance", FCVAR_NONE, true, 0.0, true, 1.0);
    g_hCvarGrenadeEnabled = CreateConVar("bot_ai_grenade_enabled", "1", "Enable grenade", FCVAR_NONE, true, 0.0, true, 1.0);
    g_hCvarGrenadeHordeMult = CreateConVar("bot_ai_grenade_horde_mult", "3", "Horde mult", FCVAR_NONE, true, 0.0, true, 10.0);
    g_iBotBTRoot = BT_CreateBotTree();
    CreateTimer(1.0, Timer_Debug, _, TIMER_REPEAT);
}
public void OnMapStart() {
    // reapply if needed
}
public Action Event_PlayerSpawn(Handle event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (!IsSurvivorBot(client)) return Plugin_Continue;
    g_iTickCounter[client]=0;
    BT_Bind(client, g_iBotBTRoot);
    return Plugin_Continue;
}
public Action Event_PlayerHurt(Handle event, const char[] name, bool dontBroadcast) {
    int victim = GetClientOfUserId(GetEventInt(event, "userid"));
    if (victim>0 && IsSurvivorBot(victim)) {
        BB_SetFloat(victim, "_heal_last_dmg", GetGameTime());
    }
    return Plugin_Continue;
}
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon) {
    if (!IsSurvivorBot(client) || !IsPlayerAlive(client)) return Plugin_Continue;
    if (GetEntProp(client, Prop_Send, "m_isIncapacitated") || GetEntProp(client, Prop_Send, "m_isHangingFromLedge")) return Plugin_Continue;
    g_iTickCounter[client]++;
    if (g_iTickCounter[client] < TICK_INTERVAL) {
        // 非决策帧：保持上次 BT 决策的移动/视角，避免与引擎互抢导致顿挫
        BT_ApplyControlLite(client, buttons);
        if (g_bBT_AnglesSet[client]) BT_ApplyAngles(client, angles);
        return Plugin_Changed;
    }
    g_iTickCounter[client]=0;
    if (!BT_IsBound(client)) return Plugin_Continue;
    BT_ResetMovement(client);
    BT_Tick(client);
    BT_ApplyControlFrame(client, buttons);
    BT_ApplyAngles(client, angles);
    return Plugin_Changed;
}
public Action Timer_Debug(Handle timer) { return Plugin_Continue; }
