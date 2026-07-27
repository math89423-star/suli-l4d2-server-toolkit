// PTG Module: ptg_sdk — SDK call setup, RecomputeFlowDistances hook
// Extracted from l4d_path_to_goal.inc (backup)

void LoadSDK()
{
    g_bFlowRecomputeHooked = false;
    g_hRecomputeFlow = null;
    g_hRecomputeFlowDetour = null;
    Handle gd = LoadGameConfigFile(PLUGIN_NAME);
    if (gd == null)
    {
        LogMessage("Missing gamedata file: %s.txt", PLUGIN_NAME);
        delete gd;
        return;
    }

    StartPrepSDKCall(SDKCall_Raw);
    if (!PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "TerrorNavMesh::RecomputeFlowDistances"))
    {
        LogMessage("RecomputeFlowDistances PrepSDKCall_SetFromConf failed");
    }
    g_hRecomputeFlow = EndPrepSDKCall();
    if (g_hRecomputeFlow == null)
    {
        LogMessage("RecomputeFlowDistances SDKCall setup failed");
    }

    g_hRecomputeFlowDetour = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_Ignore);
    if (g_hRecomputeFlowDetour == null)
    {
        LogMessage("RecomputeFlowDistances DHookCreateDetour failed");
    }
    if (!DHookSetFromConf(g_hRecomputeFlowDetour, gd, SDKConf_Signature, "TerrorNavMesh::RecomputeFlowDistances"))
    {
        LogMessage("RecomputeFlowDistances failed");
        g_hRecomputeFlowDetour = null;
    }
    if (g_hRecomputeFlowDetour != null)
    {
        g_bFlowRecomputeHooked = g_hRecomputeFlowDetour.Enable(Hook_Post, Hook_RecomputeFlowPost);
    }
    delete gd;
}

public MRESReturn Hook_RecomputeFlowPost(Address pThis)
{
    #if DEBUG>1
    LogMessage("RecomputeFlowDistances");
    #endif
    NavChanged(true);
    return MRES_Ignored;
}
