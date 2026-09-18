# JackpotHood 主网上线前全面审计报告（2026-09-11）

> 范围：core（JackpotHood.sol）、Perks、Genesis NFT、Token（mock）、DEX；线上 API 全功能核对；
> 不变量测试套件扩充；测试网新 core 真实生命周期端到端。
> 方法：五路并行（合约精读 ×2 + 不变量扩充 + 线上 API 核对 + 链上 E2E），所有标记「确认」的问题均有 PoC 实证。
> 结果：**确认缺陷已全部修复并重新部署 V4.2**（core `0xCD8726B6b3479fBe7415B8550d6Eb689e2950cc9`，块 117716742），
> 修复后 forge **73/73 全绿**（invariant 128,000 calls/条 0 revert）。
> 测试网当前核心指标：详见文末「测试网运行数据」。

---

## 0. 结论摘要

- **无 Critical**。**2 High + 2 Medium 确认缺陷已修复**（V4.2），另有 1 项 High 级主网前置条件（_stakers 女巫面）已缓解。
- **测试基建重大发现**：09-08 就位的 invariant 套件此前是**空转**的（handler 下溢 bug 导致轮次永不结算，
  派彩/滚存/共担从未真正执行过，一直是 vacuous pass）——已修复 handler 并加反 vacuity 回归测试，
  现 invariant 真实结算真实派彩。
- **线上 API 十项全过**：/api/state、/api/round、/api/mytickets、/api/leaderboard、/api/me、/health 等
  与链上直读逐字段一致（API 审计 D 报告逐字段核对表见附录）。
- **链上生命周期 9 步全过**（质押往返/单张/批量 200 组/赠票/免费额度/开奖/领奖/分红/JPH 质押记账）。

---

## 1. 已修复的确认缺陷（V4.2，全部 PoC 实证 + 修复后回归）

### H-1（High）：settle 滚存与兑付扣减口径矛盾（phantom rollover）——已修复
- **位置**：`_settle`（滚存缩放 + 兑付扣减 + 缩水块）
- **问题**：空档滚存按 `rollover × prizePool/(prizePool+stakeCash)` 缩放（隐含现金按比例消耗），但兑付是
  ticketBank 优先全额扣。有中奖且 stakeCash>0 时每轮记入无现金支撑的滚存（phantom ≈ W×S/(P+S)）；
  缩水块 `rollover += cut` 在穿仓时同样无现金。PoC：全额退出场景合约资不抵债 1.14 ETH；
  测试网参数下 phantom 比例 ≈97%（这就是早前"奖池 1.39、ticketBank=0"虚高显示的成因）。
- **修复**（选项 b，保持"bank 优先、缺口共担"语义）：
  ① 缩水块删除 `rollover += cut`（穿仓削减额直接核销，这正是缩水含义）；
  ② `_creditPrize` 前加守恒帽 `if (rollover > ticketBank) rollover = ticketBank;`
  （记入滚存 ≤ 票款现金留存，归纳不变量 pendingRollover ≤ ticketBank 恒成立）；
  ③ 原有 prizePool 占比缩放保留。
- **回归**：`test_RolloverCappedByRetainedBank`（帽恰好绑死、phantom=0）、`test_JackpotBustNoPhantomRollover`
  （穿仓后无裸滚存、余额精确覆盖负债、头奖照常兑付）、`test_ShrinkCutNotRolled`（削减额不滚存）。

### H-2（High，可用性）：_stakers 只增不减 → 粉尘质押女巫可瘫痪结算——已缓解
- **问题**：settle 双循环遍历 _stakers（实测 23.2k gas/质押者），无最低质押额、数组永不清除；
  按 ~50M 单 tx 上限约 1,030 个 1-wei 粉尘地址即可永久瘫痪 settle。
- **修复**：`MIN_STAKE = 0.01 ether`（仅首次质押要求）；全额赎回即 swap-pop 移除
  （新增 `_stakerIndexPlusOne` 索引映射）；攻击成本变为 0.01 ETH × 数千地址且数组可收缩。
- **回归**：`test_MinStakeAndStakerSwapPop`（下限/追加/移除/再质押/换位者赎回全覆盖）。
- **残留说明**：数千个 ≥0.01 ETH 真实质押仍可能接近单 tx 上限；主网如需更高冗余，
  把共担/分红循环改分页是后续工程项（见 §3 主网清单）。

### M-1（Medium）：voidRound 把 10% 抽水双重承诺——已修复
- **问题**：`_voidedOwed += ticketRevenue + ticketFee`，但退款只按全款（=ticketRevenue）实退；
  fee 部分预留永不灭失，同时 fee 现金又滚入下轮奖池——一笔现金两处承诺。
  PoC：作废并全额退款后合约余额=0 但 pendingRollover=0.01。
- **修复**：`owed` 只计 `ticketRevenue`；`_voidedOwed` 改 public 以便直接断言。fee 滚存保留（有意设计）。
- **已知残留（有界、有语义依据）**：作废轮全员退款时 fee 滚存无专属现金背书，规模上界=作废轮 10% 抽水；
  彻底消除需改为 fee 不滚存（改变经济语义，未采纳）。

### M-2（Medium）：免费票三条路径缺数字/注数校验——已修复
- **问题**：freeTicket/redeemFreeTickets/redeemPerkExternal 均未校验每位 ≤9 与 count 合法；
  非法票 _comboOf ≥1e6 落在统计桶之外但可判中 1-5 档 → 同档重复兑付（tierClaimed>tierPots）
  且该轮 sweepUnclaimed 永久 revert（PoC 实证：非法票多领 0.24 ETH + sweep 卡死）。
- **修复**：校验下沉到 `_record`（一处覆盖全部六条入口）：count ∈ [1, MAX_UNITS_PER_BUY]、每位 ≤ 9。
- **回归**：FreeTicketAtomicity +2（三条免费入口非法数字/非法注数均 revert 且额度不扣）。

### 顺带修复
- `setPerkContract` 新增 `PerkContractUpdated` 事件（外围审计 M-1 的最小缓解；主网仍建议多签+时间锁）。
- core 头部注释旧分档模型（"≥1k:1/…"）更正为现行线性规则（每 10 万 JPH=1 张/天、上限 3 张）。

## 2. 未修的确认项（低危/产品面，主网清单跟踪）

| 项 | 级别 | 内容 | 处置 |
|---|---|---|---|
| Perks 日界快照 | Low | 跨 UTC 0 点质押数秒即得 1 天免费票额度 | 受 MAX_STORED_PERK=3 与摩擦限制，主网改秒级线性或满 24h 起算 |
| NFT 未注资可开售 | Low | mint 不校验配额偿付能力，owner 误操作下买家 claim 卡死 | 主网 NFT 重建时加注资校验（现网已足额锁定 100 万，无现役风险） |
| setMintParams 售后调参 | Low | quotaPerNft 中途上调可超注资额 | 主网冻结开售后 quota |
| NFT 非标准 ERC721 | Medium（产品面） | 无 safeTransferFrom/supportsInterface/tokenURI，二级市场不识、误转合约地址锁死 | 主网版本继承 OZ ERC721（保留配额钩子） |
| mock Token faucet 无限领 | 主网必换 | 原样上主网即无限增发 | 已在主网 TODO（替换真实代币），复核确认 |
| DEX 流动性永久锁定 | 设计确认 | 无 LP token/撤池函数，注入即永久 | 主网注资前确认为意图；feeTo 主网改指质押奖励池 |
| 随机性信任假设 | Low（披露） | Orbit 中心化 sequencer 可影响 blockhash | 主网条款披露或叠加外部熵源 |
| /api/* 未知路径走 SPA 200 | Low | 纯 API 调用方不友好 | 后续改 404 JSON |
| 未来轮 /api/round 返回全零 | Low | 忠实透传链上行为 | 前端判空即可 |
| settle/startRound 两笔交易间短暂"零轮" | Low | 秒级竞态 | buildState 可加 salesEnd==0 回退旧缓存 |

## 3. 主网上线硬性清单（本次审计后更新）

1. **真实代币替换 mock**（faucet 无限增发风险，Critical-if-shipped）。
2. **多签部署 + keeper 密钥托管**（admin 单点 EOA 风险面：pause 冻结用户资金、setPerkContract 间接抽血通道——
   虽有事件了，多签+时间锁是主网底线）。
3. **主网 RPC 单 tx/块 gas 上限实测**（决定 MAX_BATCH_TICKETS 与 _stakers 规模安全的最终参数）。
4. DEX feeTo 改指质押奖励池；确认流动性永久锁定为意图。
5. NFT 重建（OZ ERC721 + 注资校验 + quota 冻结）。
6. Perks 秒级线性累积（或满 24h 起算）。
7. 条款页披露随机性信任假设与质押共担机制。
8. ROUND_SECONDS=86400 / LOCK_MINUTES=15 / ANCHOR_FIRST_UTC=true。

## 4. 测试网运行数据（截至 2026-09-11，V4.2 部署后）

- 当前 core：`0xCD8726B6b3479fBe7415B8550d6Eb689e2950cc9`（创建块 117716742），perks `0x6d922F0Bd2c4820ceC36aE1F14b86aE99580C374`
- 测试计数：**73/73 绿**（JackpotHood 39 + Perks 8 + Invariant 11 + AuditRepro 2 + BatchBounds 7 + FreeTicketAtomicity 6），
  invariant 每条 256 runs × 500 depth 全跑满、0 revert，耗时 ~6 分钟
- E2E 九步全过（tx hash 见 E 报告）：含 200 组批量购票、领奖到账公式精确（due×0.88−gas）
- API 核对：10/10 项一致（含 leaderboard/me 与事件重算逐 wei 对齐）

## 附录：各分报告索引

- core 精读（A）：H-1/M-1/M-2/H-2/L-1~L-3 + Info（含 PoC 数值与 gas 标定）
- 外围四件套（B）：M-1（setPerkContract 信任面）/M-2（NFT 合规）/L-1~L-5 + Info（DEX 账平实测等）
- 不变量扩充（C）：vacuous 发现与修复、性质→不变量对照表（I1-I10）
- 线上 API（D）：10 项逐字段核对表 + 4 条低危观察
- 链上 E2E（E）：9 步 tx hash 与到账公式核对

---

## 补遗（2026-09-11 晚）：V4.3 公平赔率封顶（审计后产品机制变更）

**变更**：应用户决策新增小奖项封顶——结算时 `档池实际派彩 = min(档池, 封顶倍数 × 票价 × 该档中奖注数)`，
封顶倍数 = 命中率倒数公平赔率：末1位 10×、末2位 100×、末3位 1000×、末4位 10000×、末5位 100000×、头奖不限。
超出部分滚存（走 V4.2 守恒帽，pendingRollover ≤ ticketBank 恒成立不变）。

**动机**：人少时一人独吞档池 + 质押者大幅失血（实测 200 注/期净 −0.456 ETH）。

**影响复核**（解析模型 + 20 万固定种子蒙特卡洛双向吻合 <1%）：
- 当前池参数下玩家净返奖率（扣 12% 抽水）：毛 373% → **净 214%**（手感保留，因池子补贴）
- 质押者每期净损益：−0.456 → **−0.27 ETH**（出血大幅收窄；平衡点 T* ≈ **1,762 注/期**，/calc 已实时反映）
- 封顶只在低销量触发；>~250 注/期后末位档分薄自然低于封顶线，机制隐形

**合约改动**：src/JackpotHood.sol 新增 `_payoutCapMult()` 纯函数（[0,100000,10000,1000,100,10]，0=头奖不限；
注：Solidity 不支持数组常量，用纯函数表达同一张表）+ _settle 封顶块（滚存质押成分缩放之后、reserveNeeded 之前；
封顶余量全额滚存受守恒帽兜底）。既有 2 个测试修正到封顶语义 + 新增 4 个封顶测试（独中触发/分薄不触发/
头奖不限/守恒不破）。**forge 77/77 全绿**。

**部署**：core `0x12642673FA050fcA450d0519d833655A73e17E40` / perks `0x819DFC8d52ee44C1001B127dD441E07E3b6d0C04`
（创建块 117782284）；质押第三次迁移（6.3209 ETH，V4.2 清零）；/calc 已纳入封顶模型（二项分布精确求和）。

---

## 再补遗（2026-09-13）：V4.4 机制升级（Megapot 借鉴）

**变更**：① 质押退出改两段式队列（requestUnstake → 陪跑当前轮结算 → finalizeUnstake），堵死结算前抢跑共担的洞
（实测：申请后遭共担清算则按削减后余额领取；unstakeEth 已删除）。② 购票侧推荐人 5% 立付
（有推荐人时买票 10% 抽水拆为 5% 立付推荐人 + 5% 进质押池；无推荐人 10% 全入池不变；推荐人拒收则并回池，
购票永不卡死）。

**测试**：forge **85/85 绿**（基线 77 + 新增 8：两段式退出全流程/防抢跑语义/重复挂单 revert/终态后轮次/购票分成
三条路径/拒收容错/赠送同口径）。Invariant 适配两段式（ghost 跟踪挂单，反空转钉死覆盖）。

**字节码**：新功能使合约 25125B 超 EIP-170 上限 549B → 瘦身 846B 至 **24279B**（rounds/pendingAdmin 转 internal +
custom errors 批转换 + metadata/bytecodeHash 裁剪），余量 297B——下次加功能前必须先量尺寸。

**部署**：core `0x9fCB876196586B828A5c42e4287fFCB3BAACc806` / perks `0x0959fF76cb5dccC2A403b3c255f4126b70f1bC2b`
（创建块 118940651）。注意 V4.3 沉淀 ~1.37 ETH 池现金（奖池负债性质，无 admin 取款通道，任何人仍可免许可
推轮领奖）。前端两段式退出 UI + abi/server/i18n/规则页全部同步；站点 revision 00035-rvt。

