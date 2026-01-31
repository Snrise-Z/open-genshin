# 38 专题：Shop/商店系统：`Shop.json` + `ShopGoodsExcel` → 刷新/限购/成本结算

本文把“商店（Shop）”当成 ARPG 引擎里最常见的 **经济系统模块** 来拆：  
它的本质是一个 **商品目录（Catalog）+ 价格（Cost）+ 资格门槛（Time/Level）+ 限购与刷新（Limit/Refresh）** 的组合。

与其他章节关系：

- `analysis/16-reward-drop-item.md`：商店买到的东西最终仍然是 Item 入包（ActionReason=Shop）。
- `analysis/24-openstate-and-progress-gating.md`：很多“商店是否可用”在官方通常由 OpenState/任务进度控；本仓库更多依赖客户端/UI，服务端校验偏弱。
- `analysis/36-resource-layering-and-overrides.md`：`data/Shop.json`、`data/ShopChest.v2.json` 可覆盖 jar defaults，是最常见的“只改数据”入口。

---

## 38.1 抽象模型：Shop = Catalog（商品）+ Pricing（成本）+ Policy（限购/刷新）

用中性概念描述：

- **ShopType/ShopId**：一个“商店页面/商店集合”的 ID（例如城市杂货/铁匠/礼包页…）
- **Goods**：一条商品定义（商品 id、售卖物、成本、限购、刷新规则）
- **Player Purchase Ledger（玩家购买台账）**：
  - “本周期已买多少”
  - “下次刷新时间”

本仓库的实现非常直白：**shop 数据是“商品表”，玩家侧是“限购表”**。

---

## 38.2 数据层入口：`Shop.json`（主商品表）与 Excel 注入

### 38.2.1 `data/Shop.json`：自定义商店表（最常改）

结构（从 `ShopTable/ShopInfo` 反推）：

```text
[
  {
    "shopId": <int>,
    "items": [
      {
        "goodsId": <int>,                 // 全局商品 ID（非常建议全局唯一）
        "goodsItem": { "id": <itemId>, "count": <int> },

        // 价格（3 套入口，最终会合并到 payItems）
        "scoin": <int>,                   // 通过 Mora(202) 扣
        "costItemList": [ { "id": <itemId>, "count": <int> }, ... ],
        // 下面两个通常也会以 costItemList 的形式写入，但会被“虚拟币处理”提取出来
        "hcoin": <int>,                   // 通过 itemId=201 扣（虚拟币）
        "mcoin": <int>,                   // 通过 itemId=203 扣（虚拟币）

        // 限购与有效期（注意：服务端校验并不完整，见 38.6）
        "buyLimit": <int>,                // 0 表示不限购
        "beginTime": <unixSec>,
        "endTime": <unixSec>,
        "minLevel": <int>,
        "maxLevel": <int>,

        // 刷新
        "refreshType": "SHOP_REFRESH_DAILY|WEEKLY|MONTHLY",
        "shopRefreshParam": <int>,        // 刷新间隔参数（见 38.4）

        // 依赖链（目前未见强校验）
        "preGoodsIdList": [<goodsId>, ...]
      }
    ]
  }
]
```

对应加载入口：

- `Grasscutter/src/main/java/emu/grasscutter/game/shop/ShopSystem.java` 的 `loadShop()`

### 38.2.2 `resources/ExcelBinOutput/ShopGoodsExcelConfigData.json`：可选“Excel 注入”

当配置 `Configuration.GAME_OPTIONS.enableShopItems=true` 时，`ShopSystem.loadShop()` 会额外把：

- `ShopGoodsExcelConfigData.json`（`ShopGoodsData`）

按 `shopType` 分组注入到 `shopData` 中（相当于“官方表”+“自定义表”合并）。

这非常适合两种玩法：

1. 你完全依赖 ExcelBinOutput 做商店（减少手写 `Shop.json`）
2. 你把 `Shop.json` 当成“自定义补丁”，只写少量你要新增的 goods

### 38.2.3 `data/ShopChest.v2.json`：礼包/箱子的“打开产出表”

注意：这不是 Shop.json 的子表，而是“某些道具打开时给什么”的表。

- 加载：`ShopSystem.loadShopChest()` 读 `ShopChest.v2.json`（key=int chestId, value=string）
- 使用：`ItemUseOpenRandomChest`（见 38.5.2）

`ShopChest.v2.json` 的 value 是一种紧凑 DSL：

```text
{
  "<chestId>": "104002:40,202:30000, ...",
  ...
}
```

> 你工作区顶层也可能存在 `data/ShopChest.json` 等旧格式文件，但当前代码路径使用的是 `ShopChest.v2.json`（若用户目录没有，会回退到 jar defaults）。

---

## 38.3 引擎侧关键链路：加载 → 下发商品 → 购买扣款 → 记录限购

### 38.3.1 Shop 的内存结构：`ShopSystem.shopData`

文件：`Grasscutter/src/main/java/emu/grasscutter/game/shop/ShopSystem.java`

- `shopData: Map<shopId, List<ShopInfo>>`
- `shopChestData: Map<chestId, List<ItemParamData>>`

加载时会做一个重要动作：

- `shopTable.getItems().forEach(ShopInfo::removeVirtualCosts)`

也就是把 `costItemList` 中的 `201/203` 抽出来，转存到 `hcoin/mcoin` 字段（见 38.5）。

### 38.3.2 获取商店列表：`PacketGetShopRsp`

文件：`Grasscutter/src/main/java/emu/grasscutter/server/packet/send/PacketGetShopRsp.java`

做了三件事：

1. 把 `ShopInfo` 转成 proto `ShopGoods` 下发（包含价格、限购、时间、等级等）
2. 计算每个 goods 的 `nextRefreshTime`（见 38.4）
3. 绑定/更新玩家的 `ShopLimit`（如果没有就创建一条，确保刷新时间被持久化）

### 38.3.3 购买请求：`HandlerBuyGoodsReq`

文件：`Grasscutter/src/main/java/emu/grasscutter/server/packet/recv/HandlerBuyGoodsReq.java`

关键逻辑（强烈建议你把它当“经济扣款的最小闭环”来研究）：

1. **定位商品**：
   - `configShop = shopData.get(shopType)`
   - `goodsId` 在 list 里找 `ShopInfo`
2. **读取玩家限购台账**：`player.getGoodsLimit(goodsId)`
   - 若已过期：刷新 `nextRefreshTime`
   - 否则：取 `hasBoughtInPeriod`
3. **校验 buyLimit**：
   - `buyLimit==0` 视为不限购
4. **构造成本并扣款**：
   - `costItemList + Mora(202)*scoin + Hcoin(201)*hcoin + Mcoin(203)*mcoin`
   - `player.getInventory().payItems(costs, buyCount)`
5. **写回台账**：`player.addShopLimit(goodsId, buyCount, nextRefreshTime)`
6. **发放商品**：
   - `new GameItem(goodsItemId, buyCount * goodsItemCount)`
   - `player.getInventory().addItem(item, ActionReason.Shop, true)`

---

## 38.4 刷新语义：GMT+8 每天 4 点为锚（Daily/Weekly/Monthly）

刷新计算入口：

- `ShopSystem.getShopNextRefreshTime(ShopInfo)`

固定参数：

- `REFRESH_HOUR = 4`
- `TIME_ZONE = "Asia/Shanghai"`（GMT+8）

时间计算函数在：

- `Grasscutter/src/main/java/emu/grasscutter/utils/Utils.java`
  - `getNextTimestampOfThisHour(hour, tz, param)`（日刷）
  - `getNextTimestampOfThisHourInNextWeek(...)`（周刷，以周一为锚）
  - `getNextTimestampOfThisHourInNextMonth(...)`（月刷，以每月 1 号为锚）

### 38.4.1 `shopRefreshParam` 的含义（从实现反推）

这些函数都会循环 `param` 次“推进到下一次刷新点”：

- `param=1`：下一次刷新
- `param=2`：下下次刷新

因此它更像“刷新间隔倍率”（隔天/隔周/隔月）而不是“星期几/几号”。

### 38.4.2 限购记录是“按 goodsId 记账”，不是按 shopId

玩家侧持久化结构：

- `Player.shopLimit: List<ShopLimit>`
- `ShopLimit.shopGoodId`（注意名字：是 goodsId）
- `hasBoughtInPeriod` + `nextRefreshTime`

这意味着：

- 同一个 `goodsId` 即使出现在多个商店里，也会共享限购与刷新台账  
  （建议你设计时避免重复 goodsId）

---

## 38.5 成本与“虚拟货币”处理：`201/202/203` 的三套扣款入口

### 38.5.1 `ShopInfo.removeVirtualCosts()`：把 costItemList 里的虚拟币拆出来

文件：`Grasscutter/src/main/java/emu/grasscutter/game/shop/ShopInfo.java`

它会扫描 `costItemList`：

- `id==201` → 累加到 `hcoin`
- `id==203` → 累加到 `mcoin`

并把这些条目从 `costItemList` 删除。

因此在 `Shop.json` 里你既可以：

- 直接写 `hcoin/mcoin` 字段
- 也可以写进 `costItemList`（会被提取出来）

### 38.5.2 “礼包/箱子”是通过 ItemUseAction 实现的：`ItemUseOpenRandomChest`

文件：`Grasscutter/src/main/java/emu/grasscutter/game/props/ItemUseAction/ItemUseOpenRandomChest.java`

- 道具 useParam 携带 `chestId`
- 使用时去 `ShopSystem.getShopChestData(chestId)`
- 把解析出的 `ItemParamData` 转成 `GameItem` 发放

也就是说：**你可以把“付费礼包/开箱”完全做成一个数据驱动的 item**，不用写 Lua。

---

## 38.6 “只改数据”能做什么？（以及当前实现的校验缺口）

### 38.6.1 只改数据就能做

1. **新增/修改商店页面**：改 `data/Shop.json`
   - 新增一个 `shopId`
   - 配置 `items` 列表
2. **做周期性限购**：给 goods 配 `buyLimit + refreshType + shopRefreshParam`
3. **做“时间窗口商品”**：填写 `beginTime/endTime`（注意见下条）
4. **做礼包**：用 `Shop.json` 卖一个“礼包道具”，礼包道具本身用 `ShopChest.v2.json` 配产出

### 38.6.2 需要特别注意：购买侧的服务端校验并不完整

`HandlerBuyGoodsReq` 目前主要校验：

- goodsId 是否存在于该 shop 的列表中
- buyLimit 是否超
- 扣款是否成功

但它 **没有严格校验**（至少在当前代码中未看到）：

- `beginTime/endTime` 是否在有效期
- `minLevel/maxLevel` 是否满足
- `preGoodsIdList` 的前置依赖是否满足

结论：如果你要把它当成一个更严谨的“线上经济系统”，这些校验属于典型的引擎边界；  
如果你是私有实验环境，通常可以接受“客户端 UI 自己约束”。

---

## 38.7 小结

- Shop 系统的“玩法编排层”主要是 `data/Shop.json` 与（可选）`ShopGoodsExcelConfigData.json`：它们定义了“卖什么/多少钱/限购怎么刷”。
- 玩家侧只有一个很薄的持久化层：`ShopLimit(goodsId → boughtInPeriod/nextRefreshTime)`。
- `ShopChest.v2.json + ItemUseOpenRandomChest` 给了你一个非常通用的“礼包/箱子”范式：**把复杂奖励发放从商店购买里剥离出去**，让商店只负责“卖一个可打开的道具”。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理 `Shop.json/ShopGoodsExcel → ShopSystem → GetShopRsp/BuyGoodsReq → ShopLimit 刷新语义`，并补充 `ShopChest.v2.json` 作为“礼包打开表”的可复用范式。

