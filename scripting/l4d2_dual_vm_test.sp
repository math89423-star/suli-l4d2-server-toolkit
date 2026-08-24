/**
 * l4d2_dual_vm_test.sp
 * 
 * 忠实复刻 L4DViewmodels (foxhound27) 结构
 * + M7 tagging 共存系统
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_TAG "[DualVM]"
#define M7_MODEL "models/custom_weapons/m7/v_m7.mdl"

int g_iViewModels[MAXPLAYERS + 1][2];
Handle g_hCreateViewModel;

int g_iOffset_ViewModel;
int g_iOffset_ActiveWeapon;
int g_iOffset_Weapon;
int g_iOffset_Sequence;
int g_iOffset_PlaybackRate;

// 动画偏移 - 用于 M7 模型序列号与 AK47 的差异
// L4DViewmodels 用 -1，验证用
int g_AnimOffset = -1;

int g_iM7ModelIndex;
bool g_bIsM7Weapon[2048]; // per-weapon-entity tag

public Plugin myinfo =
{
    name = "[L4D2] Suli Dual VM Test",
    author = "Suli Agent + foxhound27",
    description = "Dual VM following L4DViewmodels + M7 tagging",
    version = "2.0.0",
    url = ""
};

public void OnPluginStart()
{
    Handle gameConf = LoadGameConfigFile("L4DViewmodels");
    if (!gameConf)
    {
        SetFailState("Cannot open L4DViewmodels gamedata!");
    }

    StartPrepSDKCall(SDKCall_Player);
    PrepSDKCall_SetFromConf(gameConf, SDKConf_Virtual, "CreateViewModel");
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_ByValue);

    if ((g_hCreateViewModel = EndPrepSDKCall()) == INVALID_HANDLE)
    {
        SetFailState("Failed to create CreateViewModel SDKCall!");
    }
    CloseHandle(gameConf);

    g_iOffset_ViewModel = FindSendPropInfo("CBasePlayer", "m_hViewModel");
    g_iOffset_ActiveWeapon = FindSendPropInfo("CBasePlayer", "m_hActiveWeapon");
    g_iOffset_Weapon = FindSendPropInfo("CBaseViewModel", "m_hWeapon");
    g_iOffset_Sequence = FindSendPropInfo("CBaseViewModel", "m_nSequence");
    g_iOffset_PlaybackRate = FindSendPropInfo("CBaseViewModel", "m_flPlaybackRate");

    HookEvent("player_spawn", Event_PlayerSpawn);

    RegConsoleCmd("sm_tagm7", CmdTagM7, "Tag held weapon as M7");
    RegConsoleCmd("sm_untagm7", CmdUntagM7, "Untag held weapon");

    PrintToServer("%s Loaded. Offsets: VM=%d AW=%d W=%d Seq=%d Rate=%d", PLUGIN_TAG,
        g_iOffset_ViewModel, g_iOffset_ActiveWeapon, g_iOffset_Weapon, g_iOffset_Sequence, g_iOffset_PlaybackRate);
}

public void OnMapStart()
{
    g_iM7ModelIndex = PrecacheModel(M7_MODEL, true);
}

public void OnClientPostAdminCheck(int client)
{
    g_iViewModels[client][0] = -1;
    g_iViewModels[client][1] = -1;

    SDKHook(client, SDKHook_PostThink, OnClientThinkPost);
}

public void Event_PlayerSpawn(Handle event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (client <= 0 || !IsClientInGame(client) || GetClientTeam(client) < 2)
        return;

    // Create the second view model (VM1)
    SDKCall(g_hCreateViewModel, client, 1);

    g_iViewModels[client][0] = GetViewModel(client, 0);
    g_iViewModels[client][1] = GetViewModel(client, 1);

    PrintToServer("%s Player %d spawned: VM0=%d, VM1=%d", PLUGIN_TAG, client,
        g_iViewModels[client][0], g_iViewModels[client][1]);
}

int GetViewModel(int client, int index)
{
    return GetEntDataEnt2(client, g_iOffset_ViewModel + (index * 4));
}

public void OnClientThinkPost(int client)
{
    static int currentWeapon[MAXPLAYERS + 1];

    int viewModel1 = g_iViewModels[client][0]; // VM0
    int viewModel2 = g_iViewModels[client][1]; // VM1

    if (!IsPlayerAlive(client))
    {
        if (viewModel2 != -1)
        {
            g_iViewModels[client][0] = -1;
            g_iViewModels[client][1] = -1;
            currentWeapon[client] = 0;
        }
        return;
    }

    // Re-fetch viewmodels if invalid (weapon switch can change them)
    if (viewModel1 <= 0 || !IsValidEntity(viewModel1))
    {
        g_iViewModels[client][0] = GetViewModel(client, 0);
        viewModel1 = g_iViewModels[client][0];
    }
    if (viewModel2 <= 0 || !IsValidEntity(viewModel2))
    {
        g_iViewModels[client][1] = GetViewModel(client, 1);
        viewModel2 = g_iViewModels[client][1];
    }

    if (viewModel1 <= 0 || !IsValidEntity(viewModel1) || viewModel2 <= 0 || !IsValidEntity(viewModel2))
        return;

    int activeWeapon = GetEntDataEnt2(client, g_iOffset_ActiveWeapon);

    // Check if the player has switched weapon.
    if (activeWeapon != currentWeapon[client])
    {
        currentWeapon[client] = 0;

        if (activeWeapon > 0 && IsValidEntity(activeWeapon) && g_bIsM7Weapon[activeWeapon])
        {
            // Tagged M7 weapon: set VM1 model + bind weapon
            SetEntProp(viewModel2, Prop_Send, "m_nModelIndex", g_iM7ModelIndex);
            SetEntData(viewModel2, g_iOffset_Weapon, GetEntData(viewModel1, g_iOffset_Weapon), _, true);

            currentWeapon[client] = activeWeapon;
        }
    }

    if (currentWeapon[client])
    {
        // M7 weapon active: hide VM0, show VM1, sync animation
        SetEntProp(viewModel1, Prop_Send, "m_nModelIndex", 0); // hide original
        SetEntProp(viewModel2, Prop_Send, "m_nModelIndex", g_iM7ModelIndex); // ensure M7

        SetEntData(viewModel2, g_iOffset_Sequence, GetEntData(viewModel1, g_iOffset_Sequence) - g_AnimOffset, _, true);
        SetEntData(viewModel2, g_iOffset_PlaybackRate, GetEntData(viewModel1, g_iOffset_PlaybackRate), _, true);
    }
    else
    {
        // Not M7 weapon: hide VM1 (fake)
        SetEntProp(viewModel2, Prop_Send, "m_nModelIndex", 0);
    }
}

public Action CmdTagM7(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Handled;

    int weapon = GetEntDataEnt2(client, g_iOffset_ActiveWeapon);
    if (weapon <= 0 || !IsValidEntity(weapon))
    {
        ReplyToCommand(client, "%s No weapon held!", PLUGIN_TAG);
        return Plugin_Handled;
    }

    g_bIsM7Weapon[weapon] = true;
    char className[32];
    GetEdictClassname(weapon, className, sizeof(className));
    ReplyToCommand(client, "%s Weapon %d (%s) tagged as M7", PLUGIN_TAG, weapon, className);
    return Plugin_Handled;
}

public Action CmdUntagM7(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Handled;

    int weapon = GetEntDataEnt2(client, g_iOffset_ActiveWeapon);
    if (weapon <= 0 || !IsValidEntity(weapon))
    {
        ReplyToCommand(client, "%s No weapon held!", PLUGIN_TAG);
        return Plugin_Handled;
    }

    g_bIsM7Weapon[weapon] = false;
    ReplyToCommand(client, "%s Weapon %d untagged", PLUGIN_TAG, weapon);
    return Plugin_Handled;
}
