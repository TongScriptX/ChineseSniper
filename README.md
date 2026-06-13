# ChineseSniper

执行器脚本，用于查找当前 `PlaceId` 下亚太地区中人数最多的公开服务器并跳转。

## 文件

- `apac_server_hop.lua`: 主脚本

## 工作方式

1. 调用 `games.roblox.com` 拉取公开服务器列表，按人数从高到低扫描。
2. 对候选服务器调用 `gamejoin.roblox.com/v1/join-game-instance`。
3. 从 `joinScript.DataCenterId` 推断服务器所在机房。
4. 只保留 APAC 机房，并跳转到人数最多且未满的目标服。

## 说明

- 这是执行器脚本，不是标准 Roblox Studio 内的 `LocalScript`。
- 当前映射覆盖公开资料中常见的 `Singapore`、`Tokyo`、`Mumbai`、`Sydney`、`Osaka`。
- `Hong Kong`、`Taiwan` 没有稳定公开映射时，默认不参与筛选。
