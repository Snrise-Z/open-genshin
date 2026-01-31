# 54 专题：GM Handbook/管理控制台：HTTP UI → 认证（sessionKey）→ 动作执行（grant/give/teleport/spawn）→（可选）Dispatch 转发

本文把 GM Handbook 当成一个“控制面（Control Plane）”模块来研究：  
它不是玩法编排层本身，但它极大影响你研究/调试玩法的效率，并提供了一套可复用的模式：

> 外部工具（网页/UI）→ 鉴权 → 发送管理动作 → 服务端执行并修改玩家状态 → 返回结果

这套模式对你未来“把项目当 ARPG 引擎来用”非常重要：你一定会想要自己的内容编辑器、GM 面板、调试命令、自动化测试工具。

与其他章节关系：

- `analysis/36-resource-layering-and-overrides.md`：Handbook UI 本身是静态资源（HTML），属于“资源覆盖层”的一部分。
- `analysis/52-mail-system.md`：GM 工具常与“发邮件/发奖励/发物品”联动；本仓库的 Handbook 已支持 give item。
- `analysis/55-player-tick-and-daily-reset.md`：Handbook 的动作最终修改的是玩家状态（背包/位置/角色），这些状态会被 tick/同步系统持续推送给客户端。

---

## 54.1 模块入口：`HandbookHandler` 提供 `/handbook` 与控制 API

文件：`Grasscutter/src/main/java/emu/grasscutter/server/http/documentation/HandbookHandler.java`

它在 HTTP Server 启动时被注册（见 `Grasscutter.java` 中的 router 注册）。

路由（简化）：

- `GET /handbook`：返回 handbook HTML（`/html/handbook.html`）
- `GET /handbook/authenticate`：返回认证页面（由 authenticator 渲染）
- `POST /handbook/authenticate`：执行认证
- 控制动作（POST）：
  - `/handbook/avatar`：grant avatar
  - `/handbook/item`：give item
  - `/handbook/teleport`：teleport to scene
  - `/handbook/spawn`：spawn entity

控制动作是否可用由配置决定：

- `HANDBOOK.enable && HANDBOOK.allowCommands`

并且有基础限流：

- `HANDBOOK.limits.enabled` 时按 IP 统计请求次数（每 interval 秒清零）
- `/handbook/spawn` 额外限制一次请求的实体数量（`maxEntities`）

---

## 54.2 配置：`GameOptions.HandbookOptions`

文件：`Grasscutter/src/main/java/emu/grasscutter/config/ConfigContainer.java`

关键字段：

- `enable`：是否启用 Handbook 服务
- `allowCommands`：是否允许执行控制命令
- `limits`：
  - `enabled/interval/maxRequests/maxEntities`
- `server`：
  - `enforced/address/port/canChange`

`HandbookHandler` 构造时会把 `server.*` 注入 HTML 模板（替换占位符），用于在 UI 上锁定/展示默认服务器地址端口。

---

## 54.3 认证：Handbook 的“token”其实就是玩家 sessionKey

### 54.3.1 Authenticator：`HandbookAuthentication`

文件：`Grasscutter/src/main/java/emu/grasscutter/auth/DefaultAuthenticators.java`（内部类 `HandbookAuthentication`）

它会加载：

- `/html/handbook_auth.html`

并实现两步：

1. `presentPage`：展示认证页面  
   - 在 HYBRID 模式下，会尝试按 IP 找到在线玩家并“自动填入 session token”
2. `authenticate`：处理表单提交  
   - 读取 `playerid`
   - 调 `DispatchUtils.fetchSessionKey(uid)` 获取 sessionKey
   - 把 token + playerId 渲染进 auth 页面返回给 UI

### 54.3.2 权限判定：`HandbookActions.isAuthenticated`

文件：`Grasscutter/src/main/java/emu/grasscutter/game/HandbookActions.java`

判定非常直接：

- `player.getSessionKey().equals(token)`

因此你可以把 GM Handbook 的认证抽象为：

> “证明你能拿到该玩家的 sessionKey”。

在私有环境里这足够用于调试；若用于更严肃的环境，需要更强的鉴权与审计（超出本文范围）。

---

## 54.4 动作执行：`HandbookActions` 四个内建动作（可复用范式）

请求体对象定义在：

- `Grasscutter/src/main/java/emu/grasscutter/utils/objects/HandbookBody.java`

动作枚举：

- `GRANT_AVATAR / GIVE_ITEM / TELEPORT_TO / SPAWN_ENTITY`

### 54.4.1 Grant Avatar（发角色）

`HandbookActions.grantAvatar(GrantAvatar request)`：

- 解析 playerId 与 avatarId
- 校验 token
- `new Avatar(avatarData)` 并设置等级/命座/技能等级
- `player.addAvatar(avatar)` 并发 `PacketAddNoGachaAvatarCardNotify`

### 54.4.2 Give Item（发物品）

`HandbookActions.giveItem(GiveItem request)`：

- 解析 itemId，校验 token
- 支持 `amount` 超过 int 上限时拆分为多次入包（每次 `Integer.MAX_VALUE`）
- `player.inventory.addItem(new GameItem(itemData, amount), ActionReason.Gm)`

### 54.4.3 Teleport（传送）

`HandbookActions.teleportTo(TeleportTo request)`：

- 解析 sceneId，校验 token
- 找 `player.world.getSceneById(sceneId)`
- `world.transferPlayerToScene(player, sceneId, defaultPosition)`
- 设置 rotation

### 54.4.4 Spawn Entity（刷怪）

`HandbookActions.spawnEntity(SpawnEntity request)`：

- 解析 entityId（怪物类型 id），校验 token
- 校验 level 1..200
- 循环 `amount` 次 `new EntityMonster(scene, entityData, pos, rot, level)` 并 `scene.addEntity`

这些动作共同构成一个非常清晰的“管理动作范式”：

1. 解析输入
2. 定位玩家（在线玩家对象）
3. 校验 token
4. 执行状态变更
5. 返回 Response(status/message)

---

## 54.5 Dispatch 转发：同一套动作既可本地执行，也可通过 DispatchServer 广播

`DispatchUtils.performHandbookAction`（文件：`Grasscutter/src/main/java/emu/grasscutter/utils/DispatchUtils.java`）会根据运行模式选择执行路径：

- `DISPATCH_ONLY`：
  - 构造 `GmTalkReq`（action + data）
  - 通过 DispatchServer 广播
  - 等待 `GmTalkRsp` 回来（5 秒超时）
- `HYBRID / GAME_ONLY`：
  - 直接在本地 switch 调 `HandbookActions.*`

`DispatchClient`（文件：`Grasscutter/src/main/java/emu/grasscutter/server/dispatch/DispatchClient.java`）也实现了对 `GmTalkReq` 的处理：

- 解码 action/data
- 本地执行 `DispatchUtils.performHandbookAction`
- 回发 `GmTalkRsp`

这本质是在展示一种“控制面命令的跨进程转发模型”：

> 控制台只需要面向 Dispatch；真正执行在 GameServer 节点上完成。

---

## 54.6 “GM Handbook（文本手册）”生成：`Tools.createGmHandbooks`

根目录存在 `GM Handbook/` 文件夹（以及 `Tools` 的生成逻辑）。

文件：`Grasscutter/src/main/java/emu/grasscutter/tools/Tools.java`

`createGmHandbooks()` 会：

1. `ResourceLoader.loadAll()` 加载全部资源（Item/Avatar/Monster/Quest/TextMap…）
2. 按多语言 TextMap 生成一个大 txt：
   - Commands
   - Avatars
   - Items（含 itemUse 信息的展示/分类）
   - Monsters
   - Scenes（scriptData）
   - Quests
   - Achievements
3. 输出到 `./GM Handbook/GM Handbook - <lang>.txt`

它虽然不是“网页 Handbook 控制台”的一部分，但对你做内容研究非常实用：

- 可以快速查到 id→名称（跨语言）
- 作为脚本/配表编写时的索引工具

---

## 54.7 可扩展性：如果你要加一个新的 Handbook 动作，需要改哪里？

把它当作“可复用控制面范式”，新增动作通常涉及：

1. `HandbookBody.Action` 增加枚举项 + request body class
2. `HandbookHandler` 增加 HTTP 路由（POST）并 `ctx.bodyAsClass(...)`
3. `DispatchUtils.performHandbookAction` 增加 case（本地执行）
4. `HandbookActions` 增加具体实现（并统一 token 校验）
5. 若走 dispatch：`DispatchClient.handleHandbookAction` 增加 action→decode 映射

这套路径非常适合作为你未来自研编辑器/调试面板的模板。

---

## 54.8 小结

- GM Handbook 是控制面模块：它把“管理动作”做成 HTTP API + 网页 UI，并用 sessionKey 做轻量鉴权。
- 同一套动作支持本地执行与 Dispatch 转发，体现出“多进程/多节点控制面”的通用设计。
- 对“把项目当 ARPG 引擎”的目标而言，这一模块的最大价值不是玩法本身，而是：它提供了一个可复用的外部工具接入范式。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理 Handbook 的 HTTP 路由、认证方式、四个内建动作与 Dispatch 转发模型，并总结新增动作的扩展路径。

