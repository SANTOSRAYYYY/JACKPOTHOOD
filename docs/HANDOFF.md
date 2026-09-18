# JackpotHood —— 完整交接文档（给 Kimi / 任何新助手）

> 本文档自包含，不需要历史聊天即可接手。先读这一份，再按需读 docs/ 下其它文档。
> 最后更新：2026-09-17（社区轮预售合约+前端全套上线，core 零改动走 PerkRouter 桥；**00042-6lx**）。
> 初版：2026-09-08 深夜，全套 V4 重建与 UI 修复完成后。
> 用户：21ab 钱包（0x9692cdb6cC6cb7537bBc3062066c733014EF21ab），中文交流。

---

## 0. 一句话定位

JackpotHood = 跑在 **Robinhood Chain（Arbitrum Orbit L2）测试网**上的 6 位数字链上彩票：
100% ETH 奖池、6 奖级（40/25/15/12/5/3）、买票抽水 10% 进质押分红池、中奖再抽 12%
（推荐人 5% + 质押池 7%，无推荐人 12% 全入池）、ETH 质押真实入池并承担大奖超额的共担清算、
JPH 代币质押（独立 Perks 合约）每天赚免费票。免费票/赠票/批量购票/NFT 配额齐全。
前端 6 语言（en/zh/ja/ko/vi/la），Privy 钱包登录，响应式手机适配。

**当前是「用户拍板重来的 V4 拆分版」：core（无 JPH）+ Perks（JPH 记账）双合约，
外加全新 JPH 代币、Genesis NFT、DEX pair。全部已在测试网部署并接入线上站点。**

---

## 1. 环境与入口（先记住这些）

| 项 | 值 |
|---|---|
| 仓库根目录 | `C:\Users\coins\robinhood`（Windows，Git Bash shell） |
| 线上站点 | https://www.jackpothood.com （Cloudflare 代理 → Google Cloud Run） |
| Cloud Run 原始域 | https://jackpothood-237361412264.asia-east1.run.app |
| GCP 项目 / 服务 / 区域 | jackpothood-app / jackpothood / asia-east1 |
| gcloud 命令 | `"/c/Users/coins/AppData/Local/Google/Cloud SDK/google-cloud-sdk/bin/gcloud.cmd"`（不在 PATH） |
| 测试网 RPC | https://rpc.testnet.chain.robinhood.com （chain id 46630，~0.18s/块） |
| 主网 RPC（未上线） | https://rpc.mainnet.chain.robinhood.com （chain id 4663） |
| Explorer | https://explorer.testnet.chain.robinhood.com （Blockscout，有 /api/v2 REST） |
| 部署私钥 | 仓库根 `.env` 的 `DEPLOYER_PRIVATE_KEY`（= 21ab；**绝不 echo/输出**；取值：`K=$(grep -E "^DEPLOYER_PRIVATE_KEY=" .env | cut -d= -f2 | tr -d '"' | tr -d '\r')`） |
| Keeper 私钥 | GCP Secret Manager `keeper-pk`（Cloud Run 注入 KEEPER_PK；**绝不输出**） |
| 本地开发 | `cd frontend && npm run dev`（vite，5173）；生产同目录 `npm run build` |
| Foundry | 仓库内（forge/cast 可用），solc 0.8.28，优化器 1 run |
| 其它环境变量 | .env 另含 BUYBACK_WALLET / JPH_TOKEN / DEPLOY_MOCK_JPH / TICKET_PRICE_WEI / SEED_POOL_WEI / KEEPER_PRIVATE_KEY |

## 2. 链上合约（V4 全套，当前线上唯一真相源）

全部部署者 = 21ab；管理员 = 21ab（core/NFT 的 admin 都是他）。

| 组件 | 地址 | 创建块 | 说明 |
|---|---|---|---|
| **JackpotHood core**（主合约，**V4.4 当前版**） | `0x9fCB876196586B828A5c42e4287fFCB3BAACc806` | 118940651 | 轮参数 600s/120s lock/anchorFirst=false；MAX_BATCH_TICKETS=1000；V4.3 封顶 + V4.2 审计修复全保留 + **质押两段式退出（requestUnstake→陪跑本轮结算→finalizeUnstake，防结算前抢跑）+ 购票推荐 5% 立付（ReferralPurchasePaid 事件）**；字节码 24279B（EIP-170 余量 297B）；unstakeEth 已删除；**perkContract 现已指向 PerkRouter**（09-14 社区轮起） |
| **PerkRouter**（免费票路由，**当前生效**） | `0x9f63Cfc9e7cE76efFd0209504d8842c913B26D87` | ~09-14 | core.perkContract 槽位持有者；白名单 {Perks新, Presale} 转发 redeemPerkExternal |
| JackpotHoodPerks（JPH 质押→免费票，**新，指 router**） | `0x6baefD034328A827F1bd08D6F1DaAed1c5A0e098` | ~09-14 | config.js PERKS_ADDRESS 已指向此；旧 perks 里质押的 JPH 可随时 unstakeJph 取回（不依赖 core） |
| **JackpotHoodPresale**（社区轮） | `0xa29c858E6d48b1d39a82E7009776c5D9f96b63D8` | ~09-14 | 预售 10 万张：阶梯价 0.0008/0.0009/0.001（20k/30k/50k 分界）、10 JPH/张、推荐 0.5 JPH/张、满 500 张送 NFT2、3 天期（主网 30 天）、finalize 60% 永久 stakeEth + 20/10/10 分账、未售 JPH 烧毁；已充 50 万 JPH |
| **GenesisNFT2**（创世 NFT 新版，无 JPH 配额） | `0xB9E8311a105C92b0fcEDe203F95f1DFe050335d2` | ~09-14 | cap 1000、1/钱包、claim 需 presale.purchased≥500、adminAirdrop 支持快照空投 |
| JackpotHoodPerks（JPH 质押→免费票，~~V4.4 旧~~） | `0x0959fF76cb5dccC2A403b3c255f4126b70f1bC2b` | 118940651 | 已被新 Perks 取代（core 槽位移交 router）；合约内质押 JPH 可正常 unstake |
| ~~旧 core V4.3~~（已弃用） | `0x12642673FA050fcA450d0519d833655A73e17E40` | 117782284 | 封顶版；质押已被用户自行提空；~1.37 ETH 池现金沉淀（奖池负债性质，无 admin 通道） |
| ~~旧 core V4.2~~（已弃用） | `0xCD8726B6b3479fBe7415B8550d6Eb689e2950cc9` | 117716742 | 审计修复版，被 V4.3 封顶版取代；资金已提空 |
| ~~旧 core V4.1~~（已弃用） | `0x94e407b923424E196F67B44F5F6d12116b95982A` | 117427193 | 批量上限版，被 V4.2 取代 |
| ~~旧 core V4~~（已弃用，只读） | `0xDD2F8d1A8aefE837BFc22912ca2DFE073ccC7a02` | 115715866 | 最早的一代 |
| ~~旧 perks V4.3/V4.2/V4.1/V4~~（已弃用） | `0x819D…` / `0x6d92…` / `0xA48B…` / `0x9cfB…` | — | — |
| JACKPOTHOOD 代币（新） | `0xa4c7CC40653Db4af3E2b3642D992088De94Be427` | 115712152 | supply 2,000,000；带 faucet()（测试网每人领 1 万） |
| Genesis NFT | `0xB51cE45F61E2E387a3b663a7bA0F51207834c38e` | 115712152 | 0.1 ETH mint、每 NFT 1000 JPH 配额（已锁 1,000,000 JPH）、每钱包 1 个 |
| DEX pair（JPH/WETH） | `0xff8EA0BfBe62f55e0A317814Be7e5817912794cb` | 115712153 | 卖税 10%（feeTo=21ab） |
| DEX router | `0x802EbEc5A32A8B70D0f84630B33B6728F7EeE18c` | 115712153 | 流动性 0.006 ETH + 6 万 JPH |
| WETH（复用） | `0x9eB818e23E02f23dfD7e6b34f26A5E5Ebd698B99` | — | 测试网原生 WETH |

- config 已同步：`frontend/src/config.js`（TESTNET 块 + PERKS_ADDRESS 常量 + JACKPOT_CREATED=118940651）
- 部署脚本：`script/DeployAll.s.sol`（token+NFT+core+perks+DEX 一键）；`script/Deploy.s.sol`（仅 core+perks）
- **线上 Cloud Run revision 00042-6lx**（09-17 起；env：CONTRACT_ADDRESS=0x9fCB…、CONTRACT_CREATED=118940651、RPC、CHAIN_ID=46630、**PRIZE_BUCKET=jackpothood-app-prizes** + secret KEEPER_PK）
- 已验证：/api/state ok（V4.4 轮 2 已开、轮 3 在售，keeper 瞬态后自愈推进）；unstakeReqOf 等新接口链上直读正常

## 3. 经济模型 ground truth（改 UI/文档前先对照这里）

1. 票 = 6 位数字（每位 0-9），0.001 ETH/注（TICKET_PRICE），从**末位**向前匹配。
2. 买票：90% 进当期奖池（prizePool+ticketBank），10% 抽水（ticketFee→结算进 stakingPool 按质押快照分红）。
3. 中奖派彩基数 pool = prizePool + stakeCash（**质押真实入池**）；6 档份额 = pool×40/25/15/12/5/3%（第 6 档=末 1 位也中奖）。
4. 空档滚存；有主未领到期 sweep 单滚；领奖再扣 12%：赢家净得 88%，推荐人 5%（若有，从中奖抽水里出），其余 7% 进质押池（无推荐人 12% 全进池）。
5. ETH 质押活期：随时按净值提；大奖超过票款银行（ticketBank）的缺口在结算时按全体质押者份额即时共担（从不冻结）；质押分红（stakingPool）按结算时刻快照分。
6. JPH 质押（Perks 合约，**不参与 ETH 分红**）：线性 每 10 万 JPH = 每天 1 张免费票，未领余额上限 3 张（MAX_STORED_PERK）。
7. 免费票：管理员 freeTicket 直发 / freeCredits 额度（用户 redeem 自选号）/ Perks 代发；零成本、照常中奖兑奖；每轮免费出票上限 1000 注（MAX_FREE_PER_ROUND）。
8. 批量：buyTickets/giftTickets/redeemFreeTickets，合约层一组 tx 最多 **1000** 个号码组合（V4.1 起；旧 core 为 200）、每组合注数上限 1000。**注意（09-14 复测）**：RPC 节点对 raw tx 大小有 **~100KB 硬上限**——实测 400 组（≈90KB calldata）通过、450 组（≈101KB）必报 "oversized data"（eth_estimateGas 不触发该限制，只有 sendRawTransaction 触发，所以钱包里表现为"卡住"）；早年记录的 741 gas 上限已先被大小上限覆盖。前端 submitBatch 按 **400 组/tx 自动拆分**多笔顺序签名（GAS_CHUNK=400，每片独立计算 msg.value，并预估算 gas 显式传入让钱包跳过自身估算），500 组 = 2 笔、1000 组 = 3 笔。
9. 免费票退款不可退；作废轮（voidRound，仅 admin）票款全退（预留 _voidedOwed），90% 票款同步回退 ticketBank。
10. 随机性：commit-reveal + commitHash 公证快照（快照后**永久可结算**，不受 256 块窗口限制）；错过 30s 窗口可重试 commit。
11. NFT：0.1 ETH 铸造 → 锁 1000 JPH 可领；配额跟随 NFT；铸造费由 owner 用于注入 DEX 流动性（合约内无回购逻辑）。
12. 与主网差异：测试网 600s/轮、120s 停售窗、anchorFirst=false（首轮部署后即开）；主网拟 86400s、15min、anchorFirst=true、ROUND_SECONDS/LOCK_MINUTES env 控制。

代码对照：src/JackpotHood.sol（BUY_FEE_BPS=1000、WIN_FEE_BPS=1200、REFERRAL_BPS=500、
tierPots 在 _settle：pool×40/25/15/12/5/3，units[5] 用 lastDigitUnits[winningPacked>>40]（byte5=末位，已确认字节序正确）；
_pack：numbers[i]→byte i，number[5]=末位=packed>>40 桶）。

## 4. 仓库地图

```
robinhood/
├─ src/                    # Solidity 合约（0.8.28）
│  ├─ JackpotHood.sol      # core：购票/开奖/领奖/质押/免费票/void/sweep（843 行）
│  ├─ JackpotHoodPerks.sol # JPH 质押免费票（159 行，桥 core.redeemPerkExternal）
│  ├─ JackpotHoodNFT.sol   # Genesis NFT + 配额领取（242 行）
│  ├─ dex/                 # JHPair/JHRouter/JHWETH9（卖税 AMM，测试用）
│  └─ mocks/JackpotHoodToken.sol  # 最小 ERC20 + faucet（测试网代币）
├─ script/  DeployAll.s.sol（全套）/ Deploy.s.sol（core+perks）/ DeployNFT.s.sol / DeployDex.s.sol
├─ test/    JackpotHood.t.sol(33) / Perks.t.sol(8) / Invariant.t.sol(5)  → 46 全绿
├─ frontend/
│  ├─ src/App.jsx          # 主站 SPA（路径路由：/,/history,/rules,/stake,/token,/nft,/admin…），147 个函数组件逻辑
│  ├─ src/{AdminPage,DrawsPage,StakePage,NftPage,TokenPage,RulesPage,WalletMenu,LangSwitcher}.jsx
│  ├─ src/i18n.js          # 6 语言 286 键；useI18n/t/tr；字符串列表用 '|' 分段
│  ├─ src/config.js        # ★ 换合约地址只改这里（TESTNET 块 + PERKS_ADDRESS 常量）
│  ├─ src/abi.js           # jackpotAbi/nftAbi/perksAbi（与链上 ABI 匹配）
│  ├─ server.mjs           # ★ Cloud Run 主程序：静态托管 + keeper(60s) + /api/state + /api/mytickets + /__keeper + /healthz
│  ├─ styles.css           # 响应式（900/640 断点）
│  ├─ wrangler.toml        # 遗留 CF Worker 配置（线上已不用；worker 已死）
│  └─ Dockerfile           # node:20-alpine，npm ci + build，跑 server.mjs
├─ docs/                   # DEPLOY_GCP / SESSION_STATE / audit-report-2026-09-08 / audit / legacy-contracts / product
├─ gcp_deploy.sh           # 部署脚本（注意：内部 CONTRACT_ADDRESS 需要手动保持最新）
└─ .env                    # 私钥等（勿提交、勿输出、勿写进代码）
```

## 5. 前端要点

- **钱包**：Privy（app id 在 config，本地 dev 可换 VITE_PRIVY_APP_ID）；页面所有写操作走连接钱包；
  管理后台 /admin 从合约读 admin() 并与连接钱包比对做门禁（WalletMenu 切换钱包）。
- **数据流**：App.jsx 每 8s 轮询 /api/state（服务端聚合：state 5s、feed 60s、mytickets 8s 缓存，链上读全并发）；
  直连链兜底**仅在 API 超过 30s 不健康时**启用（此前每 15s 全量直连 RPC——含全历史 getLogs——是"网站很卡"主因，09-10 已修）；
  server.mjs 读 CONTRACT_ADDRESS env。两处必须指向同一合约，否则会重现"数字新旧交替"类问题。
- **大字（hero）** = assets.prize + assets.stake（=totalPoolAssets 两个返回值相加；该 view 已修到
  committed/drawn 期间也显示当轮池，防开奖瞬间归零）。小字展示 prize/stake 拆分。
- **中奖播报** winFeed 与 **领奖提示** claimable 显示 ETH **净额**（App.jsx 对 previewClaim 毛额 ×88%）。
- **i18n 编辑红线**：改完必须 `cd frontend && npm run build` 验语法。历史教训：整行替换会丢尾部逗号/
  转义撇号，连环报错——优先「行内片段替换」，不要整行重写多段 '|' 字符串。
- RulesPage 文案必须与第 3 节 ground truth 一致（曾残留 V2「回购 JPH」说法，已全部清理）。

## 6. 合约要点与安全

- core：无任何 admin 取款通道（后门=0）；admin 只能 pause/unpause/voidRound/grantFreeCredits/
  freeTicket/setPerkContract/proposeAdmin。paused 只挡买票/领取，开奖结算不停。
- voidRound 会把该轮 90% 票款从 ticketBank/prizePool 回退（否则大奖会错误转嫁质押者）——改代码时勿破坏。
- Perks 桥：core.redeemPerkExternal 仅 perkContract 可调；perks 与 core 双向引用需同时部署。
- 46 项 forge 测试（33+8+5 invariant）已全绿；改动合约后 `forge test` 全量跑（invariant 约 2.5 分钟）。
- 已知低风险项（审计记录）：~~_stakers 数组不清零~~（V4.2 已修：MIN_STAKE=0.01 + swap-pop 收缩；数千真实质押
  触单 tx 上限的远期风险见 audit-report-2026-09-11 §3 主网清单）。
  （2026-09-10 已清：la 字典西/意混入已全部润色；healthz 404 根因查明 = Google 前端 GFE 拦截
  /healthz 保留路径、请求根本不到容器，健康检查已迁 `/health`，/healthz 别名保留但勿用。）

## 7. 运维手册

- **改前端/文案**：改完 `cd frontend && npm run build` → `gcloud builds submit --tag gcr.io/jackpothood-app/jackpothood .`
  （云端构建约 5-7 分钟）→ `gcloud run deploy jackpothood --image gcr.io/jackpothood-app/jackpothood:latest
  --region=asia-east1 --allow-unauthenticated --memory 512Mi --min-instances 1 --no-cpu-throttling
  --set-env-vars "CONTRACT_ADDRESS=<当前 core>,RPC_URL=...,CHAIN_ID=46630,CONTRACT_CREATED=<core 创建块>,PRIZE_BUCKET=jackpothood-app-prizes"
  --set-secrets "KEEPER_PK=keeper-pk:latest"`。域名 www.jackpothood.com 走 CF→run.app，自动生效；
  index.html 已 no-cache（用户硬刷新一次即可）。
- **keeper**：server.mjs 内自驱动（setInterval 15s，KEEPER_INTERVAL_MS 可调；**必须 --no-cpu-throttling 部署**，否则无请求时 CPU 冻结、开奖停摆），commit→snapshot（含 stale 重试）→settle→startRound；
  部署 revision 后约 1-2 tick 内自动补开过期轮（已验证可自愈）。手动触发：GET /__keeper。
- **查链上状态**：`cast call <addr> "fn()(type)" --rpc-url https://rpc.testnet.chain.robinhood.com`；
  批量事件可用 explorer REST /api/v2 或 viem getLogs（大跨度分段）。
- **部署新合约**：见第 2 节脚本；**ANCHOR_FIRST_UTC 测试网必须 false**（true 会把轮 1 锚到 UTC 零点，
  曾有返工教训）；部署后：更新 config.js 三处地址+创建块 → build → 云构建 → run deploy 换 env → 验证
  /api/state roundId/status/assets → 若需质押用 `cast send <core> "stakeEth()" --value <wei>`。
- **旧 CF Worker**（wrangler）已废弃（workers.dev 访问失败），不要再 wrangler deploy；config 若再被它引用会显示旧合约。

## 8. 本阶段已完成（勿重复做）

1. ✅ 查明 10 ETH 质押去向（旧合约 0x6baB，admin=21ab）与 0.2/10.18 闪烁根因（旧缓存页面连旧合约 + 大字=prize+stake）。
2. ✅ 旧合约资金回收：0x6baB 10 ETH、0xa1fc 5 ETH+0.0001、E3B190 0.1+0.1017 → 全部回 21ab（≈15.2 ETH）。
3. ✅ 全套 V4 重部署（token/NFT/core/perks/DEX，地址见第 2 节）+ 21ab 重新质押 10 ETH 进新 core。
4. ✅ 线上切换 revision 00011；HTML no-cache + API no-store；gcp_deploy.sh 更新为新 core。
5. ✅ UI 审计修复 60+ 处（领奖/播报 JPH→ETH、净额 88%、奖档表补百分比、buyback 残留清理、
   JPH 质押档位改线性、5 位→6 位、推荐 5% 口径、StakePage 硬编码 i18n 化等，6 语言全覆盖）。
6. ✅ 合约头注释 6 档修正；46 测试绿；core 843 行人工通读（含字节序/共担/回退逻辑核对）。
7. ✅ docs/legacy-contracts.md 归档旧合约与 V4 地址；audit-report-2026-09-08.md 有上轮全量审计。
8. ✅ 09-10 交接优化：HANDOFF 数字刷新至轮 139 快照；SESSION_STATE 并入 HANDOFF 去重；la 字典润色 ~30 处；
   healthz 404 根治（GFE 拦截 /healthz，健康检查迁 /health）；移动端 640px 静态审计（无需改码）；
   gcp_deploy.sh 修正（原指已废弃旧合约 0x6084 + 错误项目 ID）；.dockerignore 嵌套秘钥加固。
9. ✅ 09-10 性能与 UI：keeper 停摆根因修复（Cloud Run CPU 冻结 → --no-cpu-throttling + 15s tick，实测无流量自动开奖）；
   "网站很卡"根因修复（浏览器每 15s 全量直连 RPC 含全历史 getLogs → API 健康时直连让路；/api/state、
   /api/mytickets 服务端全并发，mytickets 附 claimDue/claimIndices）；顶导 CJK 竖排修复（nowrap+flex-shrink）；
   邀请卡片 6 语言文案重写（5% 出自 12% 抽水、好友净得 88%）；我的彩票按期分组折叠（>8 注默认收起、
   中奖注恒显、中奖票按奖级置顶）；开奖后中奖结果 8s 轮询自动刷新（轮次/状态变化触发 + 4 次心跳）。
10. ✅ 09-10 hero 期号翻页：◁ 浏览历史期（奖池/中奖号/注数，走新增 /api/round?id=N 接口，5s 缓存）；
    ▷ 下一期预售视图（估算停售/开奖时刻、滚存预估值；当前期不在售时购票按钮可用——合约 _pickRound 自动
    计入下一期，当前期在售时按钮禁用并提示）。新 i18n 键：chipPresale/prevRound/nextRound/estLabel/
    presaleWait/presaleNow（6 语言）。期号前进自动回当前期视图。
11. ✅ 09-10 显示与领奖优化：全站奖池/中奖金额改 2 位小数（fmtEthShort）；历史开奖稳定 4 条（服务端回扫凑齐
    + 前端合并不再覆盖 loadMore 页，修复 3/4/5 条闪烁）；/api/mytickets 改事件驱动全历史（TicketPurchased/
    TicketGifted/FreeTicketIssued 三事件扫描），我的彩票不再限近 5 期、撤掉其加载更多；领奖横幅合计 +
    「一键全部领取」（逐期串行发送，合约 claim 单期一 tx）；往期 hero 中奖球放大（balls.xl）+ 奖池构成拆分
    （滚存+售票）。新 i18n 键：claimAll。
12. ✅ 09-10 领奖横幅不显示根因修复：refresh() 直连初扫（近 5 期子集）与 loadMyTickets（全历史）竞态覆盖
    claimable + 15s interval 闭包过期（account/roundId/scanFloor 恒为初始值）——重构数据所有权：API 健康时
    loadMyTickets 独占 myTickets/claimable，refresh 仅做当前期票据增量同步与 6 项账号读；interval 改经
    refreshRef 调最新闭包；loadMore 只管历史开奖（去重追加）；交易后 sendTx/submitBatch 即时 loadMyTickets。
13. ✅ 09-10 领奖横幅根因终审：真正根因 = loadMyTickets 的 rows 映射漏带 claimDue/claimIndices 两个字段，
    导致 claimable 过滤恒为空（竞态只是干扰项）。排障方法：页面注入临时 console.log + 云端构建部署后从
    用户屏幕直读执行轨迹定位（后已移除日志）。另：buildMyTickets 三个 getLogs 移除静默 catch（失败即
    500，客户端保留旧数据，不再被部分失败的空结果覆盖）。
14. ✅ 09-11 历史奖池误导显示修复：零售票期的奖池=上期原样滚存（数字恒定真实但看着像 bug），
    侧边栏历史开奖与 /history 页对 ticketRevenue=0 的期次改标「全额滚存」（i18n 键 rolledOnly，6 语言），
    有真实售票的期次才显示金额。
15. ✅ 09-11 历史期奖池口径统一为「滚存+质押快照」：poolOf(r)=六档奖池求和（结算时 pool=prizePool+stakeCash，
    tierPots[0]/40% 可反推；轮 284 实测 8.446=1.569 票池+6.877 质押，wei 级对齐）；侧边栏、往期 hero
    （拆分显示 滚存+票款+质押）、/history 页全部改用此口径。
16. ⚠️→✅ 09-11 poolOf 上线即崩溃事故（网站白屏 ~40 分钟）：App.jsx 侧边栏解构是 `round: r`（r 即轮次
    对象），误写 poolOf(r.round) → poolOf(undefined) → ErrorBoundary 兜底。热修=改 poolOf(r) + poolOf
    加 undefined 防御（00024）。教训：build 只验语法不验运行时，**渲染路径改动必须本地起 server.mjs 用
    浏览器真开一次再部署**；main.jsx 有 jh-err 错误徽章（左下角红色浮层，过滤插件噪音）可远程收错误。
17. ✅ 09-11 批量功能（swarm 两波执行）：领奖横幅只留绿色「一键全部领取」（删每期按钮+金色样式）；
    标题全站精简为 JackpotHood（i18n siteTitle×6 + index.html）；规则页 18 键×6 语言按当前玩法重写
    （10 分钟期/停售 2 分钟，00:00 UTC 仅作主网规划括注）+ RulesPage row[3] 列错位修复 + AdminPage
    mainnetSteps 的 wrangler 残留改 Cloud Run 口径；footer/heroTagline/dailyUtc/noDrawsYet 节奏文案同步。
    新增 /me 个人中心（购票/中奖/邀请/质押/NFT，/api/me 聚合）与 /ranks 排行榜（购票榜只算自购付费注数、
    邀请榜人数+收益（净额×5/88 归属法）、获利榜累计中奖总额，/api/leaderboard 60s 缓存）。顶导/footer/
    WalletMenu 均已加入口；hero 质押分红池小数改 2 位。新页面 i18n 键 42 个×6 语言（块尾整行新增）。
18. ✅ 09-11 /calc 质押盈亏平衡点计算器：输入 滚存R/票款银行bank/质押S/每期注数T/抽水比例(12%或7%)，
    64 种命中组合精确枚举（非蒙特卡洛）算每轮期望净损益 + 二分求平衡点 T*。模型关键：结算时 ticketBank
    含本期售票 90%（购票时入账，bankEff=bank+0.0009T）；命中概率/注=[1e-6,9e-6,9e-5,9e-4,9e-3,9e-2]；
    兑付上限=bankEff+S。回测：当前链上参数 net(200)=−0.4564、T*≈1,882 注/期（30 万独立蒙特卡洛复核
    一致）。/api/state 新增 ticketBank 字段。i18n 键 24 个×6。
19. ✅ 09-11 批量上限 200→1000（V4.1 重建）：MAX_BATCH_TICKETS=1000（链 gas 上限 ~1.1e15，无约束）；
    新增 test_BatchMax1000（1000 可买/1001 回滚），forge 47 全绿；新 core 0x94e407b9…+新 perks 0xA48B7433…
    （创建块 117427193，互指已接）；config.js/server.mjs 同步；前端批量上限与 12 处规则文案改 1000；
    站点切 revision 00028-gbk。资金迁移：旧 core 质押 6.3209375054622259549 ETH 全额迁移新 core、
    质押分红 0.5833 ETH 已领（轮 284 中奖用户已自行领取）；链上实测 250 组批量购票成功。
20. ⚠️→✅ 09-11 「购票失败 rpc error」根因：RPC 节点在 ~741 组/tx 有硬上限（740 组 32M gas 过、741+ 必报
    gas required exceeds allowance ~50M，与组数/calldata 相关；与链 1.1e15 块上限无关），1000 组单 tx 必挂。
    修复：前端 submitBatch 按 700 组/tx 自动拆分顺序签名（00030-vq9）。教训：「gas 无压力」的结论只验证了
    块上限，没验证单 tx 上限——大额批量必须实测边界（740/741 悬崖就是这么找出来的）。
21. ✅ 09-11 主网前全面审计（docs/audit-report-2026-09-11.md）：五路并行（core 精读/外围精读/不变量扩充/
    API 核对/链上 E2E）。**2 High + 2 Medium 确认缺陷全部修复并重建 V4.2**（0xCD87…/0x6d92…，块 117716742）：
    phantom 滚存守恒帽、void 单记账、免费票校验下沉 _record、MIN_STAKE=0.01+swap-pop；另发现旧 invariant
    套件空转（handler 下溢永不结算）已修复并加反 vacuity 回归；测试 73/73 绿；API 10/10 一致；E2E 9 步全过。
    质押已二次迁移至 V4.2（6.3209 ETH），V4.1 清零。站点 revision 00031-9sx。主网硬性清单见报告 §3。
22. ✅ 09-11 V4.3 公平赔率封顶（用户拍板：封顶倍数=命中率倒数）：_payoutCapMult 纯函数表
    [0,100000,10000,1000,100,10]（0=头奖不限）；_settle 封顶块（缩放后、reserveNeeded 前），余量滚存走
    守恒帽；forge 77/77 绿（修正 2 个旧测试语义 + 新增 4 个封顶测试）；/calc 模型升级为二项分布精确求和
    +150ms 防抖（解析 vs 20 万蒙特卡洛吻合 <1%：当前参数 net(200)=−0.27 ETH/期、平衡点 T*≈1762 注/期）；
    规则页 tiersCapNote + calcCapNote（6 语言）；质押三次迁移至 V4.3（6.3209 ETH）。站点 revision 00032-pkz。
    合约历史：V4(0xDD2F) → V4.1(0x94e4，批量 1000) → V4.2(0xCD87，审计修复) → **V4.3(0x1264…7E40，封顶)**。
23. ✅ 09-12 两项用户反馈排查：①「第六期中奖显示 0 ETH」= 非 bug：结算前 7 秒用户把 6.32 ETH 质押全提
    （tx 0xfe0cbde…），轮 6 在 stakeCash=0 下结算、池仅 0.0099，且其 11 张票末位（1/2/5/2/4/3）与中奖末位（9）
    本就不中——「绿色球」误导来自按位高亮（中间位命中也亮）。②「大批量购票钱包卡住」= 购票面板一次渲染
    上千行所致。修复：票球高亮改为只亮连续后缀命中段（与中奖判定一致）；fmtEthShort 小额自动升 4 位小数
    （不再把 0.0003 显示成 0）；购票面板超过 30 行默认收起 + 「展开全部」按钮（00033-xmw）。
24. ✅ 09-14 首页清爽化（用户拍板）：删三张静态特性卡、删 hero 质押分红池 stat、TG 顶导删除（页脚原有）、
    领水横幅收成 hero 期号行内小链接、邀请卡收成瘦横幅；新增一键快买 10/50/200 注（quickBuyN，覆盖当前
    列表且自动收起 30 行渲染）；锁仓窗 hero-left 变暗提示 + 购票 CTA 自动带期号（buySummaryNext）。
    站点 revision 00034-dmm。
25. ✅ 09-13 V4.4（Megapot 借鉴落地）：**质押两段式退出**（requestUnstake→陪跑本轮结算→finalizeUnstake，
    防结算前抢跑——正是用户轮 6 实操暴露的洞）+ **购票推荐人 5% 立付**（ReferralPurchasePaid 事件；
    拒收合约不卡购票，份额并回质押池）；字节码超限 550B → 瘦身 682B（rounds/pendingAdmin 转 internal +
    custom errors 批转换）至 24279B；forge 85/85 绿；前端两段式退出 UI + abi 同步 + 规则页口径更新 +
    开奖翻牌/倒计时脉冲/奖池呼吸/微交互全套动效精修。站点 revision 00035-rvt。VRF 调研结论见 §12。
26. ✅ 09-14 连买充能抽奖（链下实物奖，swarm 四代理 + 本人部署实测）：**streak 从链上 TicketPurchased
    事件推导**（只算自购付费、UTC 自然日、块时间戳内存缓存），**奖品配置与抽奖记录持久化在 GCS bucket
    jackpothood-app-prizes**（不加 npm 依赖：Node20 fetch + metadata server token + ifGenerationMatch 条件写；
    本地 dev 无 PRIZE_BUCKET 时落 frontend/.devdata/）。新增 8 端点（/api/streaks、/api/draw、/api/draws/claim、
    /api/draws/recent、/api/admin/prizes|draws|fulfill|grant），全部 personal_sign 验签（管理端比对链上 admin()）。
    前端：右栏顶部充能电池卡（小奖 7 格激光绿 / 大奖 14 格激光蓝 + 500 票细进度条 + 最近中奖播报）、
    抽奖 modal（6 奖品格 + 概率% + 轮播定格动画 + TG 领奖登记）；购票模块重构（删三个大绿快买按钮与骰子组，
    合并为一条「🎲 机选 [n] 生成 ｜ 快捷 10/50/200/500」quickgen-row）；排版：.app 1060→1140、右栏 340→360、
    邀请卡文字溢出/按钮竖排修复；/admin 新增抽奖配置区（6+6 奖品名+权重编辑、概率预览、记录台账、测试额度）。
    线上 E2E 全过：grant→draw（中 JPH 定制周边）→claim→fulfill→recent 播报→二次抽 409。详见 §13。
27. ✅ 09-14 安全加固三件套 + bonus 修复：mutateStore 原子变更（写冲突重读重校额度+进程内锁，并发 4 抽 1
    成功 3 sold_out）；管理端签名加 ts 10 分钟窗口 + GCS 签名注册表 48h 防重放（replay/旧格式/过期全 401）；
    IP 限流（streaks 30/draw 10/recent 60 每分钟）；bonus 用掉显式 −1 防跨周期复活。revision 00039-ndx。
28. ✅ 09-14 移动端适配（纯 CSS，00040-7w2）+ **批量购票根因修复（00041-z6j）**：RPC 节点 ~100KB raw tx
    硬上限（实测 400 组过/450 组 oversized data；eth_estimateGas 不触发所以钱包表现为"卡住"）→
    submitBatch 分片 700→400、**每片独立计价**（旧代码多片时每片都付整单金额，必 revert 的隐藏 bug）、
    预估算 gas 显式传入跳过钱包估算。
29. ✅ 09-14 社区轮预售全套（经济模型重构第一轮）：三个新合约（src/presale/：PerkRouter 67 行 /
    JackpotHoodPresale 235 行 / GenesisNFT2 150 行）+ Presale.t.sol 27 用例，forge **112/112 绿**；
    core 零改动（走 perk 桥）。测试网已部署并接线（地址见 §2 表）：setPerkContract(router)、Perks 重发、
    presale 充 50 万 JPH。链上 E2E 全过：buy 5+500（附赠 10/张、推荐 0.5/张到账）→ NFT2 claim #1 →
    迷你预售（120s 期）redeem 出票经 router 进 core → finalize 分账精确（60% 永久质押 0.01296 ETH、
    40% 回 deployer，余额归零）。老 NFT 快照落 docs/nft-snapshot-testnet.md（仅 21ab 持 1 个）。
    前端 /presale 页（PresalePage.jsx）+ 顶导/页脚 🚀 入口 + NftPage 迁移横幅 + 31 i18n 键×6。
    **创世 NFT 政策变更：不再单卖、砍 JPH 配额，并入社区轮满 500 张送；测试网持有者主网快照空投。**
30. ✅ 09-18 HoodVRF 合约开发+测试网部署（用户拍板"VRF 必须链上可验证"）：src/vrf/（HoodVRF 主合约 +
    HoodBLS 验签库 + IVrfConsumer），drand quicknet（3s/轮）+ EIP-2537 预编译链上验签（实测预编译全套在位），
    签名解压链下做（合约只收非压缩坐标 + 曲线上校验）；forge 144/144 绿；fork 真实向量验签通过；
    **链上 E2E 通过（随机数与链下预期逐字节一致，fulfill ≈216k gas）**。修复：EOA consumer 回调在本链会
    整体 revert → `_deliver` 跳过无代码地址。**当前版 0xBA8c…bb09**（旧 0x5249…d57F 弃用）。详见
    docs/vrf-design.md §8。剩余：relayer 循环（server.mjs）+ /vrf 状态页 + V5 core 集成，排在主网阶段。

## 9. 遗留 / 下一步（用户关注点，按优先级）

1. **用户验证**（09-10 现状：大字含质押 9.268 ETH；注意 **ticketBank=0**，此刻中奖赔付全额走质押现金）：
   硬刷新 www 看历史页/领奖均为 ETH；后台 /admin 批量免费票发到新 core
   （AdminPage 三种模式 free/credits/paid 实测一轮）；NftPage mint 0.1 ETH 实测；StakePage JPH 质押免费票实测
   （需要先 faucet 领 JPH：调 token 0xa4c7 的 faucet()）。另有 **0.3813 ETH 质押分红**可 claimStakeRewards 领取。
2. **手机真机响应式验证**：09-10 已做静态审计（900/760/640 三档断点，表格/SVG 图表/长地址/弹层均有响应式
   处理，未发现需改码问题）；真机过一遍仍待做。
3. **可选**：0x6084/0x05ee/0xa1fc 等旧合约残余小池（0.2 级）沉淀不可提——已决策放弃。
4. **主网上线 TODO**（config MAINNET_CONFIG 全空）：真实代币、Safe 多签部署、第三方审计、terms 页、
   ROUND_SECONDS=86400/LOCK_MINUTES=15/ANCHOR_FIRST_UTC=true、DEX 卖税 feeTo 指向质押奖励池而非部署者、
   上线前给 keeper 密钥换 Safe/托管方案。
5. 低优先剩余：_stakers 列表整理、hero 大字标题（prize+stake 合并口径，用户已知情认可）。
6. **方案二（保底小奖 Guaranteed minimums）**：用户明确说"再探讨"，未定勿动。探讨时给保底倍数方案
   （参照封顶表风格），注意需池子/金库出资且只在命中时发生。
7. 连买抽奖运营项：测试网阈值走 env（STREAK_SMALL_DAYS=7/BIG_DAYS=14/BIG_TICKETS=500，可调小做演示）；
   实物奖品履约全人工（TG 联系），/admin 台账状态机 won→claimed→fulfilled。

## 10. 安全与沟通红线（务必遵守）

- **绝不**在聊天/文件/代码里输出任何私钥（.env、KEEPER_PK、临时文件）；取值一律静默。
- **绝不**把私钥写进镜像/仓库；Secret Manager 是 keeper 密钥唯一存放处。
- 用户资金（21ab）链上大额操作（质押/提现/转账）先征得用户明确同意再做；小额 gas/测试开销可直接做。
- 用户曾暴露过 Helius API key（与 Robinhood EVM 无关）——若再遇到任何 API key 都不要外发。
- 交互用**中文**；报告先给结论再给细节；修改后要实际验证（链上/线上）并说明验证结果，不空口汇报。
- 用户决策风格：喜欢"全部重来/上最新版"式的彻底方案；技术讨论会反复确认数字与比例，
  给方案时把假设（如轮参数、费率）写清楚。
- 若用户说"换模型/交接"，把关键状态落盘到 docs/（本文件即模板）。

## 11. 常用速查

- 轮次推进状态：`curl -s <run.app>/api/state | python -m json.tool`
- 手动触发 keeper：`curl -s <run.app>/__keeper`
- 健康检查：`curl -s <run.app>/health`（**勿用 /healthz**——被 Google 前端 GFE 拦截，永远 404 到不了容器）
- 买 1 注测试（0.001 ETH，6 个 0-9）：`cast send <core> "buyTicket(uint8[6],uint64)" "[1,2,3,4,5,6]" 1 --value 1000000000000000 --private-key $K --rpc-url ...`
- 读取：`cast call <core> "totalPoolAssets()(uint256,uint256)" --rpc-url ...`
- 测试：`forge test`（46 项，invariant ~2.5min）；编译：`forge build`
- 部署 core+perks：`set -a && . ./.env && set +a && ROUND_SECONDS=600 LOCK_MINUTES=2 ANCHOR_FIRST_UTC=false JPH_TOKEN=<token地址> forge script script/Deploy.s.sol --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast`
- 前端语法保险：`cd frontend && npm run build`

## 12. VRF 调研结论（2026-09-13，Robinhood Chain 随机源选型）

**现状**：Robinhood Chain（Arbitrum Orbit L2/L3）无原生可验证 VRF——目前开奖用 blockhash
commit-reveal + 公证快照，信任假设 = 中心化 sequencer 可影响块哈希（审计 L-1 已记录）。

**调研事实**：
- 同为 Robinhood Chain 生态的项目已确认："no decentralized randomness oracle is confirmed live on 4663 today：
  native Chainlink VRF is absent, Pyth Entropy / Gelato VRF / Supra dVRF / API3 均为可自行部署到 Orbit 链但需
  provider onboarding"（github.com/imDev2023/Play-2-Earn issues #11）。
- Chainlink VRF v2.5 在 Arbitrum One 主网等公链上可用，但自定义 Orbit 链默认不支持（需 Chainlink 方接入）。
- Pyth Entropy 合约可自部署到任意 EVM 链，但 fulfill 需要 Pyth 后端/自托管 provider 签名——自托管则信任面回到自己。

**主网随机源选型优先级**（上线前按当时可用性定）：
1. **首选**：届时若 Chainlink VRF / Pyth Entropy 已支持 Robinhood 主网 → 直接接入（业界标准，可验证叙事最强）。
2. **次选（完全免入驻、可立即自研）**：drand（League of Entropy 公开信标）——开奖时承诺一个未来的 drand
   round，keeper 取回公开信标值 + 链上 BLS 验签，任何第三方可验证；工程成本中等（keeper 多一步取信标 +
   合约加验签模块），信任面为整个联盟（多方诚实即可）。
3. **保底**：维持现状 blockhash commit-reveal + 条款披露"开奖依赖 sequencer 不作恶"。

**行动项**：主网启动前查 Pyth/Chainlink 链支持清单 + 向 Robinhood 团队提 oracle 接入需求（其生态在建）。
**09-17 更新**：用户拍板「VRF 必须链上可验证」→ 定稿自研 HoodVRF（drand + EIP-2537 链上验签，keeper 仅是邮差、
履约免许可；TEE/eVRF 路线已否决）。EIP-2537 探测已完成：测试网 0x0b/0x0c/0x0e/0x0f/0x10 预编译全部在位，
**主网 4663 上线前需复跑同样探测**。详细设计见 `docs/vrf-design.md`，排期在发行者计划之后、与 V5 core 同审计。

---

## 13. 连买充能抽奖系统（2026-09-14 上线，纯链下）

**玩法**：自购付费票（TicketPurchased，与购票榜同口径）按 UTC 自然日累计连买——
连买 7 天 → 抽小奖 1 次（每满 7 天再得 1 次）；连买每满 14 天且该 14 天段内 ≥500 票 → 抽大奖 1 次。
小奖/大奖各 6 个实物奖品，名称+概率后台可改（/admin 按**百分比两位小数**编辑，最低 0.01%，每组 Σ 必须 =100%，
存储为权重 = 百分比×100、每组 Σ=10000），中奖后 TG 联系客服人工履约。

**架构**：
- streak 完全从链上事件推导（server.mjs `computeStreak`，块时间戳模块级 Map 缓存）；阈值 env
  `STREAK_SMALL_DAYS/STREAK_BIG_DAYS/STREAK_BIG_TICKETS`（默认 7/14/500）。
- 持久化 = **GCS bucket `jackpothood-app-prizes`**（asia-east1，uniform access，runtime SA
  237361412264-compute@… 有 objectAdmin；env `PRIZE_BUCKET`）。对象：`config/prizes.json`（6+6 配置，
  读不到走代码内默认配置）、`draws/{addr}.json`（抽奖记录 + bonus 测试额度）。
  本地 dev 无 PRIZE_BUCKET → 写 `frontend/.devdata/`（已 gitignore/dockerignore）。
- 写安全：抽奖前重算 streak（不信缓存）+ `mutateStore` 原子变更（读→fn→GCS ifGenerationMatch 条件写，
  412 重读**重跑 fn 重校额度**，另加进程内互斥锁；并发双抽已实测 1 成功 3 sold_out）；
  额度公式 available = earned − 本段 streak 已抽 + bonus；**bonus 被用掉时在档案里显式 −1**（防跨周期复活）。
- 限流（IP 滑动窗口，429）：/api/streaks 30/min、/api/draw 10/min、/api/draws/recent 60/min。
- 端点（server.mjs，全 JSON no-store）：GET /api/streaks?addr=（含 prizes/myDraws/thresholds，8s 缓存）、
  POST /api/draw、POST /api/draws/claim、GET /api/draws/recent（60s，短显地址无 id）、
  POST /api/admin/prizes|draws|fulfill|grant（签名者须 == 链上 admin()，缓存 5min；**消息带 ts，10 分钟
  有效窗口 + GCS `admin/used-sigs.json` 签名哈希注册表 48h 防重放**，同签名二次使用 401 replay）。
- 签名消息（personal_sign，前后端逐字节一致，改任一端必须同步）：
  抽奖 `JackpotHood 抽奖授权\n地址:{addr小写}\n档位:{tier}\n周期:{streakStart|none}`；
  领奖 `JackpotHood 领奖登记\n{id}`；管理 `JackpotHood 管理操作\n{prizes sha256hex|draws 日期|fulfill id|grant addr tier}\n{ts毫秒}`。
- 前端：ChargeCard 组件（App.jsx 尾部，side-col 顶部）：7 格绿/14 格蓝分段电池 + 票数细条 + 最近中奖播报；
  modal 轮播定格动画；购票成功后即时刷新 streaks。/admin「🎁 抽奖奖品配置」区：编辑 6+6、概率预览、
  记录台账（标记已发放）、发放测试额度（grant，QA 用）。
- 已知小冗余：i18n 的 quickBuyN/bulkLabel 键已不被引用（保留无害）；quickPick 键与一旧死键重名（后者无引用）。
- 移动端适配（09-14，00040-7w2，纯 CSS）：≤640px 时 quickgen 两行（机选行 + 4 快捷 chip 均分行）、
  大奖电池 7+7 两行、抽奖/领奖按钮全宽 ≥44px、modal 左右 12px + 85vh 滚动、invite-slim 纵排按钮全宽；
  641-900px 充能卡限宽 460px 居中。已用 ~503 CSS px 真窗口实测渲染（临时 Chrome profile，已清理）。

**履约流程**：用户抽中 → modal 点「联系客服领取」（前端自动 POST claim 登记 + 打开 TG）→ 运营在 /admin
抽奖记录核对 → 发货后点「标记已发放」。
