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
 * ⚠ 绑定规则（SM 1.12 运行时懒绑定——项目既有模式，见 left4dhooks 消费方）：
 *   - 消费方直接 `native` 声明这些函数即可；si_hud 未加载时插件照常加载，
 *     但对缺失 native 的调用会记错误日志并返回 0。
 *   - 因此调用必须经可用性守卫：FindPluginByFile("l4d2_si_hud.smx") 存在
 *     且版本 >= 1.9.0（SH_Ready 模式，见 l4d2_shop.sp），未就绪时不发起
 *     调用。si_hud 通过 RegPluginLibrary("l4d2_si_hud_api") 声明库存在，
 *     可作辅助信号。
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

/**
 * 复活币立即复活（v1.9.1+）：玩家当前处于真死亡状态（复活次数用完且无币
 * 而躺尸）时，消耗 1 枚复活币并安排自动复活（延迟 si_hud_respawn_delay）。
 * 返回 1 = 已消耗并安排复活；0 = 未生效（活着/倒下/已有复活计划/无币/非幸存者）。
 *
 * 背景：复活判定只响应 player_death 事件——躺尸后购买复活币不会再有死亡
 * 事件，币会白买。消费方在 SH_AddReviveCoins(+1) 后立即调用本 native：
 * 真死亡 → 用掉刚买的币复活；存活 → 返回 0，币正常囤积。
 */
native int SH_ReviveClient(int client);

/**
 * 复活完成全局 forward（v1.9.2+，si_hud 发布，消费方定义同名 public 函数即可
 * 自动接收）：复活币死亡复活流程确认存活后（Timer_RespawnTeleport，复活 0.5s
 * 后）触发。l4d2_shop v1.5.1 监听它发放"复活套装"（sm_shop_respawn_gear）
 * + 满血（sm_shop_respawn_health）。闲置/接管不触发（引擎自管）。
 */
forward void SH_OnClientRespawned(int client);
