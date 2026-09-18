// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {JackpotHood} from "../src/JackpotHood.sol";

/// @title 批量购票边界：1..1000 组永不因数组长度 revert，1001 组必须 revert
contract BatchBoundsTest is Test {
    JackpotHood public jp;
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 public constant PRICE = 0.001 ether;

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.prank(admin);
        jp = new JackpotHood(24 hours, 15 minutes, true);
    }

    function _batch(uint256 n) internal pure returns (uint8[6][] memory list, uint64[] memory counts) {
        list = new uint8[6][](n);
        counts = new uint64[](n);
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < 6; j++) list[i][j] = uint8((i + j) % 10);
            counts[i] = 1;
        }
    }

    /// @dev 任意 1..1000 组批量购票成功（fuzz 长度；1000 组实测 ~45.5M gas，本地 EVM 可通过）
    function testFuzz_BuyBatchAnyLengthUpTo1000(uint256 n) public {
        n = bound(n, 1, 1000);
        (uint8[6][] memory list, uint64[] memory counts) = _batch(n);
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        jp.buyTickets{value: PRICE * n}(list, counts);
        assertEq(jp.getRound(1).totalTickets, n);
    }

    function test_BuyBatch1001Reverts() public {
        (uint8[6][] memory list, uint64[] memory counts) = _batch(1001);
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert("JPH: batch too large");
        jp.buyTickets{value: PRICE * 1001}(list, counts);
    }

    function test_BuyBatchEmptyReverts() public {
        (uint8[6][] memory list, uint64[] memory counts) = _batch(0);
        vm.prank(alice);
        vm.expectRevert("JPH: bad batch");
        jp.buyTickets{value: 0}(list, counts);
    }

    function test_BuyBatchLengthMismatchReverts() public {
        (uint8[6][] memory list, uint64[] memory counts) = _batch(3);
        uint64[] memory short = new uint64[](2);
        short[0] = 1;
        short[1] = 1;
        counts;
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert("JPH: bad batch");
        jp.buyTickets{value: PRICE * 2}(list, short);
    }

    function test_BuyBatchCountBounds() public {
        (uint8[6][] memory list, uint64[] memory counts) = _batch(2);
        vm.deal(alice, 100 ether);
        // count = 0 → revert
        counts[1] = 0;
        vm.prank(alice);
        vm.expectRevert("JPH: bad count");
        jp.buyTickets{value: PRICE}(list, counts);
        // count = 1001 → revert
        counts[1] = 1001;
        vm.prank(alice);
        vm.expectRevert("JPH: bad count");
        jp.buyTickets{value: PRICE * (1 + 1001)}(list, counts);
        // count = 1000（上限）→ 成功
        counts[1] = 1000;
        vm.prank(alice);
        jp.buyTickets{value: PRICE * 1001}(list, counts);
        assertEq(jp.getRound(1).totalTickets, 1001);
    }

    /// @dev 数字位 >9 必须整批 revert
    function test_BuyBatchBadDigitReverts() public {
        (uint8[6][] memory list, uint64[] memory counts) = _batch(2);
        list[1][5] = 10;
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert("JPH: bad digit");
        jp.buyTickets{value: PRICE * 2}(list, counts);
    }

    /// @dev 批量赠票同口径（共用 _validateBatch）
    function test_GiftBatchOk() public {
        (uint8[6][] memory list, uint64[] memory counts) = _batch(3);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        jp.giftTickets{value: PRICE * 3}(bob, list, counts);
        assertEq(jp.getUserTickets(1, bob).length, 3, "recipient owns the tickets");
    }
}
