---
name: l4d2-m14ebr-asset-audit
description: M14 EBR Mod (Workshop 3605508625) 资产审计——材质/模型/音效清单及独立化方案
metadata:
  node_type: memory
  type: reference
  tags:
    - l4d2
    - m14ebr
    - weapon-model
    - material
    - asset-migration
  originSessionId: suli-m14ebr-poc
  modified: 2026-08-20T01:00:00.000Z
---

# M14 EBR Mod (3605508625) 资产审计

## 概述
完整 model replacement mod，通过覆盖原版 SG552 路径实现武器替换。
**关键发现：完整模型替换——FP MDL(817KB) 含自有 M14 EBR 3D mesh + SG552-compatible animations。**
- FP MDL: 817KB, MDL v53, 20+ L4D2 sequences (ACT_VM_IDLE/RELOAD/DEPLOY/PRIMARYATTACK/MELEE/HELPINGHAND/ITEMPICKUP)
- TP MDL: 6.8KB, stub model (idle + 1 材质引用)
- $cdmaterials = weapons\DeltaForce\M14EBR(SG552)\
- 作者已将 M14 EBR mesh 编译为 SG552 兼容动画 → 天然兼容 vanilla 状态机

## 文件位置
解包路径：`/home/administrator/l4d2-custom-weapon-poc/m14ebr/`
审计报告：`/home/administrator/l4d2-custom-weapon-poc/docs/m14ebr_asset_audit.md`

## 模型（使用原版 SG552 路径）
```
models/v_models/v_rif_sg552.mdl/vvd/dx90.vtx     ← FP（实际 M14 EBR 网格）
models/w_models/weapons/w_rifle_sg552.mdl/vvd/dx90.vtx/phy  ← TP
```

## 材质（23 VMT + 49 VTF）
位于 `materials/weapons/deltaforce/m14ebr(sg552)/`

### Shader 效果
- 全部使用 VertexLitGeneric
- Phong: $phong=1, $phongboost=1~3.25, $phongexponenttexture
- Rim Light: $rimlight=1, $rimlightexponent=100
- Env Map: $envmap=env_cubemap, $envmaptint=[0.012~0.119]
- Self-Illum: $selfillum=1（大部分材质）
- Normal Map: $bumpmap（全部材质）
- Detail: $detail=specular（部分材质）

### 材质清单
| 材质名 | 用途 | 特殊 |
|--------|------|------|
| han_m14_ebr_072 | 枪身 | color2=[0.8 0.8 0.8] |
| rec_dmr_m14_034 | 机匣 | — |
| bar_m-600_m14long_085 | 枪管 | — |
| mag_76251_30_m14large_099 | 弹匣 | — |
| sto_a_m14ebr_101 | 枪托 | — |
| pisg_a_m14ebr_051 | 握把 | — |
| mou_hydra_029 | 前握把 | — |
| mou_common_025 | 通用附件 | — |
| muz_m-c_arcompensator_081 | 枪口 | — |
| sco_re_sro_036 | 瞄准镜 | 含 glass_ui 子材质 |
| dev_lam_dbal-x2_007 | 激光 | — |
| bullets_762x51_862 | 7.62mm 弹药 | selfillum + detail |
| bullets_58x42_875 | 5.8mm 弹药 | 路径错误⚠️ |
| frog_pic_hera-cqr_005 | 前护木 | — |
| other_kacrailcover | 导轨护盖 | — |
| other_mlok-rail | M-LOK 导轨 | — |
| other_quickdraw_black | 快拔套 | — |
| magfollower_76239_003 | 弹匣底板 | — |
| specular | 通用高光 | 被其他 VMT 引用 |

### 材质路径问题
1. `bullets_58x42_875.vmt` — $basetexture 包含双重路径拼接错误
2. `bullets_762x51_862.vmt` — $detail 引用跨路径 specular

## 音效（7 文件，原版 SG552 路径）
```
sound/weapons/sg552/gunfire/sg552-1.wav
sound/weapons/sg552/gunfire/sg552-1_incendiary.wav
sound/weapons/sg552/gunother/sg552_deploy.wav
sound/weapons/sg552/gunother/sg552_boltpull.wav
sound/weapons/sg552/gunother/sg552_boltpullforward.wav
sound/weapons/sg552/gunother/sg552_clipin.wav
sound/weapons/sg552/gunother/sg552_clipout.wav
```

## 独立化目标路径
```
models/suli/weapons/m14ebr/v_m14ebr.mdl
models/suli/weapons/m14ebr/w_m14ebr.mdl
materials/suli/weapons/m14ebr/*.vmt + *.vtf
sound/suli/weapons/m14ebr/*.wav
```

## 独立化步骤
1. 重命名模型文件到 suli/ namespace
2. 反编译 MDL → 修改 $cdmaterials → 重新编译（如需要）
3. 修改 23 个 VMT 的材质路径引用
4. 修复 bullets_58x42_875.vmt 路径错误
5. 迁移音效到 suli/ namespace
6. Precache 所有新路径资源
