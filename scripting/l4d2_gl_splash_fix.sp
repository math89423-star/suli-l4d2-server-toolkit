#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

/**
 * l4d2_gl_splash_fix.sp — GL 爆炸伤害重写（v2.0.0，源码重写版）
 *
 * 原版 smx 为匿名第三方插件（无源码），2026-08-02 依据反编译行为重写：
 *  - OnEntityCreated: grenade_launcher_projectile 弹头生成后下一帧把 m_flDamage
 *    覆盖为 sm_gl_splash_damage（注意：这会覆盖 weapon_attributes 的 damage）
 *  - OnTakeDamage (SDKHooks, 8 参): 爆炸伤害（DMG_BLAST + inflictor 是 GL 弹头）
 *    按受害者类型重算：Tank ×sm_gl_tank_mult / Witch ×sm_gl_witch_mult /
 *    幸存者队友 ×sm_gl_ff_factor；其他特感保持引擎值
 *  - 修复：投掷者被自己的爆炸炸到（attacker == victim）原版直接吞掉伤害 →
 *    本版放行引擎伤害（L4D2 原版贴脸自伤恢复）
 *  - sm_gl_splash_radius 保留为兼容 cvar（原版定义为死 cvar 未使用；
 *    爆炸半径实际由引擎 cvar grenadelauncher_radius_kill/stumble 控制）
 *
 * 版本历史：
 *  v2.1.26 (2026-08-02): 诊断版——用户要求高爆弹友伤同步调低。非 GL 弹头的
 *    DMG_BLAST 对幸存者队友加日志（inflictor classname + engine 值），
 *    确认高爆弹友伤路径后再加系数控制。
 *  v2.1.25 (2026-08-02): 用户拍板微调：sm_gl_engine_damage 225 → 270
 *    （线性 1.2 倍）→ 队友直击 18 / 溅射 10。
 *  v2.1.24 (2026-08-02): 定稿！m_flDamage=225 用户实测"预期了"（直击 15/溅射 8）。
 *    225 固化到新 cvar sm_gl_engine_damage（默认 225）；ff 分支回归纯放行
 *    （删无效的 PLASMA 清理）。伤害模型定稿：
 *    队友直击 15/溅射 8（引擎后置 225×falloff/15）；自伤贴脸 14（注入）；
 *    Witch 750 两发必死；特感 750；Tank 1875；小僵尸 225×falloff。
 *  v2.1.23 (2026-08-02): 实验：清 DMG_PLASMA 无效（后置照扣 30）。引擎后置
 *    = m_flDamage×falloff×(1/15)（50/750 直击、30/750 溅射吻合）→ FrameSetDamage
 *    写 225 让后置=直击15/溅射8。特感/Tank hook 重写、Witch 注入不受影响；
 *    小僵尸吃 225×falloff（变弱则补 common 重写 750）。
 *  v2.1.22 (2026-08-02): 实测 dmgType 16777280 = DMG_BLAST|DMG_PLASMA(0x1000040)!
 *    引擎给幸存者爆炸伤害带 DMG_PLASMA 标记（damage=0）→ 后置直接扣血。
 *    实验：ff 分支清 DMG_PLASMA 位看后置是否停止；若停 → 队友伤害改为
 *    boom 注入（750×falloff×ff_factor×引擎难度 = 直击15/溅射8）完全可控。
 *  v2.1.21 (2026-08-02): 诊断实验版。14:48 TIMEOUT 实锤：Plugin_Continue 时
 *    队友完全不掉血（hp 66->66）——引擎 TakeDamage 的 damage=0。与 v2.1.16
 *    用户实测 50/25 矛盾 → 纯放行 + RAW 日志对照"engine 值 vs 实际掉血"，
 *    确定伤害本体路径后再定最终方案。
 *  v2.1.20 (2026-08-02): 单帧回补太早——实测引擎后置扣血晚于下一帧
 *    （Rochelle 300→264 扣 36，heal 帧读到未扣的 hp → excess<=0 静默跳过）。
 *    FrameMateHeal 改每帧重试（上限 60 帧 ≈1s）直到后置扣完再校准 + 超时日志。
 *  v2.1.19 (2026-08-02): Handled 也拦不住引擎后置（50/25 照扣，注入 7/8 叠加
 *    后净伤仍 57~65）。改"回补校准"：ff 分支放行引擎后置 + 记录 hp0/目标伤害
 *    （750×falloff×ff_factor×引擎难度=直击15/溅射8），下一帧 FrameMateHeal
 *    把多扣部分加回 → 净伤精确=目标。不动 m_flDamage（小僵尸清场不受影响）。
 *    倒地者不回补（防 incap 状态异常）。
 *  v2.1.18 (2026-08-02): 实锤：引擎对幸存者爆炸伤害 = 后置直接扣血（hook 里
 *    engine=0，玩家吃 50/25 = 引擎 750×falloff×(1/15)），改 damage 永远无效。
 *    队友改 Witch 同款方案：ff 分支 Plugin_Handled 吞引擎 + boom 时 DMG_GENERIC
 *    注入 750×falloff×ff_factor×引擎友伤难度系数（0.25×0.08=0.02）→
 *    直击≈15、溅射≈8（用户目标）。若引擎后置吞不掉则净伤 65/33，需再降 m_flDamage。
 *  v2.1.17 (2026-08-02): 诊断版。用户实测队友直击 50/溅射 25（按 750×0.25
 *    预期 187/94）→ 引擎对幸存者爆炸伤害疑似有后置处理覆盖修改（自伤注入
 *    14 精确=注入公式，队友走引擎路径）。ff 分支加日志拿引擎原值。
 *  v2.1.16 (2026-08-02): 用户拍板:榴弹对队友/自己伤害 0.4 → 0.25
 *    （sm_gl_ff_factor）。自伤自动继承（self_mult 0.0 = ff_factor × 引擎友伤
 *    难度系数）→ 贴脸 750×0.25×0.08 ≈ 15。
 *  v2.1.15 (2026-08-02): 用户实测满血 1500 Witch 贴脸被一发带走 —— 引擎对 Witch
 *    的爆炸补刀(0~750,绕过一切 hook)与注入叠加超 1500。用户拍板:去掉 Witch
 *    倍率,恢复 1 倍(sm_gl_witch_mult 1.5 → 1.0 = 750/发)。
 *    数学:中远距离 750×2=1500 恰好两发死;贴脸 750+引擎补刀 441≈1191 < 1500
 *    不会秒杀,第二发必死。"两下必死"保留,贴脸不再一发带走。
 *  v2.1.14 (2026-08-02): Witch 伤害全链路重做（定论：引擎对 Witch 实体的爆炸伤害
 *    有专属后置重算，DMG_BLAST 任何路径——改 damage / 注入——全被打回：
 *    14:01 注入 1125 实落 ~221、14:11 贴脸 20 单位引擎只给 ~400 且 hook 不触发）。
 *    Witch 伤害统一移到 boom 时（OnEntityDestroyed）：0~sm_gl_splash_range 内全部
 *    Witch 用 DMG_GENERIC + inflictor=投掷者 注入全额 750×1.5=1125（非爆炸类型
 *    不走引擎爆炸管线 → 无衰减无重算）。ExtendSplash 的 Witch 段删除（防双伤）。
 *    OnTakeDamage 的 Witch 分支改为尝试吞引擎伤害（Plugin_Handled，吞不掉则
 *    ≤180 引擎补刀 200~400，贴脸可能一发带走）。
 *  v2.1.13 (2026-08-02): boom 日志附加最近 Witch 距离 + 场上 Witch 数量，
 *    对照"玩家认为很近" vs "引擎判定距离"，定位 180 内不触发的原因。
 *  v2.1.12 (2026-08-02): 玩家 3-5 米炸 Witch 完全无伤害 —— 引擎爆炸判定半径
 *    仅 grenadelauncher_radius_kill 180 单位(~3.6米)，边缘/外不给伤害，hook 不触发。
 *    新增扩展溅射：弹头销毁时对爆炸点 180~500 单位内的特感/Tank/Witch 手动注入
 *    （引擎已处理 ≤180 跳过，防双伤）。cvar sm_gl_splash_range 默认 500。
 *  v2.1.11 (2026-08-02): 实测 Plugin_Changed 对 Witch 实体无效（改 1125 实际只掉
 *    几百=引擎原值；Tank client 却生效）→ 引擎对非 client 实体伤害有后置处理。
 *    Witch 分支改为：吞掉引擎伤害 + SDKHooks_TakeDamage 注入直落
 *    （bypassHooks=false + g_bInWitchInject 递归保护，attacker=玩家保计分）。
 *  v2.1.10 (2026-08-02): 玩家实测 Witch 溅射完全无日志（OnTakeDamage 未触发）。
 *    弹头销毁加"GL boom"落点日志（坐标 + 投掷者距离），判断溅射实际命中范围。
 *  v2.1.9 (2026-08-02): 诊断版。v2.1.8 特感无衰减仍"不对"，特感分支全部加
 *    LogMessage（命中分支 + 引擎原值 + 改后值），确认实际伤害路径。
 *  v2.1.8 (2026-08-02): 用户反馈溅射对 Witch 实测仅 ~100（引擎爆炸距离衰减，
 *    weapon_init.cfg 只有 damage 750 无衰减配置）。特感分支取消距离衰减：
 *    普通特感固定 750、Tank 750×2.5、Witch 750×1.5（= 直击满伤，溅射不再衰减）。
 *  v2.1.7 (2026-08-02): 用户纠正：队友实际伤害 = ff_factor × 引擎友伤难度系数
 *    （survivor_friendly_fire_factor_*，服务器 hard=0.08，sourcemod.cfg 显式设置；
 *    l4d2_ff_fix 只管 DMG_BURN 不碰爆炸）。sm_gl_self_mult 默认 0.0 =
 *    自动继承 sm_gl_ff_factor × 引擎难度系数（= 队友实际伤害，贴脸 ≈24）；
 *    >0 时手动覆盖。
 *  v2.1.6 (2026-08-02): 玩家反馈贴脸 722 直接倒地太狠。新增 sm_gl_self_mult
 *    （默认 0.4 = 与队友 FF 一致），自伤注入 = 750 × 距离衰减 × 系数。
 *  v2.1.5 (2026-08-02): 清理诊断日志（Post hook 移除、swallowed 日志移除，
 *    只留 injected 一条）。功能与 v2.1.4 相同（玩家实测自伤落地：贴脸倒地）。
 *  v2.1.4 (2026-08-02): Post 实锤：改 damage 722 → FINAL 5.0。引擎对投掷者
 *    自伤的 ~1/150 减伤在 TakeDamage 内部（hook 之后）应用，改 damage 无效。
 *    改为：自伤分支 Plugin_Handled 吞掉引擎伤害；注入无条件执行且
 *    attacker=世界(0) 尝试绕过"玩家打自己"减伤判定；Post 过滤条件放宽
 *    以观测注入伤害的 FINAL。
 *  v2.1.3 (2026-08-02): 诊断版。v2.1.2 后玩家打脚底 3 发全部走引擎路径重算
 *    （723 dmg 日志）但游戏内不掉血 → 怀疑引擎对投掷者的 1/150 减伤在
 *    OnTakeDamage hook 之后应用（改 damage 被减）。新增 OnTakeDamagePost
 *    hook 实锤最终实际掉血量。
 *  v2.1.2 (2026-08-02): 玩家实测打脚底 3 发无任何日志 —— 注入兜底静默失效：
 *    OnEntityDestroyed 里 GetEntityClassname 在实体销毁时读取不可靠，
 *    classname 判定永远失败，注入从未执行。且脚下爆炸引擎路径也不触发
 *    （爆炸点与投掷者重合，引擎不向 thrower 回传伤害）→ 双路全死。
 *    修复：OnEntityCreated 时把弹头 entref + thrower（FrameSetDamage 补存）
 *    记入 ArrayList，销毁回调查表判定，不依赖 classname。
 *  v2.1.1 (2026-08-02): 日志实锤：引擎路径触发但自伤仅 5 点（贴脸，
 *    ≈ m_flDamage/150 的投掷者减伤，等于没有）。自伤分支改为重算：
 *    damage = sm_gl_splash_damage × 线性距离衰减（grenadelauncher_radius_kill），
 *    贴脸 ≈ 675。注入兜底保留（时间窗判定仍防双伤）。
 *  v2.1.0 (2026-08-02): 玩家实测自伤仍为 0 —— 引擎对投掷者豁免爆炸伤害
 *    （OnTakeDamage 对自伤不触发/引擎不应用）。新增兜底：hook 弹头
 *    OnEntityDestroyed（=爆炸瞬间），若引擎 0.05s 窗内未给过投掷者自伤
 *    （g_fSelfDamagedAt 时间戳判定），手动注入爆炸伤害
 *    （m_flDamage × 线性距离衰减，DMG_BLAST，attacker=投掷者本人）。
 *    自伤判定双轨：attacker==victim || inflictor 的 m_hThrower==victim。
 *  v2.0.0 (2026-08-02): 重写。cvar 名/默认值与原版完全一致
 *    (650/350/0.4/2.5/1.5)，唯一行为差异 = 自伤放行。
 */

#define PROJECTILE_CLASS "grenade_launcher_projectile"

ConVar g_cvDamage;
ConVar g_cvRadius;
ConVar g_cvEngineDmg; // v2.1.24 弹头 m_flDamage（引擎后置/小僵尸基准，默认 225）
ConVar g_cvFF;
ConVar g_cvTankMult;
ConVar g_cvWitchMult;
ConVar g_cvSelfMult; // v2.1.6 自伤系数
ConVar g_cvRange;    // v2.1.12 扩展溅射范围

// v2.1.2：弹头 entref 追踪表（销毁回调不读 classname，实体销毁时不可靠）。
// g_hProjectiles 存 entref，g_hProjThrowers 存投掷者（FrameSetDamage 补存）。
ArrayList g_hProjectiles;
ArrayList g_hProjThrowers;

// v2.1.11+：注入递归保护（注入的伤害放行,防止再次进入分支）
bool g_bInInject[2048];

// v2.1.19+：队友 FF 回补校准（引擎后置扣血拦不住 → 帧循环把多扣的补回）。
// g_iMateHP0 = 后置扣血前的血量（ff 分支记录），g_fMateGoal = 目标伤害。
// v2.1.20：RequestFrame 单帧太早（后置扣血晚于下一帧），改每帧重试至扣完。
int g_iMateHP0[2048];
float g_fMateGoal[2048];
int g_iMateRetry[2048];

public Plugin myinfo =
{
    name        = "GL Splash Damage Fix",
    author      = "suli",
    description = "Grenade launcher splash damage rewrite (self-damage fixed)",
    version     = "2.1.26",
    url         = ""
};

public void OnPluginStart()
{
    g_cvDamage   = CreateConVar("sm_gl_splash_damage", "650",  "Grenade launcher explosion damage (overrides weapon script damage)", FCVAR_NOTIFY, true, 1.0);
    // v2.1.24: 弹头 m_flDamage（引擎对幸存者后置扣血 = 此值×falloff×1/15，默认
    // 225 → 直击≈15/溅射≈8；也是小僵尸爆炸清场的引擎基准，调低则清场变弱）。
    // v2.1.25: 225 → 270（用户拍板：直击 18 / 溅射 10）
    g_cvEngineDmg= CreateConVar("sm_gl_engine_damage", "270", "Projectile m_flDamage: engine survivor post-damage = this x falloff /15 (270 = 18 direct / 10 splash)", FCVAR_NOTIFY, true, 1.0);
    g_cvRadius   = CreateConVar("sm_gl_splash_radius", "350",  "Grenade launcher explosion radius (reserved; engine grenadelauncher_radius_kill/stumble)", FCVAR_NOTIFY, true, 1.0);
    // v2.1.16: 0.4 → 0.25（用户拍板;自伤自动继承 self_mult = ff_factor × 引擎难度）
    g_cvFF       = CreateConVar("sm_gl_ff_factor", "0.25",     "Grenade launcher explosion friendly fire factor (teammates; self inherits via self_mult 0.0)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvTankMult = CreateConVar("sm_gl_tank_mult", "2.5",      "Grenade launcher explosion damage multiplier vs Tank", FCVAR_NOTIFY, true, 0.0);
    // v2.1.15: 1.5 → 1.0（贴脸 1125+引擎补刀会秒 1500 满血 Witch，用户拍板去倍率）
    g_cvWitchMult= CreateConVar("sm_gl_witch_mult", "1.0",     "Grenade launcher explosion damage multiplier vs Witch (1.0 = 750/shot, two-shot kill, point-blank no one-shot)", FCVAR_NOTIFY, true, 0.0);
    // 0.0 = 自动继承 sm_gl_ff_factor × 引擎友伤难度系数（= 队友实际伤害）；>0 手动覆盖
    g_cvSelfMult = CreateConVar("sm_gl_self_mult", "0.0",      "Grenade launcher self-damage factor (0.0 = auto: ff_factor × engine FF difficulty, same as teammate actual damage)", FCVAR_NOTIFY, true, 0.0);
    g_cvRange     = CreateConVar("sm_gl_splash_range", "500",  "Extended splash range beyond engine grenadelauncher_radius_kill (units): SI/Tank/Witch in engineRadius~range take full damage", FCVAR_NOTIFY, true, 0.0);

    AutoExecConfig(true, "l4d2_gl_splash_fix");

    g_hProjectiles = new ArrayList();
    g_hProjThrowers = new ArrayList();

    // reload 场景：hook 已在线的玩家（OnClientPutInServer 不会再触发）
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
            SDKHook(i, SDKHook_OnTakeDamage, OnTakeDamage);
    }

    // reload 场景：hook 场上已有的 witch 实体（同理）
    for (int i = MaxClients + 1; i < 2048; i++)
    {
        if (!IsValidEntity(i))
            continue;
        char cls[16];
        GetEntityClassname(i, cls, sizeof(cls));
        if (StrEqual(cls, "witch"))
            SDKHook(i, SDKHook_OnTakeDamage, OnTakeDamage);
    }
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

public void OnClientDisconnect(int client)
{
    SDKUnhook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (entity < 1 || classname[0] != 'g')
        return;

    if (StrEqual(classname, PROJECTILE_CLASS))
    {
        // 弹头生成后一帧覆盖爆炸伤害（引擎初始值来自武器脚本/weapon_attributes）
        DataPack dp = new DataPack();
        dp.WriteCell(EntIndexToEntRef(entity));
        RequestFrame(FrameSetDamage, dp);

        // v2.1.2：entref 追踪（销毁回调判定不用 classname，实体销毁时读取不可靠）
        g_hProjectiles.Push(EntIndexToEntRef(entity));
        g_hProjThrowers.Push(0); // thrower 在 FrameSetDamage 补存（弹头生成时还没设）
    }
    else if (StrEqual(classname, "witch"))
    {
        SDKHook(entity, SDKHook_OnTakeDamage, OnTakeDamage);
    }
}

void FrameSetDamage(DataPack dp)
{
    dp.Reset();
    int ent = EntRefToEntIndex(dp.ReadCell());
    delete dp;

    if (ent <= 0 || !IsValidEntity(ent))
        return;

    // v2.1.23+：m_flDamage 写 sm_gl_engine_damage（默认 225，用户实测定稿）。
    // 引擎对幸存者的爆炸后置扣血 = m_flDamage×falloff×(1/15)（无法拦截）→
    // 225 时直击≈15/溅射≈8，正好命中用户目标。特感/Tank/Witch 走 hook 重写/
    // 注入（用 sm_gl_splash_damage 750），自伤走注入，均不受此值影响；
    // 小僵尸吃引擎值 225×falloff（与后置同源，已验证清场正常）。
    SetEntPropFloat(ent, Prop_Send, "m_flDamage", g_cvEngineDmg.FloatValue);

    // v2.1.2：补存投掷者（发射后一帧 m_hThrower 已设置），供销毁回调注入兜底
    int thrower = GetEntPropEnt(ent, Prop_Send, "m_hThrower");
    int idx = g_hProjectiles.FindValue(EntIndexToEntRef(ent));
    if (idx != -1 && idx < g_hProjThrowers.Length)
        g_hProjThrowers.Set(idx, thrower);
}

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage,
    int &damagetype, int &weapon, float damageForce[3], float damagePosition[3])
{
    // v2.1.11+：注入的伤害直接放行（防递归）
    if (g_bInInject[victim])
        return Plugin_Continue;

    if (!(damagetype & DMG_BLAST))
        return Plugin_Continue;

    if (inflictor < 1 || !IsValidEntity(inflictor))
        return Plugin_Continue;

    char cls[32];
    GetEntityClassname(inflictor, cls, sizeof(cls));
    if (!StrEqual(cls, PROJECTILE_CLASS))
    {
        // v2.1.26 诊断：非 GL 弹头的爆炸伤害（高爆弹/爆炸物？）对幸存者队友，
        // 用户要求高爆弹友伤同步调低——先拿引擎值 + inflictor 路径。
        if (GetClientTeam(victim) == 2)
            LogMessage("GL blast non-proj: %N engine %.0f inflictor %s dmgType %d weapon %d", victim, damage, cls, damagetype, weapon);
        return Plugin_Continue;
    }

    // 自伤：受害者是这颗弹头的投掷者本人（引擎 attacker 字段或 m_hThrower 双轨判定）。
    // v2.1.4：引擎对投掷者自伤的 ~1/150 减伤在 TakeDamage 内部（hook 之后）应用，
    // 改 damage 无效（Post 实锤 722→5.0）。直接吞掉引擎伤害，自伤交给
    // OnEntityDestroyed 的无条件注入（attacker=世界，尝试绕过减伤判定）。
    int projThrower = GetEntPropEnt(inflictor, Prop_Send, "m_hThrower");
    if (attacker == victim || projThrower == victim)
    {
        // v2.1.4：引擎对投掷者自伤有 ~1/150 后置减伤（改 damage 无效，Post 实锤），
        // 直接吞掉引擎伤害，自伤交给 OnEntityDestroyed 的无条件注入。
        return Plugin_Handled;
    }

    // Witch 实体（index > MaxClients，不是 client）
    // v2.1.14：引擎对 Witch 实体的爆炸伤害有专属后置重算——改 damage 或注入
    // DMG_BLAST 全被打回（14:01 注入 1125 实落 ~221，14:11 贴脸 hook 甚至不触发）。
    // Witch 伤害统一由 OnEntityDestroyed 的 boom 时注入负责（DMG_GENERIC 不走
    // 爆炸管线）。这里只尝试吞引擎伤害（吞不掉则 ≤180 引擎补刀 200~400，
    // 贴脸可能一发带走——符合"两下必死"上限）。
    if (victim > MaxClients)
    {
        GetEntityClassname(victim, cls, sizeof(cls));
        if (StrEqual(cls, "witch"))
        {
            LogMessage("GL splash witch-entity: %d engine %.0f (suppressed)", victim, damage);
            damage = 0.0;
            return Plugin_Handled;
        }
        return Plugin_Continue;
    }

    int zc = GetEntProp(victim, Prop_Send, "m_zombieClass");
    if (zc == 8)                 // Tank
    {
        float engine = damage;
        damage = g_cvDamage.FloatValue * g_cvTankMult.FloatValue;
        LogMessage("GL splash tank: %N engine %.0f -> %.0f", victim, engine, damage);
        return Plugin_Changed;
    }
    if (zc == 7)                 // Witch（罕见：Witch 也有 client 形态）
    {
        float engine = damage;
        damage = g_cvDamage.FloatValue * g_cvWitchMult.FloatValue;
        LogMessage("GL splash witch-client: %N engine %.0f -> %.0f", victim, engine, damage);
        return Plugin_Changed;
    }
    if (GetClientTeam(victim) == 2)
    {
        // 幸存者队友（含 bot）：v2.1.23 定稿——引擎对幸存者爆炸伤害 = 后置直接
        // 扣血（hook 里 engine=0，改 damage/Handled/清 DMG_PLASMA 全无效），
        // 量 = m_flDamage×falloff×(1/15)，由 sm_gl_engine_damage(225) 控制
        // → 直击≈15/溅射≈8。此处纯放行，不做任何修改。
        return Plugin_Continue;
    }
    if (zc >= 1 && zc <= 6)      // 普通特感：v2.1.8 取消距离衰减，溅射固定满伤
    {
        damage = g_cvDamage.FloatValue;
        LogMessage("GL splash SI: %N zc%d engine %.0f -> %.0f", victim, zc, damage, g_cvDamage.FloatValue);
        return Plugin_Changed;
    }

    // 其他（zc 0 等）：保持引擎值
    return Plugin_Continue;
}

/**
 * 弹头销毁（=爆炸）。v2.1.0 手动自伤注入兜底：
 * 引擎对投掷者豁免爆炸伤害（OnTakeDamage 不触发）时，g_fSelfDamagedAt 不会更新，
 * 这里手动补一份爆炸伤害（m_flDamage × 线性距离衰减）。引擎已给过（时间窗内）
 * 则跳过，避免双伤。全局 forward，仅处理 GL 弹头。
 */
public void OnEntityDestroyed(int entity)
{
    int entRef = EntIndexToEntRef(entity);
    int idx = g_hProjectiles.FindValue(entRef);
    if (idx == -1)
        return; // 非 GL 弹头（不读 classname：实体销毁时读取不可靠）

    int thrower = g_hProjThrowers.Get(idx);
    g_hProjectiles.Erase(idx);
    g_hProjThrowers.Erase(idx);

    // v2.1.10 诊断：爆炸落点 + 投掷者距离
    // v2.1.13：附加最近 Witch 距离（对照"玩家以为很近 vs 引擎判定距离"）
    float projPos[3];
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", projPos);

    float nearestWitch = 99999.0;
    int witchCount = 0;
    float witchRange = g_cvRange.FloatValue;
    if (witchRange <= 0.0)
        witchRange = 500.0;
    int witchAtt = (thrower >= 1 && thrower <= MaxClients && IsClientInGame(thrower)) ? thrower : 0;
    for (int e = MaxClients + 1; e < 2048; e++)
    {
        if (!IsValidEntity(e))
            continue;
        char wcls[16];
        GetEntityClassname(e, wcls, sizeof(wcls));
        if (!StrEqual(wcls, "witch"))
            continue;
        witchCount++;
        float wpos[3];
        GetEntPropVector(e, Prop_Data, "m_vecAbsOrigin", wpos);
        float d = GetVectorDistance(projPos, wpos);
        if (d < nearestWitch)
            nearestWitch = d;

        // v2.1.14+：boom 时对范围内 Witch 直接注入 —— DMG_GENERIC + inflictor=投掷者
        //（非爆炸类型，不走引擎对 Witch 的爆炸后置重算）→ 全额无衰减。
        // v2.1.15：倍率 1.0 = 750/发。贴脸 750+引擎补刀(~441)≈1191 < 1500 不会
        // 秒杀；中远距离纯 750×2=1500 恰好两发必死。
        if (d <= witchRange)
        {
            float dmg = g_cvDamage.FloatValue * g_cvWitchMult.FloatValue;
            int hpBefore = GetEntProp(e, Prop_Data, "m_iHealth");
            float zeroForce[3];
            g_bInInject[e] = true;
            SDKHooks_TakeDamage(e, witchAtt, witchAtt, dmg, DMG_GENERIC, -1, zeroForce, wpos, false);
            g_bInInject[e] = false;
            LogMessage("GL boom witch: %d dist %.0f -> %.0f (hp %d->%d)",
                e, d, dmg, hpBefore, GetEntProp(e, Prop_Data, "m_iHealth"));
        }
    }

    if (thrower >= 1 && thrower <= MaxClients && IsClientInGame(thrower))
    {
        float tPos[3];
        GetClientAbsOrigin(thrower, tPos);
        if (witchCount > 0)
            LogMessage("GL boom at (%.0f,%.0f,%.0f) thrower dist %.0f | witch x%d nearest %.0f",
                projPos[0], projPos[1], projPos[2], GetVectorDistance(projPos, tPos), witchCount, nearestWitch);
        else
            LogMessage("GL boom at (%.0f,%.0f,%.0f) thrower dist %.0f | no witch",
                projPos[0], projPos[1], projPos[2], GetVectorDistance(projPos, tPos));
    }
    else
    {
        LogMessage("GL boom at (%.0f,%.0f,%.0f) thrower %d", projPos[0], projPos[1], projPos[2], thrower);
    }

    if (thrower < 1 || thrower > MaxClients || !IsClientInGame(thrower) || !IsPlayerAlive(thrower))
        return;
    if (GetClientTeam(thrower) != 2)
        return;

    // v2.1.4：无条件注入（引擎路径已被 Plugin_Handled 吞掉，无双伤风险）。

    float throwerPos[3];
    GetClientAbsOrigin(thrower, throwerPos);

    ConVar cvRadius = FindConVar("grenadelauncher_radius_kill");
    float radius = cvRadius != null ? cvRadius.FloatValue : 180.0;
    if (radius <= 0.0)
        radius = 180.0;

    float dist = GetVectorDistance(projPos, throwerPos);
    float frac = 1.0 - (dist / radius);
    if (frac > 0.0)
    {
        // v2.1.7：self_mult 默认 0.0 = 自动继承 ff_factor × 引擎友伤难度系数
        //（与队友实际伤害一致，引擎难度系数只作用于引擎路径，注入不走那条路）。
        float selfMult = g_cvSelfMult.FloatValue;
        if (selfMult <= 0.0)
            selfMult = g_cvFF.FloatValue * GetEngineFFFactor();
        float dmg = g_cvDamage.FloatValue * frac * selfMult;

        // 本地 SDKHooks 旧版签名：SDKHooks_TakeDamage(entity, inflictor, attacker, ...)，
        // bypassHooks 默认 true → 伤害直接落地（不触发任何 OnTakeDamage，包括本插件的）。
        // v2.1.4：attacker=0（世界）绕过引擎"玩家打自己"的 ~1/150 减伤判定。
        SDKHooks_TakeDamage(thrower, entity, 0, dmg, DMG_BLAST);
        LogMessage("GL self-damage injected: %N dist %.0f/%.0f -> %.0f (self_mult %.3f)", thrower, dist, radius, dmg, selfMult);
    }

    // v2.1.19: 队友 FF 改为"引擎后置照扣 + 下一帧回补校准"（见 ff 分支的
    // g_iMateHP0/g_fMateGoal 记录，FrameMateHeal 回补），此处无需注入。

    // v2.1.12：扩展溅射（引擎半径外 ~ sm_gl_splash_range 内的特感手动注入）
    ExtendSplash(entity, projPos, thrower);
}

/**
 * v2.1.12 扩展溅射：引擎爆炸判定半径（grenadelauncher_radius_kill，180）外、
 * sm_gl_splash_range（默认 500）内的特感/Tank/Witch 手动注入满伤。
 * 引擎已给伤害的（≤180，走 OnTakeDamage 分支）跳过，防双伤。
 */
void ExtendSplash(int projectile, const float projPos[3], int thrower)
{
    float range = g_cvRange.FloatValue;
    if (range <= 0.0)
        return;

    ConVar cvRadius = FindConVar("grenadelauncher_radius_kill");
    float engineRadius = cvRadius != null ? cvRadius.FloatValue : 180.0;
    if (engineRadius <= 0.0)
        engineRadius = 180.0;

    float zeroForce[3];

    // 1. 特感 / Tank clients（team 3）
    for (int i = 1; i <= MaxClients; i++)
    {
        if (i == thrower)
            continue;
        if (!IsClientInGame(i) || !IsPlayerAlive(i))
            continue;
        if (GetClientTeam(i) != 3)
            continue;
        int zc = GetEntProp(i, Prop_Send, "m_zombieClass");
        if (zc < 1 || zc > 8)
            continue;

        float pos[3];
        GetClientAbsOrigin(i, pos);
        float dist = GetVectorDistance(projPos, pos);
        if (dist <= engineRadius)   // 引擎已给伤害，走 OnTakeDamage 分支
            continue;
        if (dist > range)
            continue;

        float dmg = g_cvDamage.FloatValue;
        if (zc == 8)
            dmg *= g_cvTankMult.FloatValue;

        g_bInInject[i] = true;
        SDKHooks_TakeDamage(i, projectile, thrower, dmg, DMG_BLAST, -1, zeroForce, projPos, false);
        g_bInInject[i] = false;
        LogMessage("GL splash EXTENDED: %N zc%d dist %.0f -> %.0f", i, zc, dist, dmg);
    }

    // v2.1.14：Witch 已由 OnEntityDestroyed 的 boom 时注入统一处理（0~range 全覆盖），
    // 此处不再重复注入（否则 180~500 双伤=一发打死）。
}

/**
 * v2.1.19+ 队友 FF 回补：引擎后置扣血拦不住，帧循环直到扣完再把多扣的部分
 * （excess = 实际扣血 - 目标伤害）加回 → 净伤 = 目标（直击 15 / 溅射 8）。
 * v2.1.20：后置扣血晚于下一帧（实测单帧回补时 hp 未扣），excess<=0 时每帧
 * 重试，上限 ~60 帧（1 秒），超时放弃。倒地（hp<1）不回补，防 incap 异常。
 */
public void FrameMateHeal(int victim)
{
    int goal = RoundToFloor(g_fMateGoal[victim]);
    int hp0 = g_iMateHP0[victim];
    if (goal <= 0 || hp0 < 0)
        return;
    if (victim < 1 || victim > MaxClients || !IsClientInGame(victim) || !IsPlayerAlive(victim) || GetClientTeam(victim) != 2)
    {
        g_iMateHP0[victim] = -1;
        g_fMateGoal[victim] = 0.0;
        return;
    }

    int hp2 = GetEntProp(victim, Prop_Send, "m_iHealth");
    if (hp2 < 1)
    {
        // 被炸倒地：不回补（incap 状态血=0，补血会破坏状态机）
        g_iMateHP0[victim] = -1;
        g_fMateGoal[victim] = 0.0;
        LogMessage("GL ff heal: %N INCAP hp0 %d goal %d, skip", victim, hp0, goal);
        return;
    }

    int excess = (hp0 - hp2) - goal;
    if (excess > 0)
    {
        SetEntProp(victim, Prop_Send, "m_iHealth", hp2 + excess);
        LogMessage("GL ff heal: %N hp %d->%d (goal %d, excess %d)", victim, hp2, hp2 + excess, goal, excess);
        g_iMateHP0[victim] = -1;
        g_fMateGoal[victim] = 0.0;
        return;
    }

    // 引擎后置还没扣（excess<=0）：等下一帧再查
    if (++g_iMateRetry[victim] > 60)
    {
        LogMessage("GL ff heal: %N TIMEOUT hp2 %d hp0 %d goal %d (engine never applied)", victim, hp2, hp0, goal);
        g_iMateHP0[victim] = -1;
        g_fMateGoal[victim] = 0.0;
        g_iMateRetry[victim] = 0;
        return;
    }
    RequestFrame(FrameMateHeal, victim);
}

/**
 * 引擎友伤难度系数（survivor_friendly_fire_factor_*）。
 * 服务器在 sourcemod.cfg 显式设置：easy 0.02 / normal 0.04 / hard 0.08 / expert 0.15。
 * 按 z_difficulty 选对应 cvar 的当前值；读不到兜底 Hard 0.08。
 */
float GetEngineFFFactor()
{
    char diff[16];
    ConVar cvDiff = FindConVar("z_difficulty");
    if (cvDiff != null)
        GetConVarString(cvDiff, diff, sizeof(diff));

    char cvarName[48];
    if (StrEqual(diff, "Easy", false))
        strcopy(cvarName, sizeof(cvarName), "survivor_friendly_fire_factor_easy");
    else if (StrEqual(diff, "Normal", false))
        strcopy(cvarName, sizeof(cvarName), "survivor_friendly_fire_factor_normal");
    else if (StrEqual(diff, "Impossible", false) || StrEqual(diff, "Expert", false))
        strcopy(cvarName, sizeof(cvarName), "survivor_friendly_fire_factor_expert");
    else
        strcopy(cvarName, sizeof(cvarName), "survivor_friendly_fire_factor_hard");

    ConVar cvFF = FindConVar(cvarName);
    if (cvFF != null && cvFF.FloatValue > 0.0)
        return cvFF.FloatValue;
    return 0.08;
}
