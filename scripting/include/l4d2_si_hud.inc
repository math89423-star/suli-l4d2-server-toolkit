#if defined _l4d2_si_hud_included
    #endinput
#endif
#define _l4d2_si_hud_included

/**
 * l4d2_si_hud 公共 API（v1.9.0+）——积分钱包 + 复活币
 *
 * si_hud 拥有并持久化 g_iWallet（可用积分）与 g_iReviveCoins（复活币）：
 * 计分入账（击杀/伤害/连杀/救援）、存档恢复（data/si_hud_scores.txt）、
 * 战役清零、重连恢复全在 si_hud 内。消费方（如 l4d2_shop）通过本 API
 * 读取/增减，不触碰内部状态。
 *
 * ⚠ 绑定规则（l4d2_shop 按字母序在 si_hud 之前加载，必须可选绑定）：
 *   - 消费方不得直接 `native` 声明这些函数（si_hud 缺失时加载硬失败）。
 *   - 正确姿势：si_hud OnPluginStart 调用
 *     RegPluginLibrary("l4d2_si_hud_api")；消费方在 OnAllPluginsLoaded 与
 *     OnLibraryAdded("l4d2_si_hud_api") 里用
 *     GetNativeHandle(FindPluginByFile("l4d2_si_hud.smx"), "SH_...") 获取
 *     句柄，OnLibraryRemoved 里清空；调用走 CallNativeHandle。
 *   - 全部句柄有效 = API 可用；任一缺失（si_hud 过旧）按整体不可用处理。
 */

/**
 * 读取玩家可用积分（钱包）。
 */
native int SH_GetWallet(int client);

/**
 * 增减玩家可用积分（负数 = 消费，正数 = 退款），结果钳制 >= 0。
 * 返回操作后的新余额（消费方聊天播报直接用返回值，无需二次读取）。
 */
native int SH_AddWallet(int client, int amount);

/**
 * 读取玩家复活币余额。
 */
native int SH_GetReviveCoins(int client);

/**
 * 增减玩家复活币，结果钳制 >= 0。返回操作后的新余额。
 */
native int SH_AddReviveCoins(int client, int amount);

/**
 * 返回复活币持有上限（si_hud_respawn_coin_max 现值；si_hud 在持久化
 * 钳制处使用同一策略，消费方购买前检查用它保持口径一致）。
 */
native int SH_GetCoinMax();
