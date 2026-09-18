// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {JackpotHood} from "../src/JackpotHood.sol";

/// @title F2 修复回归：voidRound 退款预留只计全款 ticketRevenue（fee 不再双重承诺）
/// @notice 修复前：`_voidedOwed += ticketRevenue + ticketFee`，但 refundTickets 只按全款
///         （TICKET_PRICE*count == ticketRevenue）实退，fee 部分的预留永不灭失；同时 fee 现金
///         又被滚入下一轮奖池 —— 一笔 fee 现金两处承诺（原复现见 git 历史 test_VoidFeeDoubleBooked）。
///         修复后（本文件钉死）：
///           1) `_voidedOwed += ticketRevenue` —— 预留精确等于可退义务，全额退款后预留清零；
///           2) ticketFee 滚入下轮奖池保留（有意设计：作废轮抽水视作让利下轮，金额上限 = 作废轮
///              10% 抽水，由后续票款/质押兜底）；
///           3) 守恒口径：合约余额恒 ≥ 全部预留负债（_voidedOwed 不再含永不灭失的死预留，
///              Invariant I6 的 ghostVoidLeak 补偿项已随之删除）。
contract AuditReproTest is Test {
    JackpotHood public jp;
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    uint256 public constant PRICE = 0.001 ether;

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.prank(admin);
        jp = new JackpotHood(24 hours, 15 minutes, true); // 不注资，保持账务干净
    }

    /// @dev 修复后：预留 = 全款 revenue（无 fee 双重预留），fee 仅滚存；全额退款后预留精确清零
    function test_VoidFeeSingleBooked() public {
        uint256 rid = jp.currentRoundId();

        // 1) alice 买 100 注 = 0.1 ETH：bank/pool +0.09，ticketFee +0.01
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        jp.buyTicket{value: PRICE * 100}([uint8(7), 7, 7, 7, 7, 7], 100);
        assertEq(address(jp).balance, 0.1 ether);
        assertEq(jp.ticketBank(), 0.09 ether);
        assertEq(jp.getRound(rid).ticketFee, 0.01 ether);

        // 2) 作废：预留只计全款 0.1（修复前为 0.11，其中 0.01 永不灭失）；fee 0.01 滚入下轮（有意设计）
        vm.prank(admin);
        jp.voidRound(rid);
        assertEq(jp.ticketBank(), 0, "bank reverted");
        assertEq(jp._voidedOwed(), 0.1 ether, "reserve = ticketRevenue only, fee not double-booked");
        assertEq(jp.pendingRollover(), 0.01 ether, "fee rolled into next pool (intended design)");
        // 守恒：预留负债有足额现金背书（修复前 0.11 预留里有 0.01 是空账）
        assertGe(address(jp).balance, jp._voidedOwed(), "reserve fully cash-backed");

        // 3) alice 全额退款 0.1 ETH，预留精确清零（修复前残留 0.01 永远无法领走）
        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        vm.prank(alice);
        jp.refundTickets(rid, idx);
        assertEq(alice.balance, 1 ether, "full refund paid");
        assertEq(jp._voidedOwed(), 0, "reserve fully drained, no dead residue");
        assertEq(address(jp).balance, 0, "all cash refunded");

        // 4) 滚存的 fee 被下一轮吸收为奖池（有意设计保留）
        jp.startRound();
        assertEq(jp.getRound(2).prizePool, 0.01 ether, "fee rolls to next pool by design");
    }

    /// @notice 对照组：无购票的轮次作废不产生任何预留与滚存
    function test_VoidEmptyRoundClean() public {
        uint256 rid = jp.currentRoundId();
        vm.prank(admin);
        jp.voidRound(rid);
        assertEq(jp._voidedOwed(), 0);
        assertEq(jp.pendingRollover(), 0);
        assertEq(address(jp).balance, 0);
        jp.startRound();
        assertEq(jp.getRound(2).prizePool, 0);
    }
}
