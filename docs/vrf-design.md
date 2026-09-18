# HoodVRF 设计文档 —— Robinhood 链上的链上可验证 VRF

> 状态：设计定稿（2026-09-17）。实施排在：主网上线 → 发行者计划（C 方案）之后，与 V5 core 一起审计上线。
> 硬原则（用户拍板）：**VRF 必须链上可验证**——合约内亲自验签，不信任任何链下角色（包括 keeper/TEE 运营商）。
> 备选/否决记录：TEE/eVRF（MagicBlock 式）链上只能验"某钥匙签过名"，钥匙在 enclave 里靠链下证明信任 → **否决**；
> Chainlink VRF / Pyth Entropy 需官方接入 Robinhood，不可控 → 若届时已支持可再评估（见 HANDOFF §12）。

## 0. 关键基础设施事实（2026-09-17 实测）

**Robinhood 测试网已启用 EIP-2537（BLS12-381 预编译全套）**：
- 0x0b G1ADD：∞+∞ 返回 128B 全零 ✓；0x0f PAIRING：非法输入长度报错（存在且校验输入）✓
- 0x10 MAP_FP_TO_G1：返回真实曲线点 ✓；0x0c/0x0e MSM：长度校验报错（存在）✓
- 含义：链上 drand 验签成本 ≈ 一次配对对（pairing ~ 34k×2 + 45k gas 级）+ hash-to-curve（map 预编译 2 次），
  总 gas 估计 15-25 万，Orbit 块上限下完全无感。**主网上线前需在主网（4663）复跑一次同样探测**（cast call 同上）。

## 1. 随机源：drand（League of Entropy 公开信标）

- 信标：League of Entropy 主网（30s/轮）或 quicknet（3s/轮）；HTTP API 公开（api.drand.sh 等多镜像）。
- 每轮值 = BLS 签名 σ（G1），消息 = sha256(round_number uint64 BE)；随机数 = keccak256(σ)。
- 链上验证 = 一次 BLS 配对校验：e(σ, g2) == e(hashToG1(msg), pk_beacon)，pk_beacon 为联盟公钥（合约内 immutable）。

## 2. 协议流程（commit → fulfill，免许可）

1. **commit**：使用方合约（core V5 彩票结算、或任何外部合约）调 `HoodVRF.request()`：
   记录 `{requestId, caller, drandRound}`，drandRound = roundAt(block.timestamp + MIN_DELAY)（MIN_DELAY 取 60-90s，
   保证锁定后才揭晓）；任何人可见承诺，无法预测未来信标值。
2. **fulfill**：drandRound 对应的信标值产出后，**任何人**调 `fulfill(requestId, σ)`：
   合约验签（EIP-2537）→ 存 `randomness[requestId] = keccak256(σ)` → 回调 caller 合约的 `onRandom(requestId, rnd)`。
3. **开奖集成**：core V5 在 lock 时 request，settle 时要求 randomness 已落（keeper 承担常规履约，
   用户/第三方可强制履约——keeper 死了任何人都能开奖，这比现在的 keeper 依赖还强）。
4. **降级路径**（必须实现）：drand 信标停摆超过阈值（如 30 分钟）→ 允许 admin/治理切换到
   blockhash commit-reveal 备用模式并留下事件日志；恢复后可切回。彩票不能因外部信标停摆而永久卡死。

## 3. 合约组成

- `HoodVRF.sol`：request/fulfill/randomnessOf + BLS 验签模块（适配 drand 官方 solidity 校验代码到 EIP-2537
  预编译）+ 费用开关（外部调用收 VRF_FEE，默认 0.0002 ETH/次，core 调用免费白名单）。
- `HashToCurve` 库：drand 用的是 RFC 9380 hash-to-curve（SHA-256, expand_message_xmd, map FP→G1）——
  用 0x10 预编译实现 map 步，expand_message 用 Solidity keccak/sha256 实现。有现成开源实现可参照
  （drand 官方 drand-solidity 示例需改到预编译路径）。
- 测试：固定向量测试（拿 drand 某真实轮次的 (round, σ) 在测试里验签通过 + 篡改 σ 必失败）+ 模糊测试。

## 4. 对外服务形态

- 任何合约可付费用 request → fulfill 免许可（可给履约者小额补贴，从费用里出）。
- 文档页 + /vrf 状态页（信标活性、最近履约、验证入口链接）——"可验证公平"作为协议卖点展示。
- 彩票协议发行者的彩票默认接入 HoodVRF（发行参数里不可关闭）——共享流动性 + 可验证公平 = 协议两大卖点。

## 5. 与 core 的集成点（V5 草案，届时细化）

- V5 core 结算路径改为：lock → HoodVRF.request → settle 时读 randomness（替代现有 commitHash 快照流程，
  快照作为降级模式保留）。
- EIP-170 余量：core 已无空间 → VRF 全部逻辑在 HoodVRF 独立合约，core 只加一个接口调用。
- 现有 V4.4 测试网开奖机制不变，直到 V5 主网上线。

## 6. 风险清单

| 风险 | 缓解 |
|---|---|
| drand 信标停摆/延迟 | 降级模式 + 多 HTTP 镜像取信标 |
| hash-to-curve 实现 bug | 固定向量测试（官方测试向量）+ 第三方审计 |
| 信标值被"提前知道" | drandRound 必须 > 锁定期（MIN_DELAY 内禁止任何人预知）；任何人可复核时间戳 |
| 主网 4663 未启用 EIP-2537 | 上线前探测；若无则纯 Solidity BLS 库兜底（~30 万 gas，可用但贵） |
| keeper 不履约 | fulfill 免许可 + 履约补贴；用户可自助开奖 |

## 7. 行动项（按序）

1. ~~EIP-2537 探测~~（已完成，测试网全绿）
2. 主网上线时在 4663 复跑探测
3. ~~HoodVRF 合约开发 + 固定向量测试~~（09-18 完成，见下「测试网部署」）
4. 与 V5 core 一起送第三方审计
5. /vrf 状态页 + 对外文档 + keeper 履约循环（server.mjs 加 relayer，用 @noble/curves 离线解压签名）

## 8. 测试网部署（2026-09-18，已 E2E 验证）

- **HoodVRF 当前版：`0xBA8c0e39183BCD209caAFaE986D50cDD7E2Abb09`**（EOA 回调修复版）。
  ~~旧版 0x5249BcaD5E8EA38519b390cAB733b682428Fd57F~~ 已弃用（`_deliver` 对 EOA consumer 回调会在本链整体 revert——
  Orbit 链对无代码地址的接口调用行为与主网以太坊不同，教训：**consumer 是 EOA 的路径必须单独链上实测**）。
- 链上实测（request→drand 轮 32292055→fulfill）：随机数 `0x512ac69c…259b` 与链下 keccak 预期逐字节一致；
  fulfill gas ≈ 216k；费用 0.0002 ETH、履约补贴 0.00005 ETH 正常进出。
- forge 144/144 绿（HoodVRF 32 项 + 存量 112 项）；fork 实测两组真实 drand 向量验签通过（script/VerifyDrand.s.sol）。
- 履约辅助脚本：`frontend/.devdata/vrf_fulfill_helper.cjs`（压缩签名 → x,y + keccak，用 @noble/curves）。
