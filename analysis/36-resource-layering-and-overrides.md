# 36 专题：资源覆盖/映射层（resources/Server vs ExcelBinOutput）与“只改数据”的正确姿势

本文专门讲一件决定你能否高效“只改脚本/数据”的事情：  
**资源是怎么被加载的？覆盖优先级是什么？`resources/Server/` 到底是干什么的？如何用 Mapping 把 ID ↔ 配置 ↔ 脚本串起来？**

这是把 Grasscutter 当“ARPG 引擎”使用时的关键工程能力：你不掌握这套覆盖/映射层，就会陷入“改了文件没生效/不知道读的是哪份资源”的混乱。

与其他章节关系：

- `analysis/03-data-model-and-linking.md`：ExcelBin/BinOutput/TextMap 的基础 ID 映射（本文更关注“覆盖优先级与工程实践”）。
- `analysis/15-gadget-controllers.md`：GadgetMapping → 控制器脚本（本文会把它放到资源覆盖层里理解）。
- `analysis/16-reward-drop-item.md`：Server/DropTableExcelConfigData 的特殊加载路径（本文会解释为什么它放在 Server）。

---

## 36.1 三层路径：data/、resources/、scripts/（别混）

在本工作区里有三套常见目录，它们不是一回事：

1. `data/`
   - 更像“服务器运行配置/非官方表的补充数据”
   - 例：`BlossomConfig.json`、`TowerSchedule.json`、`ChestDrop.json`、`MonsterDrop.json` 等
2. `resources/`
   - 更像“游戏资源包”：ExcelBinOutput/BinOutput/Scripts/TextMap 等
3. `scripts/`（在本仓库配置为 `resources:Scripts`）
   - 实际仍在 `resources/Scripts/` 下

路径选择由 `config.json` 的 `folderStructure` 决定。

---

## 36.2 Excel 表覆盖规则：`resources/Server/` 优先于 `resources/ExcelBinOutput/`

核心入口：`Grasscutter/src/main/java/emu/grasscutter/utils/FileUtils.java`

关键函数：

- `FileUtils.getExcelPath(filename)`：
  1. 先在 `resources/Server/` 找（支持 tsj/json/tsv，优先级 tsj > json > tsv）
  2. 不存在才回退到 `resources/ExcelBinOutput/`

因此你可以把它理解成：

> `ExcelBinOutput` = 官方设计态表（基底）  
> `Server` = 服务器侧覆盖层（patch layer / hotfix layer）

### 36.2.1 这对“只改数据”的意义

- 你想改某张 Excel 表，**优先在 `resources/Server/` 放一份同名文件覆盖**  
  这样更接近“补丁”思路，且不污染基底资源。
- 你想做“快速实验/快速回滚”也更容易：删掉 Server 覆盖文件即可回退。

---

## 36.3 data/ 的覆盖规则：用户 data 优先于 jar defaults

同样在 `FileUtils`：

- `getDataPath(path)` 会先找 `data/`（用户路径），再找 jar 内置 defaults/data

这解释了为什么很多系统配置（如 BlossomConfig/TowerSchedule）建议放在 `data/`：

- 它们不是官方 Excel 表的一部分，更像“服务器策略参数”

---

## 36.4 “映射层”的概念：让 ID ↔ BinOutput 配置 ↔ 脚本组件可连接

除了 Excel 覆盖外，本仓库还有一层非常关键的 **Mapping**：

- `resources/Server/GadgetMapping.json`
- `resources/Server/MonsterMapping.json`
- `resources/Server/SubfieldMapping.json`
- `resources/Server/DropSubfieldMapping.json`
- `resources/Server/DropTableExcelConfigData.json`（注意：它放在 Server 目录并由 ResourceLoader 手动加载）

这些文件由 `ResourceLoader` 在启动时显式加载：

- `ResourceLoader.loadGadgetMappings()`
- `ResourceLoader.loadMonsterMappings()`
- `ResourceLoader.loadSubfieldMappings()`

你可以把它们理解成“服务器侧的 glue 表”：

- 官方资源里很多东西是“分散命名/分散引用”的
- Server mapping 把它们串成可运行的管线

---

## 36.5 MonsterMapping：monsterId → ConfigMonster_*.json（BinOutput/Monster）

文件：`resources/Server/MonsterMapping.json`

结构：

```json
{ "monsterId": 21010101, "monsterJson": "ConfigMonster_Hili_None_01" }
```

运行时使用点：

- `EntityMonster` 构造时会：
  - 用 monsterId 查 mapping
  - 再去 `GameData.getMonsterConfigData()` 取对应的 `ConfigEntityMonster`

这意味着：

- 你新增/替换某个 monsterId 的表现/战斗配置，通常要：
  1. 在 `resources/BinOutput/Monster/` 放一个 `ConfigMonster_*.json`
  2. 在 `resources/Server/MonsterMapping.json` 把 monsterId 指到这个配置名

---

## 36.6 GadgetMapping：gadgetId → serverController（控制器脚本）

文件：`resources/Server/GadgetMapping.json`

结构：

```json
{ "gadgetId": 70130006, "serverController": "SetGadgetState" }
```

意义：

- `serverController` 通常对应 `resources/Scripts/Gadget/<serverController>.lua`
- 引擎会把它当成“实体控制器脚本组件”挂到 gadget 实体上（详见 `analysis/15-gadget-controllers.md`）

这条映射是你实现“复杂机关行为复用”的关键：

- Lua group 脚本负责编排（什么时候触发、阶段机）
- Gadget controller 负责“这个 gadget 的实体行为”（如何响应客户端执行、定时器、伤害等）

---

## 36.7 Subfield/DropSubfield/DropTable：掉落映射为什么在 Server？

本仓库有一条比较“工程化”的做法：

- 某些与掉落相关的表（例如 `DropTableExcelConfigData.json`）不是从 ExcelBinOutput 读，而是从 `resources/Server/` 显式加载进 `GameData.dropTableExcelConfigDataMap`

原因（从工程角度理解）：

- 掉落往往是服务器侧“策略层”，需要快速热修与覆写
- 与其让它跟随官方 ExcelBinOutput，不如把它放到 Server 层当作 patch

如果你想“只改数据调掉落”，建议优先在 `resources/Server/` 修改这些映射/表（并配合 `analysis/16-reward-drop-item.md` 的掉落链路）。

---

## 36.8 资源分层的最佳实践（强烈建议你按这个做）

给你一套可复用的“分层工作流”：

1. **官方基底**：保持 `resources/ExcelBinOutput/`、`resources/BinOutput/` 尽量不动
2. **服务器覆盖**：把你要改的 Excel 表复制到 `resources/Server/` 再改
3. **ID glue**：需要把 ID 串起来时，优先改 `resources/Server/*Mapping.json`
4. **脚本编排**：玩法逻辑尽量写在 `resources/Scripts/Scene` 与 `resources/Scripts/Common`
5. **实体行为复用**：需要时用 `resources/Scripts/Gadget` 控制器
6. **运行参数**：更像服务器策略的东西放 `data/`（如 BlossomConfig/TowerSchedule/ChestDrop）

这能让你的项目更像“引擎 + 内容包 + 补丁层”，而不是“一团乱的私服资源”。

---

## 36.9 排障：我改了数据但没生效，先按这张清单查

1. **是不是改错层了？**
   - 你改了 `ExcelBinOutput`，但 `Server/` 里有同名覆盖文件 → 实际读的是 Server
2. **是不是文件扩展名优先级导致的？**
   - `tsj` 会压过 `json`，`json` 会压过 `tsv`
3. **是不是 ResourceLoader 不是用 getExcelPath 读的？**
   - 有些文件是 `getResourcePath(\"Server/...\" )` 直接读 Server（必须放 Server 才行）
4. **是不是缺了 Mapping？**
   - 你加了 `ConfigMonster_*.json`，但 MonsterMapping 没指过去 → 实体仍然拿不到 config
5. **是不是缓存/持久化状态在挡你？**
   - group instance 缓存了变量/死亡记录 → 你改脚本后看起来没变化（见 `analysis/26-entity-state-persistence.md`）

---

## 36.10 小结

- `resources/Server/` 是“覆盖层/补丁层”，优先级高于 `ExcelBinOutput`。
- `data/` 是“服务器策略数据层”，优先级高于 jar defaults。
- Mapping 文件把分散的 ID、BinOutput 配置、脚本组件串成可运行的管线，是“只改数据”的关键抓手。
- 按“基底资源 → Server 覆盖 → Mapping glue → 脚本编排”的工作流组织内容，最像一个可维护的 ARPG 引擎项目。

---

## Revision Notes

- 2026-01-31：首次撰写本专题；梳理 `resources/Server` 的覆盖优先级、data 的覆盖规则，以及 Monster/Gadget/Drop 等 mapping 的工程化用法与排障清单。

