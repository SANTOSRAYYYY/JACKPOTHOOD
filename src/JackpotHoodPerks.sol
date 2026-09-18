// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice 最小 ERC20（JACKPOTHOOD）
interface IERC20P {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IJackpotBridge {
    function redeemPerkExternal(address recipient, uint8[6] calldata numbers, uint64 count) external;
    function paused() external view returns (bool);
}

/// @title JackpotHoodPerks —— JPH 质押免费票（从核心拆分）
/// @notice 质押 JACKPOTHOOD 每日累积免费票额度（每 10 万 JPH = 1 张/天，未领上限 3），
///         领用时调核心合约的 onlyPerk 免费出票入口。本合约不持有任何 ETH。
/// @dev 拆分的意义：核心合约聚焦资金账本并大幅瘦身；Perks 只做纯记账（JPH + 额度），
///         升级/审计互不牵连；免费票仍受核心每轮 1000 注上限约束，不引入新资金风险。
contract JackpotHoodPerks {
    IERC20P public immutable jph;
    IJackpotBridge public jackpot;
    address public admin;
    address public pendingAdmin;

    uint64 public constant MAX_STORED_PERK = 3; // 未领免费票上限 3（激励用户上线）
    uint64 public constant DAY = 86400;

    mapping(address => uint256) public jphStaked;
    mapping(address => uint64) public storedPerk;
    mapping(address => uint64) public lastAccrueDay;

    bool private _locked;

    event JphStaked(address indexed user, uint256 amount);
    event JphUnstaked(address indexed user, uint256 amount);
    event PerkRedeemed(address indexed user, uint8[6] numbers, uint64 count);
    event AdminTransferStarted(address indexed currentAdmin, address indexed newAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    modifier onlyAdmin() {
        require(msg.sender == admin, "JPH: not admin");
        _;
    }

    modifier nonReentrant() {
        require(!_locked, "JPH: reentrant");
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address jph_, address jackpot_) {
        require(jph_ != address(0) && jackpot_ != address(0), "JPH: zero address");
        jph = IERC20P(jph_);
        jackpot = IJackpotBridge(jackpot_);
        admin = msg.sender;
    }

    // ---------------------------------------------------------------
    // JPH 质押与每日额度（惰性结算，未领上限 3）
    // ---------------------------------------------------------------

    function stakeJph(uint256 amount) external nonReentrant {
        require(amount > 0, "JPH: zero amount");
        _accruePerk(msg.sender);
        require(jph.transferFrom(msg.sender, address(this), amount), "JPH: jph transferFrom failed");
        jphStaked[msg.sender] += amount;
        if (lastAccrueDay[msg.sender] == 0) lastAccrueDay[msg.sender] = uint64(block.timestamp / DAY);
        emit JphStaked(msg.sender, amount);
    }

    function unstakeJph(uint256 amount) external nonReentrant {
        require(amount > 0, "JPH: zero amount");
        _accruePerk(msg.sender);
        require(jphStaked[msg.sender] >= amount, "JPH: insufficient jph stake");
        jphStaked[msg.sender] -= amount;
        require(jph.transfer(msg.sender, amount), "JPH: jph transfer failed");
        emit JphUnstaked(msg.sender, amount);
    }

    /// @notice 每 10 万 JPH = 1 张/天（线性）
    function jphPerkPerDay(address user) public view returns (uint64) {
        return uint64(jphStaked[user] / 100_000 ether);
    }

    function _accruePerk(address user) internal {
        uint64 day = uint64(block.timestamp / DAY);
        uint64 last = lastAccrueDay[user];
        if (last == 0) {
            lastAccrueDay[user] = day;
            return;
        }
        if (day <= last) return;
        uint64 rate = jphPerkPerDay(user);
        if (rate > 0) {
            uint64 gained = uint64(day - last) * rate;
            uint64 next = storedPerk[user] + gained;
            storedPerk[user] = next > MAX_STORED_PERK ? MAX_STORED_PERK : next;
        }
        lastAccrueDay[user] = day;
    }

    function perkBalance(address user) public view returns (uint64) {
        uint64 day = uint64(block.timestamp / DAY);
        uint64 last = lastAccrueDay[user];
        uint64 accrued = storedPerk[user];
        if (last == 0 || day <= last) return accrued;
        uint64 total = accrued + uint64(day - last) * jphPerkPerDay(user);
        return total > MAX_STORED_PERK ? MAX_STORED_PERK : total;
    }

    /// @notice 领取免费票：额度扣减后调用核心合约 onlyPerk 入口出票
    function redeemPerkTicket(uint8[6] calldata numbers, uint64 count) external nonReentrant {
        require(!jackpot.paused(), "JPH: paused");
        _accruePerk(msg.sender);
        require(storedPerk[msg.sender] >= count, "JPH: no stored perk");
        storedPerk[msg.sender] -= count;
        jackpot.redeemPerkExternal(msg.sender, numbers, count);
        emit PerkRedeemed(msg.sender, numbers, count);
    }

    /// @notice 批量领取（多组不同号码一次交易，总注数受 storedPerk 与核心每轮 1000 上限约束）
    function redeemPerkTickets(uint8[6][] calldata numbersList, uint64[] calldata counts) external nonReentrant {
        require(numbersList.length > 0 && numbersList.length == counts.length, "JPH: bad batch");
        require(numbersList.length <= 200, "JPH: batch too large");
        uint64 need;
        for (uint256 i = 0; i < numbersList.length; i++) {
            require(counts[i] >= 1 && counts[i] <= 1000, "JPH: bad count");
            need += counts[i];
        }
        require(!jackpot.paused(), "JPH: paused");
        _accruePerk(msg.sender);
        require(storedPerk[msg.sender] >= need, "JPH: no stored perk");
        storedPerk[msg.sender] -= need;
        for (uint256 i = 0; i < numbersList.length; i++) {
            jackpot.redeemPerkExternal(msg.sender, numbersList[i], counts[i]);
        }
        emit PerkRedeemed(msg.sender, numbersList[0], need);
    }

    // ---------------------------------------------------------------
    // 管理（两步转移）
    // ---------------------------------------------------------------

    function proposeAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "JPH: zero admin");
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "JPH: not pending admin");
        emit AdminTransferred(admin, msg.sender);
        admin = msg.sender;
        pendingAdmin = address(0);
    }
}
