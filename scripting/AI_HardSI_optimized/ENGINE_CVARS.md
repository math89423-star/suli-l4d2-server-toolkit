# L4D2 引擎真实数值基准（ENGINE_CVARS）

> 目的：所有 AI_HardSI 数值改动必须以此表为基准，**不验证不乱填**。
> 实测方法：空服窗口内 RCON 查询（手写 RCON 协议，见文末脚本）。
> 实测日期：2026-08-03（服务器：糍耙24人纯净多特战角色服，v4.0.3 审计时点）
>
> 格式：`当前值`（引擎默认 `def.` 值，未标注 def 表示当前=默认或被插件改动且默认值未显示）

---

## 一、能力冷却 / 距离（BT 数值的直接依据）

| cvar | 实测值 | 插件对应 | 匹配状态 |
|------|--------|----------|----------|
| `z_charge_interval` | **12** | Charger 冲锋冷却簇 `Cooldown(12.0)` | ✅ v4.0.3 对齐 |
| `z_charge_warmup` | 0.5 | —（冲锋起步加速 0.5s） | — |
| `z_charge_duration` | **2.5** | —（冲锋持续） | — |
| `z_charge_start_speed` | 250 | —（起步速度 u/s） | — |
| `z_charge_max_speed` | **500** | —（最高速度 u/s） | — |
| `smoker_tongue_delay` | 1.0（def 1.5） | 插件设 1.0；拉人冷却簇 `Cooldown(1.8)` | ✅ 1.8 > 1.5/1.0 |
| `boomer_vomit_delay` | 0.1（def 1） | 插件设 0.1；post-vomit 自锁 10s | ✅ 10s ≫ 引擎冷却 |
| `z_spit_interval` | **20** | **v4.0.3 插件设 8.0**（对齐 post-spit 8s） | ✅ v4.0.3 干预 |
| `hunter_pounce_ready_range` | 500 | —（引擎：目标 500u 内蹲伏准备） | — |
| `hunter_committed_attack_range` | 10000（def 75） | 插件设 10000 | ✅ |
| `hunter_leap_away_give_up_range` | 0（def 1000） | 插件设 0 | ✅ |
| `hunter_pounce_max_loft_angle` | 0（def 45） | 插件设 0 | ✅ |
| `boomer_exposed_time_tolerance` | 10000（def 1.0） | 插件设 10000（Boomer 永不因被看到而逃） | ✅ |

### 冲锋覆盖距离计算（750 的依据）

```
覆盖 = warmup 加速段 + 全速段
  口径1（warmup 在 duration 外）: 0.5s × (250→500 线性, 平均 375) + 2.0s × 500 = 187.5 + 1000 = ~1187u
  口径2（warmup 含在 duration 内）: 0.5s × 375 + 1.5s × 500 = 187.5 + 750   = ~937u
结论: 覆盖 ≈ 940~1190u → ai_charge_proximity 750 发起完全打得到（500 反而浪费一半覆盖）
```

### 不存在的 cvar（查询确认，勿再引用）

| 名称 | 结果 | 影响 |
|------|------|------|
| `ai_ChargerChargeDistance` | Unknown command | 竞争配置（confogl/AllCharger）自创 cvar，非原版引擎。引擎对按钮路径冲锋无距离限制 |
| `ai_fast_pounce_proximity` / `ai_straight_pounce_proximity` | Unknown command | **Hunter fPounceRange 一直用 fallback 1000 / fStraightRange 200**（v3.3 注释声称已接 cvar 是虚假记录）；1000 为 v4.0.1 实战验证值，暂保持 |
| `smoker_tongue_range` / `z_tongue_range` | Unknown command | 舌头射程引擎硬编码（社区常识 ~1100u）；插件 IsInRange(850) 保守取值 ✅ |
| `hunter_pounce_interval` | Unknown command | 扑击冷却无 cvar；插件 Cooldown(1.0) 为既有实战模式 |
| `jockey_ride_*` | Unknown command | Jockey 骑乘参数非这些名字 |

---

## 二、血量 / 速度（引擎当前值，供上下文参考）

| cvar | 实测值 | 备注 |
|------|--------|------|
| `z_hunter_health` | 250 | 血量体系实际由 l4d2_si_hud 展示、l4d2_tank_unified 管 Tank |
| `z_jockey_health` | 325 | |
| `z_spitter_health` | 100 | |
| `z_charger_health` | 600 | |
| `z_tank_health` | 4000 | l4d2_tank_unified 覆盖为 存活人数×3000，最低 12000 |
| `z_witch_health` | 1500（def 1000） | 当前被改动过（Witch 血量调整入口：[[l4d2-si-health]]） |
| `z_hunter_speed` | 300 | 移动速度 u/s |
| `z_spitter_speed` | 210 | |
| `z_tank_speed` | 210 | |
| `z_common_limit` | 30 | 引擎小僵尸上限；l4d2_max_common 按人数缩放 30+6x/人，封顶 120 |

---

## 三、插件引擎数值干预清单（既成模式，改动需在此登记）

| cvar | 干预值 | 干预插件/位置 | 依据 |
|------|--------|---------------|------|
| `smoker_tongue_delay` | 1.5 → 1.0 | AI_HardSI `Smoker_OnModuleStart` | 更凶的拉人节奏 |
| `boomer_vomit_delay` | 1 → 0.1 | AI_HardSI `Boomer_OnModuleStart` | 喷吐节奏由 post-vomit 10s 自锁控制 |
| `boomer_exposed_time_tolerance` | 1.0 → 10000 | AI_HardSI `Boomer_OnModuleStart` | Boomer 永不因被看到逃跑 |
| `z_spit_interval` | 20 → 8.0 | AI_HardSI `Spitter_OnModuleStart`（v4.0.3 新增） | 对齐 post-spit 8s 自锁，消除 8-20s 无效按键 |
| `hunter_committed_attack_range` | 75 → 10000 | AI_HardSI `Hunter_OnModuleStart` | 任何距离都能 commit 扑击 |
| `hunter_leap_away_give_up_range` | 1000 → 0 | 同上 | 不因距离放弃扑击 |
| `hunter_pounce_max_loft_angle` | 45 → 0 | 同上 | 控制扑击仰角由 BT 接管 |

---

## 四、估算值 / 待验证项（当前无引擎数据支撑，改动前先验证）

| 数值 | 当前值 | 状态 |
|------|--------|------|
| Hunter 高位扑上限 `fPounceRange + 600`（1600u） | 1600 | 估算（高位 40-200u 的高度加成），方向保守（过高→sprint，无危害）；实战观察后再微调 |
| Hunter fPounceRange fallback | 1000 | 无 cvar 支撑，但 v4.0.1 出生蠕动修复实战验证过；若创建 `ai_fast_pounce_proximity` cvar 可调 |
| 冲锋覆盖口径（~940 vs ~1190u） | — | 取决于 warmup 是否计入 duration；不影响 750 结论（两口径都 ≥ 940） |
| Tank 相关数值 | — | 未实测（tank_rock_damage / tank_punch_damage 等不在本次范围）；v4.0.3 修复 5-6（Tank aggro/避障 cvar 接入）前补测 |

---

## 五、验证方法（复用）

```bash
# 空服窗口，手写 RCON 协议查询（rcon.source 库有连接 bug 不可用）
python3 - <<'EOF'
import socket, struct, time
PASS = "<rcon 密码>"
def q(cvar):
    s = socket.create_connection(('127.0.0.1', 27015), timeout=3); s.settimeout(1)
    def send(i, t, b):
        p = struct.pack('<ii', i, t) + b.encode() + b'\x00\x00'
        s.sendall(struct.pack('<i', len(p)) + p)
    send(1, 3, PASS); time.sleep(0.3)
    send(2, 2, cvar)
    data = b''
    end = time.time() + 3
    while time.time() < end:
        try: c = s.recv(8192)
        except socket.timeout: break
        if not c: break
        data += c
    s.close()
    return data.decode('utf-8', errors='replace').strip()
print(q("z_charge_interval"))
EOF
# 响应格式: "cvar" = "当前值" ( def. "默认值" ) 说明文字
```
