---
name: l4d2-cl-downloadfilter-none
description: 客户端 cl_downloadfilter none 导致永不下载自定义音效/文件（服务端 EmitSound 报 missing from disk），默认是 all
metadata: 
  node_type: memory
  type: pitfall
  originSessionId: 866c8f85-5fab-4830-987f-ed0da0dcea7c
  modified: 2026-07-31T17:00:38.765Z
---

# L4D2：cl_downloadfilter none → 客户端永不下载（2026-08-01 实锤）

## 症状链（芙芙猫猫糕无声完整根因）

- 服务端 EmitSoundToClient 一切正常（precache 8/8、FastDL 200），但该玩家
  `SIS_StartSound: Failed to load sound 'battlefield\si_kill.mp3', file probably
  missing from disk/repository`
- nginx 日志：该玩家 **0 次** mp3 下载请求（唯一有下载记录的始终是
  171.213.246.40 用户本人）
- 玩家本地 `sound/battlefield/` 文件夹**根本不存在**（排除残留文件跳过下载）

## 根因

客户端 `cl_downloadfilter` = **"none"**（"Determines which files can be
downloaded from the server (all, none, nosounds)"）→ **禁止下载服务器任何
文件**。下载决策 100% 发生在客户端本地：服务器广播下载表（邀请），客户端
对比本地文件存在性后才发起 HTTP 请求；`none` 直接不响应邀请 → nginx 永远
看不到请求。

**默认值是 "all"**——设为 none 是被玩家自己/优化教程改的（防"下载垃圾"）。

## 修复

```
cl_downloadfilter all   （控制台，客户端设置）
```
完全退出客户端重进服 → 自动下载 → 有声。若需持久化写入 config.cfg。

## 排查方法论（可复用）

1. 确认玩家**确实在我们的服上**（其报错路径 battlefield/... 是特征）
2. nginx 按 IP 分组（UA "Half-Life 2"）——只有用户 IP 有下载 = 其他人都没
   请求过
3. 有文件夹没请求 → 残留文件跳过（[[l4d2-sv-allowdownload-pitfall]]）
4. 没文件夹没请求 → **cl_downloadfilter** 或 80 端口网络不通（浏览器直测
   http://IP/l4d2_fastdl/ 区分）

## 关联

- [[l4d2-sv-allowdownload-pitfall]] — 残留文件跳过下载（有文件不请求）
- [[l4d2-bf-killfeedback]] — 音效插件（v4.4.0 CS:GO 音效，实测通过）
- 客户端"零操作"愿景的边界：下载开关在玩家手里，服务端无法强制
