// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {HoodBLS} from "./HoodBLS.sol";
import {IVrfConsumer} from "./IVrfConsumer.sol";

/// @title HoodVRF —— 基于 drand quicknet 的可验证随机数服务（链上 BLS 验签，免许可履约）
/// @dev 流程：request 锁定未来某轮 drand（roundAt(now + MIN_DELAY)）→ 该轮产出后任何人提交该轮
///      BLS 签名 (σ) 履约：合约用 EIP-2537 预编译验证 e(σ, g2) == e(H(sha256(round)), pk)，
///      随机数 = keccak256(σ 压缩编码)，再回调 consumer.onRandom（失败可 retryCallback 重投）。
///      资金安全：费用累计进 feeBalance，admin 提现不超过 feeBalance；履约补贴也从 feeBalance 出。
///      公钥合法性（在 G2 曲线上且在正确子群）由部署脚本离线/链上校验（见 DeployVRF.s.sol）。
///      降级：fallbackMode 仅留开关与事件，blockhash 承诺路径由 consumer 自行实现。
contract HoodVRF {
    // ---------------------------------------------------------------
    // 常量与数据结构
    // ---------------------------------------------------------------

    uint64 public constant DRAND_GENESIS = 1692803367; // quicknet 创世时间（/info 实测）
    uint64 public constant DRAND_PERIOD = 3;           // quicknet 3 秒/轮
    uint64 public constant MIN_DELAY = 60;             // 请求至少锁定 60s 后的未来轮
    uint256 public constant DEFAULT_FEE = 0.0002 ether;
    uint256 public constant DEFAULT_REWARD = 0.00005 ether;
    uint32 public constant DEFAULT_CALLBACK_GAS = 300_000; // 回调 gas 上限（防 consumer 烧干履约方）

    struct Request {
        address consumer;   // 接收回调的合约
        uint64 drandRound;  // 锁定的 drand 轮次
        uint64 ts;          // 请求时间
        bool paid;          // 是否付费请求（付费请求的履约才发补贴）
    }

    // ---------------------------------------------------------------
    // 状态
    // ---------------------------------------------------------------

    address public admin;
    address public pendingAdmin;
    uint256 public fee;           // 单次请求费用（admin 可调）
    uint256 public fulfillReward; // 履约补贴（admin 可调）
    uint256 public feeBalance;    // 累计费用余额（提现与补贴的唯一资金来源）
    uint32 public callbackGas = DEFAULT_CALLBACK_GAS;
    bool public fallbackMode;     // 降级开关（逻辑在 consumer 侧，这里只留痕）
    uint256 public nextId = 1;
    /// @dev EIP-2537 编码的 G2 公钥（256 字节：x_c0||x_c1||y_c0||y_c1，Fp 高 16 字节为零）
    bytes public drandPkG2;

    mapping(uint256 => Request) internal _requests;
    /// @notice 已履约随机数（0 = 未履约）
    mapping(uint256 => bytes32) public randomnessOf;
    /// @notice 免费白名单（请求方或 consumer 任一在列即免费）
    mapping(address => bool) public freeWhitelist;

    // ---------------------------------------------------------------
    // 事件与错误
    // ---------------------------------------------------------------

    event Requested(uint256 indexed id, address indexed consumer, uint64 drandRound, bool paid, bool fallbackMode);
    event Fulfilled(uint256 indexed id, uint64 drandRound, bytes32 randomness, address indexed fulfiller);
    event CallbackFailed(uint256 indexed id, address indexed consumer);
    event CallbackOk(uint256 indexed id);
    event RewardPaid(uint256 indexed id, address indexed to, uint256 amount);
    event FeeSet(uint256 fee);
    event RewardSet(uint256 reward);
    event CallbackGasSet(uint32 callbackGas);
    event WhitelistSet(address indexed account, bool free);
    event FallbackSet(bool on);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event AdminTransferStarted(address indexed oldAdmin, address indexed newAdmin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    error NotAdmin();
    error NotPendingAdmin();
    error BadConsumer();
    error BadAdmin();
    error FeeTooLow();
    error RefundFailed();
    error WithdrawFailed();
    error UnknownRequest();
    error AlreadyFulfilled();
    error NotFulfilled();
    error RoundNotYetEmitted();
    error BeforeGenesis();
    error BadRound();

    // ---------------------------------------------------------------
    // 构造与 admin
    // ---------------------------------------------------------------

    /// @param pkG2Uncompressed 非压缩 G2 公钥 192 字节（x_c0||x_c1||y_c0||y_c1 各 48 字节，
    ///        由 quicknet /info 的 96 字节压缩公钥离线解压得到，见 DeployVRF.s.sol 注释）
    constructor(bytes memory pkG2Uncompressed, uint256 fee_, uint256 reward_) {
        if (pkG2Uncompressed.length != 192) revert HoodBLS.BadLength();
        admin = msg.sender;
        fee = fee_;
        fulfillReward = reward_;
        // 逐分量校验 < p 并编码为 EIP-2537 格式（Fp 前补 16 零字节）
        bytes memory enc = new bytes(256);
        for (uint256 i = 0; i < 4; i++) {
            bytes memory comp = _slice48(pkG2Uncompressed, i);
            HoodBLS.checkFp48(comp);
            assembly {
                mcopy(add(add(enc, 32), add(mul(i, 64), 16)), add(comp, 32), 48)
            }
        }
        drandPkG2 = enc;
        emit FeeSet(fee_);
        emit RewardSet(reward_);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @dev 两步转移：先提名
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert BadAdmin();
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    /// @dev 被提名方接受
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        address old = admin;
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminTransferred(old, msg.sender);
    }

    function setFee(uint256 f) external onlyAdmin {
        fee = f;
        emit FeeSet(f);
    }

    function setFulfillReward(uint256 r) external onlyAdmin {
        fulfillReward = r;
        emit RewardSet(r);
    }

    function setCallbackGas(uint32 g) external onlyAdmin {
        callbackGas = g;
        emit CallbackGasSet(g);
    }

    function setFreeWhitelist(address account, bool free) external onlyAdmin {
        freeWhitelist[account] = free;
        emit WhitelistSet(account, free);
    }

    /// @dev 降级模式开关（仅留痕；blockhash 承诺路径由 consumer 自行处理）
    function setFallbackMode(bool on) external onlyAdmin {
        fallbackMode = on;
        emit FallbackSet(on);
    }

    /// @notice admin 提现累计费用（严格限于 feeBalance；合约不接受也无其他资金）
    function withdrawFees() external onlyAdmin {
        uint256 amt = feeBalance;
        feeBalance = 0;
        (bool ok,) = admin.call{value: amt}("");
        if (!ok) revert WithdrawFailed();
        emit FeesWithdrawn(admin, amt);
    }

    // ---------------------------------------------------------------
    // 请求
    // ---------------------------------------------------------------

    /// @notice 为自己发起随机数请求
    function request() external payable returns (uint256 id) {
        return _request(msg.sender);
    }

    /// @notice 为指定 consumer 发起请求（代付场景）
    function requestFor(address consumer) external payable returns (uint256 id) {
        if (consumer == address(0)) revert BadConsumer();
        return _request(consumer);
    }

    function _request(address consumer) internal returns (uint256 id) {
        bool free = freeWhitelist[msg.sender] || freeWhitelist[consumer];
        uint256 f = fee;
        bool paid;
        if (!free && f > 0) {
            if (msg.value < f) revert FeeTooLow();
            paid = true;
            feeBalance += f;
        }
        if (msg.value > (paid ? f : 0)) {
            uint256 excess = msg.value - (paid ? f : 0);
            (bool ok,) = msg.sender.call{value: excess}("");
            if (!ok) revert RefundFailed();
        }
        id = nextId++;
        uint64 r = roundAtTime(uint64(block.timestamp) + MIN_DELAY);
        _requests[id] = Request({consumer: consumer, drandRound: r, ts: uint64(block.timestamp), paid: paid});
        emit Requested(id, consumer, r, paid, fallbackMode);
    }

    // ---------------------------------------------------------------
    // 履约（免许可）
    // ---------------------------------------------------------------

    /// @notice 提交 drand 签名履约：校验轮次已到 + σ 在曲线上 + 配对验签，存随机数并回调
    /// @param sigX / sigY σ（G1）非压缩坐标，各 48 字节大端（解压链下做）
    function fulfill(uint256 id, bytes calldata sigX, bytes calldata sigY) external {
        if (sigX.length != 48 || sigY.length != 48) revert HoodBLS.BadLength();
        Request storage req = _requests[id];
        if (req.consumer == address(0)) revert UnknownRequest();
        if (randomnessOf[id] != bytes32(0)) revert AlreadyFulfilled();
        uint64 r = req.drandRound;
        if (block.timestamp < timeOfRound(r)) revert RoundNotYetEmitted();
        bytes32 rnd = _verifyAndDerive(r, sigX, sigY);
        _storeRandomness(id, r, rnd);
        _payReward(id, req.paid);
        _deliver(id, req.consumer, rnd);
    }

    /// @notice 回调重投：随机数已存、上次回调失败时任何人可触发重新回调
    /// @dev 失败直接 revert（冒泡 consumer 原因），与 fulfill 的静默兜底互补
    function retryCallback(uint256 id) external {
        bytes32 rnd = randomnessOf[id];
        if (rnd == bytes32(0)) revert NotFulfilled();
        IVrfConsumer(_requests[id].consumer).onRandom{gas: callbackGas}(id, rnd);
        emit CallbackOk(id);
    }

    /// @notice 验签视图（keeper/调试工具）：返回将写入的随机数
    function verifyDrandSignature(uint64 round, bytes calldata sigX, bytes calldata sigY)
        external
        view
        returns (bytes32)
    {
        return _verifyAndDerive(round, sigX, sigY);
    }

    /// @notice hash_to_G1 视图（与链下实现对拍用）
    function hashToG1(bytes32 message) external view returns (bytes memory) {
        return HoodBLS.hashToG1(_pc(), message);
    }

    /// @dev 验签 + 派生随机数：默认走 HoodBLS 全流程；测试可继承覆盖为 mock
    function _verifyAndDerive(uint64 round, bytes calldata sigX, bytes calldata sigY)
        internal
        view
        virtual
        returns (bytes32)
    {
        HoodBLS.verify(_pc(), drandPkG2, sha256(abi.encodePacked(round)), sigX, sigY);
        return keccak256(HoodBLS.compressG1(sigX, sigY));
    }

    /// @dev 写入随机数（internal 便于测试继承直接构造履约状态）
    function _storeRandomness(uint256 id, uint64 round, bytes32 rnd) internal {
        randomnessOf[id] = rnd;
        emit Fulfilled(id, round, rnd, msg.sender);
    }

    /// @dev 付费请求的履约补贴：feeBalance 足够才发，转账失败则回滚记账不阻断履约
    function _payReward(uint256 id, bool paid) internal {
        uint256 amt = fulfillReward;
        if (!paid || amt == 0 || feeBalance < amt) return;
        feeBalance -= amt;
        (bool ok,) = msg.sender.call{value: amt}("");
        if (ok) emit RewardPaid(id, msg.sender, amt);
        else feeBalance += amt;
    }

    /// @dev 回调 consumer：EOA 无代码直接跳过（实测本链对 EOA 的接口回调会整体 revert）；
    ///      合约回调失败不 revert（随机数已存），记事件待 retryCallback
    function _deliver(uint256 id, address consumer, bytes32 rnd) internal {
        if (consumer.code.length == 0) {
            emit CallbackOk(id);
            return;
        }
        try IVrfConsumer(consumer).onRandom{gas: callbackGas}(id, rnd) {}
        catch {
            emit CallbackFailed(id, consumer);
        }
    }

    function _pc() internal pure returns (HoodBLS.Precompiles memory) {
        return HoodBLS.defaultPrecompiles();
    }

    // ---------------------------------------------------------------
    // 视图
    // ---------------------------------------------------------------

    /// @notice 时刻 t 对应的 drand 轮次（t 时刻已产出/将产出的最新一轮）
    function roundAtTime(uint64 t) public pure returns (uint64) {
        if (t < DRAND_GENESIS) revert BeforeGenesis();
        return (t - DRAND_GENESIS) / DRAND_PERIOD + 1;
    }

    /// @notice 轮次 r 的产出时刻（T(r) = genesis + (r-1)*period）
    function timeOfRound(uint64 r) public pure returns (uint64) {
        if (r == 0) revert BadRound();
        return DRAND_GENESIS + (r - 1) * DRAND_PERIOD;
    }

    function getRequest(uint256 id)
        external
        view
        returns (address consumer, uint64 drandRound, uint64 ts, bool paid, bool fulfilled)
    {
        Request storage req = _requests[id];
        return (req.consumer, req.drandRound, req.ts, req.paid, randomnessOf[id] != bytes32(0));
    }

    /// @dev 从 192 字节公钥 blob 中取第 idx 个 48 字节分量
    function _slice48(bytes memory v, uint256 idx) private pure returns (bytes memory out) {
        out = new bytes(48);
        assembly {
            mcopy(add(out, 32), add(add(v, 32), mul(idx, 48)), 48)
        }
    }
}
