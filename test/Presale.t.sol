// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {JackpotHood} from "../src/JackpotHood.sol";
import {JackpotHoodPerks} from "../src/JackpotHoodPerks.sol";
import {JackpotHoodToken} from "../src/mocks/JackpotHoodToken.sol";
import {PerkRouter} from "../src/presale/PerkRouter.sol";
import {JackpotHoodPresale} from "../src/presale/JackpotHoodPresale.sol";
import {GenesisNFT2} from "../src/presale/GenesisNFT2.sol";

/// @notice 社区轮预售测试：PerkRouter + JackpotHoodPresale + GenesisNFT2 + 真 core 全链路
contract PresaleTest is Test {
    JackpotHood public core;
    JackpotHoodToken public jph;
    PerkRouter public router;
    JackpotHoodPresale public presale;
    GenesisNFT2 public nft;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address attacker = makeAddr("attacker");
    address liquidity = makeAddr("liquidity");
    address treasury = makeAddr("treasury");
    address marketing = makeAddr("marketing");

    uint64 public START;
    uint64 public constant DURATION = 3 days;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint8[6] NUMS = [1, 2, 3, 4, 5, 6];

    function setUp() public {
        vm.warp(1_700_000_000); // 现代时间
        START = uint64(block.timestamp);
        vm.startPrank(admin);
        jph = new JackpotHoodToken(10_000_000 ether);
        core = new JackpotHood(24 hours, 15 minutes, true);
        router = new PerkRouter(address(core));
        presale = new JackpotHoodPresale(
            address(jph), address(router), START, DURATION, liquidity, treasury, marketing, address(core)
        );
        nft = new GenesisNFT2(address(presale));
        core.setPerkContract(address(router)); // router 占据 perkContract 单槽
        router.setAllowed(address(presale), true);
        jph.transfer(address(presale), 2_000_000 ether); // 预售派发池
        vm.stopPrank();
    }

    function _buy(address user, uint64 n, address ref, uint256 value) internal {
        vm.deal(user, value);
        vm.prank(user);
        presale.buy{value: value}(n, ref);
    }

    // ---------------------------------------------------------------
    // 1. 阶梯价
    // ---------------------------------------------------------------

    function test_PriceOfTierBoundaries() public {
        assertEq(presale.priceOf(1), 0.0008 ether, "tier1 single");
        assertEq(presale.priceOf(20_000), 16 ether, "tier1 full");
        assertEq(presale.priceOf(20_001), 16 ether + 0.0009 ether, "tier2 first ticket");
        assertEq(presale.priceOf(50_000), 16 ether + 27 ether, "tier1+tier2 full");
        assertEq(presale.priceOf(50_001), 43 ether + 0.001 ether, "tier3 first ticket");
        assertEq(presale.priceOf(100_000), 93 ether, "whole cap");
    }

    function test_PriceOfCrossTierFrom19999() public {
        _buy(alice, 19_999, address(0), 15.9992 ether);
        assertEq(presale.sold(), 19_999);
        // 19,999 → 20,001 买 2 张 = 0.0008 + 0.0009
        assertEq(presale.priceOf(2), 0.0008 ether + 0.0009 ether, "cross-tier pair");
        _buy(alice, 2, address(0), 0.0017 ether);
        assertEq(presale.sold(), 20_001);
    }

    // ---------------------------------------------------------------
    // 2. 正常认购记账
    // ---------------------------------------------------------------

    function test_BuyNormalAccounting() public {
        _buy(alice, 10, bob, 0.008 ether);
        assertEq(presale.sold(), 10);
        assertEq(presale.credits(alice), 10, "credits");
        assertEq(presale.purchased(alice), 10, "purchased");
        assertEq(jph.balanceOf(alice), 100 ether, "10 JPH per ticket");
        assertEq(jph.balanceOf(bob), 5 ether, "0.5 JPH per ticket to referrer");
        assertEq(address(presale).balance, 0.008 ether);
    }

    // ---------------------------------------------------------------
    // 3. 金额/售罄/时间 revert
    // ---------------------------------------------------------------

    function test_BuyWrongPaymentReverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert("Presale: wrong ETH amount");
        presale.buy{value: 0.009 ether}(10, address(0)); // 超付
        vm.prank(alice);
        vm.expectRevert("Presale: wrong ETH amount");
        presale.buy{value: 0.007 ether}(10, address(0)); // 少付
    }

    function test_BuyZeroQtyReverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert("Presale: zero qty");
        presale.buy{value: 0}(0, address(0));
    }

    function test_BuySoldOutReverts() public {
        _buy(alice, 100_000, address(0), 93 ether);
        assertEq(presale.sold(), 100_000);
        assertTrue(presale.isOpen(), "sold out => redeem/finalize phase");
        vm.deal(bob, 0.001 ether);
        vm.prank(bob);
        vm.expectRevert("Presale: sold out");
        presale.buy{value: 0.001 ether}(1, address(0));
    }

    function test_BuyNotStartedReverts() public {
        vm.prank(admin);
        JackpotHoodPresale future = new JackpotHoodPresale(
            address(jph), address(router), uint64(block.timestamp + 100), DURATION,
            liquidity, treasury, marketing, address(core)
        );
        vm.deal(alice, 0.001 ether);
        vm.prank(alice);
        vm.expectRevert("Presale: not started");
        future.buy{value: 0.0008 ether}(1, address(0));
    }

    function test_BuyEndedReverts() public {
        vm.warp(START + DURATION); // == endTime → 已结束
        assertTrue(presale.isOpen());
        vm.deal(alice, 0.001 ether);
        vm.prank(alice);
        vm.expectRevert("Presale: ended");
        presale.buy{value: 0.0008 ether}(1, address(0));
    }

    // ---------------------------------------------------------------
    // 4. CAP 截断
    // ---------------------------------------------------------------

    function test_BuyClampedAtCap() public {
        _buy(alice, 99_999, address(0), 92.999 ether);
        assertEq(presale.sold(), 99_999);
        // 买 10 张只剩 1 张：只收 1 张的钱
        _buy(bob, 10, address(0), 0.001 ether);
        assertEq(presale.sold(), 100_000);
        assertEq(presale.credits(bob), 1);
        assertEq(presale.purchased(bob), 1);
        assertEq(jph.balanceOf(bob), 10 ether, "JPH for the 1 clamped ticket");
    }

    // ---------------------------------------------------------------
    // 5. 推荐人边界
    // ---------------------------------------------------------------

    function test_ReferrerSelfGetsNothing() public {
        _buy(alice, 10, alice, 0.008 ether);
        assertEq(jph.balanceOf(alice), 100 ether, "no self referral bonus");
    }

    function test_ReferrerZeroGetsNothing() public {
        _buy(alice, 10, address(0), 0.008 ether);
        assertEq(jph.balanceOf(alice), 100 ether);
        assertEq(jph.balanceOf(address(presale)), 2_000_000 ether - 100 ether, "pool only pays buyer");
    }

    // ---------------------------------------------------------------
    // 6. GenesisNFT2
    // ---------------------------------------------------------------

    function test_NftClaimThresholdAndOnce() public {
        _buy(alice, 499, address(0), 0.3992 ether);
        vm.prank(alice);
        vm.expectRevert("JHG: below threshold");
        nft.claim();

        _buy(alice, 1, address(0), 0.0008 ether); // 累计 500
        vm.prank(alice);
        uint256 tokenId = nft.claim();
        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.balanceOf(alice), 1);
        assertEq(nft.totalSupply(), 1);

        vm.prank(alice);
        vm.expectRevert("JHG: already minted");
        nft.claim();
    }

    function test_NftAdminAirdrop() public {
        address[] memory to = new address[](2);
        to[0] = bob;
        to[1] = carol;
        vm.prank(admin);
        nft.adminAirdrop(to);
        assertEq(nft.ownerOf(1), bob);
        assertEq(nft.ownerOf(2), carol);
        assertEq(nft.totalSupply(), 2);

        vm.prank(attacker);
        vm.expectRevert("JHG: not admin");
        nft.adminAirdrop(to);

        to[0] = bob; // 已铸造过 → 空投也受每钱包 1 个约束
        to[1] = alice;
        vm.prank(admin);
        vm.expectRevert("JHG: already minted");
        nft.adminAirdrop(to);
    }

    // ---------------------------------------------------------------
    // 7. 兑换免费票（经 router → core）
    // ---------------------------------------------------------------

    function test_RedeemBeforeOpenReverts() public {
        _buy(alice, 5, address(0), 0.004 ether);
        vm.prank(alice);
        vm.expectRevert("Presale: not open");
        presale.redeem(NUMS, 1);
    }

    function test_RedeemAfterEndIssuesTickets() public {
        _buy(alice, 5, address(0), 0.004 ether);
        vm.warp(START + DURATION);
        vm.prank(alice);
        presale.redeem(NUMS, 3);
        assertEq(presale.credits(alice), 2, "credits consumed");

        uint256 rid = core.currentRoundId();
        JackpotHood.Ticket[] memory t = core.getUserTickets(rid, alice);
        assertEq(t.length, 1, "one ticket entry in core");
        assertEq(t[0].count, 3);
        assertEq(core.freeMinted(rid), 3, "free mint counter");

        vm.prank(alice);
        vm.expectRevert("Presale: insufficient credits");
        presale.redeem(NUMS, 3); // 只剩 2
    }

    function test_RedeemBatch() public {
        _buy(alice, 10, address(0), 0.008 ether);
        vm.warp(START + DURATION);
        uint8[6][] memory list = new uint8[6][](2);
        uint64[] memory cnts = new uint64[](2);
        list[0] = NUMS;
        list[1] = [uint8(9), 8, 7, 6, 5, 4];
        cnts[0] = 2;
        cnts[1] = 3;
        vm.prank(alice);
        presale.redeemBatch(list, cnts);
        assertEq(presale.credits(alice), 5);

        uint256 rid = core.currentRoundId();
        // 认购期 3 天 > core 轮周期 24h：到期时当前轮早已过停售点，批量每组顺延一轮出票
        assertEq(core.getUserTickets(rid - 1, alice).length + core.getUserTickets(rid, alice).length, 2);
        assertEq(core.freeMinted(rid - 1) + core.freeMinted(rid), 5);
    }

    function test_RedeemBatchValidation() public {
        _buy(alice, 3, address(0), 0.0024 ether);
        vm.warp(START + DURATION);

        uint8[6][] memory list = new uint8[6][](2);
        uint64[] memory cnts = new uint64[](3); // 长度不等
        vm.prank(alice);
        vm.expectRevert("Presale: bad batch");
        presale.redeemBatch(list, cnts);

        uint8[6][] memory big = new uint8[6][](101);
        uint64[] memory bigCnts = new uint64[](101);
        vm.prank(alice);
        vm.expectRevert("Presale: batch too large");
        presale.redeemBatch(big, bigCnts);

        uint8[6][] memory one = new uint8[6][](1);
        uint64[] memory c1 = new uint64[](1);
        one[0] = NUMS;
        c1[0] = 4; // 超过 credits=3
        vm.prank(alice);
        vm.expectRevert("Presale: insufficient credits");
        presale.redeemBatch(one, c1);
    }

    // ---------------------------------------------------------------
    // 8. finalize 分账
    // ---------------------------------------------------------------

    function test_FinalizeSplitsExactly() public {
        _buy(alice, 10, bob, 0.008 ether);
        vm.warp(START + DURATION);
        vm.deal(address(presale), 10 ether); // 精确控制余额（含 receive() 直接转入的情形）

        uint256 stakedBefore = core.totalEthStaked();
        vm.prank(bob); // 任何人可触发
        presale.finalize();

        assertEq(core.totalEthStaked(), stakedBefore + 6 ether, "60% staked into core");
        assertEq(core.ethStaked(address(presale)), 6 ether, "stake recorded under presale");
        assertEq(liquidity.balance, 2 ether, "20%");
        assertEq(treasury.balance, 1 ether, "10%");
        assertEq(marketing.balance, 1 ether, "10%");
        assertEq(address(presale).balance, 0, "fully drained");
    }

    function test_FinalizeTwiceReverts() public {
        vm.warp(START + DURATION);
        vm.deal(address(presale), 1 ether);
        presale.finalize();
        vm.expectRevert("Presale: already finalized");
        presale.finalize();
    }

    function test_FinalizeBeforeOpenReverts() public {
        vm.expectRevert("Presale: not open");
        presale.finalize();
    }

    // ---------------------------------------------------------------
    // 9. burnUnsold
    // ---------------------------------------------------------------

    function test_BurnUnsold() public {
        _buy(alice, 10, bob, 0.008 ether); // 派出 105 JPH（买家 100 + 推荐 5）
        vm.warp(START + DURATION);
        vm.deal(address(presale), 1 ether);
        presale.finalize();

        uint256 deadBefore = jph.balanceOf(DEAD);
        uint256 pool = jph.balanceOf(address(presale));
        assertEq(pool, 2_000_000 ether - 105 ether);
        presale.burnUnsold();
        assertEq(jph.balanceOf(address(presale)), 0, "pool emptied");
        assertEq(jph.balanceOf(DEAD), deadBefore + pool, "burned to dead address");
    }

    function test_BurnBeforeFinalizeReverts() public {
        vm.expectRevert("Presale: not finalized");
        presale.burnUnsold();
    }

    // ---------------------------------------------------------------
    // 10. PerkRouter 白名单 + Perks 旧路径经 router 转发
    // ---------------------------------------------------------------

    function test_RouterRejectsUnknownCaller() public {
        vm.prank(attacker);
        vm.expectRevert("Router: not allowed");
        router.redeemPerkExternal(attacker, NUMS, 1);
    }

    function test_RouterSetAllowedOnlyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert("Router: not admin");
        router.setAllowed(attacker, true);
    }

    function test_RouterTwoStepAdmin() public {
        vm.prank(admin);
        router.proposeAdmin(bob);
        vm.prank(bob);
        router.acceptAdmin();
        assertEq(router.admin(), bob);
    }

    function test_PerksViaRouterStillWorks() public {
        vm.startPrank(admin);
        JackpotHoodPerks perks = new JackpotHoodPerks(address(jph), address(router));
        router.setAllowed(address(perks), true);
        jph.transfer(alice, 300_000 ether);
        vm.stopPrank();

        vm.prank(alice);
        jph.approve(address(perks), 200_000 ether);
        vm.prank(alice);
        perks.stakeJph(200_000 ether); // 2 张/天
        vm.warp(block.timestamp + 86400);

        vm.prank(alice);
        perks.redeemPerkTicket(NUMS, 2); // Perks → router → core
        uint256 rid = core.currentRoundId();
        JackpotHood.Ticket[] memory t = core.getUserTickets(rid, alice);
        assertEq(t.length, 1, "ticket landed via router");
        assertEq(t[0].count, 2);
        assertEq(core.freeMinted(rid), 2);
    }

    function test_NftTwoStepAdmin() public {
        vm.prank(admin);
        nft.proposeAdmin(bob);
        vm.prank(bob);
        nft.acceptAdmin();
        assertEq(nft.admin(), bob);
    }
}
