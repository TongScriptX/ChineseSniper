# ChineseSniper

执行器脚本，用于查找当前 `PlaceId` 下高人数且低延迟的公开服务器并跳转。

## 文件

- `apac_server_hop.lua`: 主脚本

## 工作方式

1. 调用 `games.roblox.com` 拉取公开服务器列表。
2. 只使用公开接口里的 `playing`、`ping`、`fps` 字段做筛选。
3. 优先选择低延迟且 FPS 正常的服务器。
4. 在符合条件的服务器里优先跳转到人数更多的目标服。

## 说明

- 这是执行器脚本，不是标准 Roblox Studio 内的 `LocalScript`。
- 如果报错类似 `[MessageError] ... attempt to call a nil value`，通常表示脚本被放进了 Roblox `LocalScript` 环境，执行器提供的 `request/http_request` API 不存在。
- Roblox 当前这条地区探测方案会返回 `401`，因此这里改为只用公开接口做“低延迟高人数”近似筛选。
- 这能明显减少卡顿，但无法再精确断言 `Hong Kong`、`Taiwan`、`Singapore` 这类具体机房名称。
