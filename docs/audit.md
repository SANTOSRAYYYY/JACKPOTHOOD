# JackpotHood 安全审计报告（自审计 v1）

> 范围：`src/JackpotHood.sol`（核心合约，37 项测试全部通过）、keeper Worker、前端。
> 本报告为内部自审计，主网上线前建议交由第三方审计机构复核。

## 1. 威胁模型与结论摘要

| 风险面 | 等级 | 结论 |
|---|---|---|
| 奖池代币被盗（管理员后门） | ✅ 无 | 合约中不存在任何能把 JACKPOTHOOD 转给管理员的路径；奖池仅用于兑奖与滚存 |
| 购票 ETH 被挪用 | ✅ 无 | 仅 `buybackWallet` 可提取；作废退款额被预留（`totalVoidedOwed`），可提额度自动扣减 |
| 重入攻击 | ✅ 已防 | 购票/兑奖/退款/提款/注入全部带 `nonReentrant`，先记账后转账 |
| 整数溢出 | ✅ 已防 | Solidity 0.8.28 原生 checked 运算；奖池分配用整数除法、余尘滚存，无精度丢失 |
| 随机数操纵 | ⚠️ 有信任假设 | 见 §3 |
| keeper 私钥泄露 | ⚠️ 影响有限 | keeper 无任何特权：开奖是 permissionless 的，任何人都能补位；其唯一特权是回购提款（提款额仅限票款，且资金流向为公开 DEX 回购） |
| 前端 XSS/钓鱼 | ⚠️ 常规风险 | 静态站点、无服务端、无用户输入落库；Privy 域名白名单生效 |
| 合约可升级性 | ❗ 无 | 合约不可升级；缺陷修复需重新部署 + 迁移（测试网已实践三次，见 §7 迁移手册） |

## 2. 访问控制矩阵

| 函数 | 权限 | 备注 |
|---|---|---|
| buyTicket / giftTicket / claim / refundTickets / sweepUnclaimed / commitDraw / settleDraw / startRound / setReferrer / depositPrizeTokens / depositReferralBonus | 任何人 | 全部 permissionless，核心玩法无需信任任何一方 |
| withdrawRevenue | 仅 buybackWallet | 建议 Safe 3/5 多签（主网） |
| pause / unpause / voidRound / setBuybackWallet / proposeAdmin | 仅 admin | 建议 Safe 3/5 多签（主网）；开奖不受 pause 影响，避免搁浅 |
| acceptAdmin | 仅 pendingAdmin | 两步移交，防手滑锁死 |

## 3. 随机性信任假设（重要）

V1 随机源 = **承诺-揭示区块哈希**：

1. `commitDraw` 在开奖时间后承诺「未来区块」，任何人可触发、无法预知该区块哈希；
2. 号码推导用逐字节拒绝采样（≥250 丢弃），0–9 严格均匀、无模偏差；
3. 链上固化：结算时 `seedHash` 写入合约（不可篡改的公证记录，前端可逐字节验证）。

信任假设与已知边界：
- **排序器（sequencer）理论上有「扣块」（withholding）能力**：L2 排序器可通过选择性出块影响区块哈希。这是所有 L2 区块哈希类随机源的共性。ROBINHOOD CHAIN 主网上线前建议升级为 **Chainlink VRF / 多源异或**，接口已预留（`commitDraw`/`settleDraw` 两步结构可整体替换随机源，不动奖池逻辑）。
- **EVM 区块编号 ≠ 浏览器编号**（实测发现，见 README）：公证页已改为展示链上固化的 `seedHash` + 哈希搜索验证，不依赖编号映射。
- 承诺区块超出 256 块窗口后可重新承诺（`commitDraw` 顺延），有兜底。

## 4. 经济模型审计

- 奖池 50/20/20/10 + 余尘：全部滚存或分配，**平台零留存**（合约无任何抽成路径）
- 空奖级 100% 滚存 → 奖池只增不减（除非有人中奖，中奖部分进入可兑奖池，属于用户资金）
- 推荐奖励 5% 由独立 `referralBonusPool` 支付，不足时按池余额封顶，**绝不从中奖者奖金中扣**
- 回购闭环：票款 100% 归集 → 回购钱包提取 → DEX 兑换 → 注入奖池，全程事件可查
- 逾期未领（30 天）由任何人 `sweepUnclaimed` 滚入当期奖池

## 5. 测试覆盖（37 项）

购票/赠票/校验、四奖级核算、滚存、承诺-揭示全链路（含过期重试）、兑奖/重复兑奖防御、作废+退款（退款预留保护）、暂停/恢复、管理员两步移交、推荐奖励（正常/封顶/防自荐）、跨期资金平衡回归。

建议补充（主网前）：模糊测试（echidna/foundry invariant fuzz）、第三方审计、主网灰度期小额奖池运行。

## 6. 前端与 Worker 审计

- Worker 无特权：私钥仅用于支付 gas 的 permissionless 调用；带 isolate 互斥锁 + 遗留资金自愈注入（已修复一次并发 nonce 冲突并验证）
- Worker 扫描近期 5 期窗口补开（已修复一次「预创建下一轮导致漏开」事故并验证）
- 前端错误边界、ABI 运行时解析、双语/多语言字典均有回归实测；静态托管（Cloudflare）无服务端攻击面

## 7. 合约迁移手册（缺陷修复/升级时）

1. 部署新合约 → 注入保底奖池与推荐池
2. `setBuybackWallet(keeper)`（测试网自动化）或 Safe（主网）
3. Worker `CONTRACT_ADDRESS` 指向新合约（支持 LEGACY 变量并行收尾旧合约）
4. 前端 `config.js` 更新合约地址
5. 旧合约保持自助兑奖 30 天（`claim` 无需 keeper）

## 8. 免费引流票（freeTicket，v2 新增）

- **接口**：`freeTicket(recipient, numbers, count)`，仅 admin，payable 但强制 `msg.value == 0`；接收方零成本得票。
- **账目**：免费票计入 `totalTickets`/组合桶（照常参与开奖与兑奖），但**不计入 ticketRevenue**，不进入回购闭环——不虚增可提取 ETH。
- **退款安全**：免费票以哨兵 gifter `0x...dEaD` 标记，`refundTickets`/`previewRefund` 跳过——作废期次只退实际收取的 ETH（`totalVoidedOwed` 恒等于实收），杜绝从合约白拿。
- **限额**：`MAX_FREE_PER_ROUND = 1000` 注/期（`freeMinted` 计数），防脚本事故大规模稀释付费票赔率。
- **风险提示（运营注意）**：免费票稀释付费票中奖期望——只作拉新手段限量使用；兑换/滚存等路径与付费票完全一致。
- **测试**：权限、零支付、误带 ETH 拒绝、每期限额、混合退款只退付费部分、免费票中奖兑奖——共 6 项，全部通过（套件 43 项全绿）。

## 9. 免费额度（grantFreeCredits / redeemFreeTicket，v3 新增）

- **流程**：管理员 `grantFreeCredits(recipient, amount)` 发放额度（不计息不过期）→ 用户 `redeemFreeTicket(numbers, count)` 以自选号码零成本领用，额度扣减；不使用则一直留存。
- **记账一致性**：领用走 `_buyFor(..., isFree=true)`，与 freeTicket 完全同路径——哨兵 gifter、不计 revenue、不可退款、照常兑奖、计入每期免费限额（1000 注/期）。
- **原子性**：先扣额度再出票，出票回滚（如当期免费限额用尽）则额度原样保留，可下期再领。
- **测试**：权限、发放+领用（自选号码压缩验证）、额度不足回滚、每期限额回滚且额度保留、领用票中奖兑奖、作废零退款义务——6 项，全部通过（套件 49 项全绿）。
