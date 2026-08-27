// ============================================================================
// bt_core.inc — Lightweight Behavior Tree Framework for SourcePawn
// ============================================================================
// Node-ID architecture: each node is an int index into global arrays.
// Trees are built once and shared across all clients. Per-client runtime
// state (running child index, cooldown timers, etc.) lives in the
// blackboard (StringMap per client).
//
// Usage:
//   int root = BT_Create(BTN_SELECTOR);
//   int seq  = BT_Create(BTN_SEQUENCE);  BT_AddChild(root, seq);
//   int cond = BT_CreateCondition(MyConditionFunc); BT_AddChild(seq, cond);
//   int act  = BT_CreateAction(MyActionFunc);       BT_AddChild(seq, act);
//   BT_Bind(client, root);
//   BT_Tick(client);  // call in OnPlayerRunCmd
// ============================================================================

#if defined _bt_core_included
  #endinput
#endif
#define _bt_core_included

#include <sourcemod>

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

#define BT_MAX_NODES   1024   // max total nodes across all trees (v3.7: 512→768; v5.18: 768→1024)
#define BT_MAX_CLIENTS MAXPLAYERS + 1

enum BT_Status {
    BT_SUCCESS = 0,
    BT_FAILURE = 1,
    BT_RUNNING = 2
};

enum BT_NodeType {
    BTN_INVALID = 0,
    BTN_SELECTOR,          // OR: tick children L→R, first non-FAILURE
    BTN_SEQUENCE,          // AND: tick children L→R, first non-SUCCESS
    BTN_PARALLEL,          // tick all children, succeed if >=N succeed
    BTN_INVERTER,          // invert child's result
    BTN_COOLDOWN,          // rate-limit child execution
    BTN_FORCE_SUCCESS,     // always return SUCCESS
    BTN_FORCE_FAILURE,     // always return FAILURE
    BTN_REPEAT_UNTIL_FAIL, // loop child until it fails
    BTN_CONDITION,         // leaf: condition check
    BTN_ACTION,            // leaf: execute action
    BTN_WAIT               // leaf: wait for duration
};

// Leaf callback signature: BT_Status MyFunc(int client)
// Return BT_SUCCESS, BT_FAILURE, or (for actions) BT_RUNNING.
typedef BT_TickFunc = function BT_Status (int client);

// ---------------------------------------------------------------------------
// Node storage (shared across all clients — tree structure is immutable)
// ---------------------------------------------------------------------------

BT_NodeType g_eBTNodeType[BT_MAX_NODES];
ArrayList   g_hBTChildren[BT_MAX_NODES];  // ArrayList<int> of child node IDs
float       g_fBTParam[BT_MAX_NODES];     // cooldown seconds, wait seconds, parallel thresholds
float       g_fBTParam2[BT_MAX_NODES];    // second param (parallel: maxFailures)
Function    g_hBTFunc[BT_MAX_NODES];      // callback for CONDITION / ACTION leaves
int         g_iBTNodeCount = 0;

// ---------------------------------------------------------------------------
// Per-client state
// ---------------------------------------------------------------------------

int     g_iBTRoot[BT_MAX_CLIENTS];              // root node ID for each client
StringMap g_hBTBlackboard[BT_MAX_CLIENTS];      // per-client key-value store

// Running child index for composite nodes (per-client per-node)
int     g_iBTRunningChild[BT_MAX_CLIENTS][BT_MAX_NODES];
// v5.6: 最后命中子序号（SUCCESS/RUNNING 都记录）—— 原版 SUCCESS 分支把
// runningChild 清 -1 → ai_debug 采样看不到 1-tick 的 SUCCESS 分支
// （呕吐/拉人/吐酸等攻击命中全被读成 -1，"几乎从不攻击"是观测盲区）
int     g_iBTLastWinningChild[BT_MAX_CLIENTS][BT_MAX_NODES];

// ---------------------------------------------------------------------------
// Tick context — allows leaf callbacks to access their node's params
// ---------------------------------------------------------------------------

int     g_iBTCurrentTickNode = -1;               // nodeId currently being ticked
float   g_fBTNodeUserParam1[BT_MAX_NODES];       // arbitrary user param for leaf nodes
float   g_fBTNodeUserParam2[BT_MAX_NODES];       // second user param

stock void BT_SetUserParam1(int nodeId, float value) { g_fBTNodeUserParam1[nodeId] = value; }
stock void BT_SetUserParam2(int nodeId, float value) { g_fBTNodeUserParam2[nodeId] = value; }

// ---------------------------------------------------------------------------
// Movement output (written by BT actions, applied by OnPlayerRunCmd)
// ---------------------------------------------------------------------------

// v5.22: BT Control Mask —— 每帧控制权声明（云端审查任务书 §2.2）。
// 行为节点声明"当前行为接管哪些输入类别"，只有被接管的类别才在
// Apply 阶段清除 Valve 原版 AI 的原始按键意图；未接管的类别保留
// Valve/NextBot 原生输入（攀爬/梯子/跳跃/引擎技能等不破坏）。
// BT_AddButton/BT_RemoveButton/BT_SetAimAngles 会自动声明对应的类别；
// Hold/Ambush 类"接管移动以保持静止"的节点显式调 BT_TakeControl。
enum BT_ControlFlags {
    BTCTRL_NONE    = 0,
    BTCTRL_MOVE    = (1 << 0),   // 移动键：FORWARD/BACK/MOVELEFT/MOVERIGHT
    BTCTRL_VIEW    = (1 << 1),   // 视角覆盖
    BTCTRL_ATTACK  = (1 << 2),   // IN_ATTACK / IN_ATTACK2
    BTCTRL_DUCK    = (1 << 3),   // IN_DUCK
    BTCTRL_JUMP    = (1 << 4),   // IN_JUMP
    BTCTRL_USE     = (1 << 5),   // IN_USE | IN_SPEED (P0-2 生还者)
    BTCTRL_FULL    = BTCTRL_MOVE | BTCTRL_VIEW | BTCTRL_ATTACK | BTCTRL_DUCK | BTCTRL_JUMP | BTCTRL_USE
};

int     g_iBT_ButtonsAdd[MAXPLAYERS + 1];       // buttons to ADD
int     g_iBT_ButtonsRemove[MAXPLAYERS + 1];    // buttons to REMOVE
bool    g_bBT_AnglesSet[MAXPLAYERS + 1];
float   g_fBT_Angles[MAXPLAYERS + 1][3];
bool    g_bBT_Teleport[MAXPLAYERS + 1];
int     g_iBTControlMask[MAXPLAYERS + 1];       // v5.22: 当前帧 BT 接管的输入类别

// --- Control mask API (v5.22) ---
stock void BT_TakeControl(int client, int flags) {
    g_iBTControlMask[client] |= flags;
}

stock void BT_ReleaseControl(int client, int flags) {
    g_iBTControlMask[client] &= ~flags;
}

stock bool BT_HasControl(int client, int flag) {
    return (g_iBTControlMask[client] & flag) != 0;
}

// --- 细粒度清除（替换无差别 BT_ResetMovement 的滥用场景）---
// 只接管/清空"移动"类别：Hold/埋伏类节点用这个停住，同时保留
// 同一 Sequence 前面节点刚添加的 IN_DUCK/IN_JUMP 等非移动输入。
stock void BT_ClearMoveDirection(int client) {
    BT_RemoveButton(client, IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT);
    BT_TakeControl(client, BTCTRL_MOVE);
}

stock void BT_ClearAttack(int client) {
    BT_RemoveButton(client, IN_ATTACK | IN_ATTACK2);
    BT_TakeControl(client, BTCTRL_ATTACK);
}

stock void BT_ClearDuck(int client) {
    BT_RemoveButton(client, IN_DUCK);
    BT_TakeControl(client, BTCTRL_DUCK);
}

// ---------------------------------------------------------------------------
// Node Creation
// ---------------------------------------------------------------------------

stock int BT_Create(BT_NodeType type) {
    if (g_iBTNodeCount >= BT_MAX_NODES) {
        ThrowError("BT: exceeded BT_MAX_NODES (%d)", BT_MAX_NODES);
        return -1;
    }
    int id = g_iBTNodeCount++;
    g_eBTNodeType[id] = type;
    g_hBTChildren[id] = null;
    g_fBTParam[id] = 0.0;
    g_fBTParam2[id] = 0.0;
    g_hBTFunc[id] = INVALID_FUNCTION;
    return id;
}

stock void BT_AddChild(int parentId, int childId) {
    if (parentId < 0 || parentId >= g_iBTNodeCount) {
        ThrowError("BT: invalid parent node %d", parentId);
        return;
    }
    if (childId < 0 || childId >= g_iBTNodeCount) {
        ThrowError("BT: invalid child node %d", childId);
        return;
    }
    if (g_hBTChildren[parentId] == null) {
        g_hBTChildren[parentId] = new ArrayList(1);
    }
    g_hBTChildren[parentId].Push(childId);
}

// Convenience: create node and set its Function in one call
stock int BT_CreateLeaf(BT_NodeType type, BT_TickFunc func) {
    int id = BT_Create(type);
    g_hBTFunc[id] = func;
    return id;
}

stock int BT_CreateCondition(BT_TickFunc func) {
    return BT_CreateLeaf(BTN_CONDITION, func);
}

stock int BT_CreateAction(BT_TickFunc func) {
    return BT_CreateLeaf(BTN_ACTION, func);
}

stock int BT_CreateSelector(int numChildren, int child1, int child2 = -1,
    int child3 = -1, int child4 = -1, int child5 = -1, int child6 = -1,
    int child7 = -1, int child8 = -1) {
    int id = BT_Create(BTN_SELECTOR);
    BT_AddChild(id, child1);
    if (child2 >= 0) BT_AddChild(id, child2);
    if (child3 >= 0) BT_AddChild(id, child3);
    if (child4 >= 0) BT_AddChild(id, child4);
    if (child5 >= 0) BT_AddChild(id, child5);
    if (child6 >= 0) BT_AddChild(id, child6);
    if (child7 >= 0) BT_AddChild(id, child7);
    if (child8 >= 0) BT_AddChild(id, child8);
    return id;
}

stock int BT_CreateSequence(int numChildren, int child1, int child2 = -1,
    int child3 = -1, int child4 = -1, int child5 = -1, int child6 = -1,
    int child7 = -1, int child8 = -1) {
    int id = BT_Create(BTN_SEQUENCE);
    BT_AddChild(id, child1);
    if (child2 >= 0) BT_AddChild(id, child2);
    if (child3 >= 0) BT_AddChild(id, child3);
    if (child4 >= 0) BT_AddChild(id, child4);
    if (child5 >= 0) BT_AddChild(id, child5);
    if (child6 >= 0) BT_AddChild(id, child6);
    if (child7 >= 0) BT_AddChild(id, child7);
    if (child8 >= 0) BT_AddChild(id, child8);
    return id;
}

stock int BT_CreateInverter(int childId) {
    int id = BT_Create(BTN_INVERTER);
    BT_AddChild(id, childId);
    return id;
}

stock int BT_CreateCooldown(float seconds, int childId) {
    int id = BT_Create(BTN_COOLDOWN);
    g_fBTParam[id] = seconds;
    BT_AddChild(id, childId);
    return id;
}

stock int BT_CreateForceSuccess(int childId) {
    int id = BT_Create(BTN_FORCE_SUCCESS);
    BT_AddChild(id, childId);
    return id;
}

stock int BT_CreateForceFailure(int childId) {
    int id = BT_Create(BTN_FORCE_FAILURE);
    BT_AddChild(id, childId);
    return id;
}

stock int BT_CreateRepeatUntilFail(int childId) {
    int id = BT_Create(BTN_REPEAT_UNTIL_FAIL);
    BT_AddChild(id, childId);
    return id;
}

stock int BT_CreateWait(float seconds) {
    int id = BT_Create(BTN_WAIT);
    g_fBTParam[id] = seconds;
    return id;
}

stock int BT_CreateParallel(int minSuccess, int maxFailure,
    int child1, int child2 = -1, int child3 = -1, int child4 = -1) {
    int id = BT_Create(BTN_PARALLEL);
    g_fBTParam[id] = float(minSuccess);
    g_fBTParam2[id] = float(maxFailure);
    BT_AddChild(id, child1);
    if (child2 >= 0) BT_AddChild(id, child2);
    if (child3 >= 0) BT_AddChild(id, child3);
    if (child4 >= 0) BT_AddChild(id, child4);
    return id;
}

// ---------------------------------------------------------------------------
// Blackboard
// ---------------------------------------------------------------------------

stock void BB_Init(int client) {
    if (g_hBTBlackboard[client] != null) {
        delete g_hBTBlackboard[client];
    }
    g_hBTBlackboard[client] = new StringMap();
}

stock void BB_Reset(int client) {
    if (g_hBTBlackboard[client] != null) {
        delete g_hBTBlackboard[client];
    }
    g_hBTBlackboard[client] = new StringMap();
}

stock void BB_Cleanup(int client) {
    if (g_hBTBlackboard[client] != null) {
        delete g_hBTBlackboard[client];
        g_hBTBlackboard[client] = null;
    }
}

stock bool BB_Exists(int client) {
    return g_hBTBlackboard[client] != null;
}

stock void BB_SetInt(int client, const char[] key, int value) {
    if (g_hBTBlackboard[client] == null) return;
    g_hBTBlackboard[client].SetValue(key, value, true);
}

stock int BB_GetInt(int client, const char[] key, int defaultVal = 0) {
    if (g_hBTBlackboard[client] == null) return defaultVal;
    int val;
    if (g_hBTBlackboard[client].GetValue(key, val)) {
        return val;
    }
    return defaultVal;
}

stock void BB_SetFloat(int client, const char[] key, float value) {
    if (g_hBTBlackboard[client] == null) return;
    g_hBTBlackboard[client].SetValue(key, view_as<int>(value), true);
}

stock float BB_GetFloat(int client, const char[] key, float defaultVal = 0.0) {
    if (g_hBTBlackboard[client] == null) return defaultVal;
    int val;
    if (g_hBTBlackboard[client].GetValue(key, val)) {
        return view_as<float>(val);
    }
    return defaultVal;
}

stock void BB_SetBool(int client, const char[] key, bool value) {
    BB_SetInt(client, key, value ? 1 : 0);
}

stock bool BB_GetBool(int client, const char[] key, bool defaultVal = false) {
    return BB_GetInt(client, key, defaultVal ? 1 : 0) != 0;
}

// ---------------------------------------------------------------------------
// Scheduler: bind / tick / unbind
// ---------------------------------------------------------------------------

stock void BT_Bind(int client, int rootId) {
    BT_Unbind(client);  // cleanup previous binding
    g_iBTRoot[client] = rootId;
    BB_Init(client);
}

stock void BT_Unbind(int client) {
    g_iBTRoot[client] = -1;
    // Clear per-node running state
    for (int i = 0; i < g_iBTNodeCount; i++) {
        g_iBTRunningChild[client][i] = -1;
    }
    BB_Cleanup(client);
}

stock bool BT_IsBound(int client) {
    return g_iBTRoot[client] >= 0 && BB_Exists(client);
}

// Reset a node's running state (called when an abandoned subtree needs cleanup)
stock void BT_ResetNodeState(int client, int nodeId) {
    g_iBTRunningChild[client][nodeId] = -1;
    // Recursively reset children
    if (g_hBTChildren[nodeId] != null) {
        int len = g_hBTChildren[nodeId].Length;
        for (int i = 0; i < len; i++) {
            BT_ResetNodeState(client, g_hBTChildren[nodeId].Get(i));
        }
    }
}

// v5.22: 真 Abort —— Selector/Sequence 放弃旧 RUNNING 子树时调用。
// 除递归清 running child 外，清除 action-local 的停滞状态：
//   - WAIT 节点的时间戳（_bt_wait_<id>）—— 否则"Wait 3s 跑 1s 被抢占，
//     5s 后重入立即 SUCCESS"（云端审查任务书 §3.4）
//   - Cooldown 不清理（抢占后保持冷却合理，防止被抢占分支立刻重入刷冷却）
stock void BT_AbortNode(int client, int nodeId) {
    if (nodeId < 0 || nodeId >= g_iBTNodeCount) return;
    g_iBTRunningChild[client][nodeId] = -1;

    if (g_eBTNodeType[nodeId] == BTN_WAIT) {
        char waitKey[32];
        Format(waitKey, sizeof(waitKey), "_bt_wait_%d", nodeId);
        if (g_hBTBlackboard[client] != null) {
            g_hBTBlackboard[client].Remove(waitKey);
        }
    }

    // v5.33: abort 时清除 ranged ability 的 TRYING 状态 + locked target
    // 防止子树被抢占后旧 try_at/lock_target 残留，下次进入时继续消费过期窗口
    if (g_hBTBlackboard[client] != null) {
        SI_AbilitySetState(client, "_smoker", ABILITY_IDLE);
        SI_AttackClearTarget(client, "_smoker");
        // v5.34 FIX: 清除 _smoker_try_at —— 原版只清 state+lock_target，
        // 残留 try_at 让下次进入 TryTongue 误判"已在 TRYING"跳过 LockTarget，
        // 但 lock_target=-1 → 不瞄准 + 无条件 IN_ATTACK → 对着空气按 1.2s
        SI_AbilityClearTryAt(client, "_smoker");
        SI_AbilitySetState(client, "_spitter", ABILITY_IDLE);
        SI_AttackClearTarget(client, "_spitter");
        // v5.34 FIX: 清除 _spitter_waiting_spit + _spitter_press_start ——
        // 残留 waiting_spit=true 让 PredictiveSpit/Spit 跳过重新锁目标，
        // 但 lock_target 已被清 -1 → "锁目标无效"立即退出 → 吐酸被静默取消
        BB_SetBool(client, "_spitter_waiting_spit", false);
        BB_SetFloat(client, "_spitter_press_start", 0.0);
        SI_AbilitySetState(client, "_boomer", ABILITY_IDLE);
        SI_AbilitySetState(client, "_hunter", ABILITY_IDLE);
        SI_AbilitySetState(client, "_charger", ABILITY_IDLE);
        SI_AttackClearTarget(client, "_charger");
        SI_AbilitySetState(client, "_jockey", ABILITY_IDLE);
    }

    if (g_hBTChildren[nodeId] != null) {
        int len = g_hBTChildren[nodeId].Length;
        for (int i = 0; i < len; i++) {
            BT_AbortNode(client, g_hBTChildren[nodeId].Get(i));
        }
    }
}

// Reset button accumulators before tick
stock void BT_ResetMovement(int client) {
    g_iBT_ButtonsAdd[client] = 0;
    g_iBT_ButtonsRemove[client] = 0;
    g_bBT_AnglesSet[client] = false;
    g_bBT_Teleport[client] = false;
    g_iBTControlMask[client] = 0;   // v5.22: 每 tick 重置控制声明
}

// Apply accumulated movement changes to OnPlayerRunCmd parameters
stock void BT_ApplyMovement(int client, int &buttons) {
    if (g_iBT_ButtonsAdd[client] != 0) {
        buttons |= g_iBT_ButtonsAdd[client];
    }
    if (g_iBT_ButtonsRemove[client] != 0) {
        buttons &= ~g_iBT_ButtonsRemove[client];
    }
}

// v5.22: 每帧控制输出应用（Think/Control 分离的核心出口）。
// 1) 对被 BT 接管的输入类别，先清除 Valve 原版 AI 的原始按键意图；
// 2) 再叠加 BT 累积输出（Add/Remove）。
// 非决策帧也调用本函数（沿用上次决策的累积输出 + 控制声明），
// 从而"决策降频、控制输出每帧应用"，消除 Valve/BT 交替接管抖动。
// v5.23.1 FIX: **ATTACK 类永不清理** —— 引擎发起技能（Hunter 扑击 press /
// Charger 冲锋 / 引擎能力触发）依赖 Valve AI 自己按下 IN_ATTACK 的时机，
// 清理它会剥夺引擎技能触发窗口（实机：Hunter 近距离按了不扑、Charger 触发
// 困难）。ATTACK 的"接管"只通过 BT_AddButton 加键表达，不通过清理。
stock void BT_ApplyControlFrame(int client, int &buttons) {
    int mask = g_iBTControlMask[client];
    if (mask & _:BTCTRL_MOVE) {
        // 只清移动类：导航相关。意图明确 = BT 接管移动（走走停停）。
        // 注意：不包含 IN_SPEED（冲刺键）—— 由 BT Add 表达。
        buttons &= ~(IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT);
        // P0-2: 生还者 IN_SPEED 随 MOVE 一并清理（原 MOVE 不含 SPEED，奶时泄漏跑）
        if (mask & _:BTCTRL_USE) buttons &= ~IN_SPEED;
    }
    if (mask & _:BTCTRL_DUCK) {
        buttons &= ~IN_DUCK;
    }
    if (mask & _:BTCTRL_JUMP) {
        buttons &= ~IN_JUMP;
    }
    if (mask & _:BTCTRL_USE) {
        buttons &= ~IN_USE;
    }
    BT_ApplyMovement(client, buttons);
}

// v5.23.1: 非决策帧轻量应用 —— 只重放 BT 上次的 Add/Remove 按键，
// **不清理 Valve 输入、不覆盖视角**。恢复引擎 AI 的技能触发 press
// 与原生导航（该帧 Valve 输入原样通过），同时保持 BT 的持续意图
// （Hold 静止靠 RemoveButton 重放、走位靠 AddButton 重放）。
stock void BT_ApplyControlLite(int client, int &buttons) {
    BT_ApplyMovement(client, buttons);
}

stock void BT_ApplyAngles(int client, float angles[3]) {
    if (g_bBT_AnglesSet[client]) {
        angles[0] = g_fBT_Angles[client][0];
        angles[1] = g_fBT_Angles[client][1];
        angles[2] = g_fBT_Angles[client][2];
    }
}

// ---------------------------------------------------------------------------
// Movement helpers (called from BT action callbacks)
// ---------------------------------------------------------------------------

// v5.22: 输出即声明 —— 任何 BT 按键输出自动声明接管对应输入类别，
// Apply 阶段据此清除 Valve 原版意图（见 BT_ApplyControlFrame）。
stock int BT_FlagsForButtons(int buttons) {
    int flags = 0;
    if (buttons & (IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT)) flags |= _:BTCTRL_MOVE;
    if (buttons & (IN_ATTACK | IN_ATTACK2)) flags |= _:BTCTRL_ATTACK;
    if (buttons & IN_DUCK) flags |= _:BTCTRL_DUCK;
    if (buttons & IN_JUMP) flags |= _:BTCTRL_JUMP;
    if (buttons & (IN_USE | IN_SPEED)) flags |= _:BTCTRL_USE;
    return flags;
}

stock void BT_AddButton(int client, int button) {
    g_iBT_ButtonsAdd[client] |= button;
    g_iBTControlMask[client] |= BT_FlagsForButtons(button);
}

stock void BT_RemoveButton(int client, int button) {
    g_iBT_ButtonsRemove[client] |= button;
    g_iBTControlMask[client] |= BT_FlagsForButtons(button);
}

stock void BT_SetAimAngles(int client, float pitch, float yaw, float roll = 0.0) {
    g_bBT_AnglesSet[client] = true;
    g_fBT_Angles[client][0] = pitch;
    g_fBT_Angles[client][1] = yaw;
    g_fBT_Angles[client][2] = roll;
    g_iBTControlMask[client] |= _:BTCTRL_VIEW;   // v5.22
}

stock void BT_TeleportToAngles(int client, float angles[3]) {
    g_bBT_Teleport[client] = true;
    g_fBT_Angles[client][0] = angles[0];
    g_fBT_Angles[client][1] = angles[1];
    g_fBT_Angles[client][2] = angles[2];
}

// ---------------------------------------------------------------------------
// Core Tick Engine — BT_TickNode defined first so no forward declaration needed
// ---------------------------------------------------------------------------

BT_Status BT_TickNode(int nodeId, int client) {
    if (nodeId < 0 || nodeId >= g_iBTNodeCount) {
        return BT_FAILURE;
    }

    BT_NodeType type = g_eBTNodeType[nodeId];

    switch (type) {
        case BTN_SELECTOR: {
            if (g_hBTChildren[nodeId] == null) return BT_FAILURE;
            int len = g_hBTChildren[nodeId].Length;
            if (len == 0) return BT_FAILURE;

            // Re-evaluate from child 0 every tick (conditional abort)
            // v5.22: 丢弃旧 RUNNING 子树的时机覆盖全部退出路径 —— 原版只在
            // "新子节点 RUNNING" 时 reset 旧子节点；高优先级子节点直接
            // SUCCESS/FAILURE 提前返回时旧子树状态残留（WAIT 时间戳等），
            // 重新进入时恢复陈旧状态。现在 SUCCESS/FAILURE/RUNNING 三条
            // 路径统一调 BT_AbortNode 收尾旧子树。
            int prevRunning = g_iBTRunningChild[client][nodeId];
            for (int i = 0; i < len; i++) {
                int childId = g_hBTChildren[nodeId].Get(i);
                BT_Status result = BT_TickNode(childId, client);

                if (result == BT_RUNNING) {
                    // If this is a different child than last tick, reset old one
                    if (prevRunning != i && prevRunning >= 0 && prevRunning < len) {
                        BT_AbortNode(client, g_hBTChildren[nodeId].Get(prevRunning));
                    }
                    g_iBTRunningChild[client][nodeId] = i;
                    g_iBTLastWinningChild[client][nodeId] = i;   // v5.6
                    return BT_RUNNING;
                }
                if (result == BT_SUCCESS) {
                    if (prevRunning != i && prevRunning >= 0 && prevRunning < len) {
                        BT_AbortNode(client, g_hBTChildren[nodeId].Get(prevRunning));
                    }
                    g_iBTRunningChild[client][nodeId] = -1;
                    g_iBTLastWinningChild[client][nodeId] = i;   // v5.6: SUCCESS 也记录
                    return BT_SUCCESS;
                }
                // BT_FAILURE → continue to next child
            }
            if (prevRunning >= 0 && prevRunning < len) {
                BT_AbortNode(client, g_hBTChildren[nodeId].Get(prevRunning));
            }
            g_iBTRunningChild[client][nodeId] = -1;
            return BT_FAILURE;
        }

        case BTN_SEQUENCE: {
            if (g_hBTChildren[nodeId] == null) return BT_SUCCESS;
            int len = g_hBTChildren[nodeId].Length;
            if (len == 0) return BT_SUCCESS;

            // Re-evaluate from child 0 every tick
            // v5.22: 同 Selector —— 旧 RUNNING 子树被推进/失败时统一 Abort 收尾
            int prevRunning = g_iBTRunningChild[client][nodeId];
            for (int i = 0; i < len; i++) {
                int childId = g_hBTChildren[nodeId].Get(i);
                BT_Status result = BT_TickNode(childId, client);

                if (result == BT_FAILURE) {
                    if (prevRunning >= 0 && prevRunning < len && prevRunning != i) {
                        BT_AbortNode(client, g_hBTChildren[nodeId].Get(prevRunning));
                    }
                    g_iBTRunningChild[client][nodeId] = -1;
                    return BT_FAILURE;
                }
                if (result == BT_RUNNING) {
                    if (prevRunning >= 0 && prevRunning < len && prevRunning != i) {
                        BT_AbortNode(client, g_hBTChildren[nodeId].Get(prevRunning));
                    }
                    g_iBTRunningChild[client][nodeId] = i;
                    return BT_RUNNING;
                }
                // BT_SUCCESS → continue to next child
            }
            if (prevRunning >= 0 && prevRunning < len) {
                BT_AbortNode(client, g_hBTChildren[nodeId].Get(prevRunning));
            }
            g_iBTRunningChild[client][nodeId] = -1;
            return BT_SUCCESS;
        }

        case BTN_PARALLEL: {
            if (g_hBTChildren[nodeId] == null) return BT_FAILURE;
            int len = g_hBTChildren[nodeId].Length;
            if (len == 0) return BT_FAILURE;

            int successCount = 0, failureCount = 0, runningCount = 0;
            for (int i = 0; i < len; i++) {
                int childId = g_hBTChildren[nodeId].Get(i);
                BT_Status result = BT_TickNode(childId, client);
                // v3.2 FIX: add break statements — the fall-through meant
                // SUCCESS also incremented failureCount and runningCount.
                switch (result) {
                    case BT_SUCCESS:  { successCount++;  break; }
                    case BT_FAILURE:  { failureCount++;  break; }
                    case BT_RUNNING:  { runningCount++;  break; }
                }
            }

            int minSuccess = RoundToNearest(g_fBTParam[nodeId]);
            int maxFailure = RoundToNearest(g_fBTParam2[nodeId]);

            if (successCount >= minSuccess) return BT_SUCCESS;
            if (failureCount > maxFailure) return BT_FAILURE;
            return BT_RUNNING;
        }

        case BTN_INVERTER: {
            if (g_hBTChildren[nodeId] == null) return BT_FAILURE;
            int childId = g_hBTChildren[nodeId].Get(0);
            BT_Status result = BT_TickNode(childId, client);
            if (result == BT_SUCCESS)  return BT_FAILURE;
            if (result == BT_FAILURE)  return BT_SUCCESS;
            return BT_RUNNING;  // RUNNING passes through
        }

        case BTN_COOLDOWN: {
            // v3.2 FIX: per-node cooldown key (was shared "_bt_cd_last" across
            // all Cooldown nodes in the tree — e.g., Smoker's two cooldowns
            // interfered with each other).
            char cdKey[32];
            Format(cdKey, sizeof(cdKey), "_bt_cd_%d", nodeId);

            float now = GetGameTime();
            float lastTick = BB_GetFloat(client, cdKey);
            float cooldown = g_fBTParam[nodeId];

            // If within cooldown, skip child entirely
            if (lastTick > 0.0 && (now - lastTick) < cooldown) {
                // Still RUNNING if the child was running last tick
                if (g_iBTRunningChild[client][nodeId] >= 0) {
                    return BT_RUNNING;
                }
                return BT_FAILURE;
            }

            if (g_hBTChildren[nodeId] == null) return BT_FAILURE;
            int childId = g_hBTChildren[nodeId].Get(0);
            BT_Status result = BT_TickNode(childId, client);

            if (result != BT_RUNNING) {
                // v5.6: 只在 SUCCESS 时武装冷却 —— 原版 FAILURE 也 arm：条件
                // 静态失败的分支（Charger 750u 门外、Smoker 拉人簇全灭）每
                // 1.8s/12s 才重评一次，产生"冷却已结束仍不尝试"的评估量子；
                // 且失败不消耗冷却（条件便宜，立即重试无代价）。
                if (result == BT_SUCCESS) {
                    BB_SetFloat(client, cdKey, now);
                }
                g_iBTRunningChild[client][nodeId] = -1;
            } else {
                g_iBTRunningChild[client][nodeId] = 0;
            }
            return result;
        }

        case BTN_FORCE_SUCCESS: {
            if (g_hBTChildren[nodeId] == null) return BT_SUCCESS;
            int childId = g_hBTChildren[nodeId].Get(0);
            BT_TickNode(childId, client);  // tick child but ignore result
            return BT_SUCCESS;
        }

        case BTN_FORCE_FAILURE: {
            if (g_hBTChildren[nodeId] == null) return BT_FAILURE;
            int childId = g_hBTChildren[nodeId].Get(0);
            BT_TickNode(childId, client);  // tick child but ignore result
            return BT_FAILURE;
        }

        case BTN_REPEAT_UNTIL_FAIL: {
            if (g_hBTChildren[nodeId] == null) return BT_FAILURE;
            int childId = g_hBTChildren[nodeId].Get(0);
            BT_Status result = BT_TickNode(childId, client);

            if (result == BT_FAILURE) {
                g_iBTRunningChild[client][nodeId] = -1;
                return BT_SUCCESS;  // exit normally
            }
            if (result == BT_SUCCESS) {
                // Child succeeded — reset and re-tick on next frame
                BT_ResetNodeState(client, childId);
                g_iBTRunningChild[client][nodeId] = 0;
                return BT_RUNNING;
            }
            // BT_RUNNING — child still executing
            g_iBTRunningChild[client][nodeId] = 0;
            return BT_RUNNING;
        }

        case BTN_CONDITION, BTN_ACTION: {
            if (g_hBTFunc[nodeId] == INVALID_FUNCTION) {
                return BT_FAILURE;
            }
            // Set tick context so callbacks can access g_fBTNodeUserParam*[nodeId]
            int prevTickNode = g_iBTCurrentTickNode;
            g_iBTCurrentTickNode = nodeId;
            // Call the registered callback
            BT_Status result;
            Call_StartFunction(INVALID_HANDLE, g_hBTFunc[nodeId]);
            Call_PushCell(client);
            Call_Finish(result);
            g_iBTCurrentTickNode = prevTickNode;
            return result;
        }

        case BTN_WAIT: {
            // v3.4 FIX: per-node wait key (was shared "_bt_wait_start" across
            // all Wait nodes — same bug Cooldown had before v3.2 fix).
            char waitKey[32];
            Format(waitKey, sizeof(waitKey), "_bt_wait_%d", nodeId);

            float now = GetGameTime();
            float waitStart = BB_GetFloat(client, waitKey);
            if (waitStart <= 0.0) {
                BB_SetFloat(client, waitKey, now);
                return BT_RUNNING;
            }
            if ((now - waitStart) >= g_fBTParam[nodeId]) {
                BB_SetFloat(client, waitKey, 0.0);
                return BT_SUCCESS;
            }
            return BT_RUNNING;
        }

        default: {
            return BT_FAILURE;
        }
    }
}

// Main entry point — call in OnPlayerRunCmd after resetting movement state
stock BT_Status BT_Tick(int client) {
    if (!BT_IsBound(client)) return BT_FAILURE;
    return BT_TickNode(g_iBTRoot[client], client);
}

// ---------------------------------------------------------------------------
// Debug: get node type name for logging
// ---------------------------------------------------------------------------

stock void BT_GetNodeTypeName(BT_NodeType type, char[] buffer, int maxlen) {
    // v3.2 FIX: replaced switch-case (whose break-statements were silently
    // dropped by SourcePawn's parser) with a static-array lookup that is
    // immune to fall-through by construction.
    // BTN_WAIT = 11, so 12 slots (0..11 inclusive).
    static const char sNodeNames[12][] = {
        "Invalid",          // BTN_INVALID=0
        "Selector",         // BTN_SELECTOR=1
        "Sequence",         // BTN_SEQUENCE=2
        "Parallel",         // BTN_PARALLEL=3
        "Inverter",         // BTN_INVERTER=4
        "Cooldown",         // BTN_COOLDOWN=5
        "ForceSuccess",     // BTN_FORCE_SUCCESS=6
        "ForceFailure",     // BTN_FORCE_FAILURE=7
        "RepeatUntilFail",  // BTN_REPEAT_UNTIL_FAIL=8
        "Condition",        // BTN_CONDITION=9
        "Action",           // BTN_ACTION=10
        "Wait"              // BTN_WAIT=11
    };
    if (type >= BTN_INVALID && type <= BTN_WAIT)
        strcopy(buffer, maxlen, sNodeNames[_:type]);
    else
        strcopy(buffer, maxlen, "Unknown");
}
