#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#define MODE_NORMAL 0
#define MODE_INCEND 1
#define MODE_EXPLOS 2
// DMG_BLAST defined in sdkhooks.inc but ensure exists for older includes
#if !defined DMG_BLAST
#define DMG_BLAST (1<<6)
#endif
ConVar g_cvIncendAdd, g_cvExplosAdd;
ConVar g_cvExplosSelfDmg, g_cvExplosSelfRadius, g_cvExplosSelfStagger;
float g_fLastSelfDmg[MAXPLAYERS+1];
int g_iTotalPool[MAXPLAYERS+1];
int g_iMode[MAXPLAYERS+1];
bool g_bUnlocked[MAXPLAYERS+1]; // deprecated, kept for compat - see g_iWeaponUnlock per-entity
int g_iWeaponUnlock[2048]; // bit0=incend bit1=explos per weapon entindex
int g_iClipSize[MAXPLAYERS+1];
float g_fRStart[MAXPLAYERS+1];
bool g_bRSwitched[MAXPLAYERS+1];
bool g_bForceReload[MAXPLAYERS+1];
bool g_bInReload[MAXPLAYERS+1];
float g_fReloadEnd[MAXPLAYERS+1];
int g_iReloadGive[MAXPLAYERS+1];
int g_iReloadOldCur[MAXPLAYERS+1];
Handle g_hReloadTimer[MAXPLAYERS+1];
int g_iShotgunNeed[MAXPLAYERS+1];
int g_iShotgunGive[MAXPLAYERS+1];
int g_iOldBtn[MAXPLAYERS+1];
int g_iPendingMode[MAXPLAYERS+1];
int g_iSwitchOldClip[MAXPLAYERS+1];
float g_fLastVerify[MAXPLAYERS+1];
int g_iWeaponRef[MAXPLAYERS+1];
bool g_bLaser[MAXPLAYERS+1];
int g_iAmmoType[MAXPLAYERS+1];
bool g_bShotgunNativeReload[MAXPLAYERS+1]; // 霰弹枪正在走引擎原生reload
int g_iShotgunPreReloadClip[MAXPLAYERS+1]; // 原生reload前的弹夹量
Handle g_hHudSync=null;
public Action Timer_ShotgunShell(Handle timer,int userid);
public Action Timer_ShotgunSwitchShell(Handle timer,int userid);
public Action Timer_EndShotgun(Handle t,int userid);
public Action Timer_PollReloadNormal(Handle timer,int userid);
public Action Timer_ExplosTrace(Handle timer,int userid);
public Action Timer_ShotgunNativeReloadDone(Handle timer,int userid);
public Action OnTakeDamageSelfCheck(int victim,int &attacker,int &inflictor,float &damage,int &damagetype,int &weapon,float damageForce[3],float damagePosition[3]);
public void Event_WeaponEquip(Event e,const char[] n,bool d);
public void Event_Fire(Event e,const char[] n,bool d);
public void Event_BulletImpact(Event e,const char[] n,bool d);
public void Event_RoundStart(Event e,const char[] n,bool d);
public void Event_Upgrade(Event e,const char[] n,bool d);
public void Event_Use(Event e,const char[] n,bool d);
public Plugin myinfo={name="[L4D2] Tactical Shared Pool",author="suli",description="共享总池 40/540+40=620 T切换",version="1.1.0",url=""};
public void OnPluginStart(){
    g_cvIncendAdd=CreateConVar("l4d2_tactical_incend_add","40","燃烧包追加",FCVAR_NOTIFY,true,1.0,true,200.0);
    g_cvExplosAdd=CreateConVar("l4d2_tactical_explos_add","40","高爆包追加",FCVAR_NOTIFY,true,1.0,true,200.0);
    g_cvExplosSelfDmg=CreateConVar("l4d2_tactical_explos_self_damage","25","高爆自伤基础伤害(贴脸) 平衡用 20-30",FCVAR_NOTIFY,true,1.0,true,100.0);
    g_cvExplosSelfRadius=CreateConVar("l4d2_tactical_explos_self_radius","150","高爆自伤判定半径",FCVAR_NOTIFY,true,10.0,true,500.0);
    g_cvExplosSelfStagger=CreateConVar("l4d2_tactical_explos_self_stagger","1","高爆自伤是否带击退硬直",FCVAR_NOTIFY,true,0.0,true,1.0);
    HookEvent("upgrade_pack_used",Event_Upgrade,EventHookMode_Post);
    HookEvent("upgrade_pack_added",Event_Upgrade,EventHookMode_Post);
    HookEvent("player_use",Event_Use,EventHookMode_Post);
    HookEvent("weapon_fire",Event_Fire,EventHookMode_Post);
    HookEvent("bullet_impact",Event_BulletImpact,EventHookMode_Post);
    HookEvent("round_start",Event_RoundStart,EventHookMode_PostNoCopy);
    HookEvent("item_pickup",Event_WeaponEquip,EventHookMode_Post);
    HookEvent("weapon_drop",Event_WeaponEquip,EventHookMode_Post);
    RegConsoleCmd("sm_tactical",Cmd_Switch);
    RegConsoleCmd("sm_changeammo",Cmd_Switch);
    RegConsoleCmd("sm_t",Cmd_Switch);
    RegConsoleCmd("sm_tinfo",Cmd_Info);
    AutoExecConfig(true,"l4d2_tactical_shared");
    g_hHudSync=CreateHudSynchronizer();
    CreateTimer(0.3,Timer_HUD,_,TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
    for(int i=1;i<=MaxClients;i++) g_iAmmoType[i]=-1;
    // hook already connected clients for late load
    for(int i=1;i<=MaxClients;i++) if(IsClientInGame(i)) SDKHook(i, SDKHook_OnTakeDamage, OnTakeDamageSelfCheck);
}
public void Event_RoundStart(Event e,const char[] n,bool d){ for(int i=1;i<=MaxClients;i++){ g_iTotalPool[i]=0; g_iMode[i]=0; g_bUnlocked[i]=false; g_fLastSelfDmg[i]=0.0; g_bShotgunNativeReload[i]=false; g_iShotgunPreReloadClip[i]=0; } for(int i=0;i<2048;i++) g_iWeaponUnlock[i]=0; }
public void OnClientPutInServer(int c){ CreateTimer(5.0,Timer_Bind,GetClientUserId(c),TIMER_FLAG_NO_MAPCHANGE); SDKHook(c, SDKHook_OnTakeDamage, OnTakeDamageSelfCheck); }
public void OnClientDisconnect(int c){ SDKUnhook(c, SDKHook_OnTakeDamage, OnTakeDamageSelfCheck); }
public Action Timer_Bind(Handle t,int id){ int c=GetClientOfUserId(id); if(c>0&&IsClientInGame(c)&&!IsFakeClient(c)){ ClientCommand(c,"bind t \"sm_tactical\""); } return Plugin_Stop; }
void EnsurePool(int client){
    int w=GetPlayerWeaponSlot(client,0);
    if(w<=0||!IsValidEdict(w)) return;
    int clip=GetEntProp(w,Prop_Send,"m_iClip1");
    int up=GetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded");
    int curClip= clip>0?clip:up;
    char wcls[64]; GetEdictClassname(w,wcls,sizeof(wcls));
    int maxClip=L4D2_GetIntWeaponAttribute(wcls,L4D2IWA_ClipSize);
    if(maxClip<=0){
        if(StrContains(wcls,"shotgun",false)!=-1) maxClip=8;
        else if(StrContains(wcls,"rifle",false)!=-1) maxClip=50;
        else if(StrContains(wcls,"sniper",false)!=-1) maxClip=15;
        else maxClip=40;
        // 回退用当前 clip 若仍0则用 maxClip
        if(curClip<=0) curClip=maxClip;
    } else {
        // maxClip 有效，用它作为 g_iClipSize，curClip 保持当前弹量用于 total 计算
        if(curClip<=0) curClip=maxClip;
    }
    int at=GetEntProp(w,Prop_Send,"m_iPrimaryAmmoType");
    int curRef=EntIndexToEntRef(w);
    bool isNewWeapon=(g_iWeaponRef[client]!=curRef || g_iAmmoType[client]!=at);
    int reserveNow=GetEntProp(client,Prop_Send,"m_iAmmo",_,at);
    g_iClipSize[client]=maxClip>0?maxClip:curClip;
    g_iAmmoType[client]=at;
    g_iWeaponRef[client]=curRef;
    g_bLaser[client]=(GetEntProp(w,Prop_Send,"m_upgradeBitVec")&4)!=0;
    if(g_iTotalPool[client]==0 || isNewWeapon){
        // 新枪按真实弹药重算总池，避免旧枪 620 污染 M16 50/50 等
        // 对已解锁枪且池非0时，若是同枪仅更新 clip/at，不重置 total（保持开火消耗后的 total）
        if(isNewWeapon){
            int b=(w>=0&&w<2048)?g_iWeaponUnlock[w]:0;
            if(b==0){
                // 未解锁新枪：用真实 reserve+cur 重置，避免 50/524 覆盖
                g_iTotalPool[client]=reserveNow+curClip;
            } else {
                // 已解锁新枪（如之前该 M16 已解锁过）：保留共享池，但按新枪 clip 校正
                // 若旧池与新枪真实 total 差异过大（>200），以真实为准防污染
                int realTotal=reserveNow+curClip;
                if(g_iTotalPool[client]==0) g_iTotalPool[client]=realTotal;
                else if(realTotal>0 && (g_iTotalPool[client]-realTotal>200 || realTotal-g_iTotalPool[client]>200)){
                    // 差异大说明是不同弹药类型的枪，重置为真实
                    g_iTotalPool[client]=realTotal;
                }
                // 否则保持旧池（共享池跨枪）
            }
        } else {
            g_iTotalPool[client]=reserveNow+curClip;
        }
        LogMessage("[shared] EnsurePool recalc client=%d w=%d cls=%s cur=%d reserve=%d total=%d isNew=%d b=%d",client,w,wcls,curClip,reserveNow,g_iTotalPool[client],isNewWeapon,(w>=0&&w<2048)?g_iWeaponUnlock[w]:-1);
    }
}
public void Event_Upgrade(Event e,const char[] n,bool d){
    // 仅 upgrade_pack_used 视为真实获取，upgrade_pack_added（拾取包）不计入，避免空拿解锁
    if(StrEqual(n,"upgrade_pack_added")) return;
    int c=GetClientOfUserId(e.GetInt("userid")); if(c<=0||!IsClientInGame(c)||!IsPlayerAlive(c)) return;
    int ent=e.GetInt("upgradeid"); char cls[64]; cls[0]='\0'; if(ent>0&&IsValidEdict(ent)) GetEdictClassname(ent,cls,sizeof(cls));
    if(StrContains(cls,"laser",false)!=-1) return;
    // 仅 upgrade_ammo_* 才计入，upgradepack_*（部署前）不计
    if(StrContains(cls,"upgradepack",false)!=-1 && StrContains(cls,"upgrade_ammo",false)==-1) return;
    bool isExpl=StrContains(cls,"explosive",false)!=-1;
    if(cls[0]=='\0'){ int w=GetPlayerWeaponSlot(c,0); if(w>0&&IsValidEdict(w)) isExpl=(GetEntProp(w,Prop_Send,"m_upgradeBitVec")&2)!=0; }
    // 延迟 0.25s 校验武器是否真实获得该升级（m_upgradeBitVec），避免空拿/部署未拾取即解锁（原0.12过早常Verify fail）
    DataPack dp; CreateDataTimer(0.25, Timer_VerifyUpgrade, dp, TIMER_FLAG_NO_MAPCHANGE);
    dp.WriteCell(GetClientUserId(c));
    dp.WriteString(cls);
    dp.WriteCell(isExpl?1:0);
    LogMessage("[shared] Upgrade queued client=%d %s pool=%d cls=%s",c,isExpl?"explos":"incend",g_iTotalPool[c],cls);
}
public void Event_Use(Event e,const char[] n,bool d){
    int c=GetClientOfUserId(e.GetInt("userid")); if(c<=0||!IsClientInGame(c)||!IsPlayerAlive(c)) return;
    int ent=e.GetInt("entity"); if(ent<=0||!IsValidEdict(ent)) return;
    char cls[64]; GetEdictClassname(ent,cls,sizeof(cls));
    if(StrContains(cls,"upgrade_ammo",false)!=-1){ // 仅弹药堆触发，拾取/部署 upgradepack 不触发
        bool isExpl=StrContains(cls,"explosive",false)!=-1;
        DataPack dp2; CreateDataTimer(0.25, Timer_VerifyUpgrade, dp2, TIMER_FLAG_NO_MAPCHANGE);
        dp2.WriteCell(GetClientUserId(c));
        char stdCls[64]; Format(stdCls,sizeof(stdCls),"%s",cls);
        dp2.WriteString(stdCls);
        dp2.WriteCell(isExpl?1:0);
        LogMessage("[shared] Use queued client=%d %s cls=%s",c,isExpl?"explos":"incend",cls);
    } else if(StrContains(cls,"ammo",false)!=-1){
        // 弹药堆：回满总池
        CreateTimer(0.2,Timer_SyncAmmo,GetClientUserId(c),TIMER_FLAG_NO_MAPCHANGE);
    }
}
public Action Timer_VerifyUpgrade(Handle timer, DataPack dp){
    dp.Reset(); int uid=dp.ReadCell(); char cls[64]; dp.ReadString(cls,sizeof(cls)); int isExplCell=dp.ReadCell();
    int c=GetClientOfUserId(uid); if(c<=0||!IsClientInGame(c)||!IsPlayerAlive(c)) return Plugin_Stop;
    float now=GetGameTime();
    if(now - g_fLastVerify[c] < 0.4){ LogMessage("[shared] Verify dedup skip client=%d",c); return Plugin_Stop; }
    g_fLastVerify[c]=now;
    int w=GetPlayerWeaponSlot(c,0); if(w<=0||!IsValidEdict(w)) return Plugin_Stop;
    int bit=GetEntProp(w,Prop_Send,"m_upgradeBitVec");
    int upAmmo=GetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded");
    bool hasIncend=(bit & 1)!=0;
    bool hasExplos=(bit & 2)!=0;
    // 严格以武器上真实出现特殊弹为准：需 bit 含 1/2 或 upAmmo>0
    if((bit & 3)==0 && upAmmo<=0){
        LogMessage("[shared] Verify fail no special on weapon client=%d bit=%d up=%d cls=%s",c,bit,upAmmo,cls);
        return Plugin_Stop;
    }
    bool isExpl=false;
    if(hasExplos) isExpl=true;
    else if(hasIncend) isExpl=false;
    else if(upAmmo>0){
        // upAmmo>0 但 bit 暂未同步（少见），以 cls 为准
        if(StrContains(cls,"explosive",false)!=-1) isExpl=true;
        else if(StrContains(cls,"incendiary",false)!=-1) isExpl=false;
        else isExpl=hasExplos;
    } else {
        // 无 bit 也无 up，回退 cls
        if(StrContains(cls,"explosive",false)!=-1) isExpl=true;
        else if(StrContains(cls,"incendiary",false)!=-1) isExpl=false;
        else { LogMessage("[shared] Verify fail unknown type client=%d bit=%d up=%d cls=%s",c,bit,upAmmo,cls); return Plugin_Stop; }
    }
    // 二次校验：声明类型需与 bit/up 一致
    if(isExpl && !hasExplos && upAmmo<=0){ LogMessage("[shared] Verify fail need explos but bit=%d up=%d client=%d",bit,upAmmo,c); return Plugin_Stop; }
    if(!isExpl && !hasIncend && upAmmo<=0){ LogMessage("[shared] Verify fail need incend but bit=%d up=%d client=%d",bit,upAmmo,c); return Plugin_Stop; }
    EnsurePool(c);
    int add=g_iClipSize[c]>0?g_iClipSize[c]:(isExpl?g_cvExplosAdd.IntValue:g_cvIncendAdd.IntValue);
    if(add<=0 || g_iClipSize[c]<=0){
        char wcls2[64]; GetEdictClassname(w,wcls2,sizeof(wcls2));
        int def2=L4D2_GetIntWeaponAttribute(wcls2,L4D2IWA_ClipSize);
        if(def2>0) add=def2;
    }
    g_iTotalPool[c]+=add;
    if(w<2048){ g_iWeaponUnlock[w] |= (isExpl?2:1); CreateTimer(0.1, Timer_UpdateGlow, EntIndexToEntRef(w), TIMER_FLAG_NO_MAPCHANGE); }
    g_bUnlocked[c]=true;
    int need=g_iClipSize[c];
    int newBit=(isExpl?2:1)|(g_bLaser[c]?4:0);
    SetEntProp(w,Prop_Send,"m_upgradeBitVec",newBit);
    SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",need);
    SetEntProp(w,Prop_Send,"m_iClip1",need);
    g_iMode[c]=isExpl?MODE_EXPLOS:MODE_INCEND;
    if(g_iAmmoType[c]>=0) SetEntProp(c,Prop_Send,"m_iAmmo",g_iTotalPool[c]-need,_,g_iAmmoType[c]);
    PrintCenterText(c,"→ %s +%d 总池%d [%s武器已解锁]",isExpl?"高爆":"燃烧",add,g_iTotalPool[c], isExpl?"高爆":"燃烧");
    PrintToChat(c,"[战术] \x04%s\x01 已解锁 \x03%s\x01 池%d 解锁:%s T切/R补", isExpl?"高爆":"燃烧", isExpl?"高爆":"燃烧", g_iTotalPool[c], isExpl?"高爆":"燃烧");
    EmitSoundToClient(c,"ui/pickup_guitar.wav");
    LogMessage("[shared] Verify ok client=%d %s +%d pool=%d bit=%d w=%d",c,isExpl?"explos":"incend",add,g_iTotalPool[c],bit,w);
    return Plugin_Stop;
}
public Action Timer_SyncAmmo(Handle t,int id){ int c=GetClientOfUserId(id); if(c>0&&IsClientInGame(c)){ EnsurePool(c); int w=GetPlayerWeaponSlot(c,0); if(w>0&&IsValidEdict(w)){ int at=g_iAmmoType[c]; if(at>=0){ int reserve=GetEntProp(c,Prop_Send,"m_iAmmo",_,at); int clip=GetEntProp(w,Prop_Send,"m_iClip1"); int up=GetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded"); int cur=clip>0?clip:up; g_iTotalPool[c]=reserve+cur; } } } return Plugin_Stop; }
public void Event_WeaponEquip(Event e,const char[] n,bool d){ int c=GetClientOfUserId(e.GetInt("userid")); if(c<=0||!IsClientInGame(c)) return; int w=GetPlayerWeaponSlot(c,0); if(w<=0||!IsValidEdict(w)) return; int bits=(w>=0&&w<2048)?g_iWeaponUnlock[w]:0; if(g_iMode[c]!=MODE_NORMAL && !(bits & (g_iMode[c]==MODE_INCEND?1:2))){ g_iMode[c]=MODE_NORMAL; PrintCenterText(c,"该武器无此弹种 回到普通"); } 
    // 换枪后更新旧枪的光（若旧枪在地上）
    // 延迟检查地上武器
    CreateTimer(0.5, Timer_UpdateAllGroundGlow, 0, TIMER_FLAG_NO_MAPCHANGE);
}
public Action Timer_UpdateAllGroundGlow(Handle t,int d){
    int ent=-1;
    while((ent=FindEntityByClassname(ent,"weapon_*"))!=-1){
        if(ent>=0&&ent<2048) UpdateWeaponGlow(ent);
    }
    return Plugin_Stop;
}
public void Event_Fire(Event e,const char[] n,bool d){
    int c=GetClientOfUserId(e.GetInt("userid")); if(c<=0||!IsClientInGame(c)) return;
    EnsurePool(c);
    if(g_iTotalPool[c]>0) g_iTotalPool[c]--;
    if(g_iTotalPool[c]<0) g_iTotalPool[c]=0;
    // 特殊弹打空后保持特殊模式：若游戏清除了 m_upgradeBitVec/m_nUpgraded，立即恢复特殊位（仅开火消耗，不自动切普通）
    int wf=GetPlayerWeaponSlot(c,0);
    if(wf>0&&IsValidEdict(wf) && g_iMode[c]!=MODE_NORMAL){
        int bUnlock=(wf>=0&&wf<2048)?g_iWeaponUnlock[wf]:0;
        int needBitF=(g_iMode[c]==MODE_INCEND?1:2);
        if((bUnlock & needBitF) && g_iTotalPool[c]>=0){
            int bitF=GetEntProp(wf,Prop_Send,"m_upgradeBitVec");
            int upF=GetEntProp(wf,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded");
            bool hasF=(bitF & needBitF)!=0 || upF>0;
            if(!hasF){
                // 恢复特殊位，弹夹保持空（0）等待 R 补特殊
                int keepLaserF=bitF & 4;
                int newBitF=needBitF | keepLaserF;
                SetEntProp(wf,Prop_Send,"m_upgradeBitVec",newBitF);
                // 保持空仓，不自动补
                // LogMessage("[shared] Keep special after empty c=%d mode=%d",c,g_iMode[c]);
            }
        }
    }
    // 高爆自伤：开火后做射线追踪找爆炸点，若在半径内对射手造成自伤+硬直
    if(g_iMode[c]==MODE_EXPLOS){
        int w=GetPlayerWeaponSlot(c,0);
        if(w>0&&IsValidEdict(w) && (w<2048 && (g_iWeaponUnlock[w]&2)!=0 || (GetEntProp(w,Prop_Send,"m_upgradeBitVec")&2)!=0)){
            // 延迟一帧做追踪，避免与 bullet_impact 重复时由时间去重
            CreateTimer(0.03, Timer_ExplosTrace, GetClientUserId(c), TIMER_FLAG_NO_MAPCHANGE);
        }
    }
}
// 射线过滤：忽略射手自己
bool TraceFilterSelf(int entity, int mask, any data){ return entity != data; }
public Action Timer_ExplosTrace(Handle timer, int userid){
    int c=GetClientOfUserId(userid); if(c<=0||!IsClientInGame(c)||!IsPlayerAlive(c)) return Plugin_Stop;
    if(g_iMode[c]!=MODE_EXPLOS) return Plugin_Stop;
    float now=GetGameTime();
    if(now - g_fLastSelfDmg[c] < 0.12) return Plugin_Stop; // 已被 bullet_impact 处理
    float eyePos[3], eyeAng[3], dir[3], endPos[3];
    GetClientEyePosition(c, eyePos);
    GetClientEyeAngles(c, eyeAng);
    GetAngleVectors(eyeAng, dir, NULL_VECTOR, NULL_VECTOR);
    // 追踪最远 2000 单位（足够覆盖自伤 150 半径内的墙面）
    // 若没命中，爆炸点过远无需自伤
    Handle trace = TR_TraceRayFilterEx(eyePos, eyeAng, MASK_SHOT, RayType_Infinite, TraceFilterSelf, c);
    if(TR_DidHit(trace)){
        TR_GetEndPosition(endPos, trace);
        delete trace;
        TryExplosSelfDamage(c, endPos);
    } else {
        delete trace;
    }
    return Plugin_Stop;
}
void TryExplosSelfDamage(int client, float expPos[3]){
    if(client<=0||!IsClientInGame(client)||!IsPlayerAlive(client)) return;
    if(g_iMode[client]!=MODE_EXPLOS) return;
    float now=GetGameTime();
    if(now - g_fLastSelfDmg[client] < 0.12) return;
    float radius=g_cvExplosSelfRadius.FloatValue;
    if(radius<=0.0) return;
    float origin[3];
    GetClientAbsOrigin(client, origin);
    // 用腹部高度更贴近爆炸判定（脚底+40）
    origin[2]+=40.0;
    float dist=GetVectorDistance(expPos, origin);
    if(dist > radius) return;
    float maxDmg=g_cvExplosSelfDmg.FloatValue;
    if(maxDmg<=0.0) return;
    float dmg=maxDmg * (1.0 - dist / radius);
    // 保底 5，贴脸 25，边缘衰减；钳位 5-30 防止秒杀
    if(dmg < 5.0) dmg=5.0;
    if(dmg > 30.0) dmg=30.0;
    // 防止刷到倒地前连续高频自伤：0.25s 内只吃一次
    g_fLastSelfDmg[client]=now;
    // 用 world 作 attacker/inflictor 绕过引擎对 self 的 FF 豁免（参考 can_full_damage / gl_splash_fix 经验：weapon 归属=自己会被再次豁免）
    // bypassHooks=true 确保伤害直落不受其它 OnTakeDamage 插件拦截（FF 插件等）
    SDKHooks_TakeDamage(client, 0, 0, dmg, DMG_BLAST, -1, NULL_VECTOR, expPos, true);
    if(g_cvExplosSelfStagger.BoolValue){
        // moderate knockback：L4D_StaggerPlayer 会推开并硬直 1s 左右
        L4D_StaggerPlayer(client, client, expPos);
    }
    // 视觉/音效反馈
    // 小爆炸粒子可选：TE 效果
    // 文本提示
    PrintCenterText(client, "高爆自伤 -%d (%.0f/%.0f)", RoundToNearest(dmg), dist, radius);
    LogMessage("[shared] HE self-damage client=%d dist=%.1f dmg=%.1f radius=%.1f pos=(%.0f,%.0f,%.0f)", client, dist, dmg, radius, expPos[0], expPos[1], expPos[2]);
}
// bullet_impact 事件：更精确的爆炸点（带散布），同样走 TryExplosSelfDamage，去重由时间戳保证
public void Event_BulletImpact(Event e,const char[] n,bool d){
    int c=GetClientOfUserId(e.GetInt("userid")); if(c<=0||!IsClientInGame(c)||!IsPlayerAlive(c)) return;
    if(g_iMode[c]!=MODE_EXPLOS) return;
    int w=GetPlayerWeaponSlot(c,0); if(w<=0||!IsValidEdict(w)) return;
    int bits=(w>=0&&w<2048)?g_iWeaponUnlock[w]:0;
    int bitVec=GetEntProp(w,Prop_Send,"m_upgradeBitVec");
    if(!(bits & 2) && !(bitVec & 2)) return;
    float now=GetGameTime();
    if(now - g_fLastSelfDmg[c] < 0.12) return;
    float expPos[3];
    expPos[0]=e.GetFloat("x");
    expPos[1]=e.GetFloat("y");
    expPos[2]=e.GetFloat("z");
    // 事件可能给 0,0,0（未命中或版本差异），则退回追踪路径
    if(expPos[0]==0.0 && expPos[1]==0.0 && expPos[2]==0.0){
        return; // 让 Timer_ExplosTrace 处理
    }
    TryExplosSelfDamage(c, expPos);
}
// 可选：OnTakeDamage 观测口（诊断用，验证 HE 子弹是否走 DMG_BLAST）
public Action OnTakeDamageSelfCheck(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3]){
    // 仅诊断：记录 HE 弹对幸存者造成的 DMG_BLAST（若引擎放行）
    // 不做修改，避免干扰自伤注入
    return Plugin_Continue;
}
void SwitchMode(int c){
    if(g_bInReload[c] || g_hReloadTimer[c]!=null){ PrintCenterText(c,"换弹中禁止切换"); return; }
    if(g_bShotgunNativeReload[c]){ PrintCenterText(c,"换弹中禁止切换"); return; }
    if(GetEntProp(GetPlayerWeaponSlot(c,0),Prop_Send,"m_bInReload")==1){ PrintCenterText(c,"换弹中禁止切换"); return; }
    int w=GetPlayerWeaponSlot(c,0); if(w<=0||!IsValidEdict(w)) return;
    int bits = (w>=0 && w<2048) ? g_iWeaponUnlock[w] : 0;
    // 兼容旧存档：若全局有解锁但该武器无位，则认为至少该武器已解锁当前g_iMode对应类型（迁移）
    if(bits==0 && g_bUnlocked[c]){
        // 首次迁移：将当前模式视为已解锁
        if(w<2048 && g_iMode[c]==MODE_INCEND) bits|=1;
        else if(w<2048 && g_iMode[c]==MODE_EXPLOS) bits|=2;
        if(bits!=0) g_iWeaponUnlock[w]=bits;
    }
    if(bits==0){ PrintCenterText(c,"该武器未解锁特殊弹 需先用弹药包"); return; }
    int cur=g_iMode[c];
    int next=cur;
    // 按  普通->燃烧->高爆->普通 循环，但跳过未解锁的形态
    for(int tries=0; tries<3; tries++){
        if(cur==MODE_NORMAL) next=MODE_INCEND;
        else if(cur==MODE_INCEND) next=MODE_EXPLOS;
        else next=MODE_NORMAL;
        if(next==MODE_NORMAL) break;
        int needBit = (next==MODE_INCEND?1:2);
        if(bits & needBit) break;
        cur=next; // 试下一形态
    }
    if(next!=MODE_NORMAL){
        int needBit2 = (next==MODE_INCEND?1:2);
        if(!(bits & needBit2)){ PrintCenterText(c,"该武器未解锁 %s", next==MODE_INCEND?"燃烧":"高爆"); return; }
    }
    // w 已取
    if(GetEntProp(w,Prop_Send,"m_bInReload")) SetEntProp(w,Prop_Send,"m_bInReload",0);
    EnsurePool(c);
    // 重新校验bits（防止切换中武器更换）
    bits = (w>=0 && w<2048) ? g_iWeaponUnlock[w] : 0;
    if(next!=MODE_NORMAL && !(bits & (next==MODE_INCEND?1:2))){ PrintCenterText(c,"该武器未解锁该形态"); return; }
    // 不丢弃：记录旧弹夹余弹，换弹后返还至池（仅开火算消耗）
    int oldUp=GetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded");
    int oldCl=GetEntProp(w,Prop_Send,"m_iClip1");
    int oldCur = oldUp>0?oldUp:oldCl;
    g_iSwitchOldClip[c]=oldCur;
    // 清空显示但总池保持不变（旧弹已在总池中，设0后 reserve=total）
    SetEntProp(w,Prop_Send,"m_iClip1",0);
    SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",0);
    int curBit=GetEntProp(w,Prop_Send,"m_upgradeBitVec");
    SetEntProp(w,Prop_Send,"m_upgradeBitVec",curBit & 4);
    g_iPendingMode[c]=next;
    g_iMode[c]=next;
    char wcls[64]; GetEdictClassname(w,wcls,sizeof(wcls));
    float baseDur=L4D2_GetFloatWeaponAttribute(wcls,L4D2FWA_ReloadDuration);
    if(baseDur<=0.1) baseDur=0.5;
    bool isShotgun=StrContains(wcls,"shotgun",false)!=-1;
    // 先播音效
    char snd[64]; Format(snd,sizeof(snd),"weapons/%s/reload.wav",wcls[7]);
    EmitSoundToClient(c,snd);
    if(isShotgun){
        // 霰弹切换逐发：need = ClipSize - oldCur（旧弹已返还至池，池不变）
        int needShot = g_iClipSize[c] - oldCur;
        if(needShot<0) needShot=0;
        if(needShot>g_iTotalPool[c]) needShot=g_iTotalPool[c];
        // 若 need 0（已满）直接给满
        if(needShot<=0){
            int giveShot=g_iClipSize[c]>=g_iTotalPool[c]?g_iTotalPool[c]:g_iClipSize[c];
            if(next==MODE_NORMAL){
                int bit=GetEntProp(w,Prop_Send,"m_upgradeBitVec");
                SetEntProp(w,Prop_Send,"m_upgradeBitVec",bit&4);
                SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",0);
                SetEntProp(w,Prop_Send,"m_iClip1",giveShot);
                if(g_iAmmoType[c]>=0) SetEntProp(c,Prop_Send,"m_iAmmo",g_iTotalPool[c]-giveShot,_,g_iAmmoType[c]);
            } else {
                int newBit2=(next==MODE_INCEND?1:2)|(g_bLaser[c]?4:0);
                SetEntProp(w,Prop_Send,"m_upgradeBitVec",newBit2);
                SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",giveShot);
                SetEntProp(w,Prop_Send,"m_iClip1",giveShot);
                if(g_iAmmoType[c]>=0) SetEntProp(c,Prop_Send,"m_iAmmo",g_iTotalPool[c]-giveShot,_,g_iAmmoType[c]);
            }
            PrintCenterText(c,"→ %s %d发 池%d",next==0?"普通":next==1?"燃烧":"高爆",giveShot,g_iTotalPool[c]);
            g_iSwitchOldClip[c]=0;
            return;
        }
        g_bForceReload[c]=true;
        g_iShotgunNeed[c]=needShot;
        g_iShotgunGive[c]=needShot;
        g_iReloadOldCur[c]=oldCur;
        g_iReloadGive[c]=-1; // 标记切换
        g_iShotgunPreReloadClip[c]=0;
        g_fReloadEnd[c]=GetGameTime()+baseDur;
        g_bInReload[c]=true;
        if(g_hReloadTimer[c]!=null){ KillTimer(g_hReloadTimer[c]); g_hReloadTimer[c]=null; }
        g_hReloadTimer[c]=CreateTimer(baseDur+0.12,Timer_ShotgunSwitchShell,GetClientUserId(c),TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
        PrintCenterText(c,"换弹中... → %s %d发 逐发 %.2fs/发",next==0?"普通":next==1?"燃烧":"高爆",needShot,baseDur);
        LogMessage("[shared] Switch shotgun per-shell %d %d->%d need=%d dur=%.2f",c,cur,next,needShot,baseDur);
    } else {
        float dur=baseDur+0.1;
        g_bForceReload[c]=true;
        g_fReloadEnd[c]=GetGameTime()+dur;
        g_iReloadGive[c]=-1;
        if(g_hReloadTimer[c]!=null){ KillTimer(g_hReloadTimer[c]); g_hReloadTimer[c]=null; }
        DataPack p; CreateDataTimer(0.05,Timer_PollSwitch,p,TIMER_FLAG_NO_MAPCHANGE);
        p.WriteCell(GetClientUserId(c));
        PrintCenterText(c,"换弹中... → %s (%.1fs)",next==0?"普通":next==1?"燃烧":"高爆",dur);
        LogMessage("[shared] Switch poll %d %d->%d dur=%.2f pool=%d",c,cur,next,dur,g_iTotalPool[c]);
    }
}
public Action Timer_PollSwitch(Handle timer,DataPack p){
    p.Reset(); int uid=p.ReadCell(); int c=GetClientOfUserId(uid);
    if(c<=0||!IsClientInGame(c)||!IsPlayerAlive(c)) return Plugin_Stop;
    int w=GetPlayerWeaponSlot(c,0);
    if(w<=0||!IsValidEdict(w)) return Plugin_Stop;
    float now=GetGameTime();
    if(now < g_fReloadEnd[c] - 0.05) return Plugin_Continue;
    bool bInReload=GetEntProp(w,Prop_Send,"m_bInReload")!=0;
    float nextAt=GetEntPropFloat(c,Prop_Send,"m_flNextAttack");
    float nextPrim=GetEntPropFloat(w,Prop_Send,"m_flNextPrimaryAttack");
    if(bInReload) return Plugin_Continue;
    if(nextAt > now+0.05 || nextPrim > now+0.05) return Plugin_Continue;
    // 触发真实 Give
    DataPack p2; CreateDataTimer(0.01,Timer_GiveNewAmmo,p2,TIMER_FLAG_NO_MAPCHANGE);
    p2.WriteCell(GetClientUserId(c));
    LogMessage("[shared] PollSwitch done c=%d",c);
    return Plugin_Stop;
}
public Action Timer_GiveNewAmmo(Handle t,DataPack p){
    p.Reset(); int id=p.ReadCell(); int c=GetClientOfUserId(id);
    if(c<=0||!IsClientInGame(c)||!IsPlayerAlive(c)) return Plugin_Stop;
    int next=g_iPendingMode[c];
    int w=GetPlayerWeaponSlot(c,0); if(w<=0||!IsValidEdict(w)) return Plugin_Stop;
    int need=g_iClipSize[c];
    // 总池已包含旧弹（切换前 total 含 oldCur，设0后未扣），新弹直接取满但不额外扣 total（仅开火扣）
    // 新弹夹取 min(need, total) ，total 保持不变，余弹已保留
    int give=g_iTotalPool[c]>=need?need:g_iTotalPool[c];
    // 不再 g_iTotalPool-=give，保持 total 不变；旧弹已在池中，新弹从池中分配但 total 不变（切换不消耗）
    // 若需严格“切换不消耗”，保持 total；若需“切换消耗补满差值”，则 total 已含旧弹，give 已含旧弹部分，无需额外扣
    if(next==MODE_NORMAL){
        int bit=GetEntProp(w,Prop_Send,"m_upgradeBitVec");
        SetEntProp(w,Prop_Send,"m_upgradeBitVec",bit&4);
        SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",0);
        SetEntProp(w,Prop_Send,"m_iClip1",give);
        if(g_iAmmoType[c]>=0) SetEntProp(c,Prop_Send,"m_iAmmo",g_iTotalPool[c]-give,_,g_iAmmoType[c]);
        PrintCenterText(c,"→ 普通弹 %d发 池%d 返还%d",give,g_iTotalPool[c],g_iSwitchOldClip[c]);
    } else {
        int newBit=(next==MODE_INCEND?1:2)|(g_bLaser[c]?4:0);
        SetEntProp(w,Prop_Send,"m_upgradeBitVec",newBit);
        SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",give);
        SetEntProp(w,Prop_Send,"m_iClip1",give);
        if(g_iAmmoType[c]>=0) SetEntProp(c,Prop_Send,"m_iAmmo",g_iTotalPool[c]-give,_,g_iAmmoType[c]);
        PrintCenterText(c,"→ %s %d发 池%d 返还%d",next==MODE_INCEND?"燃烧":"高爆",give,g_iTotalPool[c],g_iSwitchOldClip[c]);
    }
    g_iSwitchOldClip[c]=0;
    return Plugin_Stop;
}
public Action Timer_HUD(Handle t){
    for(int c=1;c<=MaxClients;c++){
        if(!IsClientInGame(c)||IsFakeClient(c)||!IsPlayerAlive(c)) continue;
        // 特殊弹原生 reload 起始检测（兜底：若 OnPlayerRunCmd 劫持漏网，标记以便结束时转特种）— 通用，覆盖霰弹及所有步枪/狙
        if(!g_bShotgunNativeReload[c] && !g_bInReload[c] && g_hReloadTimer[c]==null) {
            int wDet = GetPlayerWeaponSlot(c,0);
            if(wDet>0 && IsValidEdict(wDet) && g_iMode[c]!=MODE_NORMAL) {
                int bitsDet=(wDet>=0&&wDet<2048)?g_iWeaponUnlock[wDet]:0;
                int needDet=(g_iMode[c]==MODE_INCEND?1:2);
                if((bitsDet & needDet)!=0 && GetEntProp(wDet,Prop_Send,"m_bInReload")!=0) {
                    g_bShotgunNativeReload[c]=true;
                    g_iShotgunPreReloadClip[c]=GetEntProp(wDet,Prop_Send,"m_iClip1");
                }
            }
        }
        // 检测原生reload是否结束（通用）
        if(g_bShotgunNativeReload[c]){
            int wDetect=GetPlayerWeaponSlot(c,0);
            if(wDetect>0&&IsValidEdict(wDetect)){
                bool bInReload=GetEntProp(wDetect,Prop_Send,"m_bInReload")!=0;
                if(!bInReload){
                    // reload结束，恢复特殊位+同步总池
                    g_bShotgunNativeReload[c]=false;
                    int modeR=g_iMode[c];
                    if(modeR!=MODE_NORMAL){
                        int newBit=(modeR==MODE_INCEND?1:2)|(g_bLaser[c]?4:0);
                        SetEntProp(wDetect,Prop_Send,"m_upgradeBitVec",newBit);
                        int finalClip=GetEntProp(wDetect,Prop_Send,"m_iClip1");
                        SetEntProp(wDetect,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",finalClip);
                    }
                    // 重新同步总池：引擎reload消耗了m_iAmmo，以引擎为准
                    int atR=g_iAmmoType[c];
                    if(atR>=0){
                        int reserveAfter=GetEntProp(c,Prop_Send,"m_iAmmo",_,atR);
                        int clipAfter=GetEntProp(wDetect,Prop_Send,"m_iClip1");
                        g_iTotalPool[c]=reserveAfter+clipAfter;
                    }
                }
            }
        }
        int w2pre=GetPlayerWeaponSlot(c,0); int b2pre=(w2pre>0&&w2pre<2048)?g_iWeaponUnlock[w2pre]:0;
        // 仅对已解锁特殊弹的武器同步共享池到武器栏；未解锁武器保持原版备弹，避免 50/524 乱覆盖
        if(b2pre!=0 && g_iTotalPool[c]!=0 && g_iAmmoType[c]>=0){
            int w=GetPlayerWeaponSlot(c,0);
            if(w>0&&IsValidEdict(w)){
                int clip=GetEntProp(w,Prop_Send,"m_iClip1");
                int up=GetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded");
                int cur= up>0?up:clip;
                // 霰弹枪原生reload期间：引擎自己管 m_iAmmo，不要覆写
                if(!g_bShotgunNativeReload[c]){
                    SetEntProp(c,Prop_Send,"m_iAmmo",g_iTotalPool[c]-cur,_,g_iAmmoType[c]);
                }
                // 同步特殊弹 UI：确保 m_upgradeBitVec/m_nUpgraded 与 g_iMode 一致，否则原生 UI 仍显示普通
                // 霰弹枪原生reload期间：特殊位已清掉让引擎装普通弹，不要恢复
                if(g_iMode[c]!=MODE_NORMAL && !g_bInReload[c] && g_hReloadTimer[c]==null && !g_bShotgunNativeReload[c]){
                    int curBit=GetEntProp(w,Prop_Send,"m_upgradeBitVec");
                    int needBit2=(g_iMode[c]==MODE_INCEND?1:2);
                    bool hasNeed=(curBit & needBit2)!=0;
                    bool hasUp=up>0;
                    if(!hasNeed || !hasUp){
                        // 保持特殊图标：仅在非换弹空闲时修正，避免与换弹动画冲突
                        if(b2pre & needBit2){
                            int keepLaser2=curBit & 4;
                            int newBit2=needBit2 | keepLaser2;
                            SetEntProp(w,Prop_Send,"m_upgradeBitVec",newBit2);
                            // 保持空仓时 up=0 已在 Event_Fire 恢复位，cur>0 时同步 up
                            if(cur>0){
                                SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",cur);
                                SetEntProp(w,Prop_Send,"m_iClip1",cur);
                            }
                        }
                    }
                }
            }
        } else if(g_iTotalPool[c]==0 && b2pre==0){
            // 未解锁且池为0时尝试初始化（兼容首局）
            EnsurePool(c);
        }
        int mode=g_iMode[c];
        // 轮询检测：武器上真实出现特殊弹即解锁（覆盖 shop 直接赋 bit 等无事件路径）
        int wPoll=GetPlayerWeaponSlot(c,0);
        if(wPoll>0&&IsValidEdict(wPoll)){
            int bitPoll=GetEntProp(wPoll,Prop_Send,"m_upgradeBitVec");
            int upPoll=GetEntProp(wPoll,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded");
            bool hasPoll=((bitPoll & 3)!=0 || upPoll>0);
            int bPoll=(wPoll>=0&&wPoll<2048)?g_iWeaponUnlock[wPoll]:0;
            if(hasPoll && bPoll != 3){
                bool isExplPoll=(bitPoll & 2)!=0 || (upPoll>0 && (bitPoll &1)==0 && (bitPoll &2)!=0);
                // 若 bit 同时有 1/2 以 bit 为准，否则按 up 存在即按 bit
                if((bitPoll & 2)!=0) isExplPoll=true;
                else if((bitPoll &1)!=0) isExplPoll=false;
                else if(upPoll>0){
                    // 无 bit 但有 up，保守按 incend
                    isExplPoll=false;
                }
                int needBitPoll = isExplPoll?2:1;
                if((bPoll & needBitPoll)!=0){
                    // 该枪已解锁该类型，跳过避免重复加池
                } else if((bitPoll & 3)!=0 || upPoll>0){
                    EnsurePool(c);
                    int addPoll=g_iClipSize[c]>0?g_iClipSize[c]:40;
                    if(addPoll<=0){
                        char tmpCls[64]; GetEdictClassname(wPoll,tmpCls,sizeof(tmpCls));
                        int defPoll=L4D2_GetIntWeaponAttribute(tmpCls,L4D2IWA_ClipSize);
                        if(defPoll>0) addPoll=defPoll;
                    }
                    float nowPoll=GetGameTime();
                    if(nowPoll - g_fLastVerify[c] > 0.4){
                        g_fLastVerify[c]=nowPoll;
                        g_iTotalPool[c]+=addPoll;
                        if(wPoll<2048){ g_iWeaponUnlock[wPoll] |= (isExplPoll?2:1); CreateTimer(0.1, Timer_UpdateGlow, EntIndexToEntRef(wPoll), TIMER_FLAG_NO_MAPCHANGE); }
                        g_bUnlocked[c]=true;
                        // 保持当前特殊弹夹为满（若已不满则补满）
                        int needPoll=g_iClipSize[c];
                        int curPoll=upPoll>0?upPoll:GetEntProp(wPoll,Prop_Send,"m_iClip1");
                        if(curPoll<needPoll){
                            int newBitPoll=(isExplPoll?2:1)|(g_bLaser[c]?4:0);
                            SetEntProp(wPoll,Prop_Send,"m_upgradeBitVec",newBitPoll);
                            SetEntProp(wPoll,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",needPoll);
                            SetEntProp(wPoll,Prop_Send,"m_iClip1",needPoll);
                            if(g_iAmmoType[c]>=0) SetEntProp(c,Prop_Send,"m_iAmmo",g_iTotalPool[c]-needPoll,_,g_iAmmoType[c]);
                        }
                        g_iMode[c]=isExplPoll?MODE_EXPLOS:MODE_INCEND;
                        PrintCenterText(c,"→ %s +%d 总池%d [%s武器已解锁]",isExplPoll?"高爆":"燃烧",addPoll,g_iTotalPool[c], isExplPoll?"高爆":"燃烧");
                        PrintToChat(c,"[战术] \x04%s\x01 已解锁 \x03%s\x01 池%d 解锁:%s T切/R补", isExplPoll?"高爆":"燃烧", isExplPoll?"高爆":"燃烧", g_iTotalPool[c], isExplPoll?"高爆":"燃烧");
                        EmitSoundToClient(c,"ui/pickup_guitar.wav");
                        LogMessage("[shared] Poll unlock client=%d w=%d bit=%d up=%d add=%d total=%d",c,wPoll,bitPoll,upPoll,addPoll,g_iTotalPool[c]);
                    }
                }
            }
        }
        int w2=GetPlayerWeaponSlot(c,0); int b2=(w2>0&&w2<2048)?g_iWeaponUnlock[w2]:0;
        if(b2!=0 || g_iTotalPool[c]>0){
            char unlockStr[16]; unlockStr[0]='\0';
            if(b2 & 1) StrCat(unlockStr,sizeof(unlockStr),"燃烧");
            if(b2 & 2) StrCat(unlockStr,sizeof(unlockStr),"高爆");
            if(unlockStr[0]=='\0') Format(unlockStr,sizeof(unlockStr),"无");
            char line[64]; Format(line,sizeof(line),"总池 %d [%s] 解锁:%s",g_iTotalPool[c],mode==0?"普通":mode==1?"燃烧":"高爆",unlockStr);
            SetHudTextParams(0.85,0.88,0.4,255,200,0,255,0,0.0,0.0,0.0);
            ShowSyncHudText(c,g_hHudSync,line);
        } else ClearSyncHud(c,g_hHudSync);
    }
    return Plugin_Continue;
}
public void OnEntityCreated(int entity, const char[] classname){
    if(StrContains(classname,"weapon_",false)!=-1){
        CreateTimer(0.2, Timer_UpdateGlow, EntIndexToEntRef(entity), TIMER_FLAG_NO_MAPCHANGE);
    }
}
public Action Timer_UpdateGlow(Handle t,int ref){ int ent=EntRefToEntIndex(ref); if(ent>0&&IsValidEdict(ent)) UpdateWeaponGlow(ent); return Plugin_Stop; }
public void OnEntityDestroyed(int ent){
    if(ent>=0 && ent<2048){
        g_iWeaponUnlock[ent]=0;
        // 实体已销毁，不再触碰其 props（IsValidEdict/HasEntProp 在此时不可靠，旧代码曾刷 m_iGlowType not found）
    }
}
void UpdateWeaponGlow(int weapon){
    if(weapon<=0||!IsValidEdict(weapon)||weapon>=2048) return;
    char cls[64]; GetEdictClassname(weapon,cls,sizeof(cls));
    if(StrContains(cls,"weapon_",false)==-1) return;
    int bits=g_iWeaponUnlock[weapon];
    // 仅对掉落在地上的武器上光（有 m_hOwnerEntity== -1 或 owner == -1）
    int owner=GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
    bool isDropped=(owner==-1 || owner==0);
    // 若被玩家持有，不上光（避免手持时光污染），仅掉落后上光
    if(!isDropped){
        L4D2_RemoveEntityGlow(weapon);
        SetEntProp(weapon, Prop_Send, "m_iGlowType", 0);
        return;
    }
    if(bits & 1){
        // 燃烧：红色
        L4D2_SetEntityGlow(weapon, L4D2Glow_Constant, 800, 0, {255,0,0}, false);
        SetEntProp(weapon, Prop_Send, "m_iGlowType", 3);
        SetEntProp(weapon, Prop_Send, "m_nGlowRange", 800);
        SetEntityRenderColor(weapon, 255, 40, 40, 255);
    } else if(bits & 2){
        // 高爆：黄色
        L4D2_SetEntityGlow(weapon, L4D2Glow_Constant, 800, 0, {255,255,0}, false);
        SetEntProp(weapon, Prop_Send, "m_iGlowType", 3);
        SetEntProp(weapon, Prop_Send, "m_nGlowRange", 800);
        SetEntityRenderColor(weapon, 255, 255, 0, 255);
    } else {
        L4D2_RemoveEntityGlow(weapon);
        SetEntProp(weapon, Prop_Send, "m_iGlowType", 0);
        SetEntityRenderColor(weapon, 255, 255, 255, 255);
    }
}
public Action OnPlayerRunCmd(int c,int &buttons,int &impulse,float vel[3],float angles[3],int &weapon,int &subtype,int &cmdnum,int &tickcount,int &seed,int mouse[2]){
    bool bWasForced=g_bForceReload[c];
    if(bWasForced){ buttons |= IN_RELOAD; g_bForceReload[c]=false; }
    // --- 霰弹枪特殊弹原生 reload 劫持：打空后重上普通弹的修复 ---
    // 引擎的霰弹 m_bInReload 会在下个 tick 才置位，现有 IN_RELOAD 上升沿已拦截按钮触发的重装，
    // 但打空后引擎可能自动起原生逐发（或按钮拦截失败的竞态）会导致插入普通弹。此处每 tick 检测原生 reload 并劫持
    {
        // 通用劫持：任意枪在特殊模式下若引擎已起原生 m_bInReload（打空后自动或竞态漏检），立即取消并转自定义特殊装填
        int wAny = GetPlayerWeaponSlot(c,0);
        if(wAny>0 && IsValidEdict(wAny) && g_iMode[c]!=MODE_NORMAL && !g_bInReload[c] && g_hReloadTimer[c]==null) {
            int bitsAny = (wAny>=0 && wAny<2048) ? g_iWeaponUnlock[wAny] : 0;
            int needBitAny = (g_iMode[c]==MODE_INCEND?1:2);
            if((bitsAny & needBitAny)!=0) {
                bool bNativeAny = GetEntProp(wAny, Prop_Send, "m_bInReload") != 0;
                if(bNativeAny && !g_bShotgunNativeReload[c]) {
                    SetEntProp(wAny, Prop_Send, "m_bInReload", 0);
                    EnsurePool(c);
                    int curUpAny = GetEntProp(wAny, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded");
                    int curClAny = GetEntProp(wAny, Prop_Send, "m_iClip1");
                    int curAny = curUpAny>0?curUpAny:curClAny;
                    int clipSizeAny = g_iClipSize[c];
                    if(clipSizeAny<=0) {
                        char tmpCls[64]; GetEdictClassname(wAny,tmpCls,sizeof(tmpCls));
                        if(StrContains(tmpCls,"shotgun",false)!=-1) clipSizeAny=8;
                        else clipSizeAny=40;
                    }
                    if(curAny < clipSizeAny) {
                        int availAny = g_iTotalPool[c] - curAny;
                        if(availAny > 0) {
                            buttons &= ~IN_RELOAD;
                            DoSpecialReload(c);
                            g_iOldBtn[c] = buttons & ~IN_RELOAD;
                            return Plugin_Changed;
                        } else {
                            PrintCenterText(c,"特殊弹药耗尽");
                            buttons &= ~IN_RELOAD;
                            g_iOldBtn[c] = buttons & ~IN_RELOAD;
                            return Plugin_Changed;
                        }
                    } else {
                        buttons &= ~IN_RELOAD;
                        g_iOldBtn[c] = buttons & ~IN_RELOAD;
                        return Plugin_Changed;
                    }
                }
            }
        }
    }
    // 空闲即时纠正：特殊模式下若普通弹残留（打空后首发上普通），0.05内自动转回特种，无需二次R
    {
        int wCorr = GetPlayerWeaponSlot(c,0);
        if(wCorr>0 && IsValidEdict(wCorr) && g_iMode[c]!=MODE_NORMAL && !g_bInReload[c] && g_hReloadTimer[c]==null && !g_bShotgunNativeReload[c]) {
            if(GetEntProp(wCorr, Prop_Send, "m_bInReload")==0) {
                int bitsCorr = (wCorr>=0&&wCorr<2048)?g_iWeaponUnlock[wCorr]:0;
                int needBitCorr = (g_iMode[c]==MODE_INCEND?1:2);
                if((bitsCorr & needBitCorr)!=0) {
                    int curBitCorr = GetEntProp(wCorr, Prop_Send, "m_upgradeBitVec");
                    int upCorr = GetEntProp(wCorr, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded");
                    int clCorr = GetEntProp(wCorr, Prop_Send, "m_iClip1");
                    int curCorr = upCorr>0?upCorr:clCorr;
                    bool hasNeedCorr = (curBitCorr & needBitCorr)!=0;
                    bool hasUpCorr = upCorr>0;
                    if(curCorr>0 && (!hasNeedCorr || !hasUpCorr)) {
                        int newBitCorr = needBitCorr | (curBitCorr & 4);
                        SetEntProp(wCorr, Prop_Send, "m_upgradeBitVec", newBitCorr);
                        SetEntProp(wCorr, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded", curCorr);
                        SetEntProp(wCorr, Prop_Send, "m_iClip1", curCorr);
                        if(g_iAmmoType[c]>=0) SetEntProp(c, Prop_Send, "m_iAmmo", g_iTotalPool[c]-curCorr, _, g_iAmmoType[c]);
                    }
                }
            }
        }
    }
    // 霰弹逐发即时纠正：特殊模式逐发装填时，引擎每插入一发普通弹，立即转为特种，保证UI一发一变
    {
        int wSC = GetPlayerWeaponSlot(c,0);
        if(wSC>0 && IsValidEdict(wSC) && g_iMode[c]!=MODE_NORMAL) {
            char wclsSC[64]; GetEdictClassname(wSC,wclsSC,sizeof(wclsSC));
            if(StrContains(wclsSC,"shotgun",false)!=-1) {
                int bitsSC = (wSC<2048)?g_iWeaponUnlock[wSC]:0;
                int needSC = (g_iMode[c]==MODE_INCEND?1:2);
                if((bitsSC & needSC)!=0) {
                    int bitSC = GetEntProp(wSC, Prop_Send, "m_upgradeBitVec");
                    int upSC = GetEntProp(wSC, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded");
                    int clSC = GetEntProp(wSC, Prop_Send, "m_iClip1");
                    int curSC = upSC>0?upSC:clSC;
                    if(curSC>0 && curSC > g_iShotgunPreReloadClip[c] && ((bitSC & needSC)==0 || upSC==0)) {
                        if(g_iShotgunNeed[c]>0 || GetEntProp(wSC, Prop_Send, "m_bInReload")!=0) {
                            int newBitSC = needSC | (bitSC & 4);
                            SetEntProp(wSC, Prop_Send, "m_upgradeBitVec", newBitSC);
                            SetEntProp(wSC, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded", curSC);
                            SetEntProp(wSC, Prop_Send, "m_iClip1", curSC);
                            if(g_iAmmoType[c]>=0) SetEntProp(c, Prop_Send, "m_iAmmo", g_iTotalPool[c]-curSC, _, g_iAmmoType[c]);
                            g_iShotgunPreReloadClip[c] = curSC;
                            if(g_iShotgunNeed[c]>0) g_iShotgunNeed[c]--;
                        }
                    }
                }
            }
        }
    }
    // 拦截特殊弹下的 R 换弹：补满特殊而不是普通
    bool curReload = (buttons & IN_RELOAD)!=0;
    // 强制注入的 IN_RELOAD 不应算作 prev，避免下次真实 R 被判为按住需按两次
    bool prevReload = (g_iOldBtn[c] & IN_RELOAD)!=0 && !bWasForced;
    if(curReload && !prevReload && !g_bInReload[c]){
        int w=GetPlayerWeaponSlot(c,0);
        if(w>0 && IsValidEdict(w) && g_iMode[c]!=MODE_NORMAL){
            int bits=(w>=0&&w<2048)?g_iWeaponUnlock[w]:0;
            int needBit=(g_iMode[c]==MODE_INCEND?1:2);
            if(bits & needBit){
                int up=GetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded");
                int cl=GetEntProp(w,Prop_Send,"m_iClip1");
                int cur= up>0?up:cl;
                EnsurePool(c);
                int clipSize=g_iClipSize[c];
                if(clipSize<=0) clipSize=40;
                if(cur < clipSize){
                    int avail = g_iTotalPool[c] - cur;
                    if(avail>0){
                        char wcls[64]; GetEdictClassname(w,wcls,sizeof(wcls));
                        bool isShotgun = StrContains(wcls,"shotgun",false)!=-1;
                        if(isShotgun){
                            // 方案A：霰弹枪同非霰弹走自定义逐发 DoSpecialReload，避免原生竞态上普通弹
                            buttons &= ~IN_RELOAD;
                            DoSpecialReload(c);
                            g_iOldBtn[c]=buttons & ~IN_RELOAD;
                            return Plugin_Changed;
                        } else {
                            // 非霰弹枪：保持原自定义逻辑（一次性补满）
                            buttons &= ~IN_RELOAD;
                            DoSpecialReload(c);
                            g_iOldBtn[c]=buttons & ~IN_RELOAD;
                            return Plugin_Changed;
                        }
                    }
                }
            }
        }
    }
    // 去除强制位再存 prev，避免污染下次上升沿检测
    if(bWasForced) g_iOldBtn[c]=buttons & ~IN_RELOAD;
    else g_iOldBtn[c]=buttons;
    return Plugin_Continue;
}
void DoSpecialReload(int c){
    if(g_bInReload[c]) return;
    int w=GetPlayerWeaponSlot(c,0); if(w<=0||!IsValidEdict(w)) return;
    if(GetEntProp(w,Prop_Send,"m_bInReload")) SetEntProp(w,Prop_Send,"m_bInReload",0);
    EnsurePool(c);
    int mode=g_iMode[c];
    if(mode==MODE_NORMAL) return;
    int curUp=GetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded");
    int curCl=GetEntProp(w,Prop_Send,"m_iClip1");
    int cur= curUp>0?curUp:curCl;
    int clipSize=g_iClipSize[c];
    if(clipSize<=0) clipSize=40;
    int need=clipSize - cur;
    if(need<=0) return;
    int avail=g_iTotalPool[c] - cur;
    if(avail<=0){
        PrintCenterText(c,"特殊弹药耗尽");
        // 保持特殊模式，不自动切普通，等待拾取新包
        g_bInReload[c]=false;
        return;
    }
    int give = need<=avail?need:avail;
    // 记录将补到的新弹量，定时后填入（期间走强制换弹动画）
    g_bInReload[c]=true;
    g_iPendingMode[c]=mode; // 复用pending存目标模式
    // 用DataPack传 give
    char wcls[64]; GetEdictClassname(w,wcls,sizeof(wcls));
    float baseDur=L4D2_GetFloatWeaponAttribute(wcls,L4D2FWA_ReloadDuration);
    if(baseDur<=0.1) baseDur=0.45;
    bool isShotgun=StrContains(wcls,"shotgun",false)!=-1;
    g_bForceReload[c]=true;
    // 首帧注入后 0.05s 读真实 nextPrim 校正 g_fReloadEnd，避免 baseDur+0.1 与 0.81-1.27 实测偏差提前补弹
    g_iReloadOldCur[c]=cur;
    g_iReloadGive[c]=give;
    g_iPendingMode[c]=mode;
    g_iShotgunNeed[c]=need;
    g_iShotgunGive[c]=give;
    g_iShotgunPreReloadClip[c]=cur;
    // 预设待校正，首轮 Poll 即用 nextPrim 覆盖
    g_fReloadEnd[c]=GetGameTime()+baseDur+0.3;
    char snd[64]; Format(snd,sizeof(snd),"weapons/%s/reload.wav",wcls[7]);
    EmitSoundToClient(c,snd);
    if(isShotgun){
        if(g_hReloadTimer[c]!=null){ KillTimer(g_hReloadTimer[c]); g_hReloadTimer[c]=null; }
        g_hReloadTimer[c]=CreateTimer(0.05,Timer_ShotgunShell,GetClientUserId(c),TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
        PrintCenterText(c,"装填 %s %d发 逐发",mode==MODE_INCEND?"燃烧":"高爆",give);
        LogMessage("[shared] Reload shotgun poll c=%d need=%d give=%d baseDur=%.2f",c,need,give,baseDur);
    } else {
        float dur=baseDur+0.1;
        g_fReloadEnd[c]=GetGameTime()+dur;
        PrintCenterText(c,"装填 %s +%d (%.1fs)",mode==MODE_INCEND?"燃烧":"高爆",give,dur);
        if(g_hReloadTimer[c]!=null){ KillTimer(g_hReloadTimer[c]); g_hReloadTimer[c]=null; }
        g_hReloadTimer[c]=CreateTimer(0.05,Timer_PollReload,GetClientUserId(c),TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
        LogMessage("[shared] Reload poll c=%d mode=%d cur=%d need=%d give=%d dur=%.2f pool=%d",c,mode,cur,need,give,dur,g_iTotalPool[c]);
    }
}
public Action Timer_ShotgunShell(Handle timer,int userid){
    int c=GetClientOfUserId(userid);
    if(c<=0||!IsClientInGame(c)||!IsPlayerAlive(c)){ if(c>0){ g_bInReload[c]=false; g_hReloadTimer[c]=null; } return Plugin_Stop; }
    int w=GetPlayerWeaponSlot(c,0);
    if(w<=0||!IsValidEdict(w)){ g_bInReload[c]=false; g_hReloadTimer[c]=null; return Plugin_Stop; }
    int buttons=GetClientButtons(c);
    if(buttons & IN_ATTACK){
        g_bInReload[c]=false; g_hReloadTimer[c]=null;
        int curUpI=GetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded");
        int curClI=GetEntProp(w,Prop_Send,"m_iClip1");
        int curI=curUpI>0?curUpI:curClI;
        PrintCenterText(c,"换弹中断 %d/%d",curI,g_iClipSize[c]);
        return Plugin_Stop;
    }
    if(g_iMode[c]==MODE_NORMAL || g_iShotgunNeed[c]<=0){ g_bInReload[c]=false; g_hReloadTimer[c]=null; return Plugin_Stop; }
    float now=GetGameTime();
    // 以 m_flNextPrimaryAttack 真实动画为准，未到下发时间则等待
    float nextPrim=GetEntPropFloat(w,Prop_Send,"m_flNextPrimaryAttack");
    float nextAt=GetEntPropFloat(c,Prop_Send,"m_flNextAttack");
    bool bInReload=GetEntProp(w,Prop_Send,"m_bInReload")!=0;
    // 若仍在换弹且 nextPrim 在未来，等待
    if((bInReload || nextPrim > now+0.05 || nextAt > now+0.05) && now < g_fReloadEnd[c]+0.8){
        // 首次进入时 g_fReloadEnd 可能为首发结束时间，后续每发更新
        // 若 nextPrim 已过但仍 bInReload，说明单发动画结束但整体仍在换弹，允许补下一发
        if(nextPrim > now+0.05) return Plugin_Continue;
        if(nextAt > now+0.05) return Plugin_Continue;
        if(bInReload && now < g_fReloadEnd[c]) return Plugin_Continue;
    }
    // 霰弹逐发改为引擎驱动：等待引擎插入一发后再转特种，避免自增与引擎双重叠加导致UI跳变/不同步
    int curClipNow = GetEntProp(w, Prop_Send, "m_iClip1");
    if(curClipNow > g_iShotgunPreReloadClip[c]) {
        int newClip = curClipNow;
        if(newClip > g_iClipSize[c]) newClip = g_iClipSize[c];
        if(newClip > g_iTotalPool[c]) newClip = g_iTotalPool[c];
        int mode2 = g_iPendingMode[c];
        int newBit2 = (mode2==MODE_INCEND?1:2)|(g_bLaser[c]?4:0);
        SetEntProp(w, Prop_Send, "m_upgradeBitVec", newBit2);
        SetEntProp(w, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded", newClip);
        SetEntProp(w, Prop_Send, "m_iClip1", newClip);
        if(g_iAmmoType[c]>=0) SetEntProp(c, Prop_Send, "m_iAmmo", g_iTotalPool[c]-newClip, _, g_iAmmoType[c]);
        g_iShotgunPreReloadClip[c] = newClip;
        g_iShotgunNeed[c]--;
        g_iShotgunGive[c]--;
        float curNextPrim = GetEntPropFloat(w, Prop_Send, "m_flNextPrimaryAttack");
        if(curNextPrim > now) g_fReloadEnd[c]=curNextPrim;
        else g_fReloadEnd[c]=now+0.45;
        if(g_iShotgunNeed[c]<=0 || newClip>=g_iClipSize[c]) {
            CreateTimer(0.12,Timer_EndShotgun,GetClientUserId(c),TIMER_FLAG_NO_MAPCHANGE);
        }
        return Plugin_Continue;
    }
    int curUpChk = GetEntProp(w, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded");
    int curClChk = GetEntProp(w, Prop_Send, "m_iClip1");
    int curChk = curUpChk>0?curUpChk:curClChk;
    if(curChk >= g_iClipSize[c] || g_iShotgunNeed[c]<=0){
        g_bInReload[c]=false; g_hReloadTimer[c]=null;
        int mode=g_iPendingMode[c];
        int newBit=(mode==MODE_INCEND?1:2)|(g_bLaser[c]?4:0);
        SetEntProp(w, Prop_Send, "m_upgradeBitVec", newBit);
        SetEntProp(w, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded", curChk);
        SetEntProp(w, Prop_Send, "m_iClip1", curChk);
        if(g_iAmmoType[c]>=0) SetEntProp(c, Prop_Send, "m_iAmmo", g_iTotalPool[c]-curChk, _, g_iAmmoType[c]);
        PrintCenterText(c,"→ %s %d/%d 池%d",mode==MODE_INCEND?"燃烧":"高爆",curChk,g_iClipSize[c],g_iTotalPool[c]);
        return Plugin_Stop;
    }
    if(!bInReload && curClipNow==g_iShotgunPreReloadClip[c]) {
        if(now > g_fReloadEnd[c] + 0.3) {
            g_bInReload[c]=false; g_hReloadTimer[c]=null;
            int mode=g_iPendingMode[c];
            int newBit=(mode==MODE_INCEND?1:2)|(g_bLaser[c]?4:0);
            SetEntProp(w, Prop_Send, "m_upgradeBitVec", newBit);
            PrintCenterText(c,"→ %s %d/%d 池%d",mode==MODE_INCEND?"燃烧":"高爆",curClipNow,g_iClipSize[c],g_iTotalPool[c]);
            return Plugin_Stop;
        }
    }
    return Plugin_Continue;
}
public Action Timer_ShotgunSwitchShell(Handle timer,int userid){
    int c=GetClientOfUserId(userid);
    if(c<=0||!IsClientInGame(c)||!IsPlayerAlive(c)){ if(c>0){ g_bInReload[c]=false; g_hReloadTimer[c]=null; } return Plugin_Stop; }
    int w=GetPlayerWeaponSlot(c,0);
    if(w<=0||!IsValidEdict(w)){ g_bInReload[c]=false; g_hReloadTimer[c]=null; return Plugin_Stop; }
    int buttons=GetClientButtons(c);
    if(buttons & IN_ATTACK){ 
        g_bInReload[c]=false; g_hReloadTimer[c]=null;
        int curUp=GetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded");
        int curCl=GetEntProp(w,Prop_Send,"m_iClip1");
        int cur2=curUp>0?curUp:curCl;
        PrintCenterText(c,"换弹中断 %d/%d",cur2,g_iClipSize[c]);
        LogMessage("[shared] Switch shotgun interrupted c=%d cur=%d",c,cur2);
        return Plugin_Stop;
    }
    int next=g_iPendingMode[c];
    int curUp2=GetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded");
    int curCl2=GetEntProp(w,Prop_Send,"m_iClip1");
    int cur2=curUp2>0?curUp2:curCl2;
    if(cur2 >= g_iClipSize[c] || g_iShotgunNeed[c]<=0){
        g_bInReload[c]=false; g_hReloadTimer[c]=null;
        if(next!=MODE_NORMAL){
            int newBit=(next==MODE_INCEND?1:2)|(g_bLaser[c]?4:0);
            SetEntProp(w,Prop_Send,"m_upgradeBitVec",newBit);
            SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",cur2);
            SetEntProp(w,Prop_Send,"m_iClip1",cur2);
            if(g_iAmmoType[c]>=0) SetEntProp(c,Prop_Send,"m_iAmmo",g_iTotalPool[c]-cur2,_,g_iAmmoType[c]);
        }
        PrintCenterText(c,"→ %s %d/%d 池%d",next==0?"普通":next==1?"燃烧":"高爆",cur2,g_iClipSize[c],g_iTotalPool[c]);
        return Plugin_Stop;
    }
    // 切换逐发改为引擎驱动：等待引擎插入后再按目标模式纠正
    int curClipNow2 = GetEntProp(w, Prop_Send, "m_iClip1");
    if(curClipNow2 > g_iShotgunPreReloadClip[c]) {
        int newClip = curClipNow2;
        if(newClip>g_iClipSize[c]) newClip=g_iClipSize[c];
        if(newClip>g_iTotalPool[c]) newClip=g_iTotalPool[c];
        if(next==MODE_NORMAL){
            int bit=GetEntProp(w,Prop_Send,"m_upgradeBitVec");
            SetEntProp(w,Prop_Send,"m_upgradeBitVec",bit&4);
            SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",0);
            SetEntProp(w,Prop_Send,"m_iClip1",newClip);
        } else {
            int newBit2=(next==MODE_INCEND?1:2)|(g_bLaser[c]?4:0);
            SetEntProp(w,Prop_Send,"m_upgradeBitVec",newBit2);
            SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",newClip);
            SetEntProp(w,Prop_Send,"m_iClip1",newClip);
        }
        if(g_iAmmoType[c]>=0) SetEntProp(c,Prop_Send,"m_iAmmo",g_iTotalPool[c]-newClip,_,g_iAmmoType[c]);
        g_iShotgunPreReloadClip[c]=newClip;
        g_iShotgunNeed[c]--;
        if(g_iShotgunNeed[c]<=0 || newClip>=g_iClipSize[c]){
            g_bInReload[c]=false; g_hReloadTimer[c]=null;
            PrintCenterText(c,"→ %s %d/%d 池%d",next==0?"普通":next==1?"燃烧":"高爆",newClip,g_iClipSize[c],g_iTotalPool[c]);
            return Plugin_Stop;
        }
        return Plugin_Continue;
    }
    if(cur2 >= g_iClipSize[c] || g_iShotgunNeed[c]<=0){
        g_bInReload[c]=false; g_hReloadTimer[c]=null;
        if(next!=MODE_NORMAL){
            int newBit=(next==MODE_INCEND?1:2)|(g_bLaser[c]?4:0);
            SetEntProp(w,Prop_Send,"m_upgradeBitVec",newBit);
            SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",cur2);
            SetEntProp(w,Prop_Send,"m_iClip1",cur2);
            if(g_iAmmoType[c]>=0) SetEntProp(c,Prop_Send,"m_iAmmo",g_iTotalPool[c]-cur2,_,g_iAmmoType[c]);
        }
        PrintCenterText(c,"→ %s %d/%d 池%d",next==0?"普通":next==1?"燃烧":"高爆",cur2,g_iClipSize[c],g_iTotalPool[c]);
        return Plugin_Stop;
    }
    return Plugin_Continue;
}
public Action Timer_EndShotgun(Handle t,int userid){
    int c=GetClientOfUserId(userid);
    if(c>0){ g_bInReload[c]=false; if(g_hReloadTimer[c]!=null){ KillTimer(g_hReloadTimer[c]); g_hReloadTimer[c]=null; } }
    return Plugin_Stop;
}
public Action Timer_PollReload(Handle timer,int userid){
    int c=GetClientOfUserId(userid);
    if(c<=0||!IsClientInGame(c)||!IsPlayerAlive(c)){
        if(c>0){ g_bInReload[c]=false; g_hReloadTimer[c]=null; }
        return Plugin_Stop;
    }
    int w=GetPlayerWeaponSlot(c,0);
    if(w<=0||!IsValidEdict(w)){
        g_bInReload[c]=false; g_hReloadTimer[c]=null;
        return Plugin_Stop;
    }
    float now=GetGameTime();
    if(now < g_fReloadEnd[c]) return Plugin_Continue;
    // 额外校验 m_bInReload 与 nextAttack，确保换弹动画真正结束
    bool bInReload=GetEntProp(w,Prop_Send,"m_bInReload")!=0;
    float nextAt=GetEntPropFloat(c,Prop_Send,"m_flNextAttack");
    float nextPrim=GetEntPropFloat(w,Prop_Send,"m_flNextPrimaryAttack");
    if(bInReload) return Plugin_Continue;
    if(nextAt > now+0.05 || nextPrim > now+0.05) return Plugin_Continue;
    // 结束：补特殊弹
    g_hReloadTimer[c]=null;
    int give=g_iReloadGive[c];
    int oldCur=g_iReloadOldCur[c];
    int mode=g_iPendingMode[c];
    int newClip=oldCur+give;
    if(newClip>g_iClipSize[c]) newClip=g_iClipSize[c];
    if(newClip>g_iTotalPool[c]) newClip=g_iTotalPool[c];
    int newBit=(mode==MODE_INCEND?1:2)|(g_bLaser[c]?4:0);
    SetEntProp(w,Prop_Send,"m_upgradeBitVec",newBit);
    SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",newClip);
    SetEntProp(w,Prop_Send,"m_iClip1",newClip);
    if(g_iAmmoType[c]>=0) SetEntProp(c,Prop_Send,"m_iAmmo",g_iTotalPool[c]-newClip,_,g_iAmmoType[c]);
    PrintCenterText(c,"→ %s 补满 %d/%d 池%d",mode==MODE_INCEND?"燃烧":"高爆",newClip,g_iClipSize[c],g_iTotalPool[c]);
    g_bInReload[c]=false;
    LogMessage("[shared] Poll done c=%d newClip=%d",c,newClip);
    return Plugin_Stop;
}
public Action Timer_PollReloadNormal(Handle timer,int userid){
    int c=GetClientOfUserId(userid);
    if(c<=0||!IsClientInGame(c)||!IsPlayerAlive(c)) return Plugin_Stop;
    int w=GetPlayerWeaponSlot(c,0);
    if(w<=0||!IsValidEdict(w)){ if(c>0) g_hReloadTimer[c]=null; return Plugin_Stop; }
    bool bInReload=GetEntProp(w,Prop_Send,"m_bInReload")!=0;
    float nextAt=GetEntPropFloat(c,Prop_Send,"m_flNextAttack");
    float nextPrim=GetEntPropFloat(w,Prop_Send,"m_flNextPrimaryAttack");
    float now=GetGameTime();
    if(bInReload && now < g_fReloadEnd[c]) return Plugin_Continue;
    if((nextAt > now+0.05 || nextPrim > now+0.05) && now < g_fReloadEnd[c]+0.3) return Plugin_Continue;
    g_hReloadTimer[c]=null;
    int at=g_iAmmoType[c];
    if(at>=0){
        int reserve=GetEntProp(c,Prop_Send,"m_iAmmo",_,at);
        int cur=GetEntProp(w,Prop_Send,"m_iClip1");
        int up=GetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded");
        int cur2=up>0?up:cur;
        g_iTotalPool[c]=reserve+cur2;
        SetEntProp(c,Prop_Send,"m_iAmmo",g_iTotalPool[c]-cur2,_,at);
    }
    PrintCenterText(c,"普通换弹完成");
    return Plugin_Stop;
}
public Action Timer_ReloadGive(Handle t,DataPack p){
    p.Reset(); int uid=p.ReadCell(); int give=p.ReadCell(); int oldCur=p.ReadCell();
    int c=GetClientOfUserId(uid); if(c<=0||!IsClientInGame(c)||!IsPlayerAlive(c)){ if(c>0) g_bInReload[c]=false; return Plugin_Stop; }
    int w=GetPlayerWeaponSlot(c,0); if(w<=0||!IsValidEdict(w)){ g_bInReload[c]=false; return Plugin_Stop; }
    int mode=g_iMode[c];
    // 保持总池不变，仅把库存搬到弹夹：新弹夹 = oldCur+give，已保证 <= g_iTotalPool
    int newClip=oldCur+give;
    if(newClip>g_iClipSize[c]) newClip=g_iClipSize[c];
    if(newClip>g_iTotalPool[c]) newClip=g_iTotalPool[c];
    int newBit=(mode==MODE_INCEND?1:2)|(g_bLaser[c]?4:0);
    SetEntProp(w,Prop_Send,"m_upgradeBitVec",newBit);
    SetEntProp(w,Prop_Send,"m_nUpgradedPrimaryAmmoLoaded",newClip);
    SetEntProp(w,Prop_Send,"m_iClip1",newClip);
    // m_iAmmo 由HUD持续刷为 g_iTotalPool-newClip，不递减总池
    if(g_iAmmoType[c]>=0) SetEntProp(c,Prop_Send,"m_iAmmo",g_iTotalPool[c]-newClip,_,g_iAmmoType[c]);
    PrintCenterText(c,"→ %s 补满 %d/%d 池%d",mode==MODE_INCEND?"燃烧":"高爆",newClip,g_iClipSize[c],g_iTotalPool[c]);
    g_bInReload[c]=false;
    return Plugin_Stop;
}
public Action Cmd_Switch(int c,int a){ if(c>0&&IsPlayerAlive(c)) SwitchMode(c); return Plugin_Handled; }
public Action Cmd_Info(int c,int a){ if(c>0) PrintToChat(c,"[shared] 池%d 模式%d 解锁%d",g_iTotalPool[c],g_iMode[c],g_bUnlocked[c]); return Plugin_Handled; }
