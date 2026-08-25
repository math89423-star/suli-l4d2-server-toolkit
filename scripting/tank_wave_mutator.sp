// tank_wave_mutator.sp
// Tank 波次突变系统：10% 随机突变 + 连续5波无倒地强制双Tank + 连续11波无Tank强制单Tank + Tank波后3波冷静期
// v2.2.0: Tank 波强制清缴条件 = Tank 死亡（挂起 specialspawner 清缴判定）
// v2.3.0: 新增11波无Tank保底（第12波必刷单Tank，冷静期波不计数）+ 冷静期 9→3 波
// v2.4.0: 就近生成修复 —— 多次采样取 ≥450u 里最近点，确保 Tank 在引擎激活范围（防待命站桩+掉队被清）
// v2.5.0: 冷静期倍率（Tank 波前 ×1.5）+ SS_MarkWaveTank（Tank 波剿灭得分 ×3）
// v2.6.0: 双Tank生成约束 + 卡住看护（用户定稿 2026-08-16）——
//   · 生成互斥：第二只 Tank 采样点与第一只水平距离 ≥800u（防重叠互卡）
//   · 防前后包夹：两只相对幸存者方位夹角 ≤90°（同侧推进，不摆夹击阵型）
//   · 卡住看护：监控发现 Tank 位置 8s 几乎不动 → 重定位到有 LOS 的新点
//     （抢在引擎 stuck 处理/处决前，Tank 卡住根因=生成点重叠+不可达+AI 清跳）
// v2.6.1: 实机修复（2026-08-16 19:01 双Tank 50u 重叠+跨层案例）——
//   · 约束评估移到所有候选（v2.6.0 只在 ≥MIN_DIST 分支评估，贴脸兜底分支
//     绕过约束 → c8m2 PZ 点池 <750u 时约束形同虚设）
//   · 兜底改取"最远"候选（v2.4.0 注释承诺取最远、实现取第一个随机点——老坑）
//   · 生成点 LOS 检查（防跨层/隔墙生成：Tank #2 曾生成在楼下平台玩家看不到）
//   · 重定位兜底：LOS 采样失败 → 传送到最近幸存者前方 500u 地面点（必定成功）
// v2.6.2: 双Tank"放一起"（用户定稿 2026-08-16，取代互斥/夹角约束）——
//   · 生成：第二只 Tank 锚定第一只位置，4 方向 150u 微偏移（同 Z 同层），
//     LOS 通过者优先，全失败同点生成——两只一起出现，天然同侧不包夹互见；
//     删除 TANK_SPAWN_SEPARATION/MAX_ANGLE（互斥/夹角约束整套移除）
//   · 重定位：优先依附另一只存活 Tank（200u 偏移传过去，两只重新"放一起"）；
//     单 Tank 卡住 LOS 无解时 → 随机方向 700u 地面点（不再传送玩家正前方
//     500u 糊脸——用户否决该方案）
// v2.6.3: 三角形刷新 + 至少 800u（用户定稿 2026-08-16，取代"放一起"/"一前一后"）——
//   · 两只 Tank 与玩家构成【三角形】：每只距玩家 ≥800u（"至少保持800u距离"），
//     两只相对玩家夹角 60°-120°（水平面）——60° 下限保证两只间距 ≥800u
//     物理不接触不互卡；120° 上限防侧翼包夹（仍同侧推进不夹击）
//   · 严格执行距离：无 ≥800u+LOS 候选就【不刷】（删除全部贴脸 fallback——
//     历史贴脸案例 dist=298/502/561；用户："必须距离生还者队伍足够远"）
//   · 第二只失败 → 只刷第一只（单 Tank 波），不违背"足够远"
//   · 采样 12→20 降低失败率；LOS 检查防跨层/隔墙（玩家看不到 = 白刷）
// v2.6.4: 前后刷新 fallback（用户拍板 2026-08-16，tew2_1stem 20:45 实测 0/2 全灭）——
//   · 起因：20:45 室内段 20 次采样无 ≥800u+LOS 候选（specialspawner 同刻
//     10/10 invis-fb），双 Tank 预告后一只没刷（v2.6.3 严格执行的代价）
//   · 三角形优先不变；无合格点 → fallback：第一只刷队伍【前方】、第二只刷
//     【后方】（全队平均朝向/中心，用户："做一个fallback，就是前后刷新"）
//   · 距离 600→500→400 逐级缩短 + 向下 trace 找地面（防卡墙/落地）；无 LOS 要求
//   · 仍找不到地面点才放弃该只（日志区分 fallback 成功/失败原因）
// v2.6.5: fallback 距离档位 600/500/400 → 800/600/450（用户拍板，拉开前后距离）
// v2.7.1: 出生点nav校验 + 放宽主路径（用户拍板 1+2 合并）——
//   · 主路径 TANK_SPAWN_MIN_DIST 800→700 + SAMPLES 20→40（室内段800+LOS 0%成功→100% fallback）
//   · 全链路 IsNavReachable：主路径/fallback/重定位LOS后加 nav可达性，过滤Z=-2879虚空非nav点被导演秒删
// v2.7.7: 冷静期基准单一来源化（2026-08-25）——
//   · SS_OnWaveRest 不再硬编码 baseMin/baseMax=20/30 踩 ss_rest_min/max
//     （cfg 改 25/35 后每波被踩回, 用户冷静期设定从未生效——实测波1 39.2s
//     来自 [30,45] Tank 缩放、波2 26.0s 来自 [20,30] 硬编码, 均与 cfg 无关）
//   · 改为回合开始后首次 REST 从 cvar 捕获基准存全局（防连续 Tank 波叠加）,
//     每波先复位基准再按 tank_wave_rest_scale 缩放

// v2.7.6: 修复 Tank 偶尔刷新到地面之下的 bug ——
//   · 新增 FindGroundAbove：从候选点上方150u向下trace1500u找实际地面（+5u防z-fighting），
//     解决 L4D_GetRandomPZSpawnPosition 返回的Z坐标偶尔低于可行走平面的问题
//   · ValidateTankSpawnPoint 地面检测范围 120u→300u，覆盖更大几何间距
//   · 三条生成路径（主/fallback/紧急兜底）均在生成前调用 FindGroundAbove 做二次校正
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "2.7.9"

// 配置常量
#define MUTATION_CHANCE 0.07        // 7% 突变概率（v2.7.0 2026-08-17: 10%→7%, 波次密度提高后惩罚后移）
#define FORCE_TANK_WAVES 8          // 连续8波完美清缴（无倒地/死亡）触发强制双Tank（v2.7.0: 5→8）
#define FORCE_TANK_NO_SPAWN 14      // 连续14波无Tank触发保底单Tank（第15波必刷; v2.7.0: 11→14）
#define TANK_COOLDOWN_WAVES 4       // Tank波后冷静期（v2.7.0: 3→4）
#define MAX_TRACKED_TANKS 4         // 最多跟踪的 Tank 数量
// v2.4.0: 就近生成 —— 突变 Tank 生成后必须在幸存者活跃模拟范围内，否则引擎
// 不 tick 其 AI（待命站桩），且远离流程会被导演判定掉队自动清除（"被系统处死"）。
#define TANK_SPAWN_MIN_DIST 700.0   // v2.7.1: 800→700 放宽100u（配合nav校验，主路径失败率过高 100%走fallback，室内段无800+LOS点）
#define TANK_SPAWN_SAMPLES  40      // v2.7.1: 20→40（采样翻倍，降低"无候选"概率）
// v2.6.3: 三角形刷新（用户定稿）——两只与玩家构成三角形，夹角 60°-120°
#define TANK_SPAWN_ANGLE_MIN 60.0   // 夹角下限（60° 保证两只间距 ≥800u 不互卡）
#define TANK_SPAWN_ANGLE_MAX 120.0  // 夹角上限（防侧翼包夹）
// v2.6.4: 前后刷新 fallback（用户定稿）——三角形无解时第一只前方、第二只后方
// v2.6.5: 距离档位 800 → 600 → 450（用户拍板，替代 600→500→400）
#define TANK_FALLBACK_DIST_1 800.0   // 首档：尽量拉开前后距离
#define TANK_FALLBACK_DIST_2 600.0
#define TANK_FALLBACK_DIST_3 450.0   // 末档：窄段保底
// v2.6.0: 卡住看护（用户定稿）——位置长时间几乎不动 → 重定位
#define TANK_STUCK_MOVE   40.0      // 单次检查（2s）移动 < 此值视为"没动"
#define TANK_STUCK_CHECKS 4         // 连续 4 次没动（8s）→ 判定卡住 → 重定位

// specialspawner native 声明
native void SS_HoldClearing(bool hold);
// v2.5.0: 标记本波为 Tank 波（specialspawner 剿灭得分 ×3）
native void SS_MarkWaveTank();

// 全局变量
int g_iWaveCounter = 0;             // 总波次计数
int g_iNoDownWaves = 0;             // 连续无倒地波次
int g_iNoTankWaves = 0;             // 连续无Tank波次（冷静期不累加）
int g_iTankCooldown = 0;            // Tank波后冷静期剩余
bool g_bNextWaveIsTank = false;     // 下一波是否为Tank波（预警标志）
int g_iNextTankCount = 0;           // 下一波Tank数量（1=突变, 2=强制）
float g_fRestBaseMin = 0.0;         // v2.7.7 冷静期基准下限（回合开始时从 ss_rest_min 捕获, 0=未捕获）
float g_fRestBaseMax = 0.0;         // v2.7.7 冷静期基准上限（同上）。不再硬编码 20/30——
                                    // 2026-08-25 实测: cfg 改 25/35 后被旧硬编码每波踩回,
                                    // 用户设的冷静期从未生效。单一来源 = specialspawner.cfg

// Tank 波跟踪
int g_iTanks[MAX_TRACKED_TANKS];    // 当前 Tank 波生成的 Tank client 索引
int g_iTankCount = 0;               // 当前活跃 Tank 数量
Handle g_hTankMonitor = null;       // Tank 状态监控定时器
ConVar g_hCvarRestScale = null;     // v2.5.0: Tank 波前冷静期倍率
ConVar g_hCvarFrontrunner = null; // v2.7.5: Tank 瞄领跑者开关
// v2.6.0: 卡住看护状态（与 g_iTanks 同下标）
float g_fTankLastPos[MAX_TRACKED_TANKS][3];   // 上次监控位置
int   g_iTankStuckChecks[MAX_TRACKED_TANKS];  // 连续"没动"检查计数

public Plugin myinfo = {
    name = "Tank Wave Mutator",
    author = "Suli",
    description = "Random tank waves with forced spawn after 5 waves without downs",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart() {
    // 监听倒地和死亡事件
    HookEvent("player_incapacitated", Event_PlayerDown);
    HookEvent("player_death", Event_PlayerDeath);

    // 换图重置
    HookEvent("round_start", Event_RoundStart);

    // v2.5.0: Tank 波前冷静期倍率（用户设计：下一波是 Tank → 冷静期 ×1.5）
    g_hCvarRestScale = CreateConVar("tank_wave_rest_scale", "1.5",
        "Tank 波前冷静期倍率（ss_rest_min/max 基准 × 本值；1.0 = 不放大）",
        FCVAR_NONE, true, 1.0, true, 3.0);
    // v2.7.5: Tank 瞄领跑者（单独路径：以 flow 最高幸存者为参照采样，压力给到最前）
    g_hCvarFrontrunner = CreateConVar("tank_spawn_frontrunner", "1",
        "Tank 刷新瞄领跑者：1=以 flow 领跑者为参照采样（单独路径）| 0=任意生还者（旧逻辑）",
        FCVAR_NONE, true, 0.0, true, 1.0);

    LogMessage("[Tank Mutator] Plugin loaded. Mutation: %.0f%%, Force: %d waves, Cooldown: %d waves",
               MUTATION_CHANCE * 100.0, FORCE_TANK_WAVES, TANK_COOLDOWN_WAVES);
}

public void OnPluginEnd() {
    // 卸载时释放清缴挂起
    ReleaseClearingHold();
}

// ============ 事件处理 ============

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    // 换图重置所有状态
    g_iWaveCounter = 0;
    g_iNoDownWaves = 0;
    g_iNoTankWaves = 0;
    g_iTankCooldown = 0;
    g_bNextWaveIsTank = false;
    g_iNextTankCount = 0;
    // v2.7.8: 基准改为插件加载时捕获一次、跨回合持久——
    // 实测教训: ss_rest_* 在回合间不清零, 若上一回合尾部停在 Tank 缩放值
    // (如 [37.5,52.5]), 本回合首次 REST 的"重新捕获"会把污染值当基准,
    // 之后所有 normal 波全部抽到 49~51s(2026-08-25 玩家实测复现)。
    // 换图仍会重捕获: 全局量随插件换图自然重置, 且换图必然重跑 cfg。
    ClearTankTracking();
    ReleaseClearingHold();
    LogMessage("[Tank Mutator] Round start, all counters reset");
}

void Event_PlayerDown(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && IsClientInGame(client) && GetClientTeam(client) == 2) {
        // 生还者倒地，重置连续无倒地计数
        g_iNoDownWaves = 0;
        LogMessage("[Tank Mutator] Survivor down, reset no-down counter");
    }
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || !IsClientInGame(client)) return;

    if (GetClientTeam(client) == 2) {
        // 生还者死亡，重置连续无倒地计数
        g_iNoDownWaves = 0;
        LogMessage("[Tank Mutator] Survivor death, reset no-down counter");
    } else if (GetClientTeam(client) == 3 && IsTank(client)) {
        // Tank 死亡，检查是否在跟踪列表中
        CheckTankDeath(client);
    }
}

// ============ specialspawner forward 监听 ============

public void SS_OnWaveRest(float totalCountdown) {
    // 波次清缴结束，进入 REST 冷静期。specialspawner v5.25 起在本函数
    // 返回后抽取冷静期（rest = Random(ss_rest_min/max)）——本函数对
    // ss_rest_min/max 的修改即作用于本波冷静期。
    // v2.5.0: 冷静期倍率（用户设计：下一波是 Tank → 冷静期 ×1.5）。
    // v2.7.7: 基准不再硬编码 20/30——改为回合开始后首次 REST 时从 ss_rest_min/max
    // 捕获（此时 cfg 已执行、本插件尚未改写 → 即 cfg 值）。捕获一次存全局,
    // 之后每波先复位基准再缩放, 防连续 Tank 波 ×1.5 叠加膨胀。
    // （2026-08-25: cfg 改 25/35 后被旧硬编码踩回 20/30, 用户设定从未生效。）
    ConVar hRestMin = FindConVar("ss_rest_min");
    ConVar hRestMax = FindConVar("ss_rest_max");
    if (g_fRestBaseMin <= 0.0 || g_fRestBaseMax <= 0.0) {
        g_fRestBaseMin = (hRestMin != null) ? hRestMin.FloatValue : 25.0;
        g_fRestBaseMax = (hRestMax != null) ? hRestMax.FloatValue : 35.0;
        LogMessage("[Tank Mutator] Rest base captured from cvars: %.1f-%.1f", g_fRestBaseMin, g_fRestBaseMax);
    }
    if (hRestMin != null) hRestMin.SetFloat(g_fRestBaseMin);
    if (hRestMax != null) hRestMax.SetFloat(g_fRestBaseMax);
    // 此时判定下一波是否为 Tank 波，如果是则提前预警

    // 首波保护：第一波必定不是 Tank
    if (g_iWaveCounter == 0) {
        g_bNextWaveIsTank = false;
        LogMessage("[Tank Mutator] Wave #1 upcoming, first wave protection");
        return;
    }

    // Tank波后冷静期：不刷Tank，冻结无倒地/无Tank计数（打完Tank后的波次不算在内）
    if (g_iTankCooldown > 0) {
        g_iTankCooldown--;
        g_bNextWaveIsTank = false;
        g_iNextTankCount = 0;
        LogMessage("[Tank Mutator] Next wave: normal (cooldown %d left, counters frozen)", g_iTankCooldown);
        return;
    }

    // 结算刚打完的这一波（非冷静期普通波）：先累加计数，再判定下一波
    // 无倒地计数在 player_incapacitated/player_death 中被清零，此处递增=本波全程无倒地
    g_iNoDownWaves++;
    g_iNoTankWaves++;

    bool shouldSpawnTank = false;
    bool doubleTank = false;
    char reason[128];

    if (g_iNoDownWaves >= FORCE_TANK_WAVES) {
        // 强制双Tank波（连续N波无倒地）
        shouldSpawnTank = true;
        doubleTank = true;
        Format(reason, sizeof(reason), "Forced double (no downs for %d waves)", g_iNoDownWaves);
    } else if (g_iNoTankWaves >= FORCE_TANK_NO_SPAWN) {
        // 保底单Tank波（连续N波无Tank，第N+1波必刷）
        shouldSpawnTank = true;
        Format(reason, sizeof(reason), "Guaranteed (no tank for %d waves)", g_iNoTankWaves);
    } else {
        // 10% 随机突变
        float roll = GetURandomFloat();
        if (roll < MUTATION_CHANCE) {
            shouldSpawnTank = true;
            Format(reason, sizeof(reason), "Random mutation (rolled %.1f%%)", roll * 100.0);
        } else {
            Format(reason, sizeof(reason), "No mutation (rolled %.1f%%)", roll * 100.0);
        }
    }

    if (shouldSpawnTank) {
        g_bNextWaveIsTank = true;

        // v2.5.0: 下一波是 Tank → 冷静期 ×scale（specialspawner 在 forward
        // 返回后抽取 rest，此修改即生效于本波冷静期；基准用捕获值, 不叠加）
        float scale = (g_hCvarRestScale != null) ? g_hCvarRestScale.FloatValue : 1.5;
        if (hRestMin != null) hRestMin.SetFloat(g_fRestBaseMin * scale);
        if (hRestMax != null) hRestMax.SetFloat(g_fRestBaseMax * scale);

        // 预警秒数由 specialspawner 播报（"X 秒后下一波"，已含倍率），
        // 此处不再报具体秒数（v2.5.0: totalCountdown 在 forward 时尚未确定）
        if (doubleTank) {
            g_iNextTankCount = 2;
            LogMessage("[Tank Mutator] DOUBLE TANK WAVE predicted! Reason: %s", reason);
            PrintToChatAll("\x04☠ 警告：下一波将刷新 \x03双倍 TANK\x01！");
            PrintCenterTextAll("☠ 警告：下一波双倍 TANK 来袭！");
        } else {
            g_iNextTankCount = 1;
            LogMessage("[Tank Mutator] TANK WAVE predicted! Reason: %s", reason);
            PrintToChatAll("\x04☠ 警告：下一波将刷新 TANK！\x01");
            PrintCenterTextAll("☠ 警告：下一波 TANK 来袭！");
        }

        PrintToChatAll("\x04[Tank Mutator]\x01 做好准备！");

        // Tank 波后进入 N 波冷静期，计数器归零
        g_iTankCooldown = TANK_COOLDOWN_WAVES;
        g_iNoDownWaves = 0;
        g_iNoTankWaves = 0;
    } else {
        // 普通波：计数已在上方累加
        g_bNextWaveIsTank = false;
        g_iNextTankCount = 0;
        LogMessage("[Tank Mutator] Next wave: normal. No-down: %d/%d, No-tank: %d/%d. %s",
                   g_iNoDownWaves, FORCE_TANK_WAVES, g_iNoTankWaves, FORCE_TANK_NO_SPAWN, reason);
    }
}

public void SS_OnWaveStart(bool started) {
    // 波次开始（PHASE_PRESSURE），started = 是否真的刷出了特感
    g_iWaveCounter++;

    if (!started) {
        // 零波（上限满/全倒等），specialspawner 直接进收尾期
        LogMessage("[Tank Mutator] Wave #%d: zero wave (no SI spawned)", g_iWaveCounter);
        return;
    }

    LogMessage("[Tank Mutator] Wave #%d started", g_iWaveCounter);

    // 如果这波预判为 Tank 波，现在生成 Tank
    if (g_bNextWaveIsTank) {
        // 立即挂起清缴（Tank 波期间强制等 Tank 死）
        SetClearingHold(true);

        // 延迟1.5秒生成（等 specialspawner 批次完成），传入 Tank 数量
        DataPack pack;
        CreateDataTimer(1.5, Timer_SpawnTank, pack, TIMER_FLAG_NO_MAPCHANGE);
        pack.WriteCell(g_iNextTankCount);
        g_bNextWaveIsTank = false;  // 消费标志位
        g_iNextTankCount = 0;
    }
}

Action Timer_SpawnTank(Handle timer, DataPack pack) {
    pack.Reset();
    int tankCount = pack.ReadCell();
    if (tankCount < 1) tankCount = 1;

    // 清空旧跟踪
    ClearTankTracking();

    int spawned = 0;
    // v2.7.5: 队首/队尾单独路径（单Tank瞄领跑者，双Tank一首一尾夹击前后）
    bool useFront = (g_hCvarFrontrunner != null && g_hCvarFrontrunner.BoolValue);
    int frontClient = -1, tailClient = -1;
    if (useFront) {
        frontClient = GetFrontrunner();
        if (tankCount == 2) tailClient = GetTailRunner();
        if (frontClient > 0) LogMessage("[Tank Mutator] Frontrunner path: front=%N flow=%.0f %s", frontClient, L4D2Direct_GetFlowDistance(frontClient), (tailClient>0? "tail assigned":""));
        if (tailClient > 0) LogMessage("[Tank Mutator] Tail path: tail=%N flow=%.0f", tailClient, L4D2Direct_GetFlowDistance(tailClient));
    }
    for (int n = 0; n < tankCount && spawned < MAX_TRACKED_TANKS; n++) {
        int client = -1;
        if (useFront) {
            if (tankCount == 2) {
                // 双Tank：0→队首，1→队尾（前后夹击）
                int want = (n == 0) ? frontClient : tailClient;
                if (want > 0 && IsClientInGame(want) && IsPlayerAlive(want) && !GetEntProp(want, Prop_Send, "m_isIncapacitated"))
                    client = want;
                else
                    client = (want == frontClient) ? tailClient : frontClient;
                if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
                    client = GetAnyAliveSurvivor();
                LogMessage("[Tank Mutator] Tank #%d ref %s %N", n+1, (n==0?"front":"tail"), client);
            } else {
                // 单Tank：瞄领跑者
                if (frontClient > 0 && IsClientInGame(frontClient) && IsPlayerAlive(frontClient))
                    client = frontClient;
                else
                    client = GetAnyAliveSurvivor();
            }
        } else {
            client = GetAnyAliveSurvivor();
        }
        if (client <= 0) {
            LogMessage("[Tank Mutator] Tank spawn failed: no alive survivor found");
            break;
        }

        float refPos[3];
        GetClientAbsOrigin(client, refPos);
        float eye[3];
        GetClientEyePosition(client, eye);

        float spawnPos[3], spawnAng[3] = {0.0, 0.0, 0.0};
        float bestPos[3];
        float bestDist = -1.0;
        int validCount = 0;

        // v2.6.3: 三角形刷新（用户定稿）——两只 Tank 与玩家构成三角形：
        // 每只 ≥800u + LOS（玩家可见）+ 两只相对玩家水平夹角 60°-120°。
        // 严格执行距离：无合格点 → 不刷（绝不贴脸 fallback——用户："必须
        // 距离生还者队伍足够远"；历史贴脸案例 dist=298/502/561）。
        bool hasBuddy = (spawned > 0 && g_iTanks[0] > 0 && IsClientInGame(g_iTanks[0]));
        float buddyPos[3];
        if (hasBuddy)
            GetClientAbsOrigin(g_iTanks[0], buddyPos);

        // 夹角阈值：cos60°=0.5（太挤） / cos120°=-0.5（快包夹）
        float maxCos = Cosine(TANK_SPAWN_ANGLE_MIN * 0.01745329252);
        float minCos = Cosine(TANK_SPAWN_ANGLE_MAX * 0.01745329252);

        for (int attempt = 0; attempt < TANK_SPAWN_SAMPLES; attempt++) {
            float candidate[3];
            if (!L4D_GetRandomPZSpawnPosition(client, 8, 5, candidate))
                continue;
            float dist = GetVectorDistance(refPos, candidate);
            validCount++;

            // 严格距离：≥800u（用户："至少保持800u距离"）
            if (dist < TANK_SPAWN_MIN_DIST)
                continue;

            // LOS：玩家可见（防跨层/隔墙——只算世界几何，忽略玩家实体）
            TR_TraceRayFilter(candidate, eye, MASK_SOLID, RayType_EndPoint, TraceFilter_World);
            if (TR_GetFraction() < 0.95)
                continue;

            // 三角形夹角：两只相对玩家 60°-120°（水平面；同侧推进不包夹）
            // v2.7.5: 队首/队尾双Tank时禁用三角约束（前后夹击天然 180°，会误判为包夹）
            if (hasBuddy && !(useFront && tankCount == 2)) {
                float d1x = buddyPos[0] - refPos[0];
                float d1y = buddyPos[1] - refPos[1];
                float d2x = candidate[0] - refPos[0];
                float d2y = candidate[1] - refPos[1];
                float len1 = SquareRoot(d1x * d1x + d1y * d1y);
                float len2 = SquareRoot(d2x * d2x + d2y * d2y);
                if (len1 > 1.0 && len2 > 1.0) {
                    float cosA = (d1x * d2x + d1y * d2y) / (len1 * len2);
                    if (cosA > maxCos || cosA < minCos)
                        continue;   // 夹角 <60°（两只太挤）或 >120°（接近包夹）
                }
            }

            // v2.7.0: hull/nav/可达性验证
            if (!ValidateTankSpawnPoint(candidate))
                continue;
            // v2.7.1: nav 可达性（防非nav/悬空点被导演秒删 Z=-2879案例）
            if (!IsNavReachable(candidate, refPos))
                continue;

            if (bestDist < 0.0 || dist < bestDist) {
                bestDist = dist;
                bestPos[0] = candidate[0]; bestPos[1] = candidate[1]; bestPos[2] = candidate[2];
            }
        }

        if (bestDist < 0.0) {
            LogMessage("[Tank Mutator] Tank #%d spawn failed: no candidate ≥%.0fu with LOS%s (足够远约束)",
                       n + 1, TANK_SPAWN_MIN_DIST, hasBuddy ? " + triangle angle" : "");
            // v2.6.4: 前后刷新 fallback（用户拍板）——三角形无解时第一只刷队伍
            // 前方、第二只刷后方（全队平均朝向/中心），距离逐级缩短 + 地面点
            if (SpawnTankFallback(n, spawnPos)) {
                int tank = L4D2_SpawnTank(spawnPos, spawnAng);
                if (tank > 0 && IsClientInGame(tank)) {
                    g_iTanks[spawned] = tank;
                    GetClientAbsOrigin(tank, g_fTankLastPos[spawned]);
                    g_iTankStuckChecks[spawned] = 0;
                    spawned++;
                    LogMessage("[Tank Mutator] Tank #%d FALLBACK spawned (%s) at (%.1f, %.1f, %.1f), client: %d",
                               n + 1, (n % 2 == 0) ? "front" : "back",
                               spawnPos[0], spawnPos[1], spawnPos[2], tank);
                } else {
                    // v2.7.9: 实体无效也走紧急 PZ 兜底(原来只有无地面才走)
                    LogMessage("[Tank Mutator] Tank #%d fallback invalid entity -> emergency PZ", n + 1);
                    bool emergOk2 = false;
                    float emergPos2[3] = {0.0,0.0,0.0};
                    float cpos2[3]; GetClientAbsOrigin(client, cpos2);
                    for (int e2 = 0; e2 < 6 && !emergOk2; e2++) {
                        float tp[3];
                        if (!L4D_GetRandomPZSpawnPosition(client, 8, 5, tp)) continue;
                        if (GetVectorDistance(tp, cpos2) < 400.0) continue;
                        emergPos2 = tp;
                        emergOk2 = true;
                    }
                    if (emergOk2) {
                        int t2 = L4D2_SpawnTank(emergPos2, spawnAng);
                        if (t2 > 0 && IsClientInGame(t2)) {
                            g_iTanks[spawned] = t2;
                            GetClientAbsOrigin(t2, g_fTankLastPos[spawned]);
                            g_iTankStuckChecks[spawned] = 0;
                            spawned++;
                            LogMessage("[Tank Mutator] Tank #%d EMERGENCY spawned at (%.1f, %.1f, %.1f), client: %d",
                                       n + 1, emergPos2[0], emergPos2[1], emergPos2[2], t2);
                        } else {
                            LogMessage("[Tank Mutator] Tank #%d emergency also failed", n + 1);
                        }
                    } else {
                        LogMessage("[Tank Mutator] Tank #%d emergency: no usable PZ point", n + 1);
                    }
                }
            } else {
                LogMessage("[Tank Mutator] Tank #%d fallback failed: no ground point front/back", n + 1);
                // v2.7.3 紧急兜底：fallback 全灭时用 Director 任意 PZ 点必刷
                // v2.7.4 加 400u 防贴脸：3次重抽 ≥400u，仍无则放行贴脸（保必刷）
                float emergPos[3] = {0.0,0.0,0.0}; bool emergOk = false;
                float cposTmp[3]; GetClientAbsOrigin(client, cposTmp);
                for (int eTry=0; eTry<3; eTry++) {
                    float tmpPos[3];
                    if (!L4D_GetRandomPZSpawnPosition(client, 8, 5, tmpPos)) break;
                    emergPos[0]=tmpPos[0]; emergPos[1]=tmpPos[1]; emergPos[2]=tmpPos[2];
                    if (GetVectorDistance(emergPos, cposTmp) < 400.0) {
                        emergOk = false;
                        continue;
                    }
                    emergOk = true;
                    break;
                }
                // 3次均 <400u 仍放行最后一次的 emergPos（保必刷）
                if (!emergOk && emergPos[0]==0.0 && emergPos[1]==0.0 && emergPos[2]==0.0) {
                    L4D_GetRandomPZSpawnPosition(client, 8, 5, emergPos);
                }
                if (emergPos[0]!=0.0 || emergPos[1]!=0.0 || emergPos[2]!=0.0) {
                    // v2.7.6: 紧急兜底也做地面校正
                    FindGroundAbove(emergPos, emergPos);
                    int tank2 = L4D2_SpawnTank(emergPos, spawnAng);
                    if (tank2 > 0 && IsClientInGame(tank2)) {
                        g_iTanks[spawned] = tank2;
                        GetClientAbsOrigin(tank2, g_fTankLastPos[spawned]);
                        g_iTankStuckChecks[spawned] = 0;
                        spawned++;
                        LogMessage("[Tank Mutator] Tank #%d EMERGENCY spawned at (%.1f, %.1f, %.1f) dist=%.0f, client: %d", n+1, emergPos[0], emergPos[1], emergPos[2], GetVectorDistance(emergPos, cposTmp), tank2);
                    } else {
                        LogMessage("[Tank Mutator] Tank #%d emergency spawn failed: invalid entity", n+1);
                    }
                } else {
                    LogMessage("[Tank Mutator] Tank #%d emergency spawn failed: no PZ position", n+1);
                }
            }
            continue;
        }

        spawnPos[0] = bestPos[0]; spawnPos[1] = bestPos[1]; spawnPos[2] = bestPos[2];
        // v2.7.6: 二次地面校正，防止引擎返回的坐标略低于地面导致 Tank 刷地底
        FindGroundAbove(spawnPos, spawnPos);

        // 直接生成 Tank
        int tank = L4D2_SpawnTank(spawnPos, spawnAng);
        if (tank > 0 && IsClientInGame(tank)) {
            g_iTanks[spawned] = tank;
            // v2.6.0: 初始化卡住看护状态
            GetClientAbsOrigin(tank, g_fTankLastPos[spawned]);
            g_iTankStuckChecks[spawned] = 0;
            spawned++;
            LogMessage("[Tank Mutator] Tank #%d spawned at (%.1f, %.1f, %.1f), dist=%.0f, client: %d",
                       n + 1, spawnPos[0], spawnPos[1], spawnPos[2], bestDist, tank);
        } else {
            LogMessage("[Tank Mutator] Tank #%d spawn failed: invalid entity", n + 1);
        }
    }

    g_iTankCount = spawned;
    LogMessage("[Tank Mutator] Spawn complete: %d/%d tanks tracked", spawned, tankCount);

    if (spawned > 0) {
        // v2.5.0: 标记本波为 Tank 波（specialspawner 剿灭得分三档 ×3）
        if (GetFeatureStatus(FeatureType_Native, "SS_MarkWaveTank") == FeatureStatus_Available) {
            SS_MarkWaveTank();
            LogMessage("[Tank Mutator] Wave marked as TANK wave for clear score x3");
        }
    }

    if (spawned == 0) {
        // 没生成任何 Tank，立即释放挂起
        LogMessage("[Tank Mutator] No tanks spawned, releasing clearing hold immediately");
        ReleaseClearingHold();
    } else {
        // 启动监控定时器（每 2 秒检查 Tank 状态）
        if (g_hTankMonitor != null) {
            KillTimer(g_hTankMonitor);
        }
        g_hTankMonitor = CreateTimer(2.0, Timer_MonitorTanks, _, TIMER_REPEAT);
    }

    return Plugin_Stop;
}

// ============ Tank 跟踪管理 ============

void ClearTankTracking() {
    for (int i = 0; i < MAX_TRACKED_TANKS; i++) {
        g_iTanks[i] = 0;
        g_iTankStuckChecks[i] = 0;
        g_fTankLastPos[i][0] = g_fTankLastPos[i][1] = g_fTankLastPos[i][2] = 0.0;
    }
    g_iTankCount = 0;
    if (g_hTankMonitor != null) {
        KillTimer(g_hTankMonitor);
        g_hTankMonitor = null;
    }
}

void CheckTankDeath(int client) {
    bool wasTracked = false;
    for (int i = 0; i < MAX_TRACKED_TANKS; i++) {
        if (g_iTanks[i] == client) {
            g_iTanks[i] = 0;
            wasTracked = true;
            LogMessage("[Tank Mutator] Tracked tank %d died", client);
            break;
        }
    }

    if (wasTracked) {
        // 重新统计存活 Tank
        CheckAllTanksStatus();
    }
}

Action Timer_MonitorTanks(Handle timer) {
    CheckAllTanksStatus();
    return Plugin_Continue;
}

void CheckAllTanksStatus() {
    int alive = 0;
    for (int i = 0; i < MAX_TRACKED_TANKS; i++) {
        if (g_iTanks[i] > 0) {
            // 检查该 Tank 是否仍然有效且存活
            if (IsClientInGame(g_iTanks[i]) && IsPlayerAlive(g_iTanks[i]) && IsTank(g_iTanks[i])) {
                alive++;

                // v2.6.0: 卡住看护 —— 位置 8s 几乎不动 → 重定位（抢在引擎
                // stuck 处理/掉队处决前；根因=双Tank重叠互卡/生成点不可达）
                float pos[3];
                GetClientAbsOrigin(g_iTanks[i], pos);
                float moved = GetVectorDistance(g_fTankLastPos[i], pos);
                if (moved < TANK_STUCK_MOVE) {
                    g_iTankStuckChecks[i]++;
                    if (g_iTankStuckChecks[i] >= TANK_STUCK_CHECKS) {
                        LogMessage("[Tank Mutator] Tank %d stuck (moved %.0f in %d checks), relocating",
                                   g_iTanks[i], moved, g_iTankStuckChecks[i]);
                        RelocateStuckTank(g_iTanks[i]);
                        GetClientAbsOrigin(g_iTanks[i], g_fTankLastPos[i]);
                        g_iTankStuckChecks[i] = 0;
                    }
                } else {
                    g_fTankLastPos[i] = pos;
                    g_iTankStuckChecks[i] = 0;
                }
            } else {
                // Tank 已失效或死亡
                if (g_iTanks[i] != 0) {
                    LogMessage("[Tank Mutator] Tank client %d no longer valid", g_iTanks[i]);
                }
                g_iTanks[i] = 0;
            }
        }
    }

    // 所有 Tank 都死了，释放清缴挂起
    if (alive == 0 && g_iTankCount > 0) {
        LogMessage("[Tank Mutator] All tanks eliminated, releasing clearing hold");
        ReleaseClearingHold();
        ClearTankTracking();
    }
}

// v2.6.0: 卡住 Tank 重定位 —— 采样 450-1500u 且与幸存者有 LOS 的点（LOS=可达性
// 代理：能看见基本能寻路到达，避免再次生成到隔墙/悬崖点）。找不到就放弃，
// 下个监控 tick 再试。传送会打断 Tank 当前动作，但卡住的 Tank 本就无有效动作。
void RelocateStuckTank(int tank) {
    // v2.6.2: 优先依附另一只存活 Tank（用户："把两个tank放一起"）——传送到
    // 伙伴 200u 随机偏移处，两只重新并肩推进。伙伴本身在动（未被判卡）→
    // 传送后直接跟上。
    int buddy = -1;
    for (int i = 0; i < MAX_TRACKED_TANKS; i++) {
        if (g_iTanks[i] > 0 && g_iTanks[i] != tank &&
            IsClientInGame(g_iTanks[i]) && IsPlayerAlive(g_iTanks[i]) && IsTank(g_iTanks[i])) {
            buddy = g_iTanks[i];
            break;
        }
    }
    if (buddy > 0) {
        float bPos[3];
        GetClientAbsOrigin(buddy, bPos);
        float angRand = GetURandomFloat() * 6.2831853;  // 0-2π 随机方向
        float dest[3];
        dest[0] = bPos[0] + Cosine(angRand) * 200.0;
        dest[1] = bPos[1] + Sine(angRand) * 200.0;
        dest[2] = bPos[2] + 80.0;   // 抬高向下 trace 找地面

        float end[3];
        end[0] = dest[0]; end[1] = dest[1]; end[2] = dest[2] - 3000.0;
        TR_TraceRayFilter(dest, end, MASK_SOLID, RayType_EndPoint, TraceFilter_World);
        if (TR_GetFraction() > 0.0 && TR_GetFraction() < 1.0) {
            float ground[3];
            TR_GetEndPosition(ground);
            // v2.7.0: hull/nav 验证
            // v2.7.1: + nav 可达性（buddy点周围200u内应在同一nav网）
            if (ValidateTankSpawnPoint(ground) && IsNavReachable(ground, bPos)) {
                float ang2[3] = {0.0, 0.0, 0.0};
                TeleportEntity(tank, ground, ang2, NULL_VECTOR);
                LogMessage("[Tank Mutator] Stuck tank %d relocated next to buddy %d at (%.1f, %.1f, %.1f)",
                           tank, buddy, ground[0], ground[1], ground[2]);
            } else {
                // v2.7.9: bPos=活Tank脚底=已被实践证明可站立 → 无条件直传
                // (旧逻辑再过校验反而把唯一可行点拒掉 → 卡死循环, 玩家实测复现)
                float ang2[3] = {0.0, 0.0, 0.0};
                TeleportEntity(tank, bPos, ang2, NULL_VECTOR);
                LogMessage("[Tank Mutator] Stuck tank %d relocated to buddy %d spot UNVALIDATED (%.1f, %.1f, %.1f)",
                           tank, buddy, bPos[0], bPos[1], bPos[2]);
            }
        } else {
            // v2.7.9: 同上无条件直传伙伴脚底
            float ang2[3] = {0.0, 0.0, 0.0};
            TeleportEntity(tank, bPos, ang2, NULL_VECTOR);
            LogMessage("[Tank Mutator] Stuck tank %d relocated to buddy %d exact spot UNVALIDATED (%.1f, %.1f, %.1f)",
                       tank, buddy, bPos[0], bPos[1], bPos[2]);
        }
        return;
    }

    // 无另一只 Tank（单 Tank 卡住）→ LOS 采样 450-1500u 最近点
    int survivor = GetAnyAliveSurvivor();
    if (survivor <= 0) {
        LogMessage("[Tank Mutator] Stuck tank %d relocate skipped: no alive survivor", tank);
        return;
    }

    float refPos[3];
    GetClientAbsOrigin(survivor, refPos);
    float eye[3];
    GetClientEyePosition(survivor, eye);

    float bestPos[3];
    float bestDist = -1.0;

    for (int attempt = 0; attempt < TANK_SPAWN_SAMPLES; attempt++) {
        float candidate[3];
        if (!L4D_GetRandomPZSpawnPosition(survivor, 8, 5, candidate))
            continue;

        float dist = GetVectorDistance(refPos, candidate);
        if (dist < 450.0 || dist > 1500.0)
            continue;   // 贴脸不传、太远不传

        // 视线通畅（只算世界几何，忽略玩家实体）
        TR_TraceRayFilter(candidate, eye, MASK_SOLID, RayType_EndPoint, TraceFilter_World);
        if (TR_GetFraction() < 0.95)
            continue;   // 被墙/天花板挡

        // v2.7.0: hull/nav 验证
        // v2.7.1: + nav 可达性（防非nav点被导演秒删）
        if (!ValidateTankSpawnPoint(candidate) || !IsNavReachable(candidate, refPos))
            continue;

        if (bestDist < 0.0 || dist < bestDist) {
            bestDist = dist;
            bestPos[0] = candidate[0];
            bestPos[1] = candidate[1];
            bestPos[2] = candidate[2];
        }
    }

    if (bestDist < 0.0) {
        // v2.6.2: LOS 采样无解 → 随机方向 700u 地面点（用户否决"玩家正前方
        // 500u 糊脸"方案——随机方向大多数时候不在玩家眼前，距离也拉开些）
        float origin[3];
        GetClientAbsOrigin(survivor, origin);
        float angRand = GetURandomFloat() * 6.2831853;
        float dest[3];
        dest[0] = origin[0] + Cosine(angRand) * 700.0;
        dest[1] = origin[1] + Sine(angRand) * 700.0;
        dest[2] = origin[2] + 80.0;

        float end[3];
        end[0] = dest[0]; end[1] = dest[1]; end[2] = dest[2] - 3000.0;
        TR_TraceRayFilter(dest, end, MASK_SOLID, RayType_EndPoint, TraceFilter_World);
        if (TR_GetFraction() > 0.0 && TR_GetFraction() < 1.0) {
            float ground[3];
            TR_GetEndPosition(ground);
            // v2.7.0: hull/nav 验证
            // v2.7.1: + nav 可达性
            if (ValidateTankSpawnPoint(ground) && IsNavReachable(ground, origin)) {
                float ang2[3] = {0.0, 0.0, 0.0};
                TeleportEntity(tank, ground, ang2, NULL_VECTOR);
                LogMessage("[Tank Mutator] Stuck tank %d relocated (random 700u) to (%.1f, %.1f, %.1f)",
                           tank, ground[0], ground[1], ground[2]);
            } else {
                LogMessage("[Tank Mutator] Stuck tank %d relocate ground failed validation/nav", tank);
            }
        } else {
            LogMessage("[Tank Mutator] Stuck tank %d relocate failed: no LOS candidate AND no fallback ground", tank);
        }
        return;
    }

    float ang[3] = {0.0, 0.0, 0.0};
    TeleportEntity(tank, bestPos, ang, NULL_VECTOR);
    LogMessage("[Tank Mutator] Stuck tank %d relocated to (%.1f, %.1f, %.1f), dist=%.0f",
               tank, bestPos[0], bestPos[1], bestPos[2], bestDist);
}

// 射线过滤器：忽略玩家实体（幸存者/特感），只把世界几何+实体当阻挡
// v2.6.6: 修复写反 bug — SourceMod TraceFilter 语义: true=允许命中该 entity
//   旧代码 return (entity >= 1 && entity <= MaxClients) 把玩家当阻挡、把门/车/prop 全忽略
public bool TraceFilter_World(int entity, int contentsMask, any data) {
    return (entity < 1 || entity > MaxClients);
}

// ============================================================================
// v2.7.0: Tank spawn validator — hull clearance + 地面 + 碰撞
// v2.7.1: 新增 nav 可达性校验（IsNavReachable）—— hull 通过但不在nav上
//         的点会被导演判 stuck/掉队秒删（Z=-2879虚空点实证）
// ============================================================================
// Tank hull: 宽 ~48u, 高 ~72u (蹲姿出生)。验证：
//   1. 向上 trace 检查头顶空间 ≥ 72u
//   2. 向下 trace 确认有地面
//   3. 水平 4 方向 trace 检查无实体阻挡（门/车/墙壁）
//   4. (v2.7.1) nav 可达性在调用方额外检查 IsNavReachable
#define TANK_HULL_HEIGHT 72.0    // Tank 蹲姿高度（出生时）
#define TANK_HULL_WIDTH  48.0    // Tank 半宽

bool IsNavReachable(float from[3], float to[3]) {
    // L4D2_NavAreaTravelDistance <0 = 至少一端不在nav或不连通
    // 用作"点是否在有效nav且可寻路到幸存者"的代理
    float d = L4D2_NavAreaTravelDistance(from, to, false);
    return d >= 0.0;
}

// v2.7.6: 从 pos 上方 SAFE_HEIGHT 向下 trace 找实际地面，返回修正后的地面坐标。
// 解决 L4D_GetRandomPZSpawnPosition 偶尔返回地面下坐标导致 Tank 刷地底的 bug。
#define FIND_GROUND_SAFE_HEIGHT 150.0
#define FIND_GROUND_TRACE_DIST  1500.0
bool FindGroundAbove(float pos[3], float outPos[3]) {
	float start[3];
	start[0] = pos[0]; start[1] = pos[1]; start[2] = pos[2] + FIND_GROUND_SAFE_HEIGHT;
	float end[3];
	end[0] = pos[0]; end[1] = pos[1]; end[2] = pos[2] - FIND_GROUND_TRACE_DIST;
	TR_TraceRayFilter(start, end, MASK_SOLID, RayType_EndPoint, TraceFilter_World);
	if (TR_GetFraction() > 0.0 && TR_GetFraction() < 1.0) {
		float hitPos[3];
		TR_GetEndPosition(hitPos);
		outPos[0] = hitPos[0]; outPos[1] = hitPos[1]; outPos[2] = hitPos[2] + 5.0;
		return true;
	}
	// 地面不可达（极罕见），原样返回
	outPos[0] = pos[0]; outPos[1] = pos[1]; outPos[2] = pos[2];
	return false;
}

bool ValidateTankSpawnPoint(float pos[3]) {
    // 1) 头顶空间检查：从 pos 向上 trace，确认有 ≥72u 净空
    float upEnd[3];
    upEnd[0] = pos[0]; upEnd[1] = pos[1]; upEnd[2] = pos[2] + TANK_HULL_HEIGHT;
    TR_TraceRayFilter(pos, upEnd, MASK_SOLID, RayType_EndPoint, TraceFilter_World);
    if (TR_GetFraction() < 1.0) {
        return false;
    }

    // 2) 脚下地面检查：从 pos 向下 trace 300u，确认有地面（v2.7.6: 120→300 覆盖更大几何间距）
    float downEnd[3];
    downEnd[0] = pos[0]; downEnd[1] = pos[1]; downEnd[2] = pos[2] - 300.0;
    TR_TraceRayFilter(pos, downEnd, MASK_SOLID, RayType_EndPoint, TraceFilter_World);
    if (TR_GetFraction() >= 1.0) {
        return false;
    }

    // 3) 水平碰撞检查：4 个方向各 trace TANK_HULL_WIDTH，确认无实体阻挡
    float dirs[4][2] = {{1.0, 0.0}, {-1.0, 0.0}, {0.0, 1.0}, {0.0, -1.0}};
    for (int d = 0; d < 4; d++) {
        float sideStart[3], sideEnd[3];
        sideStart[0] = pos[0]; sideStart[1] = pos[1]; sideStart[2] = pos[2] + 36.0;
        sideEnd[0] = sideStart[0] + dirs[d][0] * TANK_HULL_WIDTH;
        sideEnd[1] = sideStart[1] + dirs[d][1] * TANK_HULL_WIDTH;
        sideEnd[2] = sideStart[2];
        TR_TraceRayFilter(sideStart, sideEnd, MASK_SOLID, RayType_EndPoint, TraceFilter_World);
        if (TR_GetFraction() < 1.0) {
            return false;
        }
    }

    return true;
}

// ============ v2.6.4 前后刷新 fallback ============

// 全队存活幸存者平均位置（队伍中心）
bool GetTeamCenter(float center[3]) {
    center[0] = center[1] = center[2] = 0.0;
    int n = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || GetClientTeam(i) != 2 || !IsPlayerAlive(i)) continue;
        float pos[3];
        GetClientAbsOrigin(i, pos);
        center[0] += pos[0]; center[1] += pos[1]; center[2] += pos[2];
        n++;
    }
    if (n == 0) return false;
    center[0] /= n; center[1] /= n; center[2] /= n;
    return true;
}

// 全队存活幸存者平均朝向（水平面单位向量）；幸存者两两对向时平均值抵消 → false
bool GetTeamForward(float fwd[3]) {
    float sx = 0.0, sy = 0.0;
    int n = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || GetClientTeam(i) != 2 || !IsPlayerAlive(i)) continue;
        float ang[3], f[3];
        GetClientEyeAngles(i, ang);
        GetAngleVectors(ang, f, NULL_VECTOR, NULL_VECTOR);
        sx += f[0]; sy += f[1];
        n++;
    }
    if (n == 0) return false;
    float len = SquareRoot(sx * sx + sy * sy);
    if (len < 0.001) return false;
    fwd[0] = sx / len; fwd[1] = sy / len; fwd[2] = 0.0;
    return true;
}

// 前后刷新生成点：第 n 只（0=前方 / 1=后方，交替）相对队伍中心 ± 朝向。
// 距离 TANK_FALLBACK_DIST 逐级 -100 缩短，向下 trace 找地面（防卡墙/悬空）。
// 返回是否找到生成点（找不到时 spawnPos 不变）。
bool SpawnTankFallback(int n, float spawnPos[3]) {
    float center[3];
    if (!GetTeamCenter(center)) return false;

    float fwd[3];
    if (!GetTeamForward(fwd)) {
        // 全队平均朝向失效（对向/异常）→ 退化为参考幸存者朝向
        int survivor = GetAnyAliveSurvivor();
        if (survivor <= 0) return false;
        float ang[3];
        GetClientEyeAngles(survivor, ang);
        GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
        fwd[2] = 0.0;
        float len = SquareRoot(fwd[0] * fwd[0] + fwd[1] * fwd[1]);
        if (len < 0.001) return false;
        fwd[0] /= len; fwd[1] /= len;
    }

    float dir = (n % 2 == 0) ? 1.0 : -1.0;   // 第一只前方、第二只后方
    float tiers[3] = { TANK_FALLBACK_DIST_1, TANK_FALLBACK_DIST_2, TANK_FALLBACK_DIST_3 };

    // v2.7.2: 两段式 fallback 保证必刷 — 第一段 hull+nav 精选，第二段 hull 兜底（室内 nav 稀疏时仍必刷）
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < 3; i++) {
            float dist = tiers[i] * dir;
            float start[3];
            start[0] = center[0] + fwd[0] * dist;
            start[1] = center[1] + fwd[1] * dist;
            start[2] = center[2] + 80.0;   // 抬高向下 trace 找地面

            float end[3];
            end[0] = start[0]; end[1] = start[1]; end[2] = start[2] - 3000.0;
            TR_TraceRayFilter(start, end, MASK_SOLID, RayType_EndPoint, TraceFilter_World);
            if (TR_GetFraction() > 0.0 && TR_GetFraction() < 1.0) {
                // v2.7.6: 用 FindGroundAbove 替代 TR_GetEndPosition，防止多层几何打到错误平面
                float traceHit[3];
                TR_GetEndPosition(traceHit);
                FindGroundAbove(traceHit, spawnPos);
                if (pass == 0) {
                    // 第一段：hull+nav 精选（防悬空/非nav被导演秒删）
                    if (ValidateTankSpawnPoint(spawnPos) && IsNavReachable(spawnPos, center))
                        return true;
                } else {
                    // 第二段：仅 hull 兜底（nav 稀疏室内必刷）
                    if (ValidateTankSpawnPoint(spawnPos))
                        return true;
                }
            }
        }
    }
    return false;
}

// ============ specialspawner native 调用 ============

void SetClearingHold(bool hold) {
    if (GetFeatureStatus(FeatureType_Native, "SS_HoldClearing") != FeatureStatus_Available) {
        LogMessage("[Tank Mutator] WARNING: SS_HoldClearing native not available");
        return;
    }
    SS_HoldClearing(hold);
}

void ReleaseClearingHold() {
    SetClearingHold(false);
}

// ============ 工具函数 ============

// 返回任意一个存活的幸存者 client index，找不到返回 -1
int GetAnyAliveSurvivor() {
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i)) {
            return i;
        }
    }
    return -1;
}

// v2.7.5: 领跑者（flow 最大且存活），沿用 specialspawner 领跑者定义
int GetFrontrunner() {
    int best = -1;
    float bestFlow = -999999.0;
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || GetClientTeam(i) != 2 || !IsPlayerAlive(i)) continue;
        // 倒地者不参与领跑者判定（specialspawner 同口径：IsPlayerAlive 对倒地 true，但领跑需站立）
        if (GetEntProp(i, Prop_Send, "m_isIncapacitated")) continue;
        float flow = L4D2Direct_GetFlowDistance(i);
        if (flow == -9999.0 || flow == 0.0) continue;
        if (flow > bestFlow) {
            bestFlow = flow;
            best = i;
        }
    }
    if (best > 0) return best;
    // 无站立领跑者（全倒/无 flow）回退到任意存活
    return GetAnyAliveSurvivor();
}

// v2.7.5: 队尾（flow 最小且存活），双Tank时后置坦克锚点
int GetTailRunner() {
    int best = -1;
    float bestFlow = 999999.0;
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || GetClientTeam(i) != 2 || !IsPlayerAlive(i)) continue;
        if (GetEntProp(i, Prop_Send, "m_isIncapacitated")) continue;
        float flow = L4D2Direct_GetFlowDistance(i);
        if (flow == -9999.0 || flow == 0.0) continue;
        if (flow < bestFlow) {
            bestFlow = flow;
            best = i;
        }
    }
    if (best > 0) return best;
    return GetAnyAliveSurvivor();
}

bool IsTank(int client) {
    if (client <= 0 || client > MaxClients || !IsClientInGame(client)) {
        return false;
    }
    if (GetClientTeam(client) != 3) {
        return false;
    }
    int class = GetEntProp(client, Prop_Send, "m_zombieClass");
    return class == 8;  // 8 = Tank
}
