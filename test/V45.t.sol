// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {JackpotHood} from "../src/JackpotHood.sol";

/// @dev V4.5 测试壳：暴露内部结算（沿用 JackpotHood.t.sol 的 harness 模式，独立命名防冲突）
contract V45Harness is JackpotHood {
    constructor(uint256 roundDuration_, uint64 lockWindow_, bool anchorFirstUtc_)
        JackpotHood(roundDuration_, lockWindow_, anchorFirstUtc_)
    {}

    function settleWithSeed(uint256 roundId, bytes32 seed) external {
        _settle(roundId, seed);
    }

    function stakersLen() external view returns (uint256) {
        return _stakers.length;
    }
}

/// @dev 拒收 ETH 的合约（充当拒收推荐人：fallback 必回滚）
contract V45Rejecter {
    receive() external payable {
        revert("no thanks");
    }
}

/// @dev 烧 gas 的合约（receive 死循环；V4.5 起 call 限 50k gas → 子调用 OOG 走容错）
contract V45GasBurner {
    receive() external payable {
        while (true) {}
    }
}

/// @dev 恶意推荐人：receive 里重入 buy/claim/finalize（全部应被 nonReentrant 挡住）。
///      结果经事件带出（SSTORE 会超 50k gas 上限）；成功重入另发 ReentrySuccess（应永不出现）。
contract V45Reenterer {
    event ReentryAttempt(uint8 indexed idx, bytes32 reasonHash);
    event ReentrySuccess(uint8 indexed idx);

    JackpotHood public jp;

    constructor(JackpotHood _jp) {
        jp = _jp;
    }

    receive() external payable {
        uint8[6] memory nums = [uint8(1), 2, 3, 4, 5, 6];
        try jp.buyTicket{value: 0}(nums, 1) {
            emit ReentrySuccess(0);
        } catch (bytes memory r) {
            emit ReentryAttempt(0, keccak256(r));
        }
        uint256[] memory empty;
        try jp.claim(1, empty) {
            emit ReentrySuccess(1);
        } catch (bytes memory r) {
            emit ReentryAttempt(1, keccak256(r));
        }
        try jp.finalizeUnstake() {
            emit ReentrySuccess(2);
        } catch (bytes memory r) {
            emit ReentryAttempt(2, keccak256(r));
        }
    }
}

/// @title V4.5 修订测试：claim 侧推荐人容错（M-1）+ 推荐 call 50k gas 上限（L-1）
///      + 两段式退出覆盖缺口（追加质押/分红/void 成熟/Committed 申请/跨轮领取/pause）
contract V45Test is Test {
    V45Harness public jackpot;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint256 public constant PRICE = 0.001 ether;
    uint256 public constant SEED_POOL = 1 ether;

    // 种子前 6 字节 00..05 → 开奖号码 0-1-2-3-4-5
    bytes32 public constant WIN_SEED = 0x0001020304050000000000000000000000000000000000000000000000000000;

    uint8[6] JACKPOT_NUMS = [0, 1, 2, 3, 4, 5]; // 头奖：全 6 位
    uint8[6] MISS_NUMS = [7, 7, 7, 7, 7, 7];

    bytes32 public constant REENTRANT_REASON =
        keccak256(abi.encodeWithSignature("Error(string)", "JPH: reentrant"));

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.prank(admin);
        jackpot = new V45Harness(24 hours, 15 minutes, true);
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
    // M-1：中奖侧推荐人拒收 → 领奖不卡（与购票侧同口径容错）
    // ------------------------------------------------------------------

    // 绑定拒收合约推荐人：claim 成功，中奖者净得 88% 不受影响，
    // 推荐人分文未得，其 5% 并入质押池（池合计得全额 12%），并记 ReferralClaimFallback
    function test_ClaimFallbackWhenReferrerRejects() public {
        uint256 rid = jackpot.currentRoundId();
        V45Rejecter rej = new V45Rejecter();
        vm.prank(alice);
        jackpot.setReferrer(address(rej));
        _buy(alice, JACKPOT_NUMS, 1);
        _buy(carol, MISS_NUMS, 1);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        JackpotHood.Round memory r = jackpot.getRound(rid);
        uint256 due = r.tierPots[0]; // 独中头奖
        uint256 feeTotal = due * 1200 / 10000;
        uint256 refShare = due * 500 / 10000;

        uint256 poolBefore = jackpot.stakingPool();
        uint256 aliceBefore = alice.balance;
        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit JackpotHood.ReferralClaimFallback(alice, address(rej), refShare);
        jackpot.claim(rid, idx); // V4.4 必 revert；V4.5 起成功

        assertEq(alice.balance - aliceBefore, due - feeTotal, "winner net 88% unaffected");
        assertEq(address(rej).balance, 0, "rejecting referrer got nothing");
        assertEq(jackpot.stakingPool(), poolBefore + feeTotal, "full 12% to staking pool (7% + rejected 5%)");
        JackpotHood.Ticket[] memory ts = jackpot.getUserTickets(rid, alice);
        assertTrue(ts[0].claimed, "ticket marked claimed");
        // 再领第二张（无）也不会卡：重领 revert 因已 claimed，而非推荐人
        vm.prank(alice);
        vm.expectRevert("JPH: ticket claimed");
        jackpot.claim(rid, idx);
    }

    // ------------------------------------------------------------------
    // L-1：烧 gas 推荐人 —— 购票成功 + fee 全额并池 + 中奖 claim 成功，且 gas 被封顶
    // ------------------------------------------------------------------

    function test_GasBurnReferrerBuyAndClaim() public {
        uint256 rid = jackpot.currentRoundId();
        V45GasBurner gb = new V45GasBurner();
        vm.prank(alice);
        jackpot.setReferrer(address(gb));

        // 购票：call 限 50k → 子调用 OOG → ok=false → 份额留在 ticketFee（全额 10% 进池）
        vm.deal(alice, 100 ether);
        uint256 total = PRICE * 10;
        uint256 fee = total * 1000 / 10000;
        vm.prank(alice);
        uint256 g0 = gasleft();
        jackpot.buyTicket{value: total}(MISS_NUMS, 10);
        uint256 buyGas = g0 - gasleft();
        assertLt(buyGas, 500_000, "gas capped: no more gas extortion");
        assertEq(jackpot.getRound(rid).ticketFee, fee, "full 10% falls back to pool");
        assertEq(jackpot.referralPaidPerRound(rid), 0);
        assertEq(address(gb).balance, 0);

        // 同一推荐人中奖侧：claim 成功、winner 净得 88%、其 5% 并入质押池。
        // alice 自己买头奖票（推荐人已是烧 gas 合约；购票侧同样走拒收兜底，fee 全额留池）
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        jackpot.buyTicket{value: PRICE}(JACKPOT_NUMS, 1);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        JackpotHood.Round memory r = jackpot.getRound(rid);
        uint256 due = r.tierPots[0];
        uint256 feeTotal = due * 1200 / 10000;
        uint256 poolBefore = jackpot.stakingPool();
        uint256 aliceBefore = alice.balance;
        // alice 的票：idx0 = MISS×10，idx1 = 头奖
        uint256[] memory idx = new uint256[](1);
        idx[0] = 1;
        vm.prank(alice);
        jackpot.claim(rid, idx);
        assertEq(alice.balance - aliceBefore, due - feeTotal, "winner net 88%");
        assertEq(jackpot.stakingPool(), poolBefore + feeTotal, "full 12% to pool via fallback");
        assertEq(address(gb).balance, 0, "burning referrer never got paid");
    }

    // ------------------------------------------------------------------
    // 恶意推荐人重入：receive 里重入 buy/claim/finalize —— 全部被 nonReentrant 挡住
    // ------------------------------------------------------------------

    // 购票过程触发（_splitBuyFee 的立付 call）：三次重入全部 revert "JPH: reentrant"，购票照常完成
    function test_ReentrantReferrerOnBuyAllBlocked() public {
        uint256 rid = jackpot.currentRoundId();
        V45Reenterer re = new V45Reenterer(jackpot);
        vm.prank(alice);
        jackpot.setReferrer(address(re));
        uint256 total = PRICE * 10;
        uint256 refShare = (total * 1000 / 10000) / 2;

        vm.recordLogs();
        _buy(alice, MISS_NUMS, 10); // 不 revert
        assertEq(jackpot.getRound(rid).totalTickets, 10, "purchase completed");
        assertEq(address(re).balance, refShare, "referrer paid after benign return");
        _assertThreeReentriesBlocked(re);
    }

    // 领奖过程触发（claim 的推荐分成 call）：三次重入全部被挡，领奖照常完成
    function test_ReentrantReferrerOnClaimAllBlocked() public {
        uint256 rid = jackpot.currentRoundId();
        V45Reenterer re = new V45Reenterer(jackpot);
        vm.prank(alice);
        jackpot.setReferrer(address(re));
        _buy(alice, JACKPOT_NUMS, 1);
        _buy(carol, MISS_NUMS, 1);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        uint256 due = jackpot.getRound(rid).tierPots[0];
        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        uint256 aliceBefore = alice.balance;
        uint256 reBefore = address(re).balance; // 已含购票侧立付的 5%
        vm.recordLogs();
        vm.prank(alice);
        jackpot.claim(rid, idx);
        assertEq(alice.balance - aliceBefore, due - due * 1200 / 10000, "winner net 88%");
        assertEq(address(re).balance - reBefore, due * 500 / 10000, "referrer paid 5% after benign return");
        _assertThreeReentriesBlocked(re);
    }

    function _assertThreeReentriesBlocked(V45Reenterer re) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 attempts;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(re)) continue;
            if (logs[i].topics[0] == V45Reenterer.ReentryAttempt.selector) {
                bytes32 reason = abi.decode(logs[i].data, (bytes32));
                assertEq(reason, REENTRANT_REASON, "blocked by nonReentrant");
                attempts++;
            } else if (logs[i].topics[0] == V45Reenterer.ReentrySuccess.selector) {
                revert("reentrancy succeeded: nonReentrant broken");
            }
        }
        assertEq(attempts, 3, "buy/claim/finalize all attempted");
    }

    // ------------------------------------------------------------------
    // 两段式退出覆盖缺口
    // ------------------------------------------------------------------

    // 挂单期间追加质押：finalize 只付申请额，追加部分留存质押
    function test_PendingUnstakeTopUpPaysRequestedOnly() public {
        uint256 rid = jackpot.currentRoundId();
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 1 ether}();
        vm.prank(alice);
        jackpot.requestUnstake(1 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 0.5 ether}(); // 挂单期间追加（允许，不受 MIN_STAKE 限）
        assertEq(jackpot.ethStaked(alice), 1.5 ether);

        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);
        uint256 bal = alice.balance;
        vm.prank(alice);
        jackpot.finalizeUnstake();
        assertEq(alice.balance - bal, 1 ether, "finalize pays only requested amount");
        assertEq(jackpot.ethStaked(alice), 0.5 ether, "top-up stays staked");
        assertEq(jackpot.stakersLen(), 1, "still in stakers array");
    }

    // 挂单期间照常分红（结算快照含挂单份额），退出后分红可领
    function test_PendingUnstakeEarnsDividends() public {
        uint256 rid = jackpot.currentRoundId();
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 1 ether}();
        vm.prank(alice);
        jackpot.requestUnstake(1 ether); // 全额挂单
        _buy(carol, MISS_NUMS, 100); // 买票抽水 0.01 ETH
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        uint256 feePool = PRICE * 100 * 1000 / 10000;
        assertEq(jackpot.pendingStakeRewards(alice), feePool, "pending unstaker earns full snapshot dividend");
        vm.prank(alice);
        jackpot.finalizeUnstake();
        uint256 bal = alice.balance;
        vm.prank(alice);
        jackpot.claimStakeRewards();
        assertEq(alice.balance - bal, feePool, "rewards claimable after exit");
    }

    // 登记轮被 void（Open → Voided 终态）→ 挂单立即成熟（跳过陪跑结算）
    function test_VoidRoundMaturesUnstakeImmediately() public {
        uint256 rid = jackpot.currentRoundId();
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 1 ether}();
        vm.prank(alice);
        jackpot.requestUnstake(1 ether);
        vm.prank(admin);
        jackpot.voidRound(rid);
        uint256 bal = alice.balance;
        vm.prank(alice);
        jackpot.finalizeUnstake();
        assertEq(alice.balance - bal, 1 ether, "voided round matures instantly");
        assertEq(jackpot.ethStaked(alice), 0);
        assertEq(jackpot.stakersLen(), 0);
    }

    // Committed 状态申请 → 登记当轮（必须陪跑本轮结算）
    function test_RequestWhileCommittedBooksCurrentRound() public {
        uint256 rid = jackpot.currentRoundId();
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 1 ether}();
        _warpToDraw(rid);
        jackpot.commitDraw(rid); // Open → Committed
        vm.prank(alice);
        jackpot.requestUnstake(1 ether);
        (, uint64 reqRid) = jackpot.unstakeReqOf(alice);
        assertEq(reqRid, uint64(rid), "committed: booked to current round");
        vm.prank(alice);
        vm.expectRevert("JPH: not matured");
        jackpot.finalizeUnstake();
    }

    // 登记后跨多轮 finalize：无过期，跨 3 轮后照常领取
    function test_FinalizeManyRoundsLater() public {
        uint256 rid = jackpot.currentRoundId();
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 1 ether}();
        vm.prank(alice);
        jackpot.requestUnstake(1 ether);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED); // 登记轮终态

        // 跨 3 轮不来领
        for (uint256 i; i < 3; i++) {
            jackpot.startRound();
            uint256 r2 = jackpot.currentRoundId();
            _warpToDraw(r2);
            jackpot.settleWithSeed(r2, WIN_SEED);
        }
        assertEq(jackpot.currentRoundId(), rid + 3);

        uint256 bal = alice.balance;
        vm.prank(alice);
        jackpot.finalizeUnstake(); // 无过期，照常领取
        assertEq(alice.balance - bal, 1 ether);
        assertEq(jackpot.ethStaked(alice), 0);
    }

    // pause 阻断两段式退出两步；unpause 后恢复
    function test_PauseBlocksRequestAndFinalize() public {
        uint256 rid = jackpot.currentRoundId();
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 1 ether}();
        vm.deal(bob, 100 ether);
        vm.prank(bob);
        jackpot.stakeEth{value: 1 ether}();

        vm.prank(admin);
        jackpot.pause();
        vm.prank(alice);
        vm.expectRevert("JPH: paused");
        jackpot.requestUnstake(1 ether); // pause 阻断申请

        vm.prank(admin);
        jackpot.unpause();
        vm.prank(alice);
        jackpot.requestUnstake(1 ether);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED); // 登记轮终态

        vm.prank(admin);
        jackpot.pause();
        vm.prank(alice);
        vm.expectRevert("JPH: paused");
        jackpot.finalizeUnstake(); // pause 阻断领取

        vm.prank(admin);
        jackpot.unpause();
        uint256 bal = alice.balance;
        vm.prank(alice);
        jackpot.finalizeUnstake();
        assertEq(alice.balance - bal, 1 ether, "unpause restores exit");
    }
}
