#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#define MODE_INCEND 1
#define MODE_EXPLOS 2

#if !defined DMG_BLAST
#define DMG_BLAST (1<<6)
#endif

ConVar g_cvExplosSelfDmg, g_cvExplosSelfRadius, g_cvExplosSelfStagger;
float g_fLastSelfDmg[MAXPLAYERS+1];
int g_iWeaponUnlock[2048]; // bit0=incend bit1=explos per weapon entindex
int g_iHudEnt[MAXPLAYERS+1]; // 每玩家的game_text实体（左上角弹药HUD）

int GetClipSize(int weapon){
    char cls[64]; GetEdictClassname(weapon,cls,sizeof(cls));
    int maxClip=0;
    if(L4D2_IsValidWeapon(cls)) maxClip=L4D2_GetIntWeaponAttribute(cls,L4D2IWA_ClipSize);
    if(maxClip>0) return maxClip;
    if(StrContains(cls,"spas",false)!=-1 || StrContains(cls,"autoshotgun",false)!=-1) return 10;
    if(StrContains(cls,"shotgun",false)!=-1) return 8;
    if(StrContains(cls,"rifle",false)!=-1) return 50;
    if(StrContains(cls,"sniper",false)!=-1) return 15;
    if(StrContains(cls,"smg",false)!=-1) return 50;
    return 30;
}

public Plugin myinfo={name="[L4D2] Permanent Special Ammo",author="suli",description="拾取特殊弹药后武器永久发射特殊子弹",version="2.0.0",url=""};

public void OnPluginStart(){
    g_cvExplosSelfDmg=CreateConVar("l4d2_tactical_explos_self_damage","25","高爆自伤基础伤害 (0=关闭自伤)",FCVAR_NOTIFY,true,0.0,true,100.0);
    g_cvExplosSelfRadius=CreateConVar("l4d2_tactical_explos_self_radius","150","高爆自伤判定半径",FCVAR_NOTIFY,true,10.0,true,500.0);
    g_cvExplosSelfStagger=CreateConVar("l4d2_tactical_explos_self_stagger","1","高爆自伤是否带击退硬直 (0=关闭)",FCVAR_NOTIFY,true,0.0,true,1.0);
    HookEvent("bullet_impact",Event_BulletImpact,EventHookMode_Post);
    HookEvent("round_start",Event_RoundStart,EventHookMode_PostNoCopy);
    AutoExecConfig(true,"l4d2_tactical_ammo");
    CreateTimer(0.2,Timer_HUD,_,TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_RoundStart(Event e,const char[] n,bool d){
    for(int i=0;i<2048;i++) g_iWeaponUnlock[i]=0;
    for(int i=1;i<=MaxClients;i++) g_fLastSelfDmg[i]=0.0;
    CleanupAllHudEnts();
}

public void OnClientDisconnect(int c){
    if(g_iHudEnt[c]>0&&IsValidEntity(g_iHudEnt[c])) RemoveEntity(g_iHudEnt[c]);
    g_iHudEnt[c]=0;
}

void CleanupAllHudEnts(){
    for(int i=1;i<=MaxClients;i++){
        if(g_iHudEnt[i]>0&&IsValidEntity(g_iHudEnt[i])) RemoveEntity(g_iHudEnt[i]);
        g_iHudEnt[i]=0;
    }
}

// HUD轮询：检测武器特殊弹 + 持续维持（永久特殊）
public Action Timer_HUD(Handle t){
    for(int c=1;c<=MaxClients;c++){
        if(!IsClientInGame(c)||IsFakeClient(c)||!IsPlayerAlive(c)) continue;
        int w=GetPlayerWeaponSlot(c,0);
        if(w<=0||!IsValidEdict(w)) continue;
        int bitVec=GetEntProp(w,Prop_Send,"m_upgradeBitVec");
        int up=GetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded");
        int clip=GetEntProp(w,Prop_Send,"m_iClip1");
        int bits=(w>=0&&w<2048)?g_iWeaponUnlock[w]:0;
        // 检测武器上真实出现特殊弹 → 记录解锁（覆盖升级包/弹药堆/商店等所有方式）
        if((bitVec&3)!=0 || up>0){
            int mode=(bitVec&2)!=0?MODE_EXPLOS:MODE_INCEND;
            if(w<2048) g_iWeaponUnlock[w]|=(mode==MODE_EXPLOS?2:1);
            bits=(w>=0&&w<2048)?g_iWeaponUnlock[w]:0;
        }
        // 对已解锁武器持续维持特殊弹（永久，不消耗）
        if(bits!=0){
            int mode;
            if(bits&2) mode=MODE_EXPLOS;
            else if(bits&1) mode=MODE_INCEND;
            else continue;
            int needBit=(mode==MODE_INCEND?1:2);
            // 保持特殊位（保留激光位bit4）
            if((bitVec&needBit)==0){
                SetEntProp(w,Prop_Send,"m_upgradeBitVec",needBit|(bitVec&4));
            }
            // 保持特殊弹数量=弹夹量（永久射不完）
            if(clip>0 && up<clip){
                SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",clip);
            }
        }
    }
    return Plugin_Continue;
}

// 每帧刷新弹药HUD（L4D2上HudMsg/ShowHudText/KeyHintText不可靠，用game_text实体显示左上角）
public Action OnPlayerRunCmd(int client,int &buttons,int &impulse,float vel[3],float angles[3],int &weapon,int &subtype,int &cmdnum,int &tickcount,int &seed,int mouse[2]){
    if(!IsClientInGame(client)||IsFakeClient(client)||!IsPlayerAlive(client)) return Plugin_Continue;
    int w=GetPlayerWeaponSlot(client,0);
    if(w<=0||!IsValidEdict(w)) return Plugin_Continue;
    int bits=(w>=0&&w<2048)?g_iWeaponUnlock[w]:0;
    if(bits==0){
        if(g_iHudEnt[client]>0&&IsValidEntity(g_iHudEnt[client])) RemoveEntity(g_iHudEnt[client]);
        g_iHudEnt[client]=0;
        return Plugin_Continue;
    }
    int mode=(bits&2)?MODE_EXPLOS:MODE_INCEND;
    int clip=GetEntProp(w,Prop_Send,"m_iClip1");
    int maxClip=GetClipSize(w);
    int reserve=0;
    int at=GetEntProp(w,Prop_Send,"m_iPrimaryAmmoType");
    if(at>=0&&at<32) reserve=GetEntProp(client,Prop_Send,"m_iAmmo",_,at);
    char line[64];
    Format(line,sizeof(line),"[%s] %d/%d 备弹%d",mode==MODE_INCEND?"燃烧":"高爆",clip,maxClip,reserve);
    ShowAmmoHud(client,line);
    return Plugin_Continue;
}

// game_text实体在左上角显示（Display的activator=client只给该玩家看）
void ShowAmmoHud(int client,const char[] text){
    int ent=g_iHudEnt[client];
    if(ent<=0||!IsValidEntity(ent)){
        ent=CreateEntityByName("game_text");
        if(ent==-1) return;
        DispatchKeyValue(ent,"message",text);
        DispatchKeyValue(ent,"x","0.02");
        DispatchKeyValue(ent,"y","0.08");
        DispatchKeyValue(ent,"effect","0");
        DispatchKeyValue(ent,"color","255 200 0");
        DispatchKeyValue(ent,"color2","255 200 0");
        DispatchKeyValue(ent,"fadein","0");
        DispatchKeyValue(ent,"fadeout","0");
        DispatchKeyValue(ent,"fxtime","0");
        DispatchKeyValue(ent,"holdtime","0.5");
        DispatchSpawn(ent);
        g_iHudEnt[client]=ent;
    } else {
        DispatchKeyValue(ent,"message",text);
    }
    AcceptEntityInput(ent,"Display",client,client);
}

// 高爆自伤
bool TraceFilterSelf(int entity,int mask,any data){ return entity!=data; }
public Action Timer_ExplosTrace(Handle timer,int userid){
    int c=GetClientOfUserId(userid); if(c<=0||!IsClientInGame(c)||!IsPlayerAlive(c)) return Plugin_Stop;
    int w=GetPlayerWeaponSlot(c,0);
    int bits=(w>0&&w<2048)?g_iWeaponUnlock[w]:0;
    int bitVec=(w>0&&IsValidEdict(w))?GetEntProp(w,Prop_Send,"m_upgradeBitVec"):0;
    if(!(bits&2) && !(bitVec&2)) return Plugin_Stop;
    float now=GetGameTime();
    if(now-g_fLastSelfDmg[c]<0.12) return Plugin_Stop;
    float eyePos[3],eyeAng[3],endPos[3];
    GetClientEyePosition(c,eyePos);
    GetClientEyeAngles(c,eyeAng);
    Handle trace=TR_TraceRayFilterEx(eyePos,eyeAng,MASK_SHOT,RayType_Infinite,TraceFilterSelf,c);
    if(TR_DidHit(trace)){
        TR_GetEndPosition(endPos,trace);
        delete trace;
        TryExplosSelfDamage(c,endPos);
    } else { delete trace; }
    return Plugin_Stop;
}

void TryExplosSelfDamage(int client,float expPos[3]){
    if(client<=0||!IsClientInGame(client)||!IsPlayerAlive(client)) return;
    float now=GetGameTime();
    if(now-g_fLastSelfDmg[client]<0.12) return;
    float radius=g_cvExplosSelfRadius.FloatValue;
    if(radius<=0.0) return;
    float origin[3]; GetClientAbsOrigin(client,origin); origin[2]+=40.0;
    float dist=GetVectorDistance(expPos,origin);
    if(dist>radius) return;
    float maxDmg=g_cvExplosSelfDmg.FloatValue;
    if(maxDmg<=0.0) return;
    float dmg=maxDmg*(1.0-dist/radius);
    if(dmg<5.0) dmg=5.0;
    if(dmg>30.0) dmg=30.0;
    g_fLastSelfDmg[client]=now;
    SDKHooks_TakeDamage(client,0,0,dmg,DMG_BLAST,-1,NULL_VECTOR,expPos,true);
    if(g_cvExplosSelfStagger.BoolValue) L4D_StaggerPlayer(client,client,expPos);
    PrintCenterText(client,"高爆自伤 -%d (%.0f/%.0f)",RoundToNearest(dmg),dist,radius);
}

public void Event_BulletImpact(Event e,const char[] n,bool d){
    int c=GetClientOfUserId(e.GetInt("userid")); if(c<=0||!IsClientInGame(c)||!IsPlayerAlive(c)) return;
    int w=GetPlayerWeaponSlot(c,0);
    int bits=(w>0&&w<2048)?g_iWeaponUnlock[w]:0;
    int bitVec=(w>0&&IsValidEdict(w))?GetEntProp(w,Prop_Send,"m_upgradeBitVec"):0;
    if(!(bits&2) && !(bitVec&2)) return;
    float now=GetGameTime();
    if(now-g_fLastSelfDmg[c]<0.12) return;
    float expPos[3];
    expPos[0]=e.GetFloat("x"); expPos[1]=e.GetFloat("y"); expPos[2]=e.GetFloat("z");
    if(expPos[0]==0.0 && expPos[1]==0.0 && expPos[2]==0.0) return;
    TryExplosSelfDamage(c,expPos);
}

// 武器光效：掉落的已解锁武器发光
public void OnEntityCreated(int entity,const char[] classname){
    if(StrContains(classname,"weapon_",false)!=-1) CreateTimer(0.2,Timer_UpdateGlow,EntIndexToEntRef(entity),TIMER_FLAG_NO_MAPCHANGE);
}
public Action Timer_UpdateGlow(Handle t,int ref){ int ent=EntRefToEntIndex(ref); if(ent>0&&IsValidEdict(ent)) UpdateWeaponGlow(ent); return Plugin_Stop; }
public void OnEntityDestroyed(int ent){ if(ent>=0&&ent<2048) g_iWeaponUnlock[ent]=0; }
void UpdateWeaponGlow(int weapon){
    if(weapon<=0||!IsValidEdict(weapon)||weapon>=2048) return;
    int bits=g_iWeaponUnlock[weapon];
    int owner=GetEntPropEnt(weapon,Prop_Send,"m_hOwnerEntity");
    bool isDropped=(owner==-1||owner==0);
    if(!isDropped){
        L4D2_RemoveEntityGlow(weapon);
        SetEntProp(weapon,Prop_Send,"m_iGlowType",0);
        return;
    }
    if(bits&1){
        L4D2_SetEntityGlow(weapon,L4D2Glow_Constant,800,0,{255,0,0},false);
        SetEntProp(weapon,Prop_Send,"m_iGlowType",3);
        SetEntProp(weapon,Prop_Send,"m_nGlowRange",800);
    } else if(bits&2){
        L4D2_SetEntityGlow(weapon,L4D2Glow_Constant,800,0,{255,255,0},false);
        SetEntProp(weapon,Prop_Send,"m_iGlowType",3);
        SetEntProp(weapon,Prop_Send,"m_nGlowRange",800);
    } else {
        L4D2_RemoveEntityGlow(weapon);
        SetEntProp(weapon,Prop_Send,"m_iGlowType",0);
    }
}
