// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {JackpotHood} from "../src/JackpotHood.sol";

/// @title 免费票：超额领取整批回滚且额度不扣；每轮 1000 注上限触发时同样原子回滚
contract FreeTicketAtomicityTest is Test {
    JackpotHood public jp;
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.prank(admin);
        jp = new JackpotHood(24 hours, 15 minutes, true);
    }

    /// @dev 单笔领取超过额度：revert，且 freeCredits 不扣、不出票、freeMinted 不变
    function testFuzz_RedeemOverCreditsRollsBack(uint64 grant, uint64 over) public {
        grant = uint64(bound(grant, 1, 999));
        over = uint64(bound(over, 1, 1000 - grant)); // 保持单笔 ≤ MAX_UNITS_PER_BUY
        vm.prank(admin);
        jp.grantFreeCredits(alice, grant);

        vm.prank(alice);
        vm.expectRevert("JPH: no free credits");
        jp.redeemFreeTicket([uint8(1), 2, 3, 4, 5, 6], grant + over);

        assertEq(jp.freeCredits(alice), grant, "credits must be untouched");
        assertEq(jp.freeMinted(1), 0, "no free ticket minted");
        assertEq(jp.getUserTickets(1, alice).length, 0, "no ticket recorded");
    }

    /// @dev 批量领取总注数超过额度：整批回滚（不允许部分出票）
    function test_RedeemBatchOverCreditsRollsBack() public {
        vm.prank(admin);
        jp.grantFreeCredits(alice, 10);

        uint8[6][] memory list = new uint8[6][](3);
        uint64[] memory counts = new uint64[](3);
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = 0; j < 6; j++) list[i][j] = uint8(j);
            counts[i] = 4; // 共 12 注 > 10 额度
        }
        vm.prank(alice);
        vm.expectRevert("JPH: no free credits");
        jp.redeemFreeTickets(list, counts);

        assertEq(jp.freeCredits(alice), 10, "credits must be untouched");
        assertEq(jp.freeMinted(1), 0);
        assertEq(jp.getUserTickets(1, alice).length, 0, "partial batch must not exist");
    }

    /// @dev 恰好用满每轮 1000 注免费上限后，再领 1 注触发 "free cap"：
    ///      额度扣减必须随整笔 tx 回滚（redeemFreeTicket 先扣额度后出票）
    function test_FreeCapRevertKeepsCredits() public {
        vm.prank(admin);
        jp.grantFreeCredits(alice, 1000);
        vm.prank(alice);
        jp.redeemFreeTicket([uint8(1), 2, 3, 4, 5, 6], 1000); // 用满上限
        assertEq(jp.freeMinted(1), 1000);
        assertEq(jp.freeCredits(alice), 0);

        vm.prank(admin);
        jp.grantFreeCredits(alice, 10);
        vm.prank(alice);
        vm.expectRevert("JPH: free cap");
        jp.redeemFreeTicket([uint8(1), 2, 3, 4, 5, 6], 1);

        assertEq(jp.freeCredits(alice), 10, "credit deduction must roll back with the tx");
        assertEq(jp.freeMinted(1), 1000, "cap unchanged");
    }

    /// @dev 批量领取正好顶到上限成功；超上限 1 注整批复回滚且额度保留
    function test_RedeemBatchAtCapBoundary() public {
        vm.prank(admin);
        jp.grantFreeCredits(alice, 1000);
        uint8[6][] memory list = new uint8[6][](2);
        uint64[] memory counts = new uint64[](2);
        for (uint256 j = 0; j < 6; j++) {
            list[0][j] = uint8(j);
            list[1][j] = uint8(9 - j);
        }
        counts[0] = 500;
        counts[1] = 500; // 恰好 1000
        vm.prank(alice);
        jp.redeemFreeTickets(list, counts);
        assertEq(jp.freeMinted(1), 1000);

        // 再次批量 1 注 → 超 cap，整批回滚
        vm.prank(admin);
        jp.grantFreeCredits(alice, 5);
        uint8[6][] memory one = new uint8[6][](1);
        uint64[] memory c = new uint64[](1);
        c[0] = 1;
        vm.prank(alice);
        vm.expectRevert("JPH: free cap");
        jp.redeemFreeTickets(one, c);
        assertEq(jp.freeCredits(alice), 5, "batch revert must keep credits");
        assertEq(jp.freeMinted(1), 1000);
    }

    /// @dev F1：非法数字（>9）免费票三条无付款校验的入口全部 revert（校验已下沉到 _record）。
    ///      修复前此类票 _comboOf ≥ 1e6 落在 units 统计之外但 _tierOf 仍可判中 → 同档重复兑付。
    function test_FreeTicketBadDigitReverts() public {
        uint8[6] memory bad = [uint8(1), 2, 3, 4, 5, 10]; // 末位 10 > MAX_DIGIT
        // 1) 管理员直发
        vm.prank(admin);
        vm.expectRevert("JPH: bad number");
        jp.freeTicket(alice, bad, 1);
        // 2) 免费额度领取（整笔回滚，额度不扣）
        vm.prank(admin);
        jp.grantFreeCredits(alice, 10);
        vm.prank(alice);
        vm.expectRevert("JPH: bad number");
        jp.redeemFreeTicket(bad, 1);
        assertEq(jp.freeCredits(alice), 10, "credits untouched on bad digit");
        // 3) Perks 桥代发
        address fakePerk = makeAddr("fakePerk");
        vm.prank(admin);
        jp.setPerkContract(fakePerk);
        vm.prank(fakePerk);
        vm.expectRevert("JPH: bad number");
        jp.redeemPerkExternal(alice, bad, 1);

        assertEq(jp.freeMinted(1), 0, "no free ticket minted");
        assertEq(jp.getUserTickets(1, alice).length, 0, "no ticket recorded");
    }

    /// @dev F1：免费路径注数校验——count = 0 与 count > MAX_UNITS_PER_BUY 同样 revert
    function test_FreeTicketBadCountReverts() public {
        uint8[6] memory ok = [uint8(1), 2, 3, 4, 5, 6];
        // 管理员直发
        vm.prank(admin);
        vm.expectRevert("JPH: bad count");
        jp.freeTicket(alice, ok, 0);
        vm.prank(admin);
        vm.expectRevert("JPH: bad count");
        jp.freeTicket(alice, ok, 1001);
        // 额度领取（额度不扣）
        vm.prank(admin);
        jp.grantFreeCredits(alice, 2000);
        vm.prank(alice);
        vm.expectRevert("JPH: bad count");
        jp.redeemFreeTicket(ok, 0);
        vm.prank(alice);
        vm.expectRevert("JPH: bad count");
        jp.redeemFreeTicket(ok, 1001);
        assertEq(jp.freeCredits(alice), 2000, "credits untouched on bad count");
        // Perks 桥代发
        address fakePerk = makeAddr("fakePerk");
        vm.prank(admin);
        jp.setPerkContract(fakePerk);
        vm.prank(fakePerk);
        vm.expectRevert("JPH: bad count");
        jp.redeemPerkExternal(alice, ok, 0);

        assertEq(jp.freeMinted(1), 0);
    }
}
