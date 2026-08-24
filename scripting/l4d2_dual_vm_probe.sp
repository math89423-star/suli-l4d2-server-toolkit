/**
 * l4d2_dual_vm_probe.sp
 *
 * Phase 1 探测插件 — 严格验证 CCSPlayer::CreateViewModel(1) 可行性
 *
 * 目标:
 *   1. 找到 CCSPlayer::CreateViewModel(int) 的正确 virtual index
 *   2. 验证 CreateViewModel(1) 能成功创建第二个 viewmodel
 *   3. 确认 m_hViewModel[0] 和 m_hViewModel[1] 都有效
 *
 * 禁止:
 *   - 不碰 PrimaryAttack / Reload / Ammo / Damage
 *   - 不接 CustomWeaponName / CWL identity
 *   - 不做声音替换
 *   - 不做 TP model
 *
 * 成功标准:
 *   before: m_hViewModel[0] = XXX, m_hViewModel[1] = -1
 *   after:  m_hViewModel[0] = XXX, m_hViewModel[1] = YYY (valid entity)
 *
 * 参考:
 *   - AlliedModders #340151 L4DViewmodels by foxhound27
 *   - SourceMod SDKTools PrepSDKCall_SetVirtual
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "0.1.0"
#define PLUGIN_TAG "[DualVM-Probe]"

// ── 测试模型 ──────────────────────────────────────────────
// 使用已有的 M7 模型作为 custom viewmodel
// 如果不可用，会 fallback 到 AK47 viewmodel
#define TEST_FP_MODEL    "models/custom_weapons/m7/v_m7.mdl"
#define TEST_FP_MODEL_2  "models/v_models/v_rif_ak47.mdl"

// ── gamedata 键名 ─────────────────────────────────────────
#define GAMEDATA_FILE    "suli_viewmodels"

// ── 状态追踪 ──────────────────────────────────────────────
enum struct PlayerState
{
    bool    bProbing;           // 是否正在进行 index 扫描
    bool    bDualVMActive;      // Dual VM 是否已激活
    int     iVM0;               // m_hViewModel[0] entity ref
    int     iVM1;               // m_hViewModel[1] entity ref
    int     iCustomModelIdx;    // custom model 的 model index
    int     iFoundVirtualIdx;   // 找到的正确 virtual index (-1 = 未找到)
}

PlayerState g_PlayerState[MAXPLAYERS + 1];

// ── SDKCall handles ───────────────────────────────────────
Handle g_hCreateViewModel = INVALID_HANDLE;
int    g_iOffset_ViewModel = -1;     // m_hViewModel SendProp offset
int    g_iFoundVirtualIdx = -1;      // 找到的正确 virtual index

// ── 扫描参数 ──────────────────────────────────────────────
// CCSPlayer::CreateViewModel virtual index
// 通过 server_srv.so 二进制分析确认: index = 345
// vtable: 0x00c5e600 + 8 (RTTI) + 345*4 = 0x00c5eb6c = 0x00642b30 (CreateViewModel)
#define CREATE_VM_VINDEX  345

// 如果需要扫描，搜索范围
#define SCAN_START      340
#define SCAN_END        350
int    g_iScanCurrent = SCAN_START;
bool   g_bScanning = false;
int    g_iScanClient = -1;

// ── 插件信息 ──────────────────────────────────────────────
public Plugin myinfo =
{
    name        = "[L4D2] Suli Dual VM Probe",
    author      = "Suli Agent",
    description = "Phase 1: 验证 CCSPlayer::CreateViewModel(1) 可行性",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ══════════════════════════════════════════════════════════
//  OnPluginStart
// ══════════════════════════════════════════════════════════
public void OnPluginStart()
{
    PrintToServer("%s 加载中... (v%s)", PLUGIN_TAG, PLUGIN_VERSION);

    // ── 获取 m_hViewModel offset ──
    g_iOffset_ViewModel = FindSendPropInfo("CBasePlayer", "m_hViewModel");
    if (g_iOffset_ViewModel == -1)
    {
        SetFailState("%s 无法获取 m_hViewModel offset!", PLUGIN_TAG);
        return;
    }
    PrintToServer("%s m_hViewModel offset = %d", PLUGIN_TAG, g_iOffset_ViewModel);

    // ── 预缓存测试模型 ──
    PrecacheModel(TEST_FP_MODEL, true);
    PrecacheModel(TEST_FP_MODEL_2, true);

    // ── 注册命令 (使用 RegConsoleCmd 确保所有玩家可用) ──
    RegConsoleCmd("sm_probe_start",  CmdProbeStart,  "开始扫描 CreateViewModel virtual index");
    RegConsoleCmd("sm_probe_stop",   CmdProbeStop,   "停止扫描");
    RegConsoleCmd("sm_probe_status", CmdProbeStatus,  "查看扫描状态");
    RegConsoleCmd("sm_probe_test",   CmdProbeTest,    "手动测试指定 virtual index");
    RegConsoleCmd("sm_probe_dual",   CmdProbeDual,    "激活 Dual VM (使用已知 index)");
    PrintToServer("%s [OK] Plugin loaded! Commands: sm_probe_start, sm_probe_stop, sm_probe_status, sm_probe_test, sm_probe_dual", PLUGIN_TAG);
}

// ══════════════════════════════════════════════════════════
//  命令: 开始扫描
// ══════════════════════════════════════════════════════════
public Action CmdProbeStart(int client, int args)
{
    // Support: sm_probe_start [player_index]
    // If no argument, find first alive survivor
    int target = client;

    if (args > 0)
    {
        char arg[8];
        GetCmdArg(1, arg, sizeof(arg));
        target = StringToInt(arg);
    }

    // If called from console (client=0), find first alive survivor
    if (target <= 0)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == 2)
            {
                target = i;
                break;
            }
        }
    }

    PrintToServer("%s CmdProbeStart: target=%d", PLUGIN_TAG, target);

    if (target <= 0 || !IsClientInGame(target))
    {
        PrintToServer("%s FAIL: target %d not valid", PLUGIN_TAG, target);
        return Plugin_Handled;
    }

    if (!IsPlayerAlive(target))
    {
        PrintToServer("%s FAIL: target %d not alive", PLUGIN_TAG, target);
        return Plugin_Handled;
    }

    if (GetClientTeam(target) != 2)
    {
        PrintToServer("%s FAIL: target %d not survivor (team=%d)", PLUGIN_TAG, target, GetClientTeam(target));
        return Plugin_Handled;
    }

    PrintToServer("");
    PrintToServer("%s ============================================", PLUGIN_TAG);
    PrintToServer("%s Testing CreateViewModel with index %d", PLUGIN_TAG, CREATE_VM_VINDEX);
    PrintToServer("%s Player: %d (%N)", PLUGIN_TAG, target, target);
    PrintToServer("%s m_hViewModel offset: %d", PLUGIN_TAG, g_iOffset_ViewModel);
    PrintToServer("%s ============================================", PLUGIN_TAG);
    PrintToServer("");

    // Test the known index directly
    PrintToServer("%s Testing index %d ...", PLUGIN_TAG, CREATE_VM_VINDEX);
    TryCreateViewModel(target, CREATE_VM_VINDEX);

    // Test changing VM1 model
    PrintToServer("");
    PrintToServer("%s Testing VM1 model change...", PLUGIN_TAG);
    int vm1 = GetEntPropEnt(target, Prop_Send, "m_hViewModel", 1);
    if (vm1 > 0 && IsValidEntity(vm1))
    {
        char className[64];
        GetEntityClassname(vm1, className, sizeof(className));
        int currentModel = GetEntProp(vm1, Prop_Send, "m_nModelIndex");

        PrintToServer("%s   VM1 entity: %d, class: %s", PLUGIN_TAG, vm1, className);
        PrintToServer("%s   VM1 current model index: %d", PLUGIN_TAG, currentModel);

        // Use SetEntityModel to properly change the model
        char modelPath[] = "models/custom_weapons/m7/v_m7.mdl";
        PrecacheModel(modelPath, true);
        SetEntityModel(vm1, modelPath);
        int newModel = GetEntProp(vm1, Prop_Send, "m_nModelIndex");
        PrintToServer("%s   VM1 new model index: %d", PLUGIN_TAG, newModel);

        // Also test with fake predicted_viewmodel
        PrintToServer("");
        PrintToServer("%s Creating fake predicted_viewmodel...", PLUGIN_TAG);
        int fakeVM = CreateEntityByName("predicted_viewmodel");
        if (fakeVM > 0 && IsValidEntity(fakeVM))
        {
            DispatchSpawn(fakeVM);
            SetEntityModel(fakeVM, modelPath);
            int fakeIdx = GetEntProp(fakeVM, Prop_Send, "m_nModelIndex");
            PrintToServer("%s   Fake VM entity: %d, model index: %d", PLUGIN_TAG, fakeVM, fakeIdx);

            // Try to copy model index to real VM1
            SetEntProp(vm1, Prop_Send, "m_nModelIndex", fakeIdx);
            int verifyIdx = GetEntProp(vm1, Prop_Send, "m_nModelIndex");
            PrintToServer("%s   VM1 after copy: model index = %d", PLUGIN_TAG, verifyIdx);
        }
    }

    return Plugin_Handled;
}

// ══════════════════════════════════════════════════════════
//  命令: 停止扫描
// ══════════════════════════════════════════════════════════
public Action CmdProbeStop(int client, int args)
{
    g_bScanning = false;
    g_iScanClient = -1;
    ReplyToCommand(client, "%s 扫描已停止", PLUGIN_TAG);
    return Plugin_Handled;
}

// ══════════════════════════════════════════════════════════
//  命令: 查看状态
// ══════════════════════════════════════════════════════════
public Action CmdProbeStatus(int client, int args)
{
    ReplyToCommand(client, "%s === 状态报告 ===", PLUGIN_TAG);
    ReplyToCommand(client, "%s 扫描中: %s", PLUGIN_TAG, g_bScanning ? "是" : "否");
    ReplyToCommand(client, "%s 当前扫描 index: %d", PLUGIN_TAG, g_iScanCurrent);
    ReplyToCommand(client, "%s 已找到 virtual index: %d", PLUGIN_TAG, g_iFoundVirtualIdx);
    ReplyToCommand(client, "%s m_hViewModel offset: %d", PLUGIN_TAG, g_iOffset_ViewModel);

    if (g_iScanClient > 0 && IsClientInGame(g_iScanClient))
    {
        ReplyToCommand(client, "%s 扫描目标: %d (%N)", PLUGIN_TAG, g_iScanClient, g_iScanClient);
        PrintViewModelStatus(g_iScanClient);
    }

    // 打印所有存活玩家的 viewmodel 状态
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == 2)
        {
            ReplyToCommand(client, "%s --- 玩家 %d (%N) ---", PLUGIN_TAG, i, i);
            PrintViewModelStatusToClient(client, i);
        }
    }

    return Plugin_Handled;
}

// ══════════════════════════════════════════════════════════
//  命令: 手动测试指定 virtual index
// ══════════════════════════════════════════════════════════
public Action CmdProbeTest(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "%s 用法: sm_probe_test <virtual_index>", PLUGIN_TAG);
        return Plugin_Handled;
    }

    int idx = GetCmdArgInt(1);
    if (idx < 0 || idx > 500)
    {
        ReplyToCommand(client, "%s virtual index 必须在 0-500 范围内", PLUGIN_TAG);
        return Plugin_Handled;
    }

    if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        ReplyToCommand(client, "%s 必须由活着的玩家执行!", PLUGIN_TAG);
        return Plugin_Handled;
    }

    ReplyToCommand(client, "%s 测试 virtual index %d ...", PLUGIN_TAG, idx);
    TryCreateViewModel(client, idx);

    return Plugin_Handled;
}

// ══════════════════════════════════════════════════════════
//  命令: 激活 Dual VM (使用已知 index)
// ══════════════════════════════════════════════════════════
public Action CmdProbeDual(int client, int args)
{
    if (g_iFoundVirtualIdx == -1)
    {
        ReplyToCommand(client, "%s 尚未找到正确的 virtual index! 请先运行 sm_probe_start", PLUGIN_TAG);
        return Plugin_Handled;
    }

    if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        ReplyToCommand(client, "%s 必须由活着的玩家执行!", PLUGIN_TAG);
        return Plugin_Handled;
    }

    ReplyToCommand(client, "%s 激活 Dual VM (virtual index = %d) ...", PLUGIN_TAG, g_iFoundVirtualIdx);
    ActivateDualVM(client);

    return Plugin_Handled;
}

// ══════════════════════════════════════════════════════════
//  核心: 尝试调用 CreateViewModel
// ══════════════════════════════════════════════════════════
void TryCreateViewModel(int client, int virtualIdx)
{
    // ── 检查当前 m_hViewModel[1] 状态 ──
    int vm1_before = GetEntPropEnt(client, Prop_Send, "m_hViewModel", 1);
    int vm0_before = GetEntPropEnt(client, Prop_Send, "m_hViewModel", 0);

    PrintToServer("%s 测试 virtual index %d ...", PLUGIN_TAG, virtualIdx);
    PrintToServer("%s   VM0 before: %d", PLUGIN_TAG, vm0_before);
    PrintToServer("%s   VM1 before: %d", PLUGIN_TAG, vm1_before);

    // ── 构建 SDKCall ──
    Handle hSDKCall = PrepSDKCall_CreateViewModel(virtualIdx);
    if (hSDKCall == INVALID_HANDLE)
    {
        PrintToServer("%s   [FAIL] PrepSDKCall failed (virtual index %d)", PLUGIN_TAG, virtualIdx);
        return;
    }

    // ── 执行 SDKCall ──
    // SDKCall_Player: 第一个参数是 client index (1-based)
    // CreateViewModel(int index) - index=1 创建第二个 viewmodel
    SDKCall(hSDKCall, client, 1);
    CloseHandle(hSDKCall);

    // ── 检查结果 ──
    int vm1_after = GetEntPropEnt(client, Prop_Send, "m_hViewModel", 1);
    PrintToServer("%s   VM1 after: %d", PLUGIN_TAG, vm1_after);

    if (vm1_before == -1 && vm1_after != -1 && IsValidEntity(vm1_after))
    {
        // ✅ 成功!
        int modelIdx = GetEntProp(vm1_after, Prop_Send, "m_nModelIndex");

        PrintToServer("");
        PrintToServer("%s ============================================", PLUGIN_TAG);
        PrintToServer("%s *** SUCCESS! virtual index %d = CreateViewModel! ***", PLUGIN_TAG, virtualIdx);
        PrintToServer("%s ============================================", PLUGIN_TAG);
        PrintToServer("%s   VM0: %d", PLUGIN_TAG, vm0_before);
        PrintToServer("%s   VM1: %d (modelIdx=%d)", PLUGIN_TAG, vm1_after, modelIdx);
        PrintToServer("%s ============================================", PLUGIN_TAG);
        PrintToServer("");
        PrintToServer("%s >>> UPDATE gamedata: \"linux\" \"%d\"", PLUGIN_TAG, virtualIdx);

        g_iFoundVirtualIdx = virtualIdx;
        g_bScanning = false;
    }
    else if (vm1_after != -1 && vm1_after != vm1_before)
    {
        PrintToServer("%s [%d] VM1 changed: %d -> %d", PLUGIN_TAG, virtualIdx, vm1_before, vm1_after);
    }
}

// ══════════════════════════════════════════════════════════
//  构建 CreateViewModel SDKCall
// ══════════════════════════════════════════════════════════
Handle PrepSDKCall_CreateViewModel(int virtualIdx)
{
    StartPrepSDKCall(SDKCall_Player);
    PrepSDKCall_SetVirtual(virtualIdx);
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);  // int index

    Handle hCall = EndPrepSDKCall();
    if (hCall == INVALID_HANDLE)
    {
        PrintToServer("%s   EndPrepSDKCall FAILED (virtual index %d may be wrong)", PLUGIN_TAG, virtualIdx);
    }
    return hCall;
}

// ══════════════════════════════════════════════════════════
//  自动扫描循环
// ══════════════════════════════════════════════════════════
void ScanNextIndex()
{
    if (!g_bScanning)
        return;

    if (g_iScanCurrent > SCAN_END)
    {
        PrintToServer("");
        PrintToServer("%s ══════════════════════════════════════════════════", PLUGIN_TAG);
        PrintToServer("%s 扫描完成! 已搜索 %d - %d", PLUGIN_TAG, SCAN_START, SCAN_END);
        if (g_iFoundVirtualIdx != -1)
        {
            PrintToServer("%s [OK] Found CreateViewModel virtual index = %d", PLUGIN_TAG, g_iFoundVirtualIdx);
        }
        else
        {
            PrintToServer("%s [FAIL] CreateViewModel virtual index NOT found", PLUGIN_TAG);
            PrintToServer("%s Try扩大搜索范围 (modify SCAN_START/SCAN_END)", PLUGIN_TAG);
        }
        PrintToServer("%s ══════════════════════════════════════════════════", PLUGIN_TAG);
        PrintToServer("");
        g_bScanning = false;
        return;
    }

    if (g_iScanClient <= 0 || !IsClientInGame(g_iScanClient) || !IsPlayerAlive(g_iScanClient))
    {
        PrintToServer("%s [FAIL] Scan target invalid, stopping", PLUGIN_TAG);
        g_bScanning = false;
        return;
    }

    // 每 10 个 index 打印一次进度
    if (g_iScanCurrent % 10 == 0)
    {
        PrintToServer("%s 扫描进度: %d / %d (当前测试 index: %d)", PLUGIN_TAG,
            g_iScanCurrent - SCAN_START, SCAN_END - SCAN_START, g_iScanCurrent);
    }

    // 测试当前 index
    TryCreateViewModel(g_iScanClient, g_iScanCurrent);
    g_iScanCurrent++;

    // 间隔 0.3 秒，给引擎时间处理
    CreateTimer(0.3, Timer_ScanNext, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ScanNext(Handle timer)
{
    ScanNextIndex();
    return Plugin_Stop;
}

// ══════════════════════════════════════════════════════════
//  打印当前 viewmodel 状态 (安全版本)
// ══════════════════════════════════════════════════════════
void PrintViewModelStatus(int client)
{
    if (client <= 0 || !IsClientInGame(client))
        return;

    int vm0 = GetEntPropEnt(client, Prop_Send, "m_hViewModel", 0);
    int vm1 = GetEntPropEnt(client, Prop_Send, "m_hViewModel", 1);

    PrintToServer("%s --- VM Status: %N ---", PLUGIN_TAG, client);
    PrintToServer("%s   VM[0]: entity=%d", PLUGIN_TAG, vm0);
    PrintToServer("%s   VM[1]: entity=%d", PLUGIN_TAG, vm1);

    if (vm0 > 0 && IsValidEntity(vm0))
    {
        int modelIdx0 = GetEntProp(vm0, Prop_Send, "m_nModelIndex");
        PrintToServer("%s   VM[0] modelIdx=%d, seq=%d", PLUGIN_TAG, modelIdx0, GetEntProp(vm0, Prop_Send, "m_nSequence"));
    }

    if (vm1 > 0 && IsValidEntity(vm1))
    {
        int modelIdx1 = GetEntProp(vm1, Prop_Send, "m_nModelIndex");
        PrintToServer("%s   VM[1] modelIdx=%d, seq=%d", PLUGIN_TAG, modelIdx1, GetEntProp(vm1, Prop_Send, "m_nSequence"));
    }
}

void PrintViewModelStatusToClient(int target, int client)
{
    if (target <= 0 || !IsClientInGame(target))
        return;
    if (client <= 0 || !IsClientInGame(client))
        return;

    int vm0 = GetEntPropEnt(client, Prop_Send, "m_hViewModel", 0);
    int vm1 = GetEntPropEnt(client, Prop_Send, "m_hViewModel", 1);

    ReplyToCommand(target, "%s   VM[0]: %d, VM[1]: %d", PLUGIN_TAG, vm0, vm1);
}

// ══════════════════════════════════════════════════════════
//  激活 Dual VM
// ══════════════════════════════════════════════════════════
void ActivateDualVM(int client)
{
    if (g_iFoundVirtualIdx == -1)
    {
        PrintToServer("%s 无法激活 Dual VM: virtual index 未确定", PLUGIN_TAG);
        return;
    }

    // ── 创建 VM1 ──
    Handle hSDKCall = PrepSDKCall_CreateViewModel(g_iFoundVirtualIdx);
    if (hSDKCall == INVALID_HANDLE)
    {
        PrintToServer("%s SDKCall 构建失败", PLUGIN_TAG);
        return;
    }

    bool success = false;
    SDKCall(hSDKCall, client, 1, success);
    CloseHandle(hSDKCall);

    // ── 验证 ──
    int vm0 = GetEntPropEnt(client, Prop_Send, "m_hViewModel", 0);
    int vm1 = GetEntPropEnt(client, Prop_Send, "m_hViewModel", 1);

    if (vm1 <= 0 || !IsValidEntity(vm1))
    {
        PrintToServer("%s [FAIL] VM1 creation failed!", PLUGIN_TAG);
        return;
    }

    PrintToServer("%s [OK] VM1 created!", PLUGIN_TAG);
    PrintToServer("%s   VM0: entity=%d", PLUGIN_TAG, vm0);
    PrintToServer("%s   VM1: entity=%d", PLUGIN_TAG, vm1);

    // ── 设置 custom model 到 VM1 ──
    int customModelIdx = PrecacheModel(TEST_FP_MODEL);
    SetEntProp(vm1, Prop_Send, "m_nModelIndex", customModelIdx);
    SetEntityModel(vm1, TEST_FP_MODEL);

    PrintToServer("%s   VM1 model index 设置为: %d", PLUGIN_TAG, customModelIdx);

    // ── 隐藏 VM0 ──
    if (vm0 > 0 && IsValidEntity(vm0))
    {
        int effects = GetEntProp(vm0, Prop_Send, "m_fEffects");
        SetEntProp(vm0, Prop_Send, "m_fEffects", effects | 1);  // EF_NODRAW
        PrintToServer("%s   VM0 已隐藏 (EF_NODRAW)", PLUGIN_TAG);
    }

    // ── 保存状态 ──
    g_PlayerState[client].bDualVMActive = true;
    g_PlayerState[client].iVM0 = EntIndexToEntRef(vm0);
    g_PlayerState[client].iVM1 = EntIndexToEntRef(vm1);
    g_PlayerState[client].iCustomModelIdx = customModelIdx;

    PrintToServer("%s Dual VM 已激活! 测试: idle/fire/reload/switch", PLUGIN_TAG);
}

// ══════════════════════════════════════════════════════════
//  Think: 动画同步 (Phase 2)
// ══════════════════════════════════════════════════════════
public void OnGameFrame()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!g_PlayerState[i].bDualVMActive || !IsClientInGame(i) || !IsPlayerAlive(i))
            continue;

        int vm0 = EntRefToEntIndex(g_PlayerState[i].iVM0);
        int vm1 = EntRefToEntIndex(g_PlayerState[i].iVM1);

        if (vm0 <= 0 || !IsValidEntity(vm0) || vm1 <= 0 || !IsValidEntity(vm1))
        {
            CleanupDualVM(i);
            continue;
        }

        // ── 同步 VM0 → VM1 的动画状态 ──
        int seq = GetEntProp(vm0, Prop_Send, "m_nSequence");
        float rate = GetEntPropFloat(vm0, Prop_Send, "m_flPlaybackRate");

        SetEntProp(vm1, Prop_Send, "m_nSequence", seq);
        SetEntPropFloat(vm1, Prop_Send, "m_flPlaybackRate", rate);

        // ── 确保 VM0 保持隐藏 ──
        int fx = GetEntProp(vm0, Prop_Send, "m_fEffects");
        if (!(fx & 1))
            SetEntProp(vm0, Prop_Send, "m_fEffects", fx | 1);

        // ── 确保 VM1 model index 正确 ──
        int curIdx = GetEntProp(vm1, Prop_Send, "m_nModelIndex");
        if (curIdx != g_PlayerState[i].iCustomModelIdx)
            SetEntProp(vm1, Prop_Send, "m_nModelIndex", g_PlayerState[i].iCustomModelIdx);
    }
}

void CleanupDualVM(int client)
{
    // 恢复 VM0 可见性
    int vm0 = EntRefToEntIndex(g_PlayerState[client].iVM0);
    if (vm0 > 0 && IsValidEntity(vm0))
    {
        int fx = GetEntProp(vm0, Prop_Send, "m_fEffects");
        SetEntProp(vm0, Prop_Send, "m_fEffects", fx & ~1);  // 移除 EF_NODRAW
    }

    g_PlayerState[client].bDualVMActive = false;
    g_PlayerState[client].iVM0 = -1;
    g_PlayerState[client].iVM1 = -1;
    g_PlayerState[client].iCustomModelIdx = -1;
}

// ══════════════════════════════════════════════════════════
//  清理
// ══════════════════════════════════════════════════════════
public void OnClientDisconnect(int client)
{
    CleanupDualVM(client);
}

public void OnMapEnd()
{
    g_bScanning = false;
    g_iScanClient = -1;
    for (int i = 1; i <= MaxClients; i++)
        CleanupDualVM(i);
}

public void OnPlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && client <= MaxClients)
        CleanupDualVM(client);
}
