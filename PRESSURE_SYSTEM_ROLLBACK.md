# 压力系统回退记录

**日期**: 2026-08-13 20:30

## 回退原因

压力系统在集成过程中发现多个问题，暂时回退到集成前的稳定版本。

## 已发现的问题

### 1. OnWaveStarted 调用问题
- **位置**: `specialspawner.sp:1205`
- **问题**: `ExecuteSpawnQueue(totalSI, true)` - retry 参数硬编码为 true
- **影响**: 导致 `NotifyPressureWaveStart()` 永远不会被调用
- **修复**: 改为 `ExecuteSpawnQueue(totalSI, false)`

### 2. 热重载检测问题
- **位置**: `specialspawner.sp:CheckPressureTracker()`
- **问题**: 只在 `OnConfigsExecuted()` 调用，热重载时不触发
- **影响**: 插件重载后无法重新检测 pressure_tracker
- **修复**: 在 `OnMapStart()` 中也调用 `CheckPressureTracker()`

### 3. 旧插件残留问题
- **问题**: 备份目录 `plugins/backup_20260813/` 中的旧插件仍被 SourceMod 加载
- **影响**: 新旧插件同时运行，状态混乱
- **修复**: 将备份移到 `plugins/` 之外

### 4. 播报问题
- **问题**: Change 值显示为 `+d` 而非数字
- **状态**: 格式化字符串正确，但输出异常
- **待调查**: pressureChange 变量的值计算

### 5. 段位切换稳定性
- **问题**: 段位切换需要多波稳定才触发，用户体验不直观
- **待优化**: 调整稳定化机制参数或播报策略

## 回退操作

```bash
# 1. 恢复备份的插件
cp backup_20260813/specialspawner.smx plugins/
cp backup_20260813/si_composition_manager.smx plugins/
cp backup_20260813/AI_HardSI_bt.smx plugins/

# 2. 卸载 pressure_tracker
sm plugins unload pressure_tracker

# 3. 重载其他插件
sm plugins reload specialspawner
sm plugins reload si_composition_manager
sm plugins reload AI_HardSI_bt
```

## 备份位置

**压力系统版本（有问题）**:
- `/opt/gameservers/l4d2/data/addons/sourcemod/scripting/pressure_tracker.sp`
- `/opt/gameservers/l4d2/data/addons/sourcemod/scripting/specialspawner.sp` (修改版)
- `/opt/gameservers/l4d2/data/addons/sourcemod/scripting/si_composition_manager.sp` (修改版)
- `/opt/gameservers/l4d2/data/addons/sourcemod/scripting/AI_HardSI_optimized/AI_HardSI.sp` (修改版)

**稳定版本（当前运行）**:
- `/opt/gameservers/l4d2/data/addons/sourcemod/backup_20260813/*.smx`

## 下一步工作

1. 在测试环境中完善压力系统
2. 解决上述已知问题
3. 完整测试后再集成到生产环境

## Hunter 站桩问题

**状态**: 未解决，需要继续调查
- 已启用 `ai_debug 1` 调试
- v5.7 已修复部分站桩问题（LOS 迁移、crouchPrep 冷却）
- 需要实际观察 Hunter 行为并分析调试日志

**测试方法**:
- 强制切换到猎手集群模式: `sm_cvar si_comp_active_mode 5`
- 观察 Hunter 站桩时的距离、姿态、视线状态
- 检查日志中的 `rootBranch` 分支编号
