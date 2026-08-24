#include <sourcemod>
#include <sdktools>

public void OnPluginStart()
{
    RegConsoleCmd("sm_give_m7", CmdGiveM7, "Give M7 EBR (CWL custom weapon on AK47)");
    RegConsoleCmd("sm_m7", CmdGiveM7, "Give M7 EBR (CWL custom weapon on AK47)");
}

public Action CmdGiveM7(int client, int args)
{
    if (!IsClientInGame(client) || IsPlayerAlive(client))
    {
        if (IsClientInGame(client) && !IsPlayerAlive(client))
            ReplyToCommand(client, "[Suli] You must be alive to use this command.");
        return Plugin_Handled;
    }

    // Give weapon_rifle_ak47
    int weapon = GivePlayerItem(client, "weapon_rifle_ak47");
    if (!IsValidEntity(weapon))
    {
        ReplyToCommand(client, "[Suli] Failed to give weapon.");
        return Plugin_Handled;
    }

    // Find the viewmodel to locate the weapon entity
    int viewmodel = GetEntPropEnt(client, Prop_Send, "m_hViewModel");
    if (!IsValidEntity(viewmodel))
    {
        ReplyToCommand(client, "[Suli] Could not find viewmodel.");
        return Plugin_Handled;
    }

    int activeWeapon = GetEntPropEnt(viewmodel, Prop_Send, "m_hWeapon");
    if (!IsValidEntity(activeWeapon))
    {
        ReplyToCommand(client, "[Suli] Could not find active weapon from viewmodel.");
        return Plugin_Handled;
    }

    // Set CWL contexts via VScript using a logic_script entity
    // Find or create a logic_script for VScript execution
    int logicScript = FindEntityByClassname(-1, "logic_script");
    if (!IsValidEntity(logicScript))
    {
        ReplyToCommand(client, "[Suli] No logic_script entity found for VScript execution.");
        return Plugin_Handled;
    }

    // Set contexts on the weapon entity using VScript
    char code[512];
    Format(code, sizeof(code),
        "local ent = EntIndexToHScript(%d); \
         if (ent != null && ent.IsValid()) { \
             ent.SetContext(\"CustomWeaponName\", \"weapon_m7\", -1); \
             ent.SetContext(\"CustomFPmodel\", \"models/custom_weapons/m7/v_m7.mdl\", -1); \
             ent.SetContext(\"CustomTPmodel\", \"models/custom_weapons/m7/w_m7.mdl\", -1); \
             printl(\"[Suli M7] Set CWL contexts on \" + ent); \
         }",
        activeWeapon);

    SetVariantString(code);
    AcceptEntityInput(logicScript, "RunScriptCode");

    // Also try to trigger CWL's weapon detection
    // The CWL controller Think loop should pick it up on next tick
    // But we can also try to set the world model
    char wmodelcode[256];
    Format(wmodelcode, sizeof(wmodelcode),
        "local ent = EntIndexToHScript(%d); \
         if (ent != null && ent.IsValid()) { \
             ent.SetModel(\"models/custom_weapons/m7/w_m7.mdl\"); \
         }",
        activeWeapon);

    SetVariantString(wmodelcode);
    AcceptEntityInput(logicScript, "RunScriptCode");

    ReplyToCommand(client, "[Suli] M7 EBR given! CWL contexts set on weapon entity.");

    return Plugin_Handled;
}
