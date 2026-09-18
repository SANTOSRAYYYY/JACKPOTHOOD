// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PerkRouter} from "./PerkRouter.sol";

/// @notice 最小 ERC20 接口（JACKPOTHOOD）
interface IPresaleToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice core 的 ETH 质押入口（finalize 时 60% 锁入）
interface ICoreStake {
    function stakeEth() external payable;
}

/// @title JackpotHoodPresale —— 社区轮预售（阶梯价 ETH 认购，附 JPH 派发与推荐奖）
/// @notice 100,000 张额度，阶梯价：前 20,000 张 0.0008 ETH/张，20,001–50,000 张 0.0009，
///         50,001–100,000 张 0.001。每张附送 10 JPH，有效推荐人每张奖 0.5 JPH。
///         认购结束（售罄或到期）后：买家凭 credits 经 PerkRouter 在 core 兑换免费票；
///         finalize 把 ETH 收入 60% 质押进 core（永久锁定）、20/10/10 分账。
/// @dev 本合约无 admin、无任何提取/赎回函数：
///      - ETH 只能在 finalize 一次性按固定比例分流，此后合约余额恒为 0；
///      - 质押进 core 的 60% 记在 presale 合约名下，而本合约没有 requestUnstake /
///        finalizeUnstake / claimStakeRewards 入口 → 该部分本金与分红永久锁定；
///      - 未派完的 JPH 只能经 burnUnsold 转入黑洞地址。
contract JackpotHoodPresale {
    uint64 public constant CAP = 100_000;      // 预售总量（张）
    uint64 public constant TIER1_END = 20_000; // 第 1 档上界
    uint64 public constant TIER2_END = 50_000; // 第 2 档上界
    uint256 public constant PRICE1 = 0.0008 ether;
    uint256 public constant PRICE2 = 0.0009 ether;
    uint256 public constant PRICE3 = 0.001 ether;

    uint256 public constant JPH_PER_TICKET = 10 ether; // 每张附送 JPH
    uint256 public constant REF_PER_TICKET = 0.5 ether; // 推荐奖（每张）
    uint64 public constant NFT_THRESHOLD = 500; // GenesisNFT2 领取门槛（累计购入张数）

    IPresaleToken public immutable jph;
    PerkRouter public immutable router;
    address public immutable core;
    uint64 public immutable startTime;
    uint64 public immutable endTime;
    address public immutable liquidityTo;
    address public immutable treasuryTo;
    address public immutable marketingTo;

    uint64 public sold; // 已售张数
    mapping(address => uint64) public credits;   // 未兑换的免费票额度
    mapping(address => uint64) public purchased; // 累计购入（NFT 门槛用，不随兑换减少）
    bool public finalized;
    bool private _locked;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    event PresaleBuy(address indexed buyer, uint64 qty, uint256 cost, address indexed referrer);
    event PresaleRedeem(address indexed buyer, uint64 count);
    event Finalized(uint256 staked, uint256 liquidity, uint256 treasury, uint256 marketing);

    modifier nonReentrant() {
        require(!_locked, "Presale: reentrant");
        _locked = true;
        _;
        _locked = false;
    }

    constructor(
        address _jph,
        address _router,
        uint64 _startTime,
        uint64 _duration,
        address _liquidityTo,
        address _treasuryTo,
        address _marketingTo,
        address _core
    ) {
        require(_jph != address(0) && _router != address(0) && _core != address(0), "Presale: zero address");
        require(
            _liquidityTo != address(0) && _treasuryTo != address(0) && _marketingTo != address(0),
            "Presale: zero split address"
        );
        require(_duration > 0, "Presale: zero duration");
        jph = IPresaleToken(_jph);
        router = PerkRouter(_router);
        core = _core;
        startTime = _startTime;
        endTime = _startTime + _duration;
        liquidityTo = _liquidityTo;
        treasuryTo = _treasuryTo;
        marketingTo = _marketingTo;
    }

    /// @notice 允许直接转 ETH 进来（与认购款一起在 finalize 时按同一比例分账）
    receive() external payable {}

    // ---------------------------------------------------------------
    // 阶梯价
    // ---------------------------------------------------------------

    /// @notice 从当前 sold 起算，购买 n 张的总价（跨档分段求和）
    function priceOf(uint64 n) public view returns (uint256) {
        return _priceFrom(sold, n);
    }

    function _priceFrom(uint64 from, uint64 n) internal pure returns (uint256 total) {
        uint256 remaining = n;
        if (from < TIER1_END && remaining > 0) {
            uint256 inTier = _min(remaining, TIER1_END - from);
            total += inTier * PRICE1;
            from += uint64(inTier);
            remaining -= inTier;
        }
        if (from < TIER2_END && remaining > 0) {
            uint256 inTier = _min(remaining, TIER2_END - from);
            total += inTier * PRICE2;
            from += uint64(inTier);
            remaining -= inTier;
        }
        if (remaining > 0) {
            total += remaining * PRICE3;
        }
    }

    // ---------------------------------------------------------------
    // 认购
    // ---------------------------------------------------------------

    /// @notice 认购：尾单自动截断到剩余量，只收实际售出张数的钱
    /// @param n 想买的张数（>0；sold+n>CAP 时按 CAP-sold 计）
    /// @param referrer 推荐人（0 地址或本人则不发推荐奖）
    function buy(uint64 n, address referrer) external payable nonReentrant {
        require(block.timestamp >= startTime, "Presale: not started");
        require(block.timestamp < endTime, "Presale: ended");
        require(sold < CAP, "Presale: sold out");
        require(n > 0, "Presale: zero qty");
        uint64 remaining = CAP - sold;
        if (n > remaining) n = remaining;
        uint256 cost = priceOf(n);
        require(msg.value == cost, "Presale: wrong ETH amount");

        sold += n;
        credits[msg.sender] += n;
        purchased[msg.sender] += n;

        // 附送 JPH：池子不足时转剩余（min），不卡单
        uint256 due = uint256(n) * JPH_PER_TICKET;
        uint256 pay = _min(due, jph.balanceOf(address(this)));
        if (pay > 0) require(jph.transfer(msg.sender, pay), "Presale: jph transfer failed");

        // 推荐奖：非 0、非 buyer，同样按池子余额 min 派发
        if (referrer != address(0) && referrer != msg.sender) {
            uint256 refDue = uint256(n) * REF_PER_TICKET;
            uint256 refPay = _min(refDue, jph.balanceOf(address(this)));
            if (refPay > 0) require(jph.transfer(referrer, refPay), "Presale: ref transfer failed");
        }

        emit PresaleBuy(msg.sender, n, cost, referrer);
    }

    /// @notice 认购阶段是否已结束（售罄或到期）。结束后才开放 redeem / finalize。
    function isOpen() public view returns (bool) {
        return sold == CAP || block.timestamp >= endTime;
    }

    // ---------------------------------------------------------------
    // 兑换免费票（经 PerkRouter → core，受 core 每轮免费上限约束）
    // ---------------------------------------------------------------

    function redeem(uint8[6] calldata numbers, uint64 count) external nonReentrant {
        require(isOpen(), "Presale: not open");
        require(count >= 1, "Presale: zero count");
        require(credits[msg.sender] >= count, "Presale: insufficient credits");
        credits[msg.sender] -= count;
        router.redeemPerkExternal(msg.sender, numbers, count);
        emit PresaleRedeem(msg.sender, count);
    }

    /// @notice 批量兑换：多组号码一次交易（≤100 组，总注数 ≤ credits）
    function redeemBatch(uint8[6][] calldata numbersList, uint64[] calldata counts) external nonReentrant {
        require(isOpen(), "Presale: not open");
        require(numbersList.length > 0 && numbersList.length == counts.length, "Presale: bad batch");
        require(numbersList.length <= 100, "Presale: batch too large");
        uint64 need;
        for (uint256 i = 0; i < counts.length; i++) {
            require(counts[i] >= 1, "Presale: bad count");
            need += counts[i];
        }
        require(credits[msg.sender] >= need, "Presale: insufficient credits");
        credits[msg.sender] -= need;
        for (uint256 i = 0; i < numbersList.length; i++) {
            router.redeemPerkExternal(msg.sender, numbersList[i], counts[i]);
        }
        emit PresaleRedeem(msg.sender, need);
    }

    // ---------------------------------------------------------------
    // 收尾（任何人可触发，一次性）
    // ---------------------------------------------------------------

    /// @notice 分账：60% 质押进 core（永久锁定，本合约不提供任何提取/赎回入口）、
    ///         20% 流动性、10% 国库、10% 市场。整除余量并入 marketing，防 wei 尘埃滞留。
    function finalize() external nonReentrant {
        require(isOpen(), "Presale: not open");
        require(!finalized, "Presale: already finalized");
        finalized = true;

        uint256 bal = address(this).balance;
        uint256 s60 = bal * 60 / 100;
        uint256 l20 = bal * 20 / 100;
        uint256 t10 = bal * 10 / 100;
        uint256 m10 = bal - s60 - l20 - t10;

        if (s60 > 0) ICoreStake(core).stakeEth{value: s60}();
        (bool okL, ) = payable(liquidityTo).call{value: l20}("");
        require(okL, "Presale: liquidity transfer failed");
        (bool okT, ) = payable(treasuryTo).call{value: t10}("");
        require(okT, "Presale: treasury transfer failed");
        (bool okM, ) = payable(marketingTo).call{value: m10}("");
        require(okM, "Presale: marketing transfer failed");

        emit Finalized(s60, l20, t10, m10);
    }

    /// @notice finalize 后把未派完的 JPH 全部转入黑洞地址
    function burnUnsold() external nonReentrant {
        require(finalized, "Presale: not finalized");
        uint256 bal = jph.balanceOf(address(this));
        require(bal > 0, "Presale: nothing to burn");
        require(jph.transfer(DEAD, bal), "Presale: burn transfer failed");
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
