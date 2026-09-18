// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console2} from "forge-std/console2.sol";
import {JackpotHood} from "../src/JackpotHood.sol";
import {JackpotHoodPerks} from "../src/JackpotHoodPerks.sol";
import {JackpotHoodToken} from "../src/mocks/JackpotHoodToken.sol";

/// @notice Invariant handler：随机乱序驱动合约全部资金入口（时间/区块随机推进）
contract Handler is Test {
    JackpotHood public jp;
    JackpotHoodPerks public perks;
    JackpotHoodToken public jph;
    address[] public actors;
    uint256 public constant PRICE = 0.001 ether;

    // 免费票哨兵 gifter（镜像 src/JackpotHood.sol 的 FREE_TICKET 内部常量）
    address internal constant FREE_TICKET_GIFTER = address(0x000000000000000000000000000000000000dEaD);

    uint256 public ops; // 总操作计数

    // ---- 影子账本 ----
    // （F2 修复后 _voidedOwed 改为 public，守恒不变量直接读合约真值，不再需要 ghost 镜像；
    //    原 ghostVoidLeak 补偿项——ticketFee 双重记账——随修复删除，容差仅剩共担清算 floor 尘）
    uint256 public ghostLossShareEvents; // 共担清算发生次数（floor 取整尘 < 质押者数 wei/次，守恒容差用）
    uint256 public batchReverts;         // 1..1000 组合法批量购票意外 revert 数（应恒为 0）
    uint256 public oversizedAccepted;    // >1000 组批量被接受数（应恒为 0）
    uint256 public redeemAtomicityBreaks;// 免费额度批量领取非原子（应恒为 0）
    // V4.4 购票推荐 5% 立付：被作废轮若含「已推荐分成」的售票，其 5% 已离场而 _voidedOwed
    // 仍按全款 ticketRevenue 预留 → 该部分须由平台残余现金（注资/其它轮）兜底。
    // 容差 = 各作废轮 referralPaidPerRound 之和（ghost 精确计量，只增不减，保守上界）。
    uint256 public ghostVoidedRefPaid;

    // ---- 覆盖计数（反 vacuity：证明关键路径真的被执行过）----
    uint256 public ghostSettles;
    uint256 public ghostClaims;
    uint256 public ghostSweeps;
    uint256 public ghostVoids;
    uint256 public ghostRefunds;
    uint256 public ghostUnstakeRequests;
    uint256 public ghostUnstakeFinalized;

    constructor(JackpotHood jp_, JackpotHoodPerks perks_, JackpotHoodToken jph_) {
        jp = jp_;
        perks = perks_;
        jph = jph_;
        for (uint256 i = 0; i < 8; i++) {
            address a = address(uint160(0xBEEF + i));
            actors.push(a);
            vm.deal(a, 1000 ether);
        }
        vm.prank(actors[0]);
        jph.faucet(); // mock 有领水；actor 需要 JPH 用 admin 转账更稳
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
    function _rand() internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(block.timestamp, block.number, msg.sender, ops)));
    }

    // ---- 用户操作 ----
    function stake() external {
        ops++;
        address u = _actor(_rand());
        uint256 amt = (_rand() % 20 ether) + 0.01 ether; // F4：首次质押下限 MIN_STAKE=0.01（追加不受限）
        vm.deal(u, 1000 ether);
        vm.prank(u);
        jp.stakeEth{value: amt}();
    }

    // V4.4 两段式退出：无挂单 → 发起申请（陪跑当前/下一轮结算）；有挂单 → 尝试领取
    // （登记轮未终态则 revert，由引擎容忍；成熟后领取成功计覆盖数）
    function unstake() external {
        ops++;
        address u = _actor(_rand());
        (uint256 reqAmt, ) = jp.unstakeReqOf(u);
        if (reqAmt == 0) {
            uint256 s = jp.ethStaked(u);
            if (s == 0) return;
            uint256 amt = (s * (_rand() % 100)) / 100 + 1;
            if (amt > s) amt = s;
            vm.prank(u);
            try jp.requestUnstake(amt) { ghostUnstakeRequests++; } catch {}
        } else {
            vm.prank(u);
            try jp.finalizeUnstake() { ghostUnstakeFinalized++; } catch {}
        }
    }

    function buy() external {
        ops++;
        address u = _actor(_rand());
        uint8[6] memory nums;
        for (uint256 i = 0; i < 6; i++) nums[i] = uint8(_rand() % 10);
        uint64 count = uint64((_rand() % 10) + 1);
        vm.deal(u, 1000 ether);
        vm.prank(u);
        jp.buyTicket{value: PRICE * count}(nums, count);
    }

    function buyBatch() external {
        ops++;
        address u = _actor(_rand());
        uint8[6][] memory list = new uint8[6][](5);
        uint64[] memory counts = new uint64[](5);
        for (uint256 i = 0; i < 5; i++) {
            for (uint256 j = 0; j < 6; j++) list[i][j] = uint8(_rand() % 10);
            counts[i] = 1;
        }
        vm.deal(u, 1000 ether);
        vm.prank(u);
        jp.buyTickets{value: PRICE * 5}(list, counts);
    }

    function freeTicketByAdmin() external {
        ops++;
        uint8[6] memory nums;
        for (uint256 i = 0; i < 6; i++) nums[i] = uint8(_rand() % 10);
        address u = _actor(_rand());
        vm.prank(jp.admin());
        jp.freeTicket(u, nums, 1); // 受 1000/轮上限约束，超出 revert 由引擎容忍
    }

    function grantAndRedeem() external {
        ops++;
        address u = _actor(_rand());
        vm.prank(jp.admin());
        jp.grantFreeCredits(u, 10);
        uint8[6] memory nums;
        for (uint256 i = 0; i < 6; i++) nums[i] = uint8(_rand() % 10);
        vm.prank(u);
        jp.redeemFreeTicket(nums, uint64((_rand() % 10) + 1));
    }

    function jphStakePerk() external {
        ops++;
        address u = _actor(_rand());
        // 从 admin(mock owner) 转账 JPH 给 actor 再质押
        uint256 amt = (_rand() % 300_000 ether) + 1000 ether;
        vm.prank(jp.admin());
        jph.transfer(u, amt);
        vm.prank(u);
        jph.approve(address(perks), amt);
        vm.prank(u);
        perks.stakeJph(amt);
        vm.prank(u);
        // 额度按天惰性累积（未领上限 3），未累积到时 revert 由引擎容忍
        try perks.redeemPerkTicket(uint8[6]([uint8(1), 2, 3, 4, 5, 6]), 1) {} catch {}
    }

    /// @dev 结算并探测是否发生质押共担清算（totalEthStaked 下降 = 清算发生）
    function _trySettle(uint256 id) internal {
        uint256 tsBefore = jp.totalEthStaked();
        try jp.settleDraw(id) {
            ghostSettles++;
            if (jp.totalEthStaked() < tsBefore) ghostLossShareEvents++;
        } catch {}
    }

    function warpAndSettleOldest() external {
        if (_rand() % 40 != 0) return; // 降频：结算单次 ~26M gas，默认 256×500 campaign 下需控总量
        ops++;
        _advanceOnce();
    }

    /// @dev 无降频版：仅供反 vacuity 单测直接驱动（已通过 targetSelector 白名单排除出 invariant campaign）
    function warpAndSettleForce() external {
        ops++;
        _advanceOnce();
    }

    /// @dev 推进一轮并尝试结算最老未决轮（真实 commit→快照→结算；每次调用最多推进一步）
    function _advanceOnce() internal {
        uint256 rid = jp.currentRoundId();
        // 安全下界：原写法 `id > rid - 4` 在 rid < 4 时 uint256 下溢 panic，
        // 导致该函数在 rid<4 期间 100% revert（叠加 randomTick 每深度最多 ~7.5h < 23.75h，
        // 轮次永远无法推进，结算/派彩/滚存路径在原套件中从未真正执行）
        uint256 lo = rid > 3 ? rid - 3 : 1;
        for (uint256 id = lo; id <= rid; id++) { // 从最老一轮开始推进
            JackpotHood.Round memory r = jp.getRound(id);
            if (r.drawAt == 0) continue;
            if (uint8(r.status) == 0) {
                if (block.timestamp < r.drawAt) vm.warp(r.drawAt + 1);
                vm.prank(actors[0]);
                try jp.commitDraw(id) {} catch { continue; }
                vm.roll(block.number + 2);
                try jp.snapshotCommitHash(id) {} catch {}
                vm.prank(actors[0]);
                _trySettle(id);
                return;
            } else if (uint8(r.status) == 1) {
                vm.roll(block.number + 2);
                try jp.snapshotCommitHash(id) {} catch {}
                vm.prank(actors[0]);
                _trySettle(id);
                return;
            } else if (uint8(r.status) == 2 || uint8(r.status) == 3) {
                // 开新轮：仅成功时算推进一步；失败（当前轮仍未结束）则继续扫描更老的轮
                try jp.startRound() { return; } catch { continue; }
            }
        }
    }

    function claimWinners() external {
        ops++;
        address u = _actor(_rand());
        uint256 rid = jp.currentRoundId();
        uint256 lo = rid > 2 ? rid - 2 : 1; // 同上的下溢修复（原 `id > rid - 3`）
        for (uint256 id = rid; id >= lo; id--) {
            (uint256 due, uint256[] memory idx) = jp.previewClaim(id, u);
            if (due > 0) {
                vm.prank(u);
                try jp.claim(id, idx) { ghostClaims++; } catch {}
                return;
            }
        }
    }

    function randomTick() external {
        ops++;
        uint256 t = (_rand() % 3600) + 1;
        vm.warp(block.timestamp + t);
        if ((_rand() % 3) == 0) vm.roll(block.number + 1);
    }

    // ---- 覆盖扩展：赠票 / 注资 / 推荐 / 分红领取 / 逾期滚存 / 作废+退款 ----

    function gift() external {
        ops++;
        address from = _actor(_rand());
        address to = _actor(_rand() / 13);
        if (from == to) return;
        uint8[6] memory nums;
        for (uint256 i = 0; i < 6; i++) nums[i] = uint8(_rand() % 10);
        uint64 count = uint64((_rand() % 5) + 1);
        vm.deal(from, 1000 ether);
        vm.prank(from);
        try jp.giftTicket{value: PRICE * count}(to, nums, count) {} catch {}
    }

    function injectPrize() external {
        ops++;
        address u = _actor(_rand());
        uint256 amt = (_rand() % 5 ether) + 1 wei;
        vm.deal(u, 1000 ether);
        vm.prank(u);
        jp.injectPrizeEth{value: amt}();
    }

    function setRef() external {
        ops++;
        address u = _actor(_rand());
        address ref = _actor(_rand() / 7);
        if (u == ref || jp.getReferrer(u) != address(0)) return;
        vm.prank(u);
        try jp.setReferrer(ref) {} catch {}
    }

    function claimStakeRewards() external {
        ops++;
        address u = _actor(_rand());
        if (jp.pendingStakeRewards(u) == 0) return;
        vm.prank(u);
        try jp.claimStakeRewards() {} catch {}
    }

    function sweepExpired() external {
        ops++;
        uint256 rid = jp.currentRoundId();
        uint256 lo = rid > 3 ? rid - 3 : 1;
        for (uint256 id = rid; id >= lo; id--) {
            JackpotHood.Round memory r = jp.getRound(id);
            if (r.drawAt == 0 || uint8(r.status) != 2 || r.swept) continue;
            if (block.timestamp <= r.claimDeadline) vm.warp(r.claimDeadline + 1);
            try jp.sweepUnclaimed(id) { ghostSweeps++; } catch {}
            return;
        }
    }

    /// @dev 管理员作废随机一轮（Open/Committed）；作废含推荐分成售票的轮 → 累积守恒容差
    function voidSomeRound() external {
        ops++;
        uint256 rid = jp.currentRoundId();
        uint256 id = (_rand() % rid) + 1;
        JackpotHood.Round memory r = jp.getRound(id);
        if (r.drawAt == 0 || uint8(r.status) > 1) return;
        vm.prank(jp.admin());
        try jp.voidRound(id) {
            ghostVoids++;
            ghostVoidedRefPaid += jp.referralPaidPerRound(id);
        } catch {}
    }

    /// @dev 作废轮退款：按可退下标实算，成功后计覆盖数
    function refundVoided() external {
        ops++;
        address u = _actor(_rand());
        uint256 rid = jp.currentRoundId();
        uint256 lo = rid > 5 ? rid - 5 : 1;
        for (uint256 id = rid; id >= lo; id--) {
            JackpotHood.Round memory r = jp.getRound(id);
            if (r.drawAt == 0 || uint8(r.status) != 3) continue;
            JackpotHood.Ticket[] memory ts = jp.getUserTickets(id, u);
            uint256 cap = ts.length > 32 ? 32 : ts.length; // 控 gas
            uint256[] memory idx = new uint256[](cap);
            uint256 n;
            for (uint256 i = 0; i < ts.length && n < cap; i++) {
                if (ts[i].refunded || ts[i].gifter == FREE_TICKET_GIFTER) continue;
                idx[n++] = i;
            }
            if (n == 0) continue;
            uint256[] memory sel = new uint256[](n);
            for (uint256 i = 0; i < n; i++) sel[i] = idx[i];
            vm.prank(u);
            try jp.refundTickets(id, sel) { ghostRefunds++; } catch {}
            return;
        }
    }

    // ---- 批量边界：1..1000 组必须成功；>1000 组必须 revert；免费额度批量原子性 ----

    function buyBatchBounded(uint256 seed) external {
        ops++;
        address u = _actor(seed);
        // 99% 小批量（1..50 组），1% 全范围（1..1000 组，控 campaign 成本；全长度另由 BatchBounds 单测覆盖）
        uint256 n = (seed % 100 == 0) ? (seed % 1000) + 1 : (seed % 50) + 1;
        uint8[6][] memory list = new uint8[6][](n);
        uint64[] memory counts = new uint64[](n);
        uint256 units;
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < 6; j++) list[i][j] = uint8((seed >> (8 * (j % 4))) % 10);
            counts[i] = uint64(((seed >> (i % 13)) % 3) + 1); // 1..3 注/组
            units += counts[i];
        }
        vm.deal(u, 1000 ether);
        vm.prank(u);
        try jp.buyTickets{value: PRICE * units}(list, counts) {} catch { batchReverts++; }
    }

    function buyBatchOversized(uint256 seed) external {
        ops++;
        address u = _actor(seed);
        uint256 n = 1001 + (seed % 4); // 1001..1004 组：长度校验即 revert，gas 低
        uint8[6][] memory list = new uint8[6][](n);
        uint64[] memory counts = new uint64[](n);
        for (uint256 i = 0; i < n; i++) counts[i] = 1;
        vm.deal(u, 2000 ether);
        vm.prank(u);
        try jp.buyTickets{value: PRICE * n}(list, counts) { oversizedAccepted++; } catch {}
    }

    function redeemFreeBatch(uint256 seed) external {
        ops++;
        address u = _actor(seed);
        uint256 n = (seed % 20) + 1;
        vm.prank(jp.admin());
        jp.grantFreeCredits(u, uint64(n));
        uint8[6][] memory list = new uint8[6][](n);
        uint64[] memory counts = new uint64[](n);
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < 6; j++) list[i][j] = uint8((i + j) % 10);
            counts[i] = 1;
        }
        uint256 creditsBefore = jp.freeCredits(u);
        vm.prank(u);
        try jp.redeemFreeTickets(list, counts) {
            if (jp.freeCredits(u) != creditsBefore - n) redeemAtomicityBreaks++;
        } catch {
            // 触发免费 cap 等回滚时额度必须原样保留（整批原子性）
            if (jp.freeCredits(u) != creditsBefore) redeemAtomicityBreaks++;
        }
    }
}

/// @notice Invariant 测试：资金守恒 + 兑付保障（随机轰炸下永不打破）
contract InvariantTest is Test {
    JackpotHood public jp;
    JackpotHoodToken public jph;
    Handler public h;

    address admin = makeAddr("admin");

    function setUp() public {
        vm.prank(admin);
        jph = new JackpotHoodToken(100_000_000 ether);
        vm.prank(admin);
        jp = new JackpotHood(24 hours, 15 minutes, true);
        JackpotHoodPerks perks = new JackpotHoodPerks(address(jph), address(jp));
        vm.prank(admin);
        jp.setPerkContract(address(perks));
        vm.deal(admin, 100 ether); // 管理员资金（注资/直发用）
        vm.deal(address(jp), 1 ether);
        vm.prank(admin);
        jp.injectPrizeEth{value: 1 ether}();
        vm.prank(admin);
        jp.grantFreeCredits(address(0xBEEF), 50);

        h = new Handler(jp, perks, jph);
        // 让 handler 的 actors[0] 有 JPH 初始
        vm.prank(admin);
        jph.transfer(address(0xBEEF), 1_000_000 ether);
        targetContract(address(h));
        // 显式 selector 白名单：排除视图 getter（不浪费 campaign 调用）
        // 与 warpAndSettleForce（无降频推进器，只供反 vacuity 单测直接驱动）
        bytes4[] memory sels = new bytes4[](20);
        sels[0] = Handler.stake.selector;
        sels[1] = Handler.unstake.selector;
        sels[2] = Handler.buy.selector;
        sels[3] = Handler.buyBatch.selector;
        sels[4] = Handler.freeTicketByAdmin.selector;
        sels[5] = Handler.grantAndRedeem.selector;
        sels[6] = Handler.jphStakePerk.selector;
        sels[7] = Handler.warpAndSettleOldest.selector;
        sels[8] = Handler.claimWinners.selector;
        sels[9] = Handler.randomTick.selector;
        sels[10] = Handler.gift.selector;
        sels[11] = Handler.injectPrize.selector;
        sels[12] = Handler.setRef.selector;
        sels[13] = Handler.claimStakeRewards.selector;
        sels[14] = Handler.sweepExpired.selector;
        sels[15] = Handler.voidSomeRound.selector;
        sels[16] = Handler.refundVoided.selector;
        sels[17] = Handler.buyBatchBounded.selector;
        sels[18] = Handler.buyBatchOversized.selector;
        sels[19] = Handler.redeemFreeBatch.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(h), selectors: sels}));
    }

    // I1 兑付保障：任何时刻合约余额 >= 全部已开未领奖金 + 质押可赎 + 抽水负债 + 退款预留
    // （容差 ghostVoidedRefPaid：作废轮已立付推荐人的 5% 已离场但预留仍按全款计，由平台残余现金兜底）
    function invariant_solvency() public view {
        uint256 debt;
        uint256 rid = jp.currentRoundId();
        for (uint256 id = rid; id > 0 && (rid <= 8 || id > rid - 8); id--) {
            JackpotHood.Round memory r = jp.getRound(id);
            if (r.drawAt == 0 || uint8(r.status) != 2) continue;
            for (uint256 i = 0; i < 6; i++) {
                if (r.tierUnits[i] > 0 && !r.swept) debt += r.tierPots[i] - r.tierClaimed[i];
            }
        }
        debt += jp.stakingPool();
        debt += jp.totalEthStaked();
        assertGe(address(jp).balance + h.ghostVoidedRefPaid(), debt, "solvency broken");
    }

    // I2 质押现金与总质押恒等
    function invariant_stakeCashEqualsTotal() public view {
        assertEq(jp.stakeCash(), jp.totalEthStaked(), "stakeCash/total mismatch");
    }

    // I3 免费票上限永不超（全部历史轮），且免费票恒为总票数子集
    function invariant_freeCap() public view {
        uint256 rid = jp.currentRoundId();
        for (uint256 id = 1; id <= rid; id++) {
            JackpotHood.Round memory r = jp.getRound(id);
            if (r.drawAt == 0) continue;
            assertLe(jp.freeMinted(id), 1000, "free cap broken");
            assertLe(jp.freeMinted(id), r.totalTickets, "free tickets exceed total");
        }
    }

    // I4 各轮兑付不超档池
    function invariant_claimsWithinPots() public view {
        uint256 rid = jp.currentRoundId();
        for (uint256 id = rid; id > 0 && (rid <= 8 || id > rid - 8); id--) {
            JackpotHood.Round memory r = jp.getRound(id);
            if (r.drawAt == 0 || uint8(r.status) != 2) continue;
            for (uint256 i = 0; i < 6; i++) {
                assertLe(r.tierClaimed[i], r.tierPots[i], "over-claim");
            }
        }
    }

    // I5 质押者永不为负（共担扣减后）
    function invariant_stakersNonNegative() public view {
        for (uint256 i = 0; i < 8; i++) {
            assertGe(jp.ethStaked(address(uint160(0xBEEF + i))), 0, "negative stake");
        }
        assertGe(jp.stakeCash(), 0, "negative stakeCash");
    }

    // I6 全口径资金守恒：余额必须覆盖全部即时负债 =
    //    票款银行 + 质押现金 + 未分配抽水 + 已分未领分红 + 未结算轮抽水
    //    + 已开未领奖金（未 sweep）+ 作废退款预留（直接读合约 _voidedOwed 真值）。
    //    容差两项、均有界且由 ghost 精确计量：
    //    1) 共担清算 floor 取整尘 < 8 wei/次（8 名质押者每人 < 1 wei）；
    //    2) ghostVoidedRefPaid——V4.4 购票推荐 5% 立付后，作废轮的退款预留仍按全款
    //       ticketRevenue 计，但推荐份额已离场（每轮实付额经 referralPaidPerRound 精确跟踪），
    //       该缺口由平台残余现金兜底。购票本身守恒精确：90% bank + 5% ticketFee + 5% 推荐人。
    //    超出此口径的任何资金流失都会打破断言。
    function invariant_fullConservation() public view {
        uint256 debt = jp.ticketBank() + jp.stakeCash() + jp.stakingPool() + jp._voidedOwed();
        for (uint256 i = 0; i < 8; i++) {
            debt += jp.pendingStakeRewards(address(uint160(0xBEEF + i)));
        }
        uint256 rid = jp.currentRoundId();
        for (uint256 id = 1; id <= rid; id++) {
            JackpotHood.Round memory r = jp.getRound(id);
            if (r.drawAt == 0) continue;
            debt += r.ticketFee; // 未结算轮累计抽水（已扣除立付推荐人份额；settle/void 时清零或转走）
            if (uint8(r.status) == 2 && !r.swept) {
                for (uint256 t = 0; t < 6; t++) {
                    if (r.tierUnits[t] > 0) debt += r.tierPots[t] - r.tierClaimed[t];
                }
            }
        }
        uint256 tolerance = h.ghostLossShareEvents() * 8 + h.ghostVoidedRefPaid();
        assertGe(address(jp).balance + tolerance, debt, "conservation broken");
    }

    // I7 质押者个体账目之和恒等总质押（共担清算逐人扣减必须与总额一致，无漂移）
    function invariant_stakeSumEqualsTotal() public view {
        uint256 sum;
        for (uint256 i = 0; i < 8; i++) {
            sum += jp.ethStaked(address(uint160(0xBEEF + i)));
        }
        assertEq(sum, jp.totalEthStaked(), "staker sum != totalEthStaked");
    }

    // I8 待滚存只在「无开放轮」时非零：开放轮一旦出现必须立即吸收 pendingRollover
    function invariant_pendingRolloverAbsorbed() public view {
        JackpotHood.Round memory r = jp.getCurrentRound();
        if (uint8(r.status) == 0) {
            assertEq(jp.pendingRollover(), 0, "rollover not absorbed by open round");
        }
    }

    // I9 已结束轮（Drawn/Voided）抽水必须清零（settle 入分红池 / void 转滚存，不得残留）
    function invariant_ticketFeeClearedOnFinal() public view {
        uint256 rid = jp.currentRoundId();
        for (uint256 id = 1; id <= rid; id++) {
            JackpotHood.Round memory r = jp.getRound(id);
            if (r.drawAt == 0) continue;
            if (uint8(r.status) >= 2) assertEq(r.ticketFee, 0, "ticketFee not cleared on final round");
        }
    }

    // I10 批量边界与免费额度原子性：ghost 计数必须恒 0
    function invariant_batchAndRedeemIntegrity() public view {
        assertEq(h.batchReverts(), 0, "legal 1..1000 batch reverted");
        assertEq(h.oversizedAccepted(), 0, "oversized >1000 batch accepted");
        assertEq(h.redeemAtomicityBreaks(), 0, "free-credit redeem not atomic");
    }

    // 反 vacuity 回归：直接驱动 handler，确认轮次推进、真实结算真实发生、两段式退出真实走通。
    // （原 handler 循环下溢导致结算路径从未执行，I1/I4 曾长期空转——此处钉死）
    function test_HandlerActuallySettlesRounds() public {
        for (uint256 i = 0; i < 20 && (h.ghostSettles() < 3 || h.ghostUnstakeFinalized() == 0); i++) {
            h.buy();
            h.buyBatch();
            h.stake();
            h.unstake();
            h.warpAndSettleForce();
            h.unstake();
            h.claimWinners();
        }
        assertGt(jp.currentRoundId(), 1, "rounds never advanced");
        assertGt(h.ghostSettles(), 0, "no round ever settled");
        assertGt(h.ghostUnstakeRequests(), 0, "no unstake ever requested");
        assertGt(h.ghostUnstakeFinalized(), 0, "no unstake ever finalized");
        bool anyDrawn;
        for (uint256 id = 1; id <= jp.currentRoundId(); id++) {
            if (uint8(jp.getRound(id).status) == 2) {
                anyDrawn = true;
                break;
            }
        }
        assertTrue(anyDrawn, "no drawn round found");
    }
}
