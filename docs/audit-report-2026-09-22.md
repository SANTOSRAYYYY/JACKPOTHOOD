# JackpotHood 全面审计报告（2026-09-22，六路并行内部审计）

> 范围：预售三合约（A）、HoodVRF（B）、server.mjs 后端（C）、core V4.4 增量（D）、测试攻击面（E）、链上实况（F）。
> 方式：6 个独立审计代理并行 + 修复后复验。所有 High/Med 均已修复并回归。**forge 192/192 绿。**
> 关联前次：docs/audit-report-2026-09-11.md（V4.2 审计）。

## 发现与修复总表

| # | 级别 | 位置 | 问题 | 状态 |
|---|---|---|---|---|
| C-H1 | **High** | server.mjs clientIp | XFF 首位信任 → 限流整体可绕（已线上实测实锤） | ✅ 已修（取末位+回环判定；粗清改过期淘汰；429 带 Retry-After） |
| C-H2 | **High** | /api/draws/claim | 绕过 mutateStore：陈旧快照条件写 → 抽奖记录丢失更新（奖品重掷面） | ✅ 已修（收编 mutateStore；admin/prizes 同锁） |
| D-M1 | **Med** | core claim | 推荐人拒收 ETH → 中奖者奖金永久锁死（与购票侧容错口径不一致） | ✅ **V4.5 已修**：`!okRef` 时 refShare 并 stakingPool，中奖者净得 88% 不变（0x451D…BE00，字节码 24309B 预算内） |
| C-M1 | **Med** | server.mjs | 验签前全量扫描（免费 RPC 放大器）+ 读端点零限流 + 缓存无界 | ✅ 已修（验签前移 6ms 路径 + 前端带 streakStart；读端点限流；cache 5000 条淘汰） |
| C-M2 | **Med** | server.mjs | 500 原文外泄（可含 RPC URL 凭证）+ /health、/__keeper 信息暴露 | ✅ 已修（统一 internal；health 只留 ok/lastRun；__keeper 限流+脱敏） |
| C-M3 | **Med** | server.mjs useGcs | 首探失败永久钉死本地模式（多实例分叉双抽面） | ✅ 已修（负钉 60s 重探） |
| F-1 | **Med（线上故障）** | server.mjs getLogs | 事件超 RPC 1 万上限 → /api/leaderboard、/api/streaks 瘫痪 | ✅ 已修（getLogsChunked 分段+自动对半，15 处全替换；实测 top1=11802 复活） |
| D-L1 | **Low** | core 两处推荐人 call | 全 gas 转发 → gas griefing（购票实测被放大 200 倍） | ✅ V4.5 已修（50k 上限） |
| B-M1 | **Med（接受）** | HoodVRF | drand 永久停摆时未履约请求无退款路径 | 📌 接受并文档化（金额 0.0002 ETH 级；V5 可加 refundStale） |
| A-M1 | **Med（运营项）** | Presale finalize | 三个分账地址 immutable 且 push 式，其一拒收则全部资金永久锁 | 📌 当前实例三地址同 EOA 安全；主网部署前列阻断项校验（EOA 或 payable receive） |
| A-L3/D-L2 等 | Low | router admin EOA / 挂单无取消 / NFT2 非完整 ERC721 / keeper 私钥解析位置 / GCS list 分页 / 本地写非原子 | — | ✅ keeper 私钥+GCS 分页已修；其余列主网清单 |

## 链上账务实况（F 路实测，2026-09-22）

- core 余额 = 负债桶合计 **57.024124557856526299 ETH，0 wei 偏差**（现金流进出亦精确闭合）；
- keeper 近 10 轮连续结算无卡轮；预售 sold=505 ↔ 余额 0.404 ↔ JPH 494,947.5 全对账；
- 旧 V4.3 沉淀 1.3657 ETH 记录相符；旧 perks JPH 已清零。

## 测试扩充（E 路）

- 新增 `test/Audit2026.t.sol` 38 项 + `test/V45.t.sol` 10 项；**全量 192/192 绿**；
- 覆盖：跨档价格逐 wei、JPH 池耗尽、free 帽原子回滚、NFT 1000/1001、VRF 时间/坐标/补贴边界、
  两段式退出交错、挂单×void×Committed、封顶档极端量级、void×立付×封顶退款守恒。
- E 路同时独立确认 D-M1（并已将钉死旧行为的用例改写为新容错语义断言）。

## 运营处置记录

- 预售已到期并触发 finalize：60%（0.2424 ETH）永久质押入 core 储备、40%（0.1616）回 21ab；
  505 张预售票额度已全部兑换进轮（6 批×≤100）。
- 9 个合约全部通过 Blockscout 源码验证（core、perks、router、presale、NFT2、HoodVRF、token、旧 NFT、V4.5 三件套）。

## V4.5 迁移待办（本报告完成后执行）

1. 用户先在旧 core（0x9fCB…）完成：领 rid 107（8.38 ETH）/rid 506（0.91）奖金、claimStakeRewards（1.75）、
   requestUnstake 全额 → 等一轮结算 → finalizeUnstake（~45.98 ETH）。
2. 站点切 V4.5（config/env 已备好），用户重新质押进新池。
3. V4.5 已在链上冒烟：推荐购票立付 5% 精确到账（ReferralPurchasePaid 路径首次真实执行）。

## 主网第三方审计前置状态

- 内部两轮到这步：V4.2 全面审计 + 本次六路审计，High 清零、Med 清零（除已接受项）。
- 送审材料就绪：192 项测试、invariant 套件、两份审计报告、链上对账记录。
- 剩余主网清单见 HANDOFF §9（真币重发、Safe 多签、terms 页、主网参数、EIP-2537 主网探测、V5+HoodVRF 集成）。
