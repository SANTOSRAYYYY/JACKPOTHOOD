// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice 最小 ERC20 接口（JACKPOTHOOD，仅用于 JPH 质押换免费票）
/// @title JackpotHood V3 —— Robinhood Chain 每日链上彩票（ETH 奖池 + 双抽水 + 质押分红）
/// @dev 经济模型：
///      - 6 位号码，6 奖级（40/25/15/12/5/3），奖池与派彩全部为 ETH（天然通缩，无增发）
///      - 小奖项公平赔率封顶：单注赔付上限 = 命中率倒数（公平赔率）× 票价（末5~末1 = 100000/10000/1000/100/10 ×），头奖不限，超出部分滚存下期
///      - 买票抽水 10%：有推荐人时 5% 立付推荐人 + 5% 进质押分红池；无推荐人 10% 全进池（settle 时按 ETH 质押快照份额分配）
///      - 中奖领取再抽 12%：推荐人 5%（若有）+ 质押池 7%（无推荐人时 12% 全入池）
///      - ETH 质押（活期）：按每期结算时刻的份额瓜分分红池，手动领取；退出走三段式
///        （requestUnstake 申请 → 陪跑登记轮结算 → finalizeUnstake 领取），防结算前抢跑规避共担
///      - JPH 质押（Perks 合约，独立、不参与 ETH 分红）：每 100,000 JPH = 每天 1 张免费票，未领上限 3 张
///      - 免费票（管理员 grant/直发 + Perks 合约代发）：无票款，照常中奖兑奖（从奖池出）
///      - 初始奖池由平台注资（如 1 ETH，任何人也可随时注资奖池）
contract JackpotHood {
    // ---------------------------------------------------------------
    // 常量与数据结构
    // ---------------------------------------------------------------

    uint256 public constant NUMBER_LENGTH = 6;
    uint256 public constant MAX_DIGIT = 9;
    uint256 public constant MAX_UNITS_PER_BUY = 1000; // 单笔购票注数上限
    uint64 public constant CLAIM_WINDOW = 30 days;    // 兑奖时效
    uint64 public immutable lockWindow;  // 开奖前停售窗口（构造配置；测试网可短）
    uint256 public immutable roundDuration; // 轮周期（构造配置；主网 24h，测试网可 10min）
    bool public immutable anchorFirstUtc; // 首轮是否锚定下一个 UTC 00:00（测试网 false 则部署后即起算）
    uint256 public constant BUY_FEE_BPS = 1000;       // 买票抽水 10%（有推荐人：5% 立付推荐人 + 5% 进质押池）
    uint256 public constant WIN_FEE_BPS = 1200;       // 中奖抽水 12%（派彩时扣）
    uint256 public constant REFERRAL_BPS = 500;       // 推荐人 = 被推荐人奖金的 5%（从中奖抽水里出）
    uint256 public constant TICKET_PRICE = 0.001 ether;
    uint256 public constant MAX_FREE_PER_ROUND = 1000; // 免费票每期注数上限（防稀释）
    /// @dev 小奖项公平赔率封顶倍数（0 = 不封顶）：index 对应 tierPots 顺序 [头奖, 末5, 末4, 末3, 末2, 末1]，
    ///      倍数 = 该档命中率倒数。单档派彩上限 = 倍数 × TICKET_PRICE × 该档中奖注数。
    ///      （Solidity 不支持数组常量，规格表 [0, 100000, 10000, 1000, 100, 10] 以纯函数表达。）
    function _payoutCapMult(uint256 tier) internal pure returns (uint256) {
        if (tier == 1) return 100000; // 末 5 位，命中率 1/100000
        if (tier == 2) return 10000;  // 末 4 位，1/10000
        if (tier == 3) return 1000;   // 末 3 位，1/1000
        if (tier == 4) return 100;    // 末 2 位，1/100
        if (tier == 5) return 10;     // 末 1 位，1/10
        return 0;                     // 头奖不封顶
    }
    uint256 public constant MIN_STAKE = 0.01 ether;   // ETH 首次质押最低额（防粉尘质押瘫痪 settle 遍历；追加质押不受限）

    /// @dev 免费票哨兵 gifter：免费出票（管理员 freeTicket / 额度领用 / Perks 合约代发）统一标记，
    ///      不参与退款、不计 ticketFee（无票款）；照常参与开奖兑奖。
    address internal constant FREE_TICKET = address(0x000000000000000000000000000000000000dEaD);

    enum Status {
        Open,
        Committed,
        Drawn,
        Voided
    }

    struct Round {
        uint64 salesEnd;
        uint64 drawAt;
        uint64 randomBlock;
        uint64 claimDeadline;
        uint256 prizePool;      // 本轮 ETH 奖池（wei，随注资/滚存增加）
        uint256 totalTickets;   // 购票注数（免费票计入）
        uint256 ticketRevenue;  // 购票票款全款（含 10% 抽水；退款基准）
        uint256 ticketFee;      // 本轮买票抽水累计（购票推荐人已立付的 5% 不记入；settle 时转入质押池；void 时并入滚存）
        uint48 winningPacked;   // 6 位开奖号码
        bytes32 commitHash;     // 承诺区块哈希公证快照（快照后永久可结算）
        bytes32 seedHash;       // 随机源区块哈希（公证）
        uint256[6] tierPots;    // [全6 40%, 末5 25%, 末4 15%, 末3 12%, 末2 5%, 末1 3%]
        uint256[6] tierUnits;
        uint256[6] tierClaimed;
        bool swept;
        Status status;
    }

    struct Ticket {
        uint48 numbersPacked;
        uint64 count;
        address gifter; // address(0)=自购；FREE_TICKET=免费；其他=付费赠送者
        bool claimed;
        bool refunded;
    }

    /// @dev 质押退出挂单：申请后陪跑登记轮结算（防结算前抢跑规避共担），该轮终态后领取。
    ///      挂单期间记账侧不动（ethStaked/totalEthStaked 不变），照常承担共担清算与分红。
    struct UnstakeReq {
        uint256 amount;
        uint64 roundId; // 首个未结算轮：申请时当轮 Open/Committed 记当轮，否则记下一轮
    }

    // ---------------------------------------------------------------
    // 状态
    // ---------------------------------------------------------------

    address public admin;
    address internal pendingAdmin;
    bool public paused;
    bool private _locked;

    uint256 public currentRoundId;
    mapping(uint256 => Round) internal rounds; // 外部读取走 getRound/getCurrentRound（省 struct 大 getter 字节）
    mapping(uint256 => mapping(uint256 => uint256)) private comboUnits; // roundId => combo(0..999999) => 注数
    mapping(uint256 => mapping(uint8 => uint256)) private lastDigitUnits; // roundId => 个位数字 => 注数（六等=末1 档统计用，避免十万桶穷举）
    mapping(uint256 => mapping(address => Ticket[])) private userTickets;
    mapping(uint256 => uint64) public freeMinted; // roundId => 免费出票注数（cap）
    mapping(address => uint256) public freeCredits; // 管理员发放的免费票额度

    // ETH 质押（活期）：本金独立记账（stakeCash 桶，质押者按净值两段式提走，不动兑奖资金）；
    // 大奖超过「票款银行」时按全体质押者份额比例即时清算（共担亏损，不冻结）
    uint256 public totalEthStaked;
    mapping(address => uint256) public ethStaked;
    uint256 public stakeCash;   // 质押现金桶（入：质押；出：finalizeUnstake 领取 / 大奖共担清算）
    uint256 public ticketBank;  // 票款银行（入：票款90%+注资+滚存；出：兑奖；不足时质押共担）
    uint256 public stakingPool; // 未分配的抽水（settle 时清空）
    mapping(address => uint256) public pendingStakeRewards; // 已按快照分给质押者、待手动领取
    mapping(address => UnstakeReq) public unstakeReqOf; // 质押退出挂单（一人一单，终态后领取）

    // Perks 合约白名单：唯一可代用户发免费票（JPH 质押免费票逻辑已独立到 JackpotHoodPerks）
    address public perkContract;

    // 推荐（被推荐人中奖的 5% 从中奖抽水里出；购票侧 5% 从买票抽水里立付）
    mapping(address => address) private referrerOf;
    mapping(uint256 => uint256) public referralPaidPerRound; // roundId => 本轮购票已立付推荐人总额（审计/守恒跟踪用）

    uint256 public pendingRollover; // 待滚存 ETH（下一轮吸收）

    // ---------------------------------------------------------------
    // 事件
    // ---------------------------------------------------------------

    event RoundStarted(uint256 indexed roundId, uint64 salesEnd, uint64 drawAt, uint256 openingPool);
    event TicketPurchased(uint256 indexed roundId, address indexed buyer, uint256 indexed ticketIndex, uint8[6] numbers, uint64 count, uint256 pricePaid);
    event TicketGifted(uint256 indexed roundId, address indexed gifter, address indexed recipient, uint256 ticketIndex, uint8[6] numbers, uint64 count, uint256 pricePaid);
    event FreeTicketIssued(uint256 indexed roundId, address indexed recipient, uint256 ticketIndex, uint8[6] numbers, uint64 count);
    event DrawCommitted(uint256 indexed roundId, uint64 randomBlock);
    event CommitHashSnapshotted(uint256 indexed roundId, uint64 randomBlock, bytes32 commitHash);
    event RoundSettled(uint256 indexed roundId, uint8[6] winningNumbers, bytes32 seedHash, uint256 prizePool, uint256[6] tierPots, uint256[6] tierUnits, uint256 rolloverOut, uint256 stakingPaid);
    event PrizeClaimed(uint256 indexed roundId, address indexed user, uint256 ticketCount, uint256 amount);
    event EthStaked(address indexed user, uint256 amount);
    event StakerLossShared(uint256 indexed roundId, uint256 amount);
    event EthUnstaked(address indexed user, uint256 amount); // 旧即时退出事件（V4.4 起 unstakeEth 停用，保留事件签名兼容索引）
    event UnstakeRequested(address indexed user, uint256 amount, uint64 roundId);
    event UnstakeFinalized(address indexed user, uint256 amount);
    event StakeRewardsClaimed(address indexed user, uint256 amount);
    event PrizeEthInjected(address indexed from, uint256 amount, uint256 creditedRoundId);
    event UnclaimedSwept(uint256 indexed roundId, uint256 amount, uint256 creditedRoundId);
    event RoundVoided(uint256 indexed roundId, uint256 reservedRefunds);
    event TicketsRefunded(uint256 indexed roundId, address indexed user, uint256 ticketCount, uint256 amount);
    event ReferrerSet(address indexed user, address indexed referrer);
    event ReferralPurchasePaid(address indexed buyer, address indexed referrer, uint256 amount); // 购票侧推荐 5% 立付（仅实付时 emit）
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event AdminTransferStarted(address indexed currentAdmin, address indexed newAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event PerkContractUpdated(address indexed perk);

    // 高频 revert 用 custom error（省部署字节；钱包/前端按 selector 解码）
    error JPHZeroRecipient();
    error JPHWrongAmount();
    error JPHSelfGift();
    error JPHNothingToClaim();
    error JPHRoundNotDrawn();
    error JPHNotCommitted();
    error JPHBadState();

    modifier onlyAdmin() {
        require(msg.sender == admin, "JPH: not admin");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "JPH: paused");
        _;
    }

    modifier nonReentrant() {
        require(!_locked, "JPH: reentrant");
        _locked = true;
        _;
        _locked = false;
    }

    constructor(uint256 roundDuration_, uint64 lockWindow_, bool anchorFirstUtc_) {
        require(roundDuration_ > lockWindow_ && lockWindow_ > 0, "JPH: bad timing");
        roundDuration = roundDuration_;
        lockWindow = lockWindow_;
        anchorFirstUtc = anchorFirstUtc_;
        admin = msg.sender;
        _startNextRound();
    }

    // ---------------------------------------------------------------
    // 购票 / 赠票 / 免费票
    // ---------------------------------------------------------------

    uint256 public constant MAX_BATCH_TICKETS = 1000; // 批量购票每组最多 1000 个号码组合

    /// @notice 购票：90% 票款进当期 ETH 奖池，10% 抽水（有推荐人时 5% 立付推荐人、5% 进质押分红池）
    function buyTicket(uint8[6] calldata numbers, uint64 count) external payable whenNotPaused nonReentrant {
        _checkFunds(numbers, count, false);
        uint256 rid = _pickRound();
        _record(rid, msg.sender, address(0), numbers, count, false);
        _splitBuyFee(rid, msg.sender, TICKET_PRICE * count);
    }

    /// @notice 批量购票：一次交易购买多组不同号码（一次签名，gas 与逐笔相同）
    function buyTickets(uint8[6][] calldata numbersList, uint64[] calldata counts) external payable whenNotPaused nonReentrant {
        uint256 total = _validateBatch(numbersList, counts) * TICKET_PRICE;
        if (msg.value != total) revert JPHWrongAmount();
        uint256 rid = _pickRound();
        for (uint256 i = 0; i < numbersList.length; i++) {
            _record(rid, msg.sender, address(0), numbersList[i], counts[i], false);
        }
        _splitBuyFee(rid, msg.sender, total);
    }

    function giftTicket(address recipient, uint8[6] calldata numbers, uint64 count) external payable whenNotPaused nonReentrant {
        if (recipient == address(0)) revert JPHZeroRecipient();
        if (recipient == msg.sender) revert JPHSelfGift();
        _checkFunds(numbers, count, false);
        uint256 rid = _pickRound();
        _record(rid, recipient, msg.sender, numbers, count, false);
        _splitBuyFee(rid, msg.sender, TICKET_PRICE * count); // 付款人 = 赠送者，推荐分成看赠送者
    }

    /// @notice 批量赠票：一次交易把多组号码赠给同一接收人
    function giftTickets(address recipient, uint8[6][] calldata numbersList, uint64[] calldata counts) external payable whenNotPaused nonReentrant {
        if (recipient == address(0)) revert JPHZeroRecipient();
        if (recipient == msg.sender) revert JPHSelfGift();
        uint256 total = _validateBatch(numbersList, counts) * TICKET_PRICE;
        if (msg.value != total) revert JPHWrongAmount();
        uint256 rid = _pickRound();
        for (uint256 i = 0; i < numbersList.length; i++) {
            _record(rid, recipient, msg.sender, numbersList[i], counts[i], false);
        }
        _splitBuyFee(rid, msg.sender, total);
    }

    /// @notice 管理员零成本直发免费票（社区空投）
    function freeTicket(address recipient, uint8[6] calldata numbers, uint64 count) external payable onlyAdmin whenNotPaused nonReentrant {
        if (recipient == address(0)) revert JPHZeroRecipient();
        if (msg.value != 0) revert JPHWrongAmount();
        _record(_pickRound(), recipient, FREE_TICKET, numbers, count, true);
    }

    /// @notice 管理员发放免费票额度（用户自选号码、随时领用）
    uint256 public constant MAX_GRANT = 10000; // 单次发放上限（防手误）

    function grantFreeCredits(address recipient, uint64 amount) external onlyAdmin whenNotPaused {
        if (recipient == address(0)) revert JPHZeroRecipient();
        require(amount > 0 && amount <= MAX_GRANT, "JPH: bad amount");
        freeCredits[recipient] += amount;
    }

    function redeemFreeTicket(uint8[6] calldata numbers, uint64 count) external whenNotPaused nonReentrant {
        require(freeCredits[msg.sender] >= count, "JPH: no free credits");
        freeCredits[msg.sender] -= count;
        _record(_pickRound(), msg.sender, FREE_TICKET, numbers, count, true);
    }

    /// @notice 批量领取免费额度：多组不同号码一次交易（每组注数自行决定）
    function redeemFreeTickets(uint8[6][] calldata numbersList, uint64[] calldata counts) external whenNotPaused nonReentrant {
        uint256 units = _validateBatch(numbersList, counts);
        require(freeCredits[msg.sender] >= units, "JPH: no free credits");
        freeCredits[msg.sender] -= uint64(units);
        uint256 rid = _pickRound();
        for (uint256 i = 0; i < numbersList.length; i++) {
            _record(rid, msg.sender, FREE_TICKET, numbersList[i], counts[i], true);
        }
    }

    /// @dev 批量校验（长度/注数/数字）并返回总注数
    function _validateBatch(uint8[6][] calldata numbersList, uint64[] calldata counts) internal view returns (uint256 units) {
        require(numbersList.length > 0 && numbersList.length == counts.length, "JPH: bad batch");
        require(numbersList.length <= MAX_BATCH_TICKETS, "JPH: batch too large");
        for (uint256 i = 0; i < numbersList.length; i++) {
            require(counts[i] >= 1 && counts[i] <= MAX_UNITS_PER_BUY, "JPH: bad count");
            for (uint256 j = 0; j < NUMBER_LENGTH; j++) {
                require(numbersList[i][j] <= MAX_DIGIT, "JPH: bad digit");
            }
            units += counts[i];
        }
    }

    /// @dev 校验单张票面（号码/注数/金额）
    function _checkFunds(uint8[6] calldata numbers, uint64 count, bool isFree) internal view {
        require(count >= 1, "JPH: zero count");
        require(count <= MAX_UNITS_PER_BUY, "JPH: too many units");
        for (uint256 i = 0; i < NUMBER_LENGTH; i++) {
            require(numbers[i] <= MAX_DIGIT, "JPH: bad digit");
        }
        uint256 total = isFree ? 0 : TICKET_PRICE * count;
        if (msg.value != total) revert JPHWrongAmount();
    }

    /// @dev 选轮：停售窗口/已结束时顺延到下一轮（整批同轮）
    function _pickRound() internal returns (uint256 rid) {
        rid = currentRoundId;
        Round storage r = rounds[rid];
        if (r.status != Status.Open || block.timestamp >= r.salesEnd) {
            rid = _ensureNextRound();
            r = rounds[rid];
        }
        require(r.status == Status.Open, "JPH: round not selling");
    }

    /// @dev 记账。数字/注数校验下沉到此（六条入口统一兜底：免费路径此前无校验，可注入 >9 数字
    ///      制造统计外幽灵票 → 同档重复兑付）；金额校验仍由调用方（_checkFunds/_validateBatch）前置完成。
    function _record(uint256 rid, address owner, address gifter, uint8[6] calldata numbers, uint64 count, bool isFree) internal {
        require(count >= 1 && count <= MAX_UNITS_PER_BUY, "JPH: bad count");
        for (uint256 j = 0; j < NUMBER_LENGTH; j++) {
            require(numbers[j] <= MAX_DIGIT, "JPH: bad number");
        }
        Round storage r = rounds[rid];
        uint256 total = isFree ? 0 : TICKET_PRICE * count;
        uint48 packed = _pack(numbers);
        Ticket[] storage tickets = userTickets[rid][owner];
        tickets.push(Ticket({numbersPacked: packed, count: count, gifter: gifter, claimed: false, refunded: false}));

        comboUnits[rid][_comboOf(packed)] += count;
        lastDigitUnits[rid][uint8(packed >> 40)] += count; // 末1 档（六等）统计：个位=最高字节
        r.totalTickets += count;

        if (isFree) {
            freeMinted[rid] += count;
            require(freeMinted[rid] <= MAX_FREE_PER_ROUND, "JPH: free cap");
            emit FreeTicketIssued(rid, owner, tickets.length - 1, numbers, count);
        } else {
            // 10% 买票抽水先全额记 ticketFee（调用方随后经 _splitBuyFee 分流推荐人 5%），
            // 90% 进本轮 ETH 奖池（票款银行同步入账）
            r.ticketFee += total * BUY_FEE_BPS / 10000;
            r.ticketRevenue += total;
            uint256 toPool = total - total * BUY_FEE_BPS / 10000;
            r.prizePool += toPool;
            ticketBank += toPool;
            if (gifter == address(0)) {
                emit TicketPurchased(rid, owner, tickets.length - 1, numbers, count, total);
            } else {
                emit TicketGifted(rid, gifter, owner, tickets.length - 1, numbers, count, total);
            }
        }
    }

    /// @dev 购票侧推荐分成：_record 已把 10% 抽水全额记进 ticketFee；付款人有推荐人时，
    ///      从中拿出 5%（fee − fee/2，截断奇数 wei 归推荐人）立付推荐人并冲减 ticketFee。
    ///      推荐人拒收（合约 fallback 回滚）则不冲减——该份额留在 ticketFee 进质押池，
    ///      购票不被卡死。无推荐人时不动作（10% 全留池，现状不变）。
    ///      注：单注抽水 = TICKET_PRICE × BUY_FEE_BPS / 10000 = 1e14 wei 整除，逐行累计与
    ///      按批总额计算的 fee 精确相等，冲减不会透支 ticketFee。
    function _splitBuyFee(uint256 rid, address payer, uint256 total) internal {
        address referrer = referrerOf[payer];
        if (referrer == address(0)) return;
        uint256 fee = total * BUY_FEE_BPS / 10000;
        uint256 refShare = fee - fee / 2;
        (bool ok, ) = payable(referrer).call{value: refShare}("");
        if (!ok) return; // 拒收：份额留在 ticketFee（全额 10% 进质押池）
        rounds[rid].ticketFee -= refShare;
        referralPaidPerRound[rid] += refShare;
        emit ReferralPurchasePaid(payer, referrer, refShare);
    }

    // ---------------------------------------------------------------
    // 开奖（承诺-揭示）
    // ---------------------------------------------------------------

    function commitDraw(uint256 roundId) external {
        Round storage r = rounds[roundId];
        require(r.drawAt != 0, "JPH: no such round");
        if (r.status == Status.Open) {
            require(block.timestamp >= r.drawAt, "JPH: too early");
            r.randomBlock = uint64(block.number + 1);
            r.status = Status.Committed;
        } else if (r.status == Status.Committed) {
            require(block.number > r.randomBlock && blockhash(r.randomBlock) == bytes32(0), "JPH: commit not stale");
            r.randomBlock = uint64(block.number + 1);
        } else {
            revert JPHBadState();
        }
        emit DrawCommitted(roundId, r.randomBlock);
    }

    /// @notice 公证快照：把承诺区块的哈希永久存入合约（须在承诺块出块后 256 块内调用一次，
    ///         之后 settleDraw 不再受 EVM 256 块窗口限制，任何时间都可结算）。
    ///         快照内容是链上不可变的既定事实，任何人都可代为执行（keeper 自动做）。
    function snapshotCommitHash(uint256 roundId) external {
        Round storage r = rounds[roundId];
        if (r.status != Status.Committed) revert JPHNotCommitted();
        require(r.commitHash == bytes32(0), "JPH: already snapshotted");
        require(block.number > r.randomBlock, "JPH: random block not mined");
        bytes32 h = blockhash(r.randomBlock);
        require(h != bytes32(0), "JPH: hash window passed, retry commitDraw");
        r.commitHash = h;
        emit CommitHashSnapshotted(roundId, r.randomBlock, h);
    }

    function settleDraw(uint256 roundId) external {
        Round storage r = rounds[roundId];
        if (r.status != Status.Committed) revert JPHNotCommitted();
        require(r.commitHash != bytes32(0), "JPH: snapshot first");
        _settle(roundId, r.commitHash);
    }

    function _deriveNumbers(bytes32 seed) internal pure returns (uint8[6] memory numbers) {
        bytes32 cur = seed;
        uint256 idx;
        for (uint256 i = 0; i < NUMBER_LENGTH; ) {
            if (idx == 32) {
                cur = keccak256(abi.encodePacked(cur));
                idx = 0;
            }
            uint8 b = uint8(cur[idx]);
            idx++;
            if (b < 250) {
                numbers[i] = b % 10;
                i++;
            }
        }
    }

    function _settle(uint256 roundId, bytes32 seed) internal {
        Round storage r = rounds[roundId];
        uint8[6] memory winning = _deriveNumbers(seed);
        uint48 winningPacked = _pack(winning);

        // 质押真实入池：可派彩基数 = 票款留存池 + 全部质押现金（质押者承担大奖超额，见下方清算）
        uint256 pool = r.prizePool + stakeCash;
        uint256[6] memory pots = [
            pool * 40 / 100, pool * 25 / 100, pool * 15 / 100, pool * 12 / 100, pool * 5 / 100, pool * 3 / 100
        ];

        uint256[6] memory units;
        uint256 sum;
        {
            uint256 w = _comboOf(winningPacked);
            units[0] = comboUnits[roundId][w];
            sum = units[0];
            // 末 5 位：10 个前缀
            uint256 base = w % 100000;
            uint256 t;
            for (uint256 k; k < 10; k++) t += comboUnits[roundId][base + k * 100000];
            t -= units[0];
            units[1] = t;
            sum += t;
            // 末 4 位：100 个前缀
            base = w % 10000;
            t = 0;
            for (uint256 k; k < 100; k++) t += comboUnits[roundId][base + k * 10000];
            t -= sum;
            units[2] = t;
            sum += t;
            // 末 3 位：1000 个前缀
            base = w % 1000;
            t = 0;
            for (uint256 k; k < 1000; k++) t += comboUnits[roundId][base + k * 1000];
            t -= sum;
            units[3] = t;
            sum += t;
            // 末 2 位：10000 个前缀
            base = w % 100;
            t = 0;
            for (uint256 k; k < 10000; k++) t += comboUnits[roundId][base + k * 100];
            t -= sum;
            units[4] = t;
            sum += t;
            // 末 1 位：个位桶总数 − 更高档（M>=2）总数 = 六等独占
            units[5] = lastDigitUnits[roundId][uint8(winningPacked >> 40)] > sum
                ? lastDigitUnits[roundId][uint8(winningPacked >> 40)] - sum
                : 0;
        }

        r.winningPacked = winningPacked;
        r.seedHash = seed;
        r.tierUnits = units;
        r.claimDeadline = uint64(block.timestamp + CLAIM_WINDOW);
        r.status = Status.Drawn;

        // 空奖级滚存（下一轮/待滚存池）——最终 rollover 在下方兑付保障后统一入账。
        // 防重复计入：可派彩基数含质押，但滚存只滚「票款成分」——
        // 质押保持全额在 stakeCash（下轮 poolEff 仍含它），若把质押也滚进 prizePool 会每轮重复叠加。
        uint256 rollover = pool - (pots[0] + pots[1] + pots[2] + pots[3] + pots[4] + pots[5]);
        for (uint256 i; i < 6; i++) {
            if (units[i] == 0) rollover += pots[i];
        }
        if (rollover > 0 && stakeCash > 0) {
            // 滚存按成分比例拆分：质押成分不沉淀进 prizePool（防重复叠加）
            rollover = rollover * r.prizePool / (r.prizePool + stakeCash);
        }

        // 小奖项公平赔率封顶：有中奖的档，派彩上限 = 封顶倍数 × 票价 × 中奖注数（头奖倍数 0 = 不限）。
        // 超出部分滚存下期；余量现金留存在 ticketBank，由下方守恒帽兜底，不凭空记账。
        for (uint256 i; i < 6; i++) {
            uint256 mult = _payoutCapMult(i);
            if (mult > 0 && units[i] > 0) {
                uint256 cap = mult * TICKET_PRICE * units[i];
                if (pots[i] > cap) {
                    rollover += pots[i] - cap;
                    pots[i] = cap;
                }
            }
        }

        // 兑付保障：现金 = 票款银行 + 质押现金。大奖超出保障上限时，
        // 对有赢家档按比例缩水（削减额核销），质押者本金最多被扣光、不为负数。
        uint256 reserveNeeded;
        for (uint256 i; i < 6; i++) {
            if (units[i] > 0) reserveNeeded += pots[i];
        }
        uint256 shrinkable = reserveNeeded > ticketBank + stakeCash ? reserveNeeded - (ticketBank + stakeCash) : 0;
        if (shrinkable > 0) {
            // 从有赢家档（优先低档普惠，再高档）依次削减；被削减部分本就无现金支撑，
            // 直接核销（这正是穿仓缩水的含义），不再转入滚存（否则滚存无现金背书）
            for (uint256 i = 5; i < 6 && shrinkable > 0; ) {
                if (units[i] > 0 && pots[i] > 0) {
                    uint256 cut = pots[i] > shrinkable ? shrinkable : pots[i];
                    pots[i] -= cut;
                    shrinkable -= cut;
                }
                if (i == 0) break;
                unchecked { i--; }
            }
            reserveNeeded = ticketBank + stakeCash; // 削减后与保障对齐（余下走共担）
        }
        if (reserveNeeded > 0) {
            if (reserveNeeded <= ticketBank) {
                ticketBank -= reserveNeeded;
            } else {
                uint256 gap = reserveNeeded - ticketBank;
                ticketBank = 0;
                if (gap > 0 && totalEthStaked > 0) {
                    uint256 totalS = totalEthStaked;
                    uint256 charged;
                    for (uint256 i = 0; i < _stakers.length; ) {
                        address u = _stakers[i];
                        uint256 st = ethStaked[u];
                        if (st > 0) {
                            uint256 cut = gap * st / totalS;
                            if (cut > 0) {
                                ethStaked[u] = st - cut;
                                charged += cut;
                            }
                        }
                        unchecked { i++; }
                    }
                    totalEthStaked -= charged;
                    stakeCash -= charged;
                    emit StakerLossShared(roundId, charged);
                }
            }
        }

        // 清算完成：写回（可能被缩水的）档位金额，并把滚存转入下轮
        r.tierPots = pots;
        // 守恒帽：记入滚存 ≤ 兑付扣减后的票款现金留存（此时 ticketBank 已完成兑付扣减；
        // 防「有中奖且 stakeCash>0」时每轮记入无现金支撑的 phantom rollover，
        // 归纳保证 pendingRollover ≤ ticketBank 恒成立）
        if (rollover > ticketBank) rollover = ticketBank;
        if (rollover > 0) _creditPrize(rollover, roundId);

        // 买票抽水 → 质押分红池；按 ETH 质押快照份额分光（无质押者则留存）
        uint256 fee = r.ticketFee;
        r.ticketFee = 0;
        stakingPool += fee;
        uint256 stakingPaid = 0;
        if (stakingPool > 0 && totalEthStaked > 0) {
            uint256 total = totalEthStaked;
            for (uint256 i = 0; i < _stakers.length; ) {
                address u = _stakers[i];
                uint256 s = ethStaked[u];
                if (s > 0) {
                    uint256 share = stakingPool * s / total;
                    pendingStakeRewards[u] += share;
                    stakingPaid += share;
                }
                unchecked { i++; }
            }
            stakingPool -= stakingPaid;
        }

        emit RoundSettled(roundId, winning, seed, pool, pots, units, rollover, stakingPaid);
    }

    /// @notice 上一期结算后开启下一期
    function startRound() external {
        Round storage prev = rounds[currentRoundId];
        require(prev.status == Status.Drawn || prev.status == Status.Voided, "JPH: prev round not final");
        _startNextRound();
    }

    function _startNextRound() internal {
        uint256 nextId = currentRoundId + 1;
        uint64 drawAt;
        if (nextId == 1) {
            drawAt = anchorFirstUtc
                ? _nextUtcMidnight()
                : uint64(block.timestamp + roundDuration);
        } else {
            drawAt = uint64(rounds[currentRoundId].drawAt + roundDuration);
        }
        _createRound(nextId, drawAt);
    }

    function _ensureNextRound() internal returns (uint256 nextId) {
        nextId = currentRoundId + 1;
        if (rounds[nextId].drawAt == 0) {
            _createRound(nextId, uint64(rounds[currentRoundId].drawAt + roundDuration));
        }
    }

    function _createRound(uint256 id, uint64 drawAt) internal {
        uint256 opening = pendingRollover;
        pendingRollover = 0;
        Round storage r = rounds[id];
        r.salesEnd = drawAt - lockWindow;
        r.drawAt = drawAt;
        r.prizePool = opening;
        r.status = Status.Open;
        currentRoundId = id;
        emit RoundStarted(id, r.salesEnd, drawAt, opening);
    }

    function _nextUtcMidnight() internal view returns (uint64) {
        return uint64(((block.timestamp / 1 days) + 1) * 1 days);
    }

    // ---------------------------------------------------------------
    // 兑奖（中奖抽水 12%：推荐人 5% + 质押池 7%/12%）/ 退款 / 逾期滚存
    // ---------------------------------------------------------------

    function claim(uint256 roundId, uint256[] calldata ticketIndices) external whenNotPaused nonReentrant {
        Round storage r = rounds[roundId];
        if (r.status != Status.Drawn) revert JPHRoundNotDrawn();
        require(block.timestamp <= r.claimDeadline, "JPH: claim expired");

        Ticket[] storage tickets = userTickets[roundId][msg.sender];
        uint256 due;
        uint256 claimedCount;
        for (uint256 i; i < ticketIndices.length; i++) {
            Ticket storage t = tickets[ticketIndices[i]];
            require(!t.claimed, "JPH: ticket claimed");
            uint256 tier = _tierOf(t.numbersPacked, r.winningPacked);
            if (tier < 6) {
                uint256 amount = r.tierPots[tier] * t.count / r.tierUnits[tier];
                t.claimed = true;
                r.tierClaimed[tier] += amount;
                due += amount;
                claimedCount++;
            }
        }
        if (due == 0) revert JPHNothingToClaim();

        // 中奖抽水 12%：推荐人 5%（若绑定），其余入质押分红池
        uint256 fee = due * WIN_FEE_BPS / 10000;
        uint256 net = due - fee;
        address referrer = referrerOf[msg.sender];
        uint256 refShare = 0;
        if (referrer != address(0)) {
            refShare = due * REFERRAL_BPS / 10000;
            fee -= refShare;
        }
        stakingPool += fee;
        if (refShare > 0) {
            (bool okRef, ) = payable(referrer).call{value: refShare}("");
            require(okRef, "JPH: ref transfer failed");
        }
        (bool ok, ) = payable(msg.sender).call{value: net}("");
        require(ok, "JPH: transfer failed");
        emit PrizeClaimed(roundId, msg.sender, claimedCount, net);
    }

    function refundTickets(uint256 roundId, uint256[] calldata ticketIndices) external whenNotPaused nonReentrant {
        Round storage r = rounds[roundId];
        require(r.status == Status.Voided, "JPH: round not voided");

        Ticket[] storage tickets = userTickets[roundId][msg.sender];
        uint256 due;
        uint256 count;
        for (uint256 i; i < ticketIndices.length; i++) {
            Ticket storage t = tickets[ticketIndices[i]];
            if (t.gifter == FREE_TICKET) continue; // 免费票不退款
            require(!t.refunded, "JPH: ticket refunded");
            t.refunded = true;
            due += TICKET_PRICE * t.count;
            count++;
        }
        require(due > 0, "JPH: nothing to refund");
        _voidedOwed -= due;
        (bool ok, ) = payable(msg.sender).call{value: due}("");
        require(ok, "JPH: refund failed");
        emit TicketsRefunded(roundId, msg.sender, count, due);
    }

    function sweepUnclaimed(uint256 roundId) external {
        Round storage r = rounds[roundId];
        if (r.status != Status.Drawn) revert JPHRoundNotDrawn();
        require(!r.swept, "JPH: already swept");
        require(block.timestamp > r.claimDeadline, "JPH: not expired");

        // 只滚「有人中但未领取」的奖级；空奖级在 settle 时已滚存，不得重复滚
        uint256 total;
        for (uint256 i; i < 6; i++) {
            if (r.tierUnits[i] > 0) {
                total += r.tierPots[i] - r.tierClaimed[i];
            }
        }
        r.swept = true;
        // 逾期未领现金与负债一起滚回：同步回补票款银行，保证 bank 记账=可兑现金（防错误缩水）
        ticketBank += total;
        uint256 creditedRound = _creditPrize(total, roundId);
        emit UnclaimedSwept(roundId, total, creditedRound);
    }

    // ---------------------------------------------------------------
    // 奖池注资（任何人可赞助 ETH 进当前开放轮）
    // ---------------------------------------------------------------

    function injectPrizeEth() external payable nonReentrant {
        require(msg.value > 0, "JPH: zero amount");
        ticketBank += msg.value; // 注资同样进入票款银行（可兑付）
        uint256 creditedRound = _creditPrize(msg.value, 0);
        emit PrizeEthInjected(msg.sender, msg.value, creditedRound);
    }

    function _creditPrize(uint256 amount, uint256 excludeRoundId) internal returns (uint256 creditedRoundId) {
        uint256 rid = currentRoundId;
        if (rid != 0 && rid != excludeRoundId && rounds[rid].status == Status.Open) {
            rounds[rid].prizePool += amount;
            creditedRoundId = rid;
        } else {
            pendingRollover += amount;
        }
    }

    // ---------------------------------------------------------------
    // ETH 质押（活期，三段式退出）+ 分红领取
    // ---------------------------------------------------------------

    address[] internal _stakers; // 质押者索引（settle 分红/共担遍历用；全额赎回即 swap-pop 移除）
    mapping(address => bool) internal _inStakers;
    mapping(address => uint256) private _stakerIndexPlusOne; // 0 = 不在数组；否则 下标+1

    /// @notice 质押 ETH：本金立即并入奖池资金（增加当期可发奖池），退出走 requestUnstake → finalizeUnstake 两段式。
    /// @dev 派彩优先消耗票款留存；质押本金承担兜底——大奖缺口在结算时按份额共担清算。
    ///      质押者另有抽水分红（settle 快照）；挂单退出期间照常参与分红与共担。
    function stakeEth() external payable whenNotPaused nonReentrant {
        require(msg.value > 0, "JPH: zero stake");
        // 首次（或全额赎回后重新）质押有最低额限制；已有余额的追加质押不受限
        if (ethStaked[msg.sender] == 0) {
            require(msg.value >= MIN_STAKE, "JPH: below min stake");
        }
        if (!_inStakers[msg.sender]) {
            _inStakers[msg.sender] = true;
            _stakers.push(msg.sender);
            _stakerIndexPlusOne[msg.sender] = _stakers.length; // 下标+1
        }
        stakeCash += msg.value; // 质押现金独立桶：不动兑奖资金
        ethStaked[msg.sender] += msg.value;
        totalEthStaked += msg.value;
        emit EthStaked(msg.sender, msg.value);
    }

    /// @notice 质押退出第一步（申请）：登记挂单，记账侧不动（ethStaked/totalEthStaked 不变）——
    ///         当轮 Open/Committed 时登记当轮（必须陪跑本轮结算，防结算前抢跑规避共担）；
    ///         当轮已终态时登记下一轮（下一轮结算后成熟）。同一时刻只允许一笔挂单。
    function requestUnstake(uint256 amount) external whenNotPaused {
        require(amount > 0, "JPH: zero amount");
        require(ethStaked[msg.sender] >= amount, "JPH: insufficient stake");
        require(unstakeReqOf[msg.sender].amount == 0, "JPH: unstake pending");
        Round storage cur = rounds[currentRoundId];
        uint64 rid = (cur.status == Status.Open || cur.status == Status.Committed)
            ? uint64(currentRoundId)
            : uint64(currentRoundId + 1);
        unstakeReqOf[msg.sender] = UnstakeReq({amount: amount, roundId: rid});
        emit UnstakeRequested(msg.sender, amount, rid);
    }

    /// @notice 质押退出第二步（领取）：登记轮终态（Drawn/Voided）后调用。
    ///         实付 = min(申请额, 当前质押余额)——挂单期间被共担清算削减过则按削减后余额到账。
    function finalizeUnstake() external whenNotPaused nonReentrant {
        UnstakeReq memory req = unstakeReqOf[msg.sender];
        require(req.amount > 0, "JPH: no unstake pending");
        Status st = rounds[req.roundId].status;
        require(st == Status.Drawn || st == Status.Voided, "JPH: not matured");
        uint256 amount = req.amount > ethStaked[msg.sender] ? ethStaked[msg.sender] : req.amount;
        require(stakeCash >= amount, "JPH: stake cash short");
        delete unstakeReqOf[msg.sender];
        stakeCash -= amount; // 只从质押桶赎回：兑奖资金不受影响
        ethStaked[msg.sender] -= amount;
        totalEthStaked -= amount;
        if (ethStaked[msg.sender] == 0) _removeStaker(msg.sender); // 全额退出即 swap-pop 出数组
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "JPH: unstake failed");
        emit UnstakeFinalized(msg.sender, amount);
    }

    /// @dev 全额退出时把质押者从数组 swap-pop 移除（防历史粉尘质押者无限膨胀瘫痪 settle 遍历）
    function _removeStaker(address user) internal {
        uint256 idxPlusOne = _stakerIndexPlusOne[user];
        if (idxPlusOne != 0) {
            uint256 lastIdx = _stakers.length - 1;
            address lastStaker = _stakers[lastIdx];
            uint256 idx = idxPlusOne - 1;
            if (idx != lastIdx) {
                _stakers[idx] = lastStaker;
                _stakerIndexPlusOne[lastStaker] = idxPlusOne;
            }
            _stakers.pop();
            delete _stakerIndexPlusOne[user];
        }
        _inStakers[user] = false;
    }

    /// @notice 奖池资金（可派彩票款 + 质押储备）——前端展示用
    function totalPoolAssets() external view returns (uint256 prizePoolNow, uint256 stakeReserve) {
        // 轮次存在即计入（Open/Committed 都显示，避免开奖瞬间奖池数字跳变）
        Round storage r = rounds[currentRoundId];
        uint256 pool = r.drawAt != 0 ? r.prizePool : 0;
        return (pool + pendingRollover, stakeCash);
    }

    /// @notice 领取已结算的分红（settle 快照份额）
    function claimStakeRewards() external nonReentrant {
        uint256 amount = pendingStakeRewards[msg.sender];
        if (amount == 0) revert JPHNothingToClaim();
        pendingStakeRewards[msg.sender] = 0;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "JPH: reward transfer failed");
        emit StakeRewardsClaimed(msg.sender, amount);
    }

    // ---------------------------------------------------------------
    // Perks 合约桥（JPH 质押免费票独立后，唯一外部免费票入口）
    // ---------------------------------------------------------------

    modifier onlyPerk() {
        require(msg.sender == perkContract, "JPH: not perk");
        _;
    }

    /// @notice 管理员设置 Perks 合约（可置 0 停用）
    function setPerkContract(address c) external onlyAdmin {
        perkContract = c;
        emit PerkContractUpdated(c);
    }

    /// @notice Perks 合约代用户免费出票（用户已在其处核销额度）
    function redeemPerkExternal(address recipient, uint8[6] calldata numbers, uint64 count)
        external onlyPerk whenNotPaused nonReentrant
    {
        if (recipient == address(0)) revert JPHZeroRecipient();
        _record(_pickRound(), recipient, FREE_TICKET, numbers, count, true);
    }

    // ---------------------------------------------------------------
    // 推荐 / 管理 / 风控
    // ---------------------------------------------------------------

    function setReferrer(address referrer) external {
        require(referrer != address(0), "JPH: zero referrer");
        require(referrer != msg.sender, "JPH: self refer");
        require(referrerOf[msg.sender] == address(0), "JPH: referrer set");
        referrerOf[msg.sender] = referrer;
        emit ReferrerSet(msg.sender, referrer);
    }

    function getReferrer(address user) external view returns (address) {
        return referrerOf[user];
    }

    function pause() external onlyAdmin {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice 作废期次：票款 90% 从银行/奖池回退并预留全额退款；10% 抽水滚入下轮奖池（有意设计，不重复预留）
    function voidRound(uint256 roundId) external onlyAdmin {
        Round storage r = rounds[roundId];
        if (r.status != Status.Open && r.status != Status.Committed) revert JPHBadState();
        // 预留只计全款 ticketRevenue（refundTickets 的实退口径）；ticketFee 仅滚入下轮奖池——
        // 同一笔 fee 现金只承诺一次（此前同时计入 _voidedOwed 与滚存，fee 部分预留永不灭失，双重记账）
        uint256 owed = r.ticketRevenue;
        _voidedOwed += owed;
        // 票款作废回退：该轮 90% 曾计入票款银行与奖池——退款后承诺必须撤销，否则
        // 未来大奖会把已退票款当作兑付保障，损失错误转嫁质押者
        uint256 rev90 = r.ticketRevenue * 9 / 10;
        if (rev90 > 0) ticketBank = rev90 > ticketBank ? 0 : ticketBank - rev90;
        uint256 pool = (r.prizePool > rev90 ? r.prizePool - rev90 : 0) + r.ticketFee;
        r.ticketFee = 0;
        r.status = Status.Voided;
        if (pool > 0) _creditPrize(pool, roundId);
        emit RoundVoided(roundId, owed);
    }

    uint256 public _voidedOwed; // 作废期次待退款预留（= 各作废轮 ticketRevenue 未退余额；public 便于审计直接核对守恒）

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

    // ---------------------------------------------------------------
    // 视图
    // ---------------------------------------------------------------

    function getCurrentRound() external view returns (Round memory) {
        return rounds[currentRoundId];
    }

    function getRound(uint256 roundId) external view returns (Round memory) {
        return rounds[roundId];
    }

    function getUserTickets(uint256 roundId, address user) external view returns (Ticket[] memory) {
        return userTickets[roundId][user];
    }

    function previewClaim(uint256 roundId, address user) external view returns (uint256 due, uint256[] memory indices) {
        Round storage r = rounds[roundId];
        Ticket[] storage tickets = userTickets[roundId][user];
        uint256[] memory tmp = new uint256[](tickets.length);
        uint256 n;
        for (uint256 i; i < tickets.length; i++) {
            Ticket storage t = tickets[i];
            if (t.claimed) continue;
            uint256 tier = _tierOf(t.numbersPacked, r.winningPacked);
            if (tier < 6 && r.tierUnits[tier] > 0) {
                due += r.tierPots[tier] * t.count / r.tierUnits[tier];
                tmp[n++] = i;
            }
        }
        indices = new uint256[](n);
        for (uint256 i; i < n; i++) indices[i] = tmp[i];
    }

    // ---------------------------------------------------------------
    // 内部工具
    // ---------------------------------------------------------------

    function _pack(uint8[6] memory numbers) internal pure returns (uint48 packed) {
        for (uint256 i; i < NUMBER_LENGTH; i++) {
            packed |= uint48(numbers[i]) << (8 * i);
        }
    }

    function _comboOf(uint48 packed) internal pure returns (uint256) {
        uint256 c;
        for (uint256 i; i < NUMBER_LENGTH; i++) {
            c = c * 10 + uint8(packed >> (8 * i));
        }
        return c;
    }

    function _tierOf(uint48 ticketPacked, uint48 winningPacked) internal pure returns (uint256) {
        uint256 matched;
        for (uint256 i = NUMBER_LENGTH; i > 0; i--) {
            if (uint8(ticketPacked >> (8 * (i - 1))) != uint8(winningPacked >> (8 * (i - 1)))) break;
            matched++;
        }
        // matched>=1：0=头奖(全6)..5=六等(末1)；matched=0 → 6（无奖）
        return matched >= 1 ? NUMBER_LENGTH - matched : 6;
    }
}
