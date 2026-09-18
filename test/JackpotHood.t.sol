// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {JackpotHood} from "../src/JackpotHood.sol";
import {JackpotHoodPerks} from "../src/JackpotHoodPerks.sol";
import {JackpotHoodToken} from "../src/mocks/JackpotHoodToken.sol";

/// @dev 测试壳：暴露内部函数，用已知种子直接结算
contract TestHarness is JackpotHood {
    constructor(uint256 roundDuration_, uint64 lockWindow_, bool anchorFirstUtc_)
        JackpotHood(roundDuration_, lockWindow_, anchorFirstUtc_)
    {}

    function settleWithSeed(uint256 roundId, bytes32 seed) external {
        _settle(roundId, seed);
    }

    function deriveExposed(bytes32 seed) external pure returns (uint8[6] memory) {
        return _deriveNumbers(seed);
    }

    function packExposed(uint8[6] calldata numbers) external pure returns (uint48) {
        return _pack(numbers);
    }

    function tierExposed(uint48 ticket, uint48 winning) external pure returns (uint256) {
        return _tierOf(ticket, winning);
    }

    function stakersLen() external view returns (uint256) {
        return _stakers.length;
    }
}

/// @dev 拒收 ETH 的合约（充当拒收推荐人：fallback 必回滚）
contract RejectingReceiver {
    receive() external payable {
        revert("no thanks");
    }
}

/// @title V3 测试：6 位号码 5 级 ETH 奖池 + 买票抽 10%/中奖抽 12% + ETH 质押分红 + JPH 质押 perk
contract JackpotHoodTest is Test {
    TestHarness public jackpot;
    JackpotHoodPerks public perks;
    JackpotHoodToken public jph;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public referrer = makeAddr("referrer");

    uint256 public constant PRICE = 0.001 ether;
    uint256 public constant SEED_POOL = 1 ether;

    // 种子前 6 字节 00..05 → 开奖号码 0-1-2-3-4-5
    bytes32 public constant WIN_SEED = 0x0001020304050000000000000000000000000000000000000000000000000000;

    uint8[6] JACKPOT_NUMS = [0, 1, 2, 3, 4, 5]; // 头奖：全 6 位
    uint8[6] TIER1_NUMS = [9, 1, 2, 3, 4, 5]; // 末 5 位
    uint8[6] TIER2_NUMS = [9, 9, 2, 3, 4, 5]; // 末 4 位
    uint8[6] TIER3_NUMS = [9, 9, 9, 3, 4, 5]; // 末 3 位
    uint8[6] TIER4_NUMS = [9, 9, 9, 9, 4, 5]; // 末 2 位（普惠）
    uint8[6] MISS_NUMS = [7, 7, 7, 7, 7, 7];

    function setUp() public {
        vm.warp(1_700_000_000); // 现代时间：避免 utcDay=0 与「未初始化」冲突
        vm.prank(admin);
        jph = new JackpotHoodToken(10_000_000 ether);
        vm.prank(admin);
        jackpot = new TestHarness(24 hours, 15 minutes, true);
        perks = new JackpotHoodPerks(address(jph), address(jackpot));
        vm.prank(admin);
        jackpot.setPerkContract(address(perks));
        // 初始 1 ETH 注资（走真实入口 injectPrizeEth）
        vm.deal(admin, 100 ether);
        vm.prank(admin);
        jackpot.injectPrizeEth{value: SEED_POOL}();
    }

    function _buy(address user, uint8[6] memory nums, uint64 count) internal {
        vm.deal(user, 100 ether);
        vm.prank(user);
        jackpot.buyTicket{value: PRICE * count}(nums, count);
    }

    function _warpToDraw(uint256 rid) internal {
        JackpotHood.Round memory r = jackpot.getRound(rid);
        vm.warp(r.drawAt);
    }

    // ------------------------------------------------------------------
    // 购票与抽水分流
    // ------------------------------------------------------------------

    function test_InitialState() public view {
        assertEq(jackpot.currentRoundId(), 1);
        JackpotHood.Round memory r = jackpot.getRound(1);
        assertEq(uint8(r.status), uint8(JackpotHood.Status.Open));
        assertEq(r.prizePool, SEED_POOL, "1 ETH seeded");
        assertEq(jackpot.TICKET_PRICE(), PRICE);
    }

    function test_BuyFeeSplit() public {
        uint256 rid = jackpot.currentRoundId();
        _buy(alice, MISS_NUMS, 10); // 0.01 ETH
        JackpotHood.Round memory r = jackpot.getRound(rid);
        assertEq(r.totalTickets, 10);
        assertEq(r.ticketRevenue, PRICE * 10, "full revenue tracked");
        assertEq(r.ticketFee, PRICE * 10 * 1000 / 10000, "10% buy fee");
        assertEq(r.prizePool, SEED_POOL + PRICE * 10 * 9000 / 10000, "90% to prize pool");
        assertEq(address(jackpot).balance, SEED_POOL + PRICE * 10, "all ETH held");
    }

    function test_BuyWrongAmount() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(JackpotHood.JPHWrongAmount.selector);
        jackpot.buyTicket{value: PRICE + 1}(MISS_NUMS, 1);
    }

    // ------------------------------------------------------------------
    // 购票侧推荐分成（V4.4：有推荐人 5% 立付 + 5% 进池；无推荐人 10% 全进池不变）
    // ------------------------------------------------------------------

    // 有推荐人：推荐人实收 5% 精确（fee − fee/2，奇数 wei 归推荐人），ticketFee 只记 5%，守恒精确
    function test_BuyReferralSplit() public {
        uint256 rid = jackpot.currentRoundId();
        vm.prank(alice);
        jackpot.setReferrer(referrer);
        uint256 total = PRICE * 10;
        uint256 fee = total * 1000 / 10000; // 0.001 ETH
        vm.deal(alice, 100 ether);
        uint256 refBefore = referrer.balance;
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit JackpotHood.ReferralPurchasePaid(alice, referrer, fee - fee / 2);
        jackpot.buyTicket{value: total}(MISS_NUMS, 10);

        JackpotHood.Round memory r = jackpot.getRound(rid);
        assertEq(referrer.balance - refBefore, fee - fee / 2, "referrer paid 5% immediately");
        assertEq(r.ticketFee, fee / 2, "only 5% booked to staking pool");
        assertEq(r.prizePool, SEED_POOL + total * 9000 / 10000, "90% to pool unchanged");
        assertEq(jackpot.ticketBank(), SEED_POOL + total * 9000 / 10000);
        assertEq(jackpot.referralPaidPerRound(rid), fee - fee / 2, "per-round referral tracking");
        // 精确平衡：合约余额 = 注资 + 票款 − 实付推荐人
        assertEq(address(jackpot).balance, SEED_POOL + total - (fee - fee / 2), "conservation exact");
    }

    // 批量购票同口径：按批总额付一次 5%
    function test_BuyTicketsBatchReferralSplit() public {
        uint256 rid = jackpot.currentRoundId();
        vm.prank(alice);
        jackpot.setReferrer(referrer);
        uint8[6][] memory list = new uint8[6][](3);
        uint64[] memory cnts = new uint64[](3);
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = 0; j < 6; j++) list[i][j] = uint8((i + j) % 10);
            cnts[i] = uint64(i + 1); // 1+2+3 = 6 注
        }
        uint256 total = PRICE * 6;
        uint256 fee = total * 1000 / 10000;
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        jackpot.buyTickets{value: total}(list, cnts);
        assertEq(referrer.balance, fee - fee / 2, "batch: referrer 5% once on total");
        assertEq(jackpot.getRound(rid).ticketFee, fee / 2, "batch: only 5% booked");
        assertEq(jackpot.ticketBank(), SEED_POOL + total * 9000 / 10000, "batch: 90% banked");
    }

    // 推荐人是拒收合约：整笔购票不 revert，推荐人分文未得，10% 全额并入质押池
    function test_BuyReferralRejectingContractFallsBack() public {
        RejectingReceiver rej = new RejectingReceiver();
        uint256 rid = jackpot.currentRoundId();
        vm.prank(alice);
        jackpot.setReferrer(address(rej));
        uint256 total = PRICE * 10;
        uint256 fee = total * 1000 / 10000;
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        jackpot.buyTicket{value: total}(MISS_NUMS, 10); // 不 revert
        assertEq(address(rej).balance, 0, "rejecting referrer got nothing");
        assertEq(jackpot.getRound(rid).ticketFee, fee, "full 10% falls back to staking pool");
        assertEq(jackpot.referralPaidPerRound(rid), 0, "nothing paid, nothing tracked");
        assertEq(address(jackpot).balance, SEED_POOL + total, "no ETH leaked");
    }

    // 赠送路径同口径：推荐分成看付款人（赠送者）；单张与批量一致
    function test_GiftReferralSplit() public {
        uint256 rid = jackpot.currentRoundId();
        vm.prank(bob);
        jackpot.setReferrer(referrer); // 付款人 = 赠送者 bob
        vm.deal(bob, 100 ether);

        // 单张赠送
        uint256 total1 = PRICE * 4;
        uint256 fee1 = total1 * 1000 / 10000;
        vm.prank(bob);
        jackpot.giftTicket{value: total1}(carol, MISS_NUMS, 4);
        assertEq(referrer.balance, fee1 - fee1 / 2, "giftTicket: referrer 5%");
        assertEq(jackpot.getRound(rid).ticketFee, fee1 / 2, "giftTicket: 5% booked");

        // 批量赠送同口径
        uint8[6][] memory list = new uint8[6][](2);
        uint64[] memory cnts = new uint64[](2);
        for (uint256 i = 0; i < 2; i++) {
            for (uint256 j = 0; j < 6; j++) list[i][j] = uint8((i + j) % 10);
            cnts[i] = 1;
        }
        uint256 total2 = PRICE * 2;
        uint256 fee2 = total2 * 1000 / 10000;
        vm.prank(bob);
        jackpot.giftTickets{value: total2}(carol, list, cnts);
        assertEq(referrer.balance, (fee1 - fee1 / 2) + (fee2 - fee2 / 2), "giftTickets: referrer 5% on top");
        assertEq(jackpot.getRound(rid).ticketFee, fee1 / 2 + fee2 / 2, "giftTickets: 5% booked");
    }

    // ------------------------------------------------------------------
    // 开奖与中奖抽水（12%：推荐 5% + 质押池 7%）
    // ------------------------------------------------------------------

    function test_SettleAndClaimFeeSplit() public {
        uint256 rid = jackpot.currentRoundId();
        _buy(alice, JACKPOT_NUMS, 1); // 头奖
        _buy(bob, JACKPOT_NUMS, 1); // 头奖
        _buy(carol, MISS_NUMS, 1); // 分母票
        vm.prank(alice);
        jackpot.setReferrer(referrer);

        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        JackpotHood.Round memory r = jackpot.getRound(rid);
        assertEq(r.tierUnits[0], 2, "jackpot units");
        uint256 due = r.tierPots[0] / 2; // 每张头奖应得
        assertEq(r.tierPots[0], r.prizePool * 40 / 100, "40% jackpot");

        // 质押分红池在 settle 时得到买票抽水（3 张付费票 × 10%）
        uint256 buyFee = PRICE * 3 * 1000 / 10000;

        uint256 aliceBefore = alice.balance;
        uint256[] memory idx = _allIdx(rid, alice);
        vm.prank(alice);
        jackpot.claim(rid, idx);
        uint256 aliceGot = alice.balance - aliceBefore;
        assertEq(aliceGot, due * 88 / 100, "winner gets 88%");

        // 抽水：12% of due；推荐 5% 给 referrer，7% 进质押池
        uint256 feeTotal = due * 1200 / 10000;
        assertEq(referrer.balance, due * 500 / 10000, "referrer 5%");
        assertEq(jackpot.stakingPool(), buyFee + (feeTotal - due * 500 / 10000), "staking pool = buy fee + 7% win fee");
    }

    function test_ClaimNoReferrerAllFeeToPool() public {
        uint256 rid = jackpot.currentRoundId();
        _buy(alice, JACKPOT_NUMS, 1);
        _buy(carol, MISS_NUMS, 1);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);
        JackpotHood.Round memory r = jackpot.getRound(rid);
        uint256 due = r.tierPots[0];

        uint256 poolBefore = jackpot.stakingPool();
        uint256[] memory idx = _allIdx(rid, alice);
        vm.prank(alice);
        jackpot.claim(rid, idx);
        assertEq(jackpot.stakingPool(), poolBefore + due * 1200 / 10000, "12% all to pool when no referrer");
    }

    function test_EmptyTierRollsOver() public {
        uint256 rid = jackpot.currentRoundId();
        _buy(alice, TIER4_NUMS, 1); // 只有普惠中
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);
        JackpotHood.Round memory r = jackpot.getRound(rid);
        // 空奖级滚存：五等(末2,5%)有人中 → 其余 40+25+15+12+3 = 95% 滚存（六等无人中）
        uint256 expectedRoll = r.prizePool * (100 - 5) / 100;
        assertEq(jackpot.pendingRollover(), expectedRoll, "empty tiers roll to next round");
    }

    // ------------------------------------------------------------------
    // ETH 质押分红（快照）
    // ------------------------------------------------------------------

    function test_StakeAndEarnBuyFee() public {
        uint256 rid = jackpot.currentRoundId();
        // alice 质押 1 ETH，bob 质押 2 ETH（质押在票售出前生效 → settle 快照）
        uint256 poolBefore = jackpot.getRound(rid).prizePool;
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 1 ether}();
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        jackpot.stakeEth{value: 2 ether}();
        // 质押现金独立桶：不改动兑奖池与票款银行
        assertEq(jackpot.stakeCash(), 3 ether, "stake in own bucket");
        assertEq(jackpot.getRound(rid).prizePool, poolBefore, "prize pool untouched by stake");

        _buy(carol, MISS_NUMS, 100); // 0.1 ETH 票款 → 0.01 ETH 买票抽水
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        uint256 feePool = PRICE * 100 * 1000 / 10000; // 0.01 ETH
        // 无中奖 → 只有买票抽水。alice 1/3，bob 2/3（截断余尘留池 ≤1 wei）
        assertLe(jackpot.stakingPool(), 1, "dust only left in pool");
        uint256 aliceShare = jackpot.pendingStakeRewards(alice);
        uint256 bobShare = jackpot.pendingStakeRewards(bob);
        assertEq(aliceShare + bobShare, feePool - jackpot.stakingPool(), "shares sum to pool");
        assertGt(aliceShare, 0, "alice earned");

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        jackpot.claimStakeRewards();
        assertEq(alice.balance - aliceBefore, aliceShare, "alice claims rewards");
    }

    function test_StakeAfterSettleGetsNothing() public {
        uint256 rid = jackpot.currentRoundId();
        _buy(carol, MISS_NUMS, 100);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);
        // 结算后才质押：上个结算周期的抽水与他无关（快照在结算时刻）
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 1 ether}();
        assertEq(jackpot.pendingStakeRewards(alice), 0);
    }

    // V4.4：即时 unstakeEth 已删除，退出走 requestUnstake → finalizeUnstake 两段式
    function test_UnstakeEth() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 1 ether}();
        assertEq(jackpot.ethStaked(alice), 1 ether);
        // 两段式：申请 0.4 → 当轮结算 → 领取 0.4，余额 0.6
        uint256 rid = jackpot.currentRoundId();
        vm.prank(alice);
        jackpot.requestUnstake(0.4 ether);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);
        vm.prank(alice);
        jackpot.finalizeUnstake();
        assertEq(jackpot.ethStaked(alice), 0.6 ether);
        // 超额申请 revert
        vm.prank(alice);
        vm.expectRevert("JPH: insufficient stake");
        jackpot.requestUnstake(1 ether);
    }

    // ------------------------------------------------------------------
    // 质押三段式退出（申请 → 陪跑登记轮结算 → 领取）
    // ------------------------------------------------------------------

    // 全流程：Open 轮中申请 → 立即领取 revert → 结算后领取到账、ethStaked 归零、_stakers 收缩
    function test_RequestUnstakeFlow() public {
        uint256 rid = jackpot.currentRoundId();
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 1 ether}();
        assertEq(jackpot.stakersLen(), 1);

        // Open 轮中申请：登记当轮，记账侧不动
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit JackpotHood.UnstakeRequested(alice, 1 ether, uint64(rid));
        jackpot.requestUnstake(1 ether);
        (uint256 reqAmt, uint64 reqRid) = jackpot.unstakeReqOf(alice);
        assertEq(reqAmt, 1 ether);
        assertEq(reqRid, uint64(rid), "booked to current open round");
        assertEq(jackpot.ethStaked(alice), 1 ether, "stake untouched while pending");
        assertEq(jackpot.totalEthStaked(), 1 ether);
        assertEq(jackpot.stakeCash(), 1 ether);

        // 当轮未终态：立即领取 revert
        vm.prank(alice);
        vm.expectRevert("JPH: not matured");
        jackpot.finalizeUnstake();

        // 结算后领取：全额到账、质押归零、_stakers 收缩、挂单清零
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit JackpotHood.UnstakeFinalized(alice, 1 ether);
        jackpot.finalizeUnstake();
        assertEq(alice.balance - balBefore, 1 ether);
        assertEq(jackpot.ethStaked(alice), 0);
        assertEq(jackpot.totalEthStaked(), 0);
        assertEq(jackpot.stakeCash(), 0);
        assertEq(jackpot.stakersLen(), 0, "staker removed on full exit");
        (uint256 reqAmt2, ) = jackpot.unstakeReqOf(alice);
        assertEq(reqAmt2, 0, "request cleared");
    }

    // 防抢跑语义：申请后该轮发生共担清算 → finalize 按削减后余额少拿
    function test_UnstakeAntiFrontRun() public {
        uint256 rid = jackpot.currentRoundId();
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 2 ether}();
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        jackpot.stakeEth{value: 2 ether}();

        // alice 在 Open 轮申请全额退出（2 ETH）——必须陪跑本轮结算
        vm.prank(alice);
        jackpot.requestUnstake(2 ether);

        // 构造共担清算：付费票注资银行 + 免费票头奖打穿银行（同 test_LossSharingOnFreeJackpot 场景）
        _buy(carol, MISS_NUMS, 100);
        vm.prank(admin);
        jackpot.freeTicket(bob, JACKPOT_NUMS, 1);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        uint256 aliceAfterSlash = jackpot.ethStaked(alice);
        assertLt(aliceAfterSlash, 2 ether, "pending request did not escape loss sharing");

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        jackpot.finalizeUnstake();
        assertEq(alice.balance - balBefore, aliceAfterSlash, "pays min(req, slashed stake)");
        assertEq(jackpot.ethStaked(alice), 0);
        assertEq(jackpot.stakersLen(), 1, "alice removed, bob stays");
    }

    // 非法申请与重复申请 revert；无挂单直接领取 revert
    function test_RequestUnstakePendingReverts() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 1 ether}();
        vm.prank(alice);
        vm.expectRevert("JPH: zero amount");
        jackpot.requestUnstake(0);
        vm.prank(alice);
        vm.expectRevert("JPH: insufficient stake");
        jackpot.requestUnstake(2 ether);
        // 未成熟时重复申请 revert
        vm.prank(alice);
        jackpot.requestUnstake(0.5 ether);
        vm.prank(alice);
        vm.expectRevert("JPH: unstake pending");
        jackpot.requestUnstake(0.5 ether);
        // 无挂单直接领取 revert
        vm.prank(bob);
        vm.expectRevert("JPH: no unstake pending");
        jackpot.finalizeUnstake();
    }

    // 已终态（无在飞轮）时申请 → 记下一轮，下一轮结算后才可领
    function test_RequestUnstakeAfterFinalRound() public {
        uint256 rid = jackpot.currentRoundId();
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 1 ether}();
        // 先把当轮结算掉（无在飞轮次）
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);
        assertEq(uint8(jackpot.getRound(rid).status), uint8(JackpotHood.Status.Drawn));

        // 此时申请：登记为下一轮
        vm.prank(alice);
        jackpot.requestUnstake(1 ether);
        (uint256 reqAmt, uint64 reqRid) = jackpot.unstakeReqOf(alice);
        assertEq(reqAmt, 1 ether);
        assertEq(reqRid, uint64(rid + 1), "booked to next round");

        // 下一轮尚不存在 → 不可领；开轮后 Open 中仍不可领
        vm.prank(alice);
        vm.expectRevert("JPH: not matured");
        jackpot.finalizeUnstake();
        jackpot.startRound();
        uint256 rid2 = jackpot.currentRoundId();
        assertEq(rid2, rid + 1);
        vm.prank(alice);
        vm.expectRevert("JPH: not matured");
        jackpot.finalizeUnstake();

        // 下一轮结算后成熟可领
        _warpToDraw(rid2);
        jackpot.settleWithSeed(rid2, WIN_SEED);
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        jackpot.finalizeUnstake();
        assertEq(alice.balance - balBefore, 1 ether);
        assertEq(jackpot.ethStaked(alice), 0);
        assertEq(jackpot.stakersLen(), 0);
    }

    // ------------------------------------------------------------------
    // JPH 质押 perk（分档免费票）
    // ------------------------------------------------------------------

    function test_JphStakeTiers() public {
        assertEq(perks.jphPerkPerDay(alice), 0, "no stake = no perk");
        vm.prank(admin);
        jph.transfer(alice, 1_000_000 ether);
        vm.prank(alice);
        jph.approve(address(perks), 1_000_000 ether);
        vm.prank(alice);
        perks.stakeJph(50_000 ether);
        assertEq(perks.jphPerkPerDay(alice), 0, "below 100k = 0/day");
        vm.prank(alice);
        perks.stakeJph(50_000 ether);
        assertEq(perks.jphPerkPerDay(alice), 1, "100k = 1/day");
        vm.prank(alice);
        perks.stakeJph(100_000 ether);
        assertEq(perks.jphPerkPerDay(alice), 2, "200k = 2/day");
        vm.prank(alice);
        perks.stakeJph(800_000 ether);
        assertEq(perks.jphPerkPerDay(alice), 10, "1M = 10/day");
    }

    function test_JphStakePerkDaily() public {
        // bob 质押 200_000 JPH → 2 张/天（可累积）
        vm.prank(admin);
        jph.transfer(bob, 200_000 ether);
        vm.prank(bob);
        jph.approve(address(perks), 200_000 ether);
        vm.prank(bob);
        perks.stakeJph(200_000 ether);
        assertEq(perks.jphPerkPerDay(bob), 2, "200k = 2/day");

        // 当天 0 累积；下一天可领 2 张
        assertEq(perks.perkBalance(bob), 0, "no retroactive accrual");
        vm.warp(block.timestamp + 86400);
        assertEq(perks.perkBalance(bob), 2, "1 day = 2 tickets stored");

        vm.prank(bob);
        perks.redeemPerkTicket(MISS_NUMS, 1);
        assertEq(perks.perkBalance(bob), 1, "stored tickets persist");

        // 再等 3 天：本应累积 6，但上限 3（激励用户上线查看）
        vm.warp(block.timestamp + 3 * 86400);
        assertEq(perks.perkBalance(bob), 3, "capped at 3 unclaimed");
        // 领取后继续累积
        vm.prank(bob);
        perks.redeemPerkTicket(MISS_NUMS, 3);
        assertEq(perks.perkBalance(bob), 0, "spent");
        vm.warp(block.timestamp + 2 * 86400);
        assertEq(perks.perkBalance(bob), 3, "re-capped at 3 after 2 days (would be 4)");

        JackpotHood.Round memory r3 = jackpot.getRound(3);
        assertEq(r3.ticketFee, 0, "no buy fee for free tickets");
    }

    function test_JphStakePerkNoStakeReverts() public {
        vm.prank(alice);
        vm.expectRevert("JPH: no stored perk");
        perks.redeemPerkTicket(MISS_NUMS, 1);
    }

    function test_UnstakeJph() public {
        vm.prank(admin);
        jph.transfer(alice, 1000 ether);
        vm.prank(alice);
        jph.approve(address(perks), 1000 ether);
        vm.prank(alice);
        perks.stakeJph(1000 ether);
        vm.prank(alice);
        perks.unstakeJph(1000 ether);
        assertEq(perks.jphStaked(alice), 0);
        assertEq(jph.balanceOf(alice), 1000 ether, "jph returned");
    }

    // ------------------------------------------------------------------
    // 免费票/退款/管理
    // ------------------------------------------------------------------

    function test_FreeTicketAndRefundExclusion() public {
        uint256 rid = jackpot.currentRoundId();
        vm.prank(admin);
        jackpot.freeTicket(alice, MISS_NUMS, 1);
        _buy(alice, MISS_NUMS, 2);

        vm.prank(admin);
        jackpot.voidRound(rid);

        // 免费票（idx0）被排除；手动提交付费票下标 idx1（原第 2 张）
        uint256[] memory idx = new uint256[](1);
        idx[0] = 1;
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        jackpot.refundTickets(rid, idx);
        assertEq(alice.balance - balBefore, PRICE * 2, "full paid refund only");
        JackpotHood.Ticket[] memory ts = jackpot.getUserTickets(rid, alice);
        assertEq(ts[0].refunded, false, "free ticket untouched");
        assertEq(ts[1].refunded, true, "paid ticket refunded");
    }

    function test_VoidRoundRollsPoolAndFee() public {
        uint256 rid = jackpot.currentRoundId();
        _buy(alice, MISS_NUMS, 100); // 0.1 ETH 票款 → 90% 进 bank/pool、10% fee
        uint256 poolBefore = jackpot.getRound(rid).prizePool;
        uint256 fee = jackpot.getRound(rid).ticketFee;
        uint256 bankBefore = jackpot.ticketBank();
        vm.prank(admin);
        jackpot.voidRound(rid);

        // 票款 90% 回退：bank 只留注入部分；滚存 = (prizePool−90%) + fee
        uint256 rev90 = PRICE * 100 * 9 / 10;
        assertEq(jackpot.ticketBank(), bankBefore - rev90, "bank reverted for voided tickets");
        assertEq(jackpot.pendingRollover(), poolBefore - rev90 + fee, "rollover excludes voided ticket 90%");
    }

    function test_InjectPrizeEthAnyone() public {
        uint256 rid = jackpot.currentRoundId();
        uint256 before = jackpot.getRound(rid).prizePool;
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        jackpot.injectPrizeEth{value: 0.5 ether}();
        assertEq(jackpot.getRound(rid).prizePool, before + 0.5 ether, "anyone can sponsor");
    }

    function test_ClaimExpiredSweep() public {
        uint256 rid = jackpot.currentRoundId();
        _buy(alice, JACKPOT_NUMS, 1);
        _buy(carol, MISS_NUMS, 1);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        uint256 pool = jackpot.getRound(rid).prizePool; // 未领 → sweep 全量滚存
        vm.warp(block.timestamp + 30 days + 1);
        jackpot.sweepUnclaimed(rid);
        JackpotHood.Round memory r = jackpot.getRound(rid);
        assertEq(r.swept, true);
        assertEq(jackpot.pendingRollover(), pool, "unclaimed swept to next round");
    }

    function test_PauseBlocksBuy() public {
        vm.prank(admin);
        jackpot.pause();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert("JPH: paused");
        jackpot.buyTicket{value: PRICE}(MISS_NUMS, 1);
    }

    function _allIdx(uint256 rid, address user) internal view returns (uint256[] memory) {
        JackpotHood.Ticket[] memory ts = jackpot.getUserTickets(rid, user);
        uint256[] memory idx = new uint256[](ts.length);
        for (uint256 i; i < ts.length; i++) idx[i] = i;
        return idx;
    }

    // V3.3：免费票大奖打穿票款银行 → 质押按比例共担，且质押桶不影响兑奖资金
    function test_SnapshotMakesSettleImmuneToWindow() public {
        uint256 rid = jackpot.currentRoundId();
        _buy(alice, JACKPOT_NUMS, 1);
        _buy(carol, MISS_NUMS, 1);
        _warpToDraw(rid);
        jackpot.commitDraw(rid);
        // 承诺块（randomBlock = number+1）出块后立即快照
        vm.roll(block.number + 2);
        jackpot.snapshotCommitHash(rid);
        JackpotHood.Round memory rc = jackpot.getRound(rid);
        assertTrue(rc.commitHash != bytes32(0), "hash snapshotted");
        // 快照后越过 256 块窗口依然可结算（settle 读存储而非 blockhash）
        vm.roll(block.number + 300);
        jackpot.settleDraw(rid);
        JackpotHood.Round memory r = jackpot.getRound(rid);
        assertEq(uint8(r.status), uint8(JackpotHood.Status.Drawn), "settled after window");
        assertEq(r.seedHash, rc.commitHash, "seed equals snapshotted hash");
    }

    function test_SettleRequiresSnapshot() public {
        uint256 rid = jackpot.currentRoundId();
        _buy(alice, MISS_NUMS, 1);
        _warpToDraw(rid);
        jackpot.commitDraw(rid);
        vm.roll(block.number + 2);
        // 未快照时结算被拒（无论是否在窗口内）
        vm.expectRevert("JPH: snapshot first");
        jackpot.settleDraw(rid);
    }

    function test_BuyTicketsBatchOneTx() public {
        uint256 rid = jackpot.currentRoundId();
        // 5 组不同号码 × 不同注数 = 1+2+3+4+5 = 15 注，总额校验一次
        uint8[6][] memory numsList = new uint8[6][](5);
        uint64[] memory cnts = new uint64[](5);
        for (uint256 i = 0; i < 5; i++) {
            for (uint256 j = 0; j < 6; j++) numsList[i][j] = uint8((i + j) % 10);
            cnts[i] = uint64(i + 1);
        }
        uint256 total = PRICE * 15;
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        jackpot.buyTickets{value: total}(numsList, cnts);

        JackpotHood.Round memory r = jackpot.getRound(rid);
        assertEq(r.totalTickets, 15, "all batches recorded");
        assertEq(r.ticketRevenue, total, "full revenue");
        JackpotHood.Ticket[] memory ts = jackpot.getUserTickets(rid, alice);
        assertEq(ts.length, 5, "5 ticket lines");
        assertEq(r.prizePool, SEED_POOL + total * 9000 / 10000, "90% to pool once");
        assertEq(jackpot.ticketBank(), SEED_POOL + total * 9000 / 10000, "bank credited once");
    }

    function test_BuyTicketsBatchWrongValueReverts() public {
        uint8[6][] memory numsList = new uint8[6][](2);
        uint64[] memory cnts = new uint64[](2);
        for (uint256 i = 0; i < 2; i++) {
            for (uint256 j = 0; j < 6; j++) numsList[i][j] = uint8(j);
            cnts[i] = 1;
        }
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(JackpotHood.JPHWrongAmount.selector);
        jackpot.buyTickets{value: PRICE}(numsList, cnts);
    }

    function test_BuyTicketsBatchLengthMismatch() public {
        uint8[6][] memory numsList = new uint8[6][](2);
        uint64[] memory cnts = new uint64[](1);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert("JPH: bad batch");
        jackpot.buyTickets{value: PRICE * 2}(numsList, cnts);
    }

    function test_LossSharingOnFreeJackpot() public {
        uint256 rid = jackpot.currentRoundId();
        // 质押 2 ETH（独立桶）
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 2 ether}();
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        jackpot.stakeEth{value: 2 ether}();
        assertEq(jackpot.ticketBank(), SEED_POOL, "seed in ticket bank");
        assertEq(jackpot.stakeCash(), 4 ether, "stake isolated");

        // 免费票中头奖（无票款注入，打穿 bank：奖池 1 ETH 的 40% = 0.4 > bank? bank=1 → 不穿。
        // 用大奖超支构造：免费票头奖 + 更大池 → bank 已花：先付钱买票注资再加免费票
        _buy(carol, MISS_NUMS, 100); // 0.1 ETH → bank +0.09
        vm.prank(admin);
        jackpot.freeTicket(alice, JACKPOT_NUMS, 1); // 免费头奖票

        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        JackpotHood.Round memory r = jackpot.getRound(rid);
        // 质押真实入池：可派彩池 = prizePool + stakeCash = (1+0.09) + 4 = 5.09
        // 免费票中头奖（tier 有赢家）→ reserveNeeded = 40% x 5.09 ≈ 2.036
        // 兑付顺序：先 ticketBank(1.09) → 缺口 ≈0.946 由质押按比例即时共担
        uint256 gap = r.tierPots[0] - SEED_POOL - 0.09 ether;
        assertGt(gap, 0, "bank alone insufficient for jackpot");
        assertEq(jackpot.ticketBank(), 0, "bank drained first");
        assertEq(jackpot.stakeCash(), 4 ether - gap, "stakers absorbed the gap");
        assertEq(jackpot.totalEthStaked(), 4 ether - gap);

        // 免费头奖可正常兑付（保障来自票款银行 + 质押清算）——奖池为 ETH
        uint256 aliceBal = alice.balance;
        vm.prank(alice);
        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        jackpot.claim(rid, idx);
        assertGt(alice.balance - aliceBal, 0, "claimed in ETH");
    }


    // V3.4：质押真实入池 —— 头奖金额按 票款留存+质押 放大，缺口由质押按比例承担
    function test_StakeInPoolEnlargesJackpot() public {
        uint256 rid = jackpot.currentRoundId();
        vm.deal(alice, 20 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 10 ether}();
        _buy(bob, JACKPOT_NUMS, 1);
        _buy(carol, MISS_NUMS, 1);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        JackpotHood.Round memory r = jackpot.getRound(rid);
        uint256 expectedPool = SEED_POOL + PRICE * 2 * 9000 / 10000 + 10 ether;
        assertEq(r.tierPots[0], expectedPool * 40 / 100, "jackpot sized by staked pool");
        assertLt(jackpot.ethStaked(alice), 10 ether, "staker absorbed jackpot gap");
        assertEq(jackpot.ticketBank(), 0, "bank drained first");
    }

    // V3.4：质押金不足时大奖缩水（不穿仓），质押不会变负
    function test_JackpotShrinksWhenStakeExhausted() public {
        uint256 rid = jackpot.currentRoundId();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 0.1 ether}();
        vm.prank(admin);
        jackpot.freeTicket(bob, JACKPOT_NUMS, 1);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        JackpotHood.Round memory r = jackpot.getRound(rid);
        uint256 avail = SEED_POOL + 0.1 ether;
        assertLe(r.tierPots[0], avail, "jackpot capped by available cash");
        assertGe(jackpot.totalEthStaked(), 0, "stakers never negative");
        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        vm.prank(bob);
        jackpot.claim(rid, idx);
    }


    // V3.4 回归：弃奖 sweep 后出大奖不应错误缩水（sweep 同步回补票款银行）
    function test_SweepTopupsBankNoWrongShrink() public {
        // 期1：付费买普惠号并中奖，但无人兑奖 → 30 天后 sweep 滚存
        uint256 rid = jackpot.currentRoundId();
        _buy(alice, TIER4_NUMS, 1); // 普惠（末2=4-5? 用普惠号 TIER4_NUMS=[9,9,9,9,4,5] 匹配尾2=4,5）
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);
        vm.warp(block.timestamp + 31 days);
        jackpot.sweepUnclaimed(rid);

        uint256 bankAfterSweep = jackpot.ticketBank();
        assertGt(bankAfterSweep, 0, "sweep restores bank");

        // 期2：新轮（startRound 后 buy 大量头奖）中头奖，银行+质押充足 → 无缩水、质押不扣
        jackpot.startRound();
        uint256 rid2 = jackpot.currentRoundId();
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        jackpot.stakeEth{value: 2 ether}();
        _buy(carol, JACKPOT_NUMS, 1);
        _buy(alice, MISS_NUMS, 1);
        _warpToDraw(rid2);
        jackpot.settleWithSeed(rid2, WIN_SEED);
        JackpotHood.Round memory r2 = jackpot.getRound(rid2);
        // 头奖应付 = 40% x (prizePool2 + stake2) — 需 ≤ bank+stake（不缩水）→ 直接验证 stake 未被扣
        assertEq(jackpot.ethStaked(bob), 2 ether, "no wrong staker loss when bank topped");
    }


    // 6 级：末 1 位也中奖（六等 3%）——公平赔率封顶：独中时压到 10 × 票价
    function test_SixthTierLastDigitWins() public {
        uint256 rid = jackpot.currentRoundId();
        uint8[6] memory last1 = [9, 9, 9, 9, 9, 5]; // 仅末位 5 与开奖 0-1-2-3-4-5 相同
        _buy(alice, last1, 1);
        _buy(carol, MISS_NUMS, 1);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        JackpotHood.Round memory r = jackpot.getRound(rid);
        assertEq(r.tierUnits[5], 1, "last-digit winner counted in tier 6");
        // 未封顶值 = 3% pool ≈ 0.03 > 封顶 10 × 0.001 = 0.01 → 触发封顶
        assertGt(r.prizePool * 3 / 100, 10 * PRICE, "uncapped pot exceeds cap");
        assertEq(r.tierPots[5], 10 * PRICE, "sixth tier capped at 10x fair odds");
        // 兑奖（扣 12% 税后到手 88%）——按封顶后 tierPots 记账
        uint256 bal = alice.balance;
        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        vm.prank(alice);
        jackpot.claim(rid, idx);
        uint256 got = alice.balance - bal;
        uint256 expected = r.tierPots[5] * 88 / 100;
        assertEq(got, expected, "claimed 88% of capped tier-6 pot");
    }


    // 回归：空档多轮滚存不得重复叠加质押（账面 prizePool 只含票款成分）
    function test_RolloverDoesNotCompoundStake() public {
        uint256 rid = jackpot.currentRoundId();
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 1 ether}();
        _buy(bob, MISS_NUMS, 1); // 只买分母票，保证空档
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        // 全空档：prizePool(票款≈1.0009) 全额滚存（质押成分剔除）
        JackpotHood.Round memory r1 = jackpot.getRound(rid);
        assertEq(r1.prizePool + 0, r1.prizePool, "sanity");
        uint256 rolled = jackpot.pendingRollover();
        uint256 ticketSide = SEED_POOL + PRICE * 1 * 9000 / 10000; // 注入1+票款留存
        assertLe(rolled, ticketSide, "rollover excludes stake portion");

        // 再来一轮空档：prizePool 不应因质押翻倍增长
        jackpot.startRound();
        uint256 rid2 = jackpot.currentRoundId();
        uint256 p2 = jackpot.getRound(rid2).prizePool;
        _warpToDraw(rid2);
        jackpot.settleWithSeed(rid2, WIN_SEED);
        uint256 p3 = jackpot.getRound(rid2).prizePool; // settle 后字段保留
        assertLe(p3, ticketSide, "no stake compounding across empty rounds");
    }


    // 恢复：批量领取免费额度（多组不同号码一次交易）
    function test_RedeemFreeTicketsBatchRestored() public {
        vm.prank(admin);
        jackpot.grantFreeCredits(alice, 10);
        uint8[6][] memory list = new uint8[6][](3);
        uint64[] memory cnts = new uint64[](3);
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = 0; j < 6; j++) list[i][j] = uint8((i * 3 + j) % 10);
            cnts[i] = 1;
        }
        vm.prank(alice);
        jackpot.redeemFreeTickets(list, cnts);
        assertEq(jackpot.freeCredits(alice), 7, "batch deducts credits");
        assertEq(jackpot.getRound(1).totalTickets, 3, "3 lines issued");
    }

    // 安全：grant 超单次上限被拒
    function test_GrantCapEnforced() public {
        vm.prank(admin);
        vm.expectRevert("JPH: bad amount");
        jackpot.grantFreeCredits(alice, 10001);
    }

    // 安全：非白名单调用 redeemPerkExternal 被拒
    function test_PerkExternalOnlyWhitelisted() public {
        uint8[6] memory nums;
        vm.prank(alice);
        vm.expectRevert("JPH: not perk");
        jackpot.redeemPerkExternal(alice, nums, 1);
    }

    // 安全：批量领取触发每轮免费上限时整批回滚、额度不扣
    function test_BatchFreeCapRollback() public {
        uint256 rid = jackpot.currentRoundId();
        vm.prank(admin);
        jackpot.grantFreeCredits(alice, 1500);
        // 先用 999 张占满接近上限（cap=1000；再批 500 会超 → 回滚）
        vm.prank(admin);
        jackpot.freeTicket(bob, MISS_NUMS, 999);
        uint8[6][] memory list = new uint8[6][](200);
        uint64[] memory cnts = new uint64[](200);
        for (uint256 i = 0; i < 200; i++) {
            for (uint256 j = 0; j < 6; j++) list[i][j] = uint8((i + j) % 10);
            cnts[i] = 2; // 400 注 > 剩余额度 1 → 第 2 张即触发 cap
        }
        vm.prank(alice);
        vm.expectRevert("JPH: free cap");
        jackpot.redeemFreeTickets(list, cnts);
        assertEq(jackpot.freeCredits(alice), 1500, "credits untouched on rollback");
        assertEq(jackpot.getRound(rid).totalTickets, 999, "no partial issue");
    }

    // 上限：批量 1000 组可买，1001 组回滚（MAX_BATCH_TICKETS=1000）
    function test_BatchMax1000() public {
        uint8[6][] memory list1k = new uint8[6][](1000);
        uint64[] memory cnts1k = new uint64[](1000);
        for (uint256 i = 0; i < 1000; i++) {
            for (uint256 j = 0; j < 6; j++) list1k[i][j] = uint8((i + j) % 10);
            cnts1k[i] = 1;
        }
        uint256 rid = jackpot.currentRoundId();
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        jackpot.buyTickets{value: 1 ether}(list1k, cnts1k); // 1000 组 × 1 注 = 1 ETH，应成功
        assertEq(jackpot.getRound(rid).totalTickets, 1000);

        uint8[6][] memory list = new uint8[6][](1001);
        uint64[] memory cnts = new uint64[](1001);
        for (uint256 i = 0; i < 1001; i++) {
            for (uint256 j = 0; j < 6; j++) list[i][j] = uint8((i + j) % 10);
            cnts[i] = 1;
        }
        vm.expectRevert("JPH: batch too large");
        jackpot.buyTickets{value: 1.001 ether}(list, cnts);
    }

    // ------------------------------------------------------------------
    // F3 修复回归：phantom rollover（滚存守恒帽 + 穿仓削减直接核销）
    // ------------------------------------------------------------------

    // F3 PoC（审计场景）：质押 2 ETH、售 1001 注、末 2 档中奖。
    // 公平赔率封顶后：W = 5%×pool ≈ 0.195 ETH > 封顶 100×票价×1注 = 0.1 ETH → 压到 0.1，
    // 余量 0.095 计入滚存后再受守恒帽约束。
    // 修复后：守恒帽把滚存压到 ticketBank —— pendingRollover ≤ ticketBank，phantom = 0。
    function test_RolloverCappedByRetainedBank() public {
        uint256 rid = jackpot.currentRoundId();
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 2 ether}();
        _buy(bob, MISS_NUMS, 1000); // 1000 注分母（单票 count 上限）
        _buy(carol, TIER4_NUMS, 1); // 1 注末 2 档（普惠）→ 共 1001 注
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        JackpotHood.Round memory r = jackpot.getRound(rid);
        uint256 pool = r.prizePool + 2 ether; // settle 时 pool = prizePool + stakeCash = 3.9009
        uint256 w = pool * 5 / 100;
        assertEq(r.tierUnits[4], 1, "only last-2 tier hit");
        assertGt(w, 100 * PRICE, "uncapped W ~= 0.195 exceeds fair-odds cap 0.1");
        assertEq(r.tierPots[4], 100 * PRICE, "W capped at 100x ticket price");
        // 核心断言：记入滚存 ≤ 兑付扣减后的票款现金留存（本场景帽恰好绑死 → 相等）
        assertLe(jackpot.pendingRollover(), jackpot.ticketBank(), "rollover backed by retained bank cash");
        assertEq(jackpot.pendingRollover(), jackpot.ticketBank(), "cap binds exactly: phantom = 0");
        assertEq(jackpot.pendingRollover(), r.prizePool - r.tierPots[4], "rollover = ticket-side pool minus capped pot");
        // 滚存被下一轮原样吸收后仍与 bank 一致
        jackpot.startRound();
        assertEq(jackpot.getRound(2).prizePool, jackpot.ticketBank(), "no phantom carried into round 2");
    }

    // F3 PoC（穿仓）：质押 100 ETH、头奖中出 —— 修复后 pendingRollover = 0 且无资不抵债
    function test_JackpotBustNoPhantomRollover() public {
        uint256 rid = jackpot.currentRoundId();
        vm.deal(alice, 200 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 100 ether}();
        _buy(bob, JACKPOT_NUMS, 1); // 头奖
        uint256 bankBefore = jackpot.ticketBank(); // 1.0009
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        JackpotHood.Round memory r = jackpot.getRound(rid);
        uint256 gap = r.tierPots[0] - bankBefore; // 票款银行不足部分由质押共担
        assertGt(gap, 0, "bank drained by jackpot");
        assertEq(jackpot.ticketBank(), 0, "bank fully drained");
        assertEq(jackpot.ethStaked(alice), 100 ether - gap, "staker absorbed gap");
        // 修复核心：空档滚存（60% 票款成分 ≈ 0.6）因 bank 已归零被守恒帽压到 0
        assertEq(jackpot.pendingRollover(), 0, "bust round books zero rollover");
        // 无资不抵债：余额覆盖 未领奖金 + 质押余量 + 已分未领分红 + 抽水
        uint256 debt = r.tierPots[0] - r.tierClaimed[0] + jackpot.totalEthStaked()
            + jackpot.pendingStakeRewards(alice) + jackpot.stakingPool();
        assertGe(address(jackpot).balance, debt, "solvent after bust");
        // 头奖照常可兑（质押共担兜底）
        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        vm.prank(bob);
        jackpot.claim(rid, idx);
        assertEq(r.tierPots[0] - jackpot.getRound(rid).tierClaimed[0], 0, "jackpot fully claimed");
    }

    // F3 缩水路径：reserveNeeded 超过 bank+stake 时削减额直接核销（不再 rollover += cut 虚增滚存）。
    // 构造 bank < prizePool：轮 1 售票后 void（fee 0.1 滚入轮 2 奖池但无对应 bank 现金），
    // 轮 2 四档同时命中（92% pool）> bank+stake → 触发缩水。
    function test_ShrinkCutNotRolled() public {
        uint256 rid = jackpot.currentRoundId();
        _buy(alice, MISS_NUMS, 1000); // 1 ETH 票款：bank/pool +0.9，fee 0.1
        vm.prank(admin);
        jackpot.voidRound(rid); // bank = 1（seed），pendingRollover = (1.9−0.9)+0.1 = 1.1
        jackpot.startRound();
        uint256 rid2 = jackpot.currentRoundId();
        assertEq(jackpot.getRound(rid2).prizePool, 1.1 ether, "fee rolled into round 2 pool");
        assertEq(jackpot.ticketBank(), 1 ether, "bank < prizePool by the rolled fee");

        vm.deal(bob, 10 ether);
        vm.prank(bob);
        jackpot.stakeEth{value: 0.01 ether}(); // 极少质押 → 共担兜底有限
        // 四档同时命中：头奖+末5+末4+末3 = 92% pool > bank(1.0036)+stake(0.01)
        _buy(carol, JACKPOT_NUMS, 1);
        _buy(carol, TIER1_NUMS, 1);
        _buy(carol, TIER2_NUMS, 1);
        _buy(carol, TIER3_NUMS, 1);
        _warpToDraw(rid2);
        jackpot.settleWithSeed(rid2, WIN_SEED);

        JackpotHood.Round memory r = jackpot.getRound(rid2);
        uint256 pool = r.prizePool + 0.01 ether; // settle 时 pool = 1.1136
        assertEq(r.tierUnits[0] + r.tierUnits[1] + r.tierUnits[2] + r.tierUnits[3], 4, "four tiers hit");
        // 末 3 档被削减：cut = 92%×pool − (bank+stake) = 1.024512 − 1.0136 = 0.010912
        uint256 cut = pool * 92 / 100 - 1.0136 ether;
        assertEq(r.tierPots[3], pool * 12 / 100 - cut, "tier-3 pot shrunk by exactly the shortfall");
        assertEq(jackpot.ethStaked(bob), 0, "staker fully slashed");
        assertEq(jackpot.ticketBank(), 0, "bank drained");
        // 修复核心：削减额核销、空档滚存被守恒帽压到 0 —— 不记入任何无现金背书的滚存
        assertEq(jackpot.pendingRollover(), 0, "no phantom rollover from shrink path");
        // 资不抵债检查：余额覆盖 作废退款预留 + 全部未领奖金 + 未分配抽水
        uint256 unclaimed;
        for (uint256 i = 0; i < 6; i++) {
            if (r.tierUnits[i] > 0) unclaimed += r.tierPots[i] - r.tierClaimed[i];
        }
        assertGe(
            address(jackpot).balance,
            jackpot._voidedOwed() + unclaimed + jackpot.stakingPool(),
            "solvent: void reserve + prizes + fees all backed"
        );
    }

    // ------------------------------------------------------------------
    // F4 修复回归：最低质押额 + 全额赎回 swap-pop 出质押者数组
    // ------------------------------------------------------------------

    function test_MinStakeAndStakerSwapPop() public {
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        // 首次质押 < MIN_STAKE → revert
        vm.prank(alice);
        vm.expectRevert("JPH: below min stake");
        jackpot.stakeEth{value: 0.0099 ether}();
        // 首次质押恰好 0.01 → 成功
        vm.prank(alice);
        jackpot.stakeEth{value: 0.01 ether}();
        assertEq(jackpot.stakersLen(), 1);
        // 已有质押者追加 0.001（< MIN_STAKE）→ 不受限
        vm.prank(alice);
        jackpot.stakeEth{value: 0.001 ether}();
        assertEq(jackpot.ethStaked(alice), 0.011 ether);
        // 第二名质押者
        vm.prank(bob);
        jackpot.stakeEth{value: 0.05 ether}();
        assertEq(jackpot.stakersLen(), 2);
        // alice 全额退出（两段式：申请 → 本轮结算 → 领取）→ 数组收缩（swap-pop），总质押账目一致
        // bob 同轮先挂单，结算后一起领
        uint256 rid = jackpot.currentRoundId();
        vm.prank(alice);
        jackpot.requestUnstake(0.011 ether);
        vm.prank(bob);
        jackpot.requestUnstake(0.05 ether);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);
        vm.prank(alice);
        jackpot.finalizeUnstake();
        assertEq(jackpot.stakersLen(), 1, "full unstake removes staker from array");
        assertEq(jackpot.totalEthStaked(), 0.05 ether);
        assertEq(jackpot.stakeCash(), 0.05 ether);
        // 全额退出后再次质押视同首次：< MIN_STAKE 仍 revert
        vm.prank(alice);
        vm.expectRevert("JPH: below min stake");
        jackpot.stakeEth{value: 0.005 ether}();
        // ≥ MIN_STAKE 重新进入数组
        vm.prank(alice);
        jackpot.stakeEth{value: 0.01 ether}();
        assertEq(jackpot.stakersLen(), 2, "re-stake re-enters array");
        // bob（被 swap 换位者）同轮挂单已成熟 → 领取正常，数组再收缩
        vm.prank(bob);
        jackpot.finalizeUnstake();
        assertEq(jackpot.stakersLen(), 1, "swapped staker still removable");
        assertEq(jackpot.totalEthStaked(), 0.01 ether);
        assertEq(jackpot.stakeCash(), 0.01 ether);
    }

    // ------------------------------------------------------------------
    // F5：setPerkContract 事件
    // ------------------------------------------------------------------

    function test_SetPerkContractEmitsEvent() public {
        address newPerk = makeAddr("newPerk");
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit JackpotHood.PerkContractUpdated(newPerk);
        jackpot.setPerkContract(newPerk);
        assertEq(jackpot.perkContract(), newPerk);
    }

    // ------------------------------------------------------------------
    // 小奖项公平赔率封顶（PAYOUT_CAP：末5~末1 = 100000/10000/1000/100/10 ×，头奖不限）
    // ------------------------------------------------------------------

    // 封顶触发：末 1 位独中 1 注 → 实付 10 × 票价，余量进滚存
    function test_PayoutCapSoloLastDigit() public {
        uint256 rid = jackpot.currentRoundId();
        uint8[6] memory last1 = [9, 9, 9, 9, 9, 5];
        _buy(alice, last1, 1);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        JackpotHood.Round memory r = jackpot.getRound(rid);
        uint256 pool = r.prizePool; // 无质押：pool = prizePool = 1.0009
        assertEq(r.tierUnits[5], 1, "solo last-digit winner");
        uint256 uncapped = pool * 3 / 100; // ≈ 0.030027
        assertGt(uncapped, 10 * PRICE, "uncapped pot exceeds 10x cap");
        assertEq(r.tierPots[5], 10 * PRICE, "capped to 10x ticket price");
        // 滚存 = 空档 97% + 封顶余量（0.030027 − 0.01），本场景与兑付扣减后的留存精确相等
        assertEq(jackpot.pendingRollover(), pool - 10 * PRICE, "surplus + empty tiers rolled");
        assertEq(jackpot.ticketBank(), pool - 10 * PRICE, "bank retains capped surplus cash");
        // claim 按封顶后的 tierPots 记账：到手 88%
        uint256 bal = alice.balance;
        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        vm.prank(alice);
        jackpot.claim(rid, idx);
        assertEq(alice.balance - bal, (10 * PRICE) * 88 / 100, "claimed 88% of capped pot");
    }

    // 封顶不触发：多注分薄档池（pot/units < cap）→ 按原样全额分
    function test_PayoutCapNotTriggeredWhenDiluted() public {
        uint256 rid = jackpot.currentRoundId();
        uint8[6] memory last1 = [9, 9, 9, 9, 9, 5];
        _buy(alice, last1, 10); // 10 注末 1 位：档池 3%×1.009 ≈ 0.0303 < 10×票价×10 = 0.1
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        JackpotHood.Round memory r = jackpot.getRound(rid);
        uint256 pool = r.prizePool;
        uint256 pot = pool * 3 / 100;
        assertEq(r.tierUnits[5], 10);
        assertLt(pot, 10 * PRICE * 10, "pot below total cap");
        assertEq(r.tierPots[5], pot, "not capped: full 3% pot");
        // 无封顶余量：滚存仅空档部分 = pool − 中奖档
        assertEq(jackpot.pendingRollover(), pool - pot, "rollover excludes surplus when uncapped");
        // alice 单票 10 注独占档池：应得 = 全档池 × 88%
        uint256 bal = alice.balance;
        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        vm.prank(alice);
        jackpot.claim(rid, idx);
        assertEq(alice.balance - bal, pot * 88 / 100, "full pot share, uncapped");
    }

    // 头奖不封顶：独中按 40% pool 全额记账
    function test_PayoutCapJackpotUncapped() public {
        uint256 rid = jackpot.currentRoundId();
        _buy(bob, JACKPOT_NUMS, 1);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        JackpotHood.Round memory r = jackpot.getRound(rid);
        assertEq(r.tierUnits[0], 1);
        assertEq(r.tierPots[0], r.prizePool * 40 / 100, "jackpot paid in full, no cap");
    }

    // 守恒不破：封顶 + 质押共存场景下 pendingRollover ≤ ticketBank 且余额覆盖全部负债
    function test_PayoutCapConservation() public {
        uint256 rid = jackpot.currentRoundId();
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 1 ether}();
        uint8[6] memory last1 = [9, 9, 9, 9, 9, 5];
        _buy(bob, last1, 1); // 末 1 位独中 → 触发 10× 封顶
        _buy(carol, MISS_NUMS, 10);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        JackpotHood.Round memory r = jackpot.getRound(rid);
        uint256 pool = r.prizePool + 1 ether; // settle 时 pool = prizePool + stakeCash
        assertGt(pool * 3 / 100, 10 * PRICE, "uncapped exceeds cap");
        assertEq(r.tierPots[5], 10 * PRICE, "capped");
        // 守恒帽：记入滚存不超兑付扣减后的留存现金（质押成分不沉淀）
        assertLe(jackpot.pendingRollover(), jackpot.ticketBank(), "rollover backed by retained bank");
        // 资不抵债检查（审计口径）：余额 ≥ 未领奖金 + 质押本金 + 已分未领分红 + 抽水 + 作废预留
        uint256 unclaimed;
        for (uint256 i = 0; i < 6; i++) {
            if (r.tierUnits[i] > 0) unclaimed += r.tierPots[i] - r.tierClaimed[i];
        }
        uint256 debt = unclaimed + jackpot.totalEthStaked() + jackpot.pendingStakeRewards(alice)
            + jackpot.stakingPool() + jackpot._voidedOwed();
        assertGe(address(jackpot).balance, debt, "solvent under cap");
        // 封顶奖金照常可兑
        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        vm.prank(bob);
        jackpot.claim(rid, idx);
    }
}