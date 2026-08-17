---
name: l4d2-spray-tool-specs
description: L4D2 喷漆技术规格（分辨率、格式、路径、大小限制），社区验证结论
metadata: 
  node_type: memory
  type: reference
  originSessionId: 1e3e6ebb-3405-4052-8d73-33dc2b378794
---

## 数据来源

2026-07-22 通过代理检索，三个主要来源交叉验证：

| 来源 | 类型 | 可信度 |
|---|---|---|
| **Mishcatt** (rafradek/Mishcatt) | 最流行的在线 VTF 喷漆转换器，社区事实标准 | ⭐⭐⭐ |
| **L4D2-spray-generator-1024x1024** (hantentohka) | GitHub 开源工具，专门针对 L4D2 | ⭐⭐⭐ |
| **Steam 讨论** (app/550, Oct 2023) | 多个用户验证确认 | ⭐⭐ |

## 分辨率

- **必须为 2 的幂次方**：128, 256, 512, 1024
- **宽高可不同**：如 512×256、1024×256 均可（非正方形支持）
- **最大**：1024×1024（Mishcatt 默认 `width=1024, height=1024`，GitHub 工具仓库名直接命名为 "-1024x1024"）
- **最小**：128×128
- 当前工具仅支持 128/256/512，可扩展至 1024

## 文件大小限制

- **L4D2 多人游戏传输限制 ~512KB**（硬限制，非 Source 引擎限制）
- GitHub 工具代码显式约束：`while current_frame_count * frame_size_KB > 511`（511KB 上限）
- 各分辨率单帧参考大小（DXT1）：
  - 128×128 ≈ 9 KB
  - 256×256 ≈ 34 KB
  - 512×512 ≈ 130 KB
- BGRA8888 512×512 ≈ 1MB，可能超限；DXT5 ≈ 256KB，安全

## 支持格式

所有三个来源确认：

| 格式 | imageFormat | 压缩 | 质量 | 适用场景 |
|---|---|---|---|---|
| DXT1 | 13 | 高（8B/4×4块） | 低，仅1-bit alpha | 无透明需求，控制体积 |
| DXT5 | 15 | 中（16B/4×4块） | 中，完整 alpha | 有透明通道，体积敏感 |
| BGRA8888 | 12 | 无（4B/像素） | 最高 | 追求质量，体积不敏感 |

**当前工具默认 BGRA8888**，优先保障画质正确性。

## 安装路径（社区标准）

**Mishcatt 官方 VMT 模板**采用：

```
VMT $basetexture: "vgui/logos/spray"
VTF 位置:   <L4D2>/left4dead2/materials/vgui/logos/spray.vtf
VMT 位置:   <L4D2>/left4dead2/materials/vgui/logos/spray.vmt
```

**目录结构**（基于实际游戏安装）：
- `materials/vgui/logos/` — 喷漆主目录，VTF+VMT 放这里
- `materials/vgui/logos/ui/` — 游戏自带，喷漆选择器预览缩略图
- `materials/vgui/logos/custom/` — 部分用户自建，用于隔离自定义喷漆（非官方要求）

**结论：直接放 `logos/` 下，VMT 里写 `vgui/logos/{name}`**，与社区标准一致。

## VMT 模板

```vtf
"UnlitGeneric"
{
    "$basetexture" "vgui/logos/spray"
    "$translucent" "1"
    "$ignorez" "1"
    "$vertexcolor" "1"
    "$vertexalpha" "1"
}
```

不包含 `$spray` 或 `%keywords`（Mishcatt 也不包含这些非标准参数）。

## VTF 头关键参数

- **版本**：v7.0（`07 00 00 00`），部分工具标为 v7.2（向后兼容 v7.0）
- **FLAG_NOMIP** (0x80)：喷漆不需要 mipmap
- **FLAG_NOLOD** (0x100)：不需要 LOD
- **mip_count**：1（仅完整分辨率层）

## 对工具的影响

1. **路径**：已统一为 Mishcatt 标准 `vgui/logos/{name}`，不再使用 `logos/custom/`
2. **分辨率**：可考虑加 1024 选项，当前 128/256/512 已覆盖主流
3. **格式**：BGRA8888 默认正确，但需提示用户超过 512×512 时 BGRA8888 可能超 512KB 限制
4. **编码修复**：之前的 DXT c0/c1 swap bug 已修复，改用 BGRA8888 默认 + mip_count=1

## 相关记忆

- [[l4d2-map-download-server]] — 地图下载站，同属 Web 工具
- [[l4d2-deployment-rules]] — L4D2 通用部署规则
