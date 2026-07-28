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

#define BT_MAX_NODES   512    // max total nodes across all trees
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

int     g_iBT_ButtonsAdd[MAXPLAYERS + 1];       // buttons to ADD
int     g_iBT_ButtonsRemove[MAXPLAYERS + 1];    // buttons to REMOVE
bool    g_bBT_AnglesSet[MAXPLAYERS + 1];
float   g_fBT_Angles[MAXPLAYERS + 1][3];
bool    g_bBT_Teleport[MAXPLAYERS + 1];

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
    int child3 = -1, int child4 = -1, int child5 = -1, int child6 = -1) {
    int id = BT_Create(BTN_SELECTOR);
    BT_AddChild(id, child1);
    if (child2 >= 0) BT_AddChild(id, child2);
    if (child3 >= 0) BT_AddChild(id, child3);
    if (child4 >= 0) BT_AddChild(id, child4);
    if (child5 >= 0) BT_AddChild(id, child5);
    if (child6 >= 0) BT_AddChild(id, child6);
    return id;
}

stock int BT_CreateSequence(int numChildren, int child1, int child2 = -1,
    int child3 = -1, int child4 = -1, int child5 = -1, int child6 = -1) {
    int id = BT_Create(BTN_SEQUENCE);
    BT_AddChild(id, child1);
    if (child2 >= 0) BT_AddChild(id, child2);
    if (child3 >= 0) BT_AddChild(id, child3);
    if (child4 >= 0) BT_AddChild(id, child4);
    if (child5 >= 0) BT_AddChild(id, child5);
    if (child6 >= 0) BT_AddChild(id, child6);
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

// Reset button accumulators before tick
stock void BT_ResetMovement(int client) {
    g_iBT_ButtonsAdd[client] = 0;
    g_iBT_ButtonsRemove[client] = 0;
    g_bBT_AnglesSet[client] = false;
    g_bBT_Teleport[client] = false;
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

stock void BT_AddButton(int client, int button) {
    g_iBT_ButtonsAdd[client] |= button;
}

stock void BT_RemoveButton(int client, int button) {
    g_iBT_ButtonsRemove[client] |= button;
}

stock void BT_SetAimAngles(int client, float pitch, float yaw, float roll = 0.0) {
    g_bBT_AnglesSet[client] = true;
    g_fBT_Angles[client][0] = pitch;
    g_fBT_Angles[client][1] = yaw;
    g_fBT_Angles[client][2] = roll;
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
            for (int i = 0; i < len; i++) {
                int childId = g_hBTChildren[nodeId].Get(i);
                BT_Status result = BT_TickNode(childId, client);

                if (result == BT_RUNNING) {
                    // If this is a different child than last tick, reset old one
                    int prevRunning = g_iBTRunningChild[client][nodeId];
                    if (prevRunning != i && prevRunning >= 0 && prevRunning < len) {
                        BT_ResetNodeState(client, g_hBTChildren[nodeId].Get(prevRunning));
                    }
                    g_iBTRunningChild[client][nodeId] = i;
                    return BT_RUNNING;
                }
                if (result == BT_SUCCESS) {
                    g_iBTRunningChild[client][nodeId] = -1;
                    return BT_SUCCESS;
                }
                // BT_FAILURE → continue to next child
            }
            g_iBTRunningChild[client][nodeId] = -1;
            return BT_FAILURE;
        }

        case BTN_SEQUENCE: {
            if (g_hBTChildren[nodeId] == null) return BT_SUCCESS;
            int len = g_hBTChildren[nodeId].Length;
            if (len == 0) return BT_SUCCESS;

            // Re-evaluate from child 0 every tick
            for (int i = 0; i < len; i++) {
                int childId = g_hBTChildren[nodeId].Get(i);
                BT_Status result = BT_TickNode(childId, client);

                if (result == BT_FAILURE) {
                    g_iBTRunningChild[client][nodeId] = -1;
                    return BT_FAILURE;
                }
                if (result == BT_RUNNING) {
                    g_iBTRunningChild[client][nodeId] = i;
                    return BT_RUNNING;
                }
                // BT_SUCCESS → continue to next child
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
                // Child completed — reset the cooldown timer
                BB_SetFloat(client, cdKey, now);
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
