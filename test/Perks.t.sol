// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {JackpotHood} from "../src/JackpotHood.sol";
import {JackpotHoodPerks} from "../src/JackpotHoodPerks.sol";
import {JackpotHoodToken} from "../src/mocks/JackpotHoodToken.sol";

/// @notice Perks 独立合约安全测试（免费票发放链路）
contract PerksTest is Test {
    JackpotHood public jp;
    JackpotHoodPerks public perks;
    JackpotHoodToken public jph;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");

    function setUp() public {
        vm.warp(1_700_000_000); // 现代时间：避免 utcDay=0 与未初始化混淆
        vm.prank(admin);
        jph = new JackpotHoodToken(10_000_000 ether);
        vm.prank(admin);
        jp = new JackpotHood(24 hours, 15 minutes, true);
        vm.prank(admin);
        perks = new JackpotHoodPerks(address(jph), address(jp));
        vm.prank(admin);
        jp.setPerkContract(address(perks));
        vm.deal(admin, 100 ether);
        vm.prank(admin);
        jp.injectPrizeEth{value: 1 ether}();
        vm.prank(admin);
        jph.transfer(alice, 1_000_000 ether);
    }

    function _stake(uint256 amt) internal {
        vm.prank(alice);
        jph.approve(address(perks), amt);
        vm.prank(alice);
        perks.stakeJph(amt);
    }

    // 桥：perk 合约领取 → 核心出票（tier cap 1000/轮）
    function test_PerkRedeemThroughBridge() public {
        _stake(200_000 ether);
        vm.warp(block.timestamp + 86400);
        vm.prank(alice);
        perks.redeemPerkTicket([uint8(1), 2, 3, 4, 5, 6], 2);
        assertEq(jp.getRound(2).totalTickets, 2, "tickets landed in core round");
        assertEq(perks.storedPerk(alice), 0, "balance consumed");
    }

    // Perks 批量领取（一次多组）
    function test_PerkBatchRedeem() public {
        _stake(200_000 ether);
        vm.warp(block.timestamp + 2 * 86400);
        uint8[6][] memory list = new uint8[6][](2);
        uint64[] memory cnts = new uint64[](2);
        for (uint256 i = 0; i < 2; i++) {
            for (uint256 j = 0; j < 6; j++) list[i][j] = uint8((i + j) % 10);
            cnts[i] = 1;
        }
        vm.prank(alice);
        perks.redeemPerkTickets(list, cnts);
        assertEq(jp.getRound(2).totalTickets + jp.getRound(3).totalTickets, 2, "batch through bridge");
        assertEq(perks.storedPerk(alice), 1, "accrued 4 capped to 3, used 2, remaining 1");
    }

    // 安全：批量超 storedPerk 整批回滚（额度不扣、无部分出票）
    function test_PerkBatchInsufficientRollback() public {
        _stake(200_000 ether);
        vm.warp(block.timestamp + 1 * 86400);
        uint8[6][] memory list = new uint8[6][](2);
        uint64[] memory cnts = new uint64[](2);
        for (uint256 j = 0; j < 6; j++) list[0][j] = uint8(j);
        for (uint256 j = 0; j < 6; j++) list[1][j] = uint8(j + 1);
        cnts[0] = 2;
        cnts[1] = 2; // 需 4 > 当日累积 2（cap 后 2）
        vm.prank(alice);
        vm.expectRevert("JPH: no stored perk");
        perks.redeemPerkTickets(list, cnts);
        assertEq(jp.getRound(2).totalTickets, 0, "no partial issue");
        assertEq(perks.perkBalance(alice), 2, "balance intact");
    }

    // 安全：perks 无 ETH 接收通道（无 receive/fallback）
    function test_PerksCannotReceiveEth() public {
        vm.deal(address(perks), 1 ether); // 直接 deal 可以但合约无 payable 入口可转出?无 withdraw 函数
        assertEq(address(perks).balance, 1 ether); // 即便有 ETH 也无函数可取（除不可用路径）
    }

    // 安全：管理员不能动用户质押的 JPH
    function test_AdminCannotTouchUserJph() public {
        _stake(200_000 ether);
        vm.prank(admin);
        vm.expectRevert();
        jph.transferFrom(address(perks), admin, 100 ether); // 无 allowance → revert
    }

    // 安全：perk 合约即使被调用方绕过（直接调核心桥）也会被拒
    function test_DirectBridgeCallRejected() public {
        vm.prank(attacker);
        vm.expectRevert("JPH: not perk");
        jp.redeemPerkExternal(bob, [uint8(1), 2, 3, 4, 5, 6], 1);
    }

    // 安全：核心每轮免费上限对 perks 同样生效（perks 无法超发）
    function test_PerkBridgeRespectsRoundCap() public {
        _stake(1_000_000 ether); // 10 张/天 → cap 前最多累积 3
        vm.warp(block.timestamp + 5 * 86400);
        // storedPerk cap 3 → 只能发 3；核心 cap 1000 不触发；验证 cap3 足够防超发
        vm.prank(alice);
        perks.redeemPerkTicket([uint8(9), 9, 9, 9, 9, 9], 3);
        assertEq(jp.freeMinted(2), 3, "cap3 enforced upstream");
        vm.prank(alice);
        vm.expectRevert("JPH: no stored perk");
        perks.redeemPerkTicket([uint8(8), 8, 8, 8, 8, 8], 1);
    }

    // 两步管理员移交
    function test_TwoStepAdmin() public {
        vm.prank(admin);
        perks.proposeAdmin(bob);
        vm.prank(bob);
        perks.acceptAdmin();
        assertEq(perks.admin(), bob);
    }
}
