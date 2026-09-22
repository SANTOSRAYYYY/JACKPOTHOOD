// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {JackpotHood} from "../src/JackpotHood.sol";
import {JackpotHoodToken} from "../src/mocks/JackpotHoodToken.sol";
import {PerkRouter} from "../src/presale/PerkRouter.sol";
import {JackpotHoodPresale} from "../src/presale/JackpotHoodPresale.sol";
import {GenesisNFT2} from "../src/presale/GenesisNFT2.sol";
import {HoodVRF} from "../src/vrf/HoodVRF.sol";
import {HoodBLS} from "../src/vrf/HoodBLS.sol";
import {IVrfConsumer} from "../src/vrf/IVrfConsumer.sol";

/// @title Audit2026 —— 既有 144 项之外的攻击面补充
/// @notice 覆盖方向：
///  1) 预售：跨档精确价（19,999/49,999 持仓再买 3 张）、buy clamp 的 JPH/推荐附赠基数、
///     JPH 池部分耗尽→全耗尽购买、finalize 前 receive() 捐赠尘埃的逐 wei 分账、
///     小额轮 finalize 被 core MIN_STAKE 卡死及捐款自救、redeemBatch 混合号码整批原子性
///     （含超 core 每轮免费上限的批次）、NFT 第 1000/1001 个 claim、转让后再 claim。
///  2) HoodVRF：履约时间精确边界、重复 fulfill 不重复发补贴、47/49 字节坐标、
///     真合约上 (0,0)/(1,1)/x=p 坐标在配对前即 revert、feeBalance 有余额时免费请求仍无补贴、
///     paid 标志快照不受事后 setFee 影响、EOA consumer 跳过回调（vm.etch 两态）、
///     拒收补贴的履约方、拒收 ETH 的 admin 提现、requestFor 退款只退付款人。
///  3) core V4.4：两用户交错 requestUnstake/finalizeUnstake（不同轮、逆序领取）、
///     挂单期间领奖/追加质押、拒收推荐人的 5% 份额回流质押者、拒收推荐人导致中奖 claim
///     硬 revert（与购票侧兜底设计相反，锁定现状）、void 轮使挂单成熟、Committed 轮登记当轮、
///     重复下标 claim 原子回滚、兑奖窗口精确边界与 sweep 守卫、封顶档在极小/极大池的
///     逐 wei 边界、void+已立付推荐的退款守恒、承诺块过窗重承诺路径、无开放轮注资进
///     pendingRollover、拒收 ETH 质押者的退出资金锁死现状、停售点前后 _pickRound 选轮。

// ---------------------------------------------------------------------
// 共用桩
// ---------------------------------------------------------------------

/// @dev core 测试壳：用已知种子直接结算（与 JackpotHood.t.sol 的 TestHarness 同手法）
contract Audit2026CoreHarness is JackpotHood {
    constructor(uint256 roundDuration_, uint64 lockWindow_, bool anchorFirstUtc_)
        JackpotHood(roundDuration_, lockWindow_, anchorFirstUtc_)
    {}

    function settleWithSeed(uint256 roundId, bytes32 seed) external {
        _settle(roundId, seed);
    }
}

/// @dev VRF 测试壳：验签 mock（本地 anvil 无 EIP-2537 预编译）
contract Audit2026VRFHarness is HoodVRF {
    bool public mockOk = true;
    bytes32 public mockRnd = bytes32(uint256(0xbeef));

    constructor(bytes memory pk, uint256 f, uint256 r) HoodVRF(pk, f, r) {}

    function _verifyAndDerive(uint64, bytes calldata, bytes calldata) internal view override returns (bytes32) {
        if (!mockOk) revert HoodBLS.NotOnCurve();
        return mockRnd;
    }
}

/// @dev 标准 consumer：记录回调，可切换失败
contract Audit2026Consumer is IVrfConsumer {
    uint256 public lastId;
    bytes32 public lastRnd;
    uint256 public calls;
    bool public failing;

    function setFailing(bool f) external {
        failing = f;
    }

    function onRandom(uint256 id, bytes32 rnd) external {
        if (failing) revert("consumer fail");
        lastId = id;
        lastRnd = rnd;
        calls++;
    }

    receive() external payable {}
}

/// @dev 收钱必 revert 的合约（充当拒收推荐人/拒收质押者/拒收履约方/拒收 admin）
contract Audit2026Rejecter {
    receive() external payable {
        revert("no thanks");
    }

    function acceptAdmin(HoodVRF v) external {
        v.acceptAdmin();
    }

    function withdraw(HoodVRF v) external {
        v.withdrawFees();
    }

    function fulfill(HoodVRF v, uint256 id, bytes calldata x, bytes calldata y) external {
        v.fulfill(id, x, y);
    }

    function stake(JackpotHood jp) external payable {
        jp.stakeEth{value: msg.value}();
    }

    function requestUnstake(JackpotHood jp, uint256 amt) external {
        jp.requestUnstake(amt);
    }

    function finalizeUnstake(JackpotHood jp) external {
        jp.finalizeUnstake();
    }
}

// ---------------------------------------------------------------------
// 1. 预售攻击面
// ---------------------------------------------------------------------
contract Audit2026PresaleTest is Test {
    JackpotHood public core;
    JackpotHoodToken public jph;
    PerkRouter public router;
    JackpotHoodPresale public presale;
    GenesisNFT2 public nft;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address liquidity = makeAddr("liquidity");
    address treasury = makeAddr("treasury");
    address marketing = makeAddr("marketing");

    uint64 public START;
    uint64 public constant DURATION = 3 days;

    uint8[6] NUMS = [1, 2, 3, 4, 5, 6];

    function setUp() public {
        vm.warp(1_700_000_000);
        START = uint64(block.timestamp);
        vm.startPrank(admin);
        jph = new JackpotHoodToken(10_000_000 ether);
        core = new JackpotHood(24 hours, 15 minutes, true);
        router = new PerkRouter(address(core));
        presale = new JackpotHoodPresale(
            address(jph), address(router), START, DURATION, liquidity, treasury, marketing, address(core)
        );
        nft = new GenesisNFT2(address(presale));
        core.setPerkContract(address(router));
        router.setAllowed(address(presale), true);
        jph.transfer(address(presale), 2_000_000 ether);
        vm.stopPrank();
    }

    function _buy(address user, uint64 n, address ref, uint256 value) internal {
        vm.deal(user, value);
        vm.prank(user);
        presale.buy{value: value}(n, ref);
    }

    // 跨档组合实付精确到 wei：19,999 持仓再买 3 张 = 1×P1 + 2×P2；
    // 49,999 持仓再买 3 张 = 1×P2 + 2×P3；priceOf(0) = 0
    function test_PriceOfCrossTierExactWei() public {
        assertEq(presale.priceOf(0), 0, "zero qty free");
        _buy(alice, 19_999, address(0), 15.9992 ether);
        assertEq(presale.sold(), 19_999);
        // 3 张跨 1→2 档：0.0008 + 2×0.0009 = 0.0026 ether，多 1 wei 都 revert
        assertEq(presale.priceOf(3), 0.0026 ether, "19999+3 = 1xP1 + 2xP2");
        vm.deal(bob, 0.0026 ether + 1);
        vm.prank(bob);
        vm.expectRevert("Presale: wrong ETH amount");
        presale.buy{value: 0.0026 ether + 1}(3, address(0));
        _buy(bob, 3, address(0), 0.0026 ether);
        assertEq(presale.sold(), 20_002);
        assertEq(presale.credits(bob), 3);
        assertEq(jph.balanceOf(bob), 30 ether, "3x10 JPH");

        // 把 sold 推到 49,999（29,997 张全在 2 档：29,997 × 0.0009 = 26.9973 ether）
        _buy(carol, 29_997, address(0), 26.9973 ether);
        assertEq(presale.sold(), 49_999);
        // 3 张跨 2→3 档：0.0009 + 2×0.001 = 0.0029 ether
        assertEq(presale.priceOf(3), 0.0029 ether, "49999+3 = 1xP2 + 2xP3");
        _buy(carol, 3, address(0), 0.0029 ether);
        assertEq(presale.sold(), 50_002);
        // 50,002 起单张即 3 档价
        assertEq(presale.priceOf(1), 0.001 ether, "tier3 single");
    }

    // clamp 时 JPH 附赠与推荐奖都按「截断后张数」计（锁定合约现状：n 先 clamp 再乘单价/附赠）
    function test_BuyClampBonusUsesClampedQty() public {
        _buy(alice, 99_999, address(0), 92.999 ether);
        assertEq(presale.sold(), 99_999);
        // bob 想买 10 张只剩 1 张：附赠 10 JPH（非 100）、推荐人 0.5 JPH（非 5）
        vm.expectEmit(true, true, false, true, address(presale));
        emit JackpotHoodPresale.PresaleBuy(bob, 1, 0.001 ether, carol);
        _buy(bob, 10, carol, 0.001 ether);
        assertEq(presale.sold(), 100_000);
        assertEq(presale.credits(bob), 1, "credits by clamped qty");
        assertEq(presale.purchased(bob), 1, "purchased by clamped qty");
        assertEq(jph.balanceOf(bob), 10 ether, "buyer bonus = 10 JPH x 1 clamped ticket");
        assertEq(jph.balanceOf(carol), 0.5 ether, "ref bonus = 0.5 JPH x 1 clamped ticket");
        assertTrue(presale.isOpen(), "sold out => redeem/finalize phase");
    }

    // JPH 池部分耗尽（min 截断附赠）→ 全耗尽（0 附赠）购买全程成功、认购记账不受影晌
    function test_BuyJphPoolPartialThenExhausted() public {
        vm.startPrank(admin);
        JackpotHoodPresale p2 = new JackpotHoodPresale(
            address(jph), address(router), uint64(block.timestamp), DURATION,
            liquidity, treasury, marketing, address(core)
        );
        jph.transfer(address(p2), 12 ether); // 只够 1 份买家附赠 + 1 份推荐奖 + 零头
        vm.stopPrank();

        // 第 1 单：买家 10 JPH 足额（池 12→2），推荐人 0.5 足额（2→1.5）
        vm.deal(alice, 0.0008 ether);
        vm.prank(alice);
        p2.buy{value: 0.0008 ether}(1, bob);
        assertEq(jph.balanceOf(alice), 10 ether, "full buyer bonus");
        assertEq(jph.balanceOf(bob), 0.5 ether, "full ref bonus");
        assertEq(jph.balanceOf(address(p2)), 1.5 ether, "pool leftover");

        // 第 2 单：买家附赠被 min 截断为 1.5（池清零），推荐人 0
        vm.deal(carol, 0.0008 ether);
        vm.prank(carol);
        p2.buy{value: 0.0008 ether}(1, bob);
        assertEq(jph.balanceOf(carol), 1.5 ether, "partial buyer bonus = pool dust");
        assertEq(jph.balanceOf(bob), 0.5 ether, "no more ref bonus");
        assertEq(jph.balanceOf(address(p2)), 0, "pool drained");

        // 第 3 单：池已空 → 0 附赠，购买仍成功，credits/sold/ETH 照常入账
        vm.deal(dave, 0.0008 ether);
        vm.prank(dave);
        p2.buy{value: 0.0008 ether}(1, address(0));
        assertEq(jph.balanceOf(dave), 0, "zero bonus on empty pool");
        assertEq(p2.sold(), 3);
        assertEq(p2.credits(dave), 1);
        assertEq(address(p2).balance, 0.0024 ether, "ETH collected regardless of JPH pool");
    }

    // finalize 前 receive() 捐赠 7 wei 尘埃：整除余量精确并入 marketing，逐 wei 锁定
    function test_FinalizeDustDonationExactSplitWei() public {
        _buy(alice, 25, address(0), 0.02 ether);
        vm.warp(START + DURATION);
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        (bool ok,) = address(presale).call{value: 7}(""); // receive() 捐赠 7 wei
        assertTrue(ok, "donation accepted");
        uint256 bal = 0.02 ether + 7; // 20000000000000007 wei
        assertEq(address(presale).balance, bal);

        uint256 s60 = bal * 60 / 100; // 12000000000000004
        uint256 l20 = bal * 20 / 100; // 4000000000000001
        uint256 t10 = bal * 10 / 100; // 2000000000000000
        uint256 m10 = bal - s60 - l20 - t10; // 2000000000000002（整除余量归 marketing）
        vm.expectEmit(false, false, false, true, address(presale));
        emit JackpotHoodPresale.Finalized(s60, l20, t10, m10);
        presale.finalize();

        assertEq(core.ethStaked(address(presale)), s60, "60% staked exact wei");
        assertEq(liquidity.balance, l20, "20% exact wei");
        assertEq(treasury.balance, t10, "10% exact wei");
        assertEq(marketing.balance, m10, "remainder incl. dust to marketing");
        assertEq(address(presale).balance, 0, "fully drained, no dust stuck");
    }

    // 余额 = 1 wei 的极端：s60/l20/t10 整除为 0 → 全部 1 wei 归 marketing，stake 被跳过
    function test_FinalizeOneWeiAllToMarketing() public {
        vm.warp(START + DURATION);
        vm.deal(address(presale), 1);
        vm.expectEmit(false, false, false, true, address(presale));
        emit JackpotHoodPresale.Finalized(0, 0, 0, 1);
        presale.finalize();
        assertEq(core.ethStaked(address(presale)), 0, "zero stake skipped");
        assertEq(liquidity.balance, 0);
        assertEq(treasury.balance, 0);
        assertEq(marketing.balance, 1, "single wei lands in marketing");
        assertEq(address(presale).balance, 0);
    }

    // 锁定现状（设计风险，见汇报）：销售额过小使 60% < core MIN_STAKE(0.01) 时，
    // finalize 被 core stakeEth 的 "JPH: below min stake" 卡死；任何人经 receive() 捐款补齐后可自救。
    function test_FinalizeMinStakeTrapAndDonationRescue() public {
        _buy(alice, 20, address(0), 0.016 ether); // bal=0.016 → s60=0.0096 < MIN_STAKE
        vm.warp(START + DURATION);
        vm.expectRevert("JPH: below min stake"); // core stakeEth 的 revert 冒泡
        presale.finalize();
        assertFalse(presale.finalized(), "finalize bricked by MIN_STAKE");

        // 自救：路人捐款 0.001 ether → bal=0.017 → s60=0.0102 ≥ MIN_STAKE → 分账成功
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        (bool ok,) = address(presale).call{value: 0.001 ether}("");
        assertTrue(ok);
        presale.finalize();
        assertEq(core.ethStaked(address(presale)), 0.0102 ether, "rescued stake exact");
        assertEq(liquidity.balance, 0.0034 ether);
        assertEq(treasury.balance, 0.0017 ether);
        assertEq(marketing.balance, 0.0017 ether);
        assertEq(address(presale).balance, 0);
    }

    // redeemBatch 混合号码整批原子性：批内一组使 core 单轮免费票超 1000 上限 → 整批回滚，
    // presale credits 分文不扣、各轮 freeMinted 全为 0
    function test_RedeemBatchFreeCapAtomicRollback() public {
        _buy(alice, 2000, address(0), 1.6 ether);
        vm.warp(START + DURATION);
        // 到期时（3 天 > 2 轮周期）：批内第 1/2 组各顺延进新轮，第 3/4 组落入同一新轮
        // → 该轮 freeMinted 600+600=1200 > 1000 触发 "JPH: free cap"
        uint8[6][] memory list = new uint8[6][](4);
        uint64[] memory cnts = new uint64[](4);
        list[0] = NUMS;
        list[1] = [uint8(9), 8, 7, 6, 5, 4];
        list[2] = [uint8(1), 1, 1, 1, 1, 1];
        list[3] = [uint8(2), 2, 2, 2, 2, 2];
        cnts[0] = 1;
        cnts[1] = 1;
        cnts[2] = 600;
        cnts[3] = 600; // 合计 1202 ≤ credits 2000，presale 侧校验通过，core 侧 cap 引爆
        vm.prank(alice);
        vm.expectRevert("JPH: free cap");
        presale.redeemBatch(list, cnts);

        assertEq(presale.credits(alice), 2000, "credits fully rolled back");
        uint256 rid = core.currentRoundId();
        for (uint256 id = 1; id <= rid; id++) {
            assertEq(core.freeMinted(id), 0, "no free ticket leaked from reverted batch");
        }
        assertEq(core.getUserTickets(rid, alice).length, 0, "no ticket recorded");
    }

    // count=0 的两条路径：单笔 "Presale: zero count"、批内 "Presale: bad count"，额度不动
    function test_RedeemZeroCountReverts() public {
        _buy(alice, 2, address(0), 0.0016 ether);
        vm.warp(START + DURATION);
        vm.prank(alice);
        vm.expectRevert("Presale: zero count");
        presale.redeem(NUMS, 0);

        uint8[6][] memory list = new uint8[6][](1);
        uint64[] memory cnts = new uint64[](1);
        list[0] = NUMS;
        cnts[0] = 0;
        vm.prank(alice);
        vm.expectRevert("Presale: bad count");
        presale.redeemBatch(list, cnts);
        assertEq(presale.credits(alice), 2, "credits untouched");
    }

    // NFT 第 1000 个 claim 成功、第 1001 个 "JHG: sold out"（先空投 999 个再真实 claim 到顶）
    function test_NftClaimToken1000And1001() public {
        for (uint256 b; b < 3; b++) {
            address[] memory to = new address[](333);
            for (uint256 i; i < 333; i++) to[i] = address(uint160(10_000 + b * 333 + i));
            vm.prank(admin);
            nft.adminAirdrop(to);
        }
        assertEq(nft.totalSupply(), 999);

        _buy(alice, 500, address(0), 0.4 ether);
        _buy(bob, 500, address(0), 0.4 ether);
        vm.prank(alice);
        uint256 tokenId = nft.claim(); // 第 1000 个
        assertEq(tokenId, 1000);
        assertEq(nft.ownerOf(1000), alice);
        assertEq(nft.totalSupply(), 1000);

        vm.prank(bob);
        vm.expectRevert("JHG: sold out"); // 第 1001 个：达标也领不到
        nft.claim();
        assertEq(nft.totalSupply(), 1000, "supply hard-capped");
    }

    // 每钱包 1 个按「历史铸造」记而非当前持仓：转出后再 claim 仍 revert；顺带锁 approve/transferFrom 授权语义
    function test_NftClaimOnceEvenAfterTransfer() public {
        _buy(alice, 500, address(0), 0.4 ether);
        vm.prank(alice);
        nft.claim(); // tokenId 1
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        assertEq(nft.balanceOf(alice), 0);
        assertEq(nft.balanceOf(bob), 1);
        vm.prank(alice);
        vm.expectRevert("JHG: already minted"); // 无币也领不了第二次
        nft.claim();

        // 授权路径：非 owner/非被授权人 transferFrom 必 revert；approved 可转且授权被清除
        vm.prank(alice);
        vm.expectRevert("JHG: not authorized");
        nft.transferFrom(bob, alice, 1);
        vm.prank(bob);
        nft.approve(carol, 1);
        vm.prank(carol);
        nft.transferFrom(bob, dave, 1);
        assertEq(nft.ownerOf(1), dave);
        vm.prank(carol); // 授权已随转让清除
        vm.expectRevert("JHG: not authorized");
        nft.transferFrom(dave, carol, 1);
    }

    // 开售/结束精确边界：endTime-1s 可买且 redeem/finalize 仍关；endTime 整点买 revert、入口全开
    function test_BuyAtLastSecondAndEndBoundary() public {
        vm.warp(START + DURATION - 1);
        _buy(alice, 1, address(0), 0.0008 ether);
        assertFalse(presale.isOpen(), "still selling at endTime-1");
        vm.prank(alice);
        vm.expectRevert("Presale: not open");
        presale.redeem(NUMS, 1);
        vm.expectRevert("Presale: not open");
        presale.finalize();

        vm.warp(START + DURATION); // == endTime
        assertTrue(presale.isOpen());
        vm.deal(bob, 0.0008 ether);
        vm.prank(bob);
        vm.expectRevert("Presale: ended");
        presale.buy{value: 0.0008 ether}(1, address(0));
    }
}

// ---------------------------------------------------------------------
// 2. HoodVRF 攻击面
// ---------------------------------------------------------------------
contract Audit2026VRFTest is Test {
    Audit2026VRFHarness public vrf;
    Audit2026Consumer public consumer;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob"); // keeper/履约方
    address carol = makeAddr("carol");

    uint256 constant FEE = 0.0002 ether;
    uint256 constant REWARD = 0.00005 ether;

    bytes constant PK = hex"0d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a"
        hex"03cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d106451"
        hex"0e5db2b6bfbb01c867749cadffca88b36c24f3012ba09fc4d3022c5c37dce0f977d3adb5d183c7477c442b1f04515273"
        hex"01a714f2edb74119a2f2b0d5a7c75ba902d163700a61bc224ededd8e63aef7be1aaf8e93d7a9718b047ccddb3eb5d68b";
    // 任意 48 字节坐标（harness mock 不看内容，只校验长度）
    bytes constant SIG48X = hex"03ad29e4c409f9470fc2ef02f90214df49e02b441a1a241a82d622d9f608ef98fd8b11a029f1bee9d9e83b45088abe72";
    bytes constant SIG48Y = hex"01776ff7408b39c5f6f9fa50746efd7eea17fbb61f2e7b9c849ff0528e5a3deeedd029d0df345199963d75ba93b5a02a";
    // BLS12-381 基域模数 p（48 字节）：坐标 = p 必须 OutOfField
    bytes constant P48 = hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";

    function setUp() public {
        vm.warp(1_700_000_000);
        vrf = new Audit2026VRFHarness(PK, FEE, REWARD);
        consumer = new Audit2026Consumer();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 1 ether);
        vm.deal(carol, 1 ether);
    }

    receive() external payable {}

    function _paidRequest() internal returns (uint256 id) {
        vm.prank(alice);
        id = vrf.requestFor{value: FEE}(address(consumer));
    }

    function _warpToRound(uint256 id) internal {
        (, uint64 r,,,) = vrf.getRequest(id);
        vm.warp(vrf.timeOfRound(r));
    }

    // 履约时间精确边界：T(r)-1s 仍 RoundNotYetEmitted，T(r) 整点成功
    function test_FulfillExactRoundTimeBoundary() public {
        uint256 id = _paidRequest();
        (, uint64 r,,,) = vrf.getRequest(id);
        vm.warp(vrf.timeOfRound(r) - 1);
        vm.expectRevert(HoodVRF.RoundNotYetEmitted.selector);
        vrf.fulfill(id, SIG48X, SIG48Y);
        vm.warp(vrf.timeOfRound(r)); // 整点
        vrf.fulfill(id, SIG48X, SIG48Y);
        assertEq(vrf.randomnessOf(id), vrf.mockRnd());
    }

    // 重复 fulfill：第二笔 AlreadyFulfilled，不重复发补贴、不改随机数、不重复回调
    function test_FulfillTwiceNoDoubleReward() public {
        uint256 id = _paidRequest();
        _warpToRound(id);
        vm.prank(bob);
        vrf.fulfill(id, SIG48X, SIG48Y);
        assertEq(vrf.feeBalance(), FEE - REWARD);

        vm.warp(block.timestamp + 1000);
        uint256 carolBal = carol.balance;
        vm.prank(carol); // 另一个履约方再试
        vm.expectRevert(HoodVRF.AlreadyFulfilled.selector);
        vrf.fulfill(id, SIG48X, SIG48Y);
        assertEq(carol.balance, carolBal, "second fulfiller got nothing");
        assertEq(vrf.feeBalance(), FEE - REWARD, "reward not double-paid");
        assertEq(vrf.randomnessOf(id), vrf.mockRnd(), "randomness immutable");
        assertEq(consumer.calls(), 1, "callback not re-fired");
    }

    // 坐标长度 off-by-one：47/49 字节同样 BadLength（既有套件只测了 2 字节与空）
    function test_FulfillSigLength47And49Revert() public {
        uint256 id = _paidRequest();
        _warpToRound(id);
        vm.expectRevert(HoodBLS.BadLength.selector);
        vrf.fulfill(id, new bytes(47), SIG48Y);
        vm.expectRevert(HoodBLS.BadLength.selector);
        vrf.fulfill(id, new bytes(49), SIG48Y);
        vm.expectRevert(HoodBLS.BadLength.selector);
        vrf.fulfill(id, SIG48X, new bytes(47));
        vm.expectRevert(HoodBLS.BadLength.selector);
        vrf.fulfill(id, SIG48X, new bytes(49));
    }

    // 真合约（非 mock）上的坐标拒绝：(0,0) 无穷远、(1,1) 不在曲线上、x=p 越界——
    // 三者在配对预编译之前即 revert，故本地 anvil（无 EIP-2537）也能真实验证。
    // 注：合法曲线点会继续走到 pairing 预编译，本地不可用，故不在此断言其后行为。
    function test_FulfillBadCoordinatesRevertOnRealContract() public {
        HoodVRF realVrf = new HoodVRF(PK, FEE, REWARD);
        vm.prank(alice);
        uint256 id = realVrf.request{value: FEE}();
        (, uint64 r,,,) = realVrf.getRequest(id);
        vm.warp(realVrf.timeOfRound(r));

        bytes memory one = new bytes(48);
        one[47] = 0x01;
        vm.expectRevert(HoodBLS.NotOnCurve.selector); // (0,0) 无穷远
        realVrf.fulfill(id, new bytes(48), new bytes(48));
        vm.expectRevert(HoodBLS.NotOnCurve.selector); // (1,1)：y²=1 ≠ x³+4=5
        realVrf.fulfill(id, one, one);
        vm.expectRevert(HoodBLS.OutOfField.selector); // x = p 越界
        realVrf.fulfill(id, P48, one);
        assertEq(realVrf.randomnessOf(id), bytes32(0), "nothing stored on rejected sigs");
    }

    // feeBalance 有余额时，免费请求（白名单）履约照样不发补贴；付费请求照发——paid 按请求记账
    function test_FreeRequestNoRewardWithFundedFeeBalance() public {
        uint256 paidId = _paidRequest(); // feeBalance = FEE
        vrf.setFreeWhitelist(carol, true);
        vm.prank(carol);
        uint256 freeId = vrf.requestFor{value: 0}(address(consumer));
        (,,, bool paidFlag,) = vrf.getRequest(freeId);
        assertFalse(paidFlag);

        _warpToRound(freeId); // 两请求同刻发起 → 同一 drand 轮
        uint256 bobBal = bob.balance;
        vm.prank(bob);
        vrf.fulfill(freeId, SIG48X, SIG48Y);
        assertEq(bob.balance, bobBal, "free request: zero reward despite funded feeBalance");
        assertEq(vrf.feeBalance(), FEE, "feeBalance untouched by free fulfill");

        vm.prank(bob);
        vrf.fulfill(paidId, SIG48X, SIG48Y);
        assertEq(bob.balance, bobBal + REWARD, "paid request: reward paid");
        assertEq(vrf.feeBalance(), FEE - REWARD);
        assertEq(consumer.calls(), 2);
    }

    // paid 标志是请求时快照：admin 事后把 fee 调 0，历史付费请求履约仍发补贴
    function test_PaidFlagSnapshotSurvivesFeeChange() public {
        uint256 id = _paidRequest();
        vrf.setFee(0); // 只影响后续请求
        _warpToRound(id);
        uint256 bobBal = bob.balance;
        vm.prank(bob);
        vrf.fulfill(id, SIG48X, SIG48Y);
        assertEq(bob.balance, bobBal + REWARD, "snapshot paid flag honored");
        assertEq(vrf.feeBalance(), FEE - REWARD);

        vm.prank(carol); // 新请求在 0 费下：不付费、无 paid 标志
        uint256 freeId = vrf.requestFor{value: 0}(address(consumer));
        (,,, bool paidFlag,) = vrf.getRequest(freeId);
        assertFalse(paidFlag);
        assertEq(vrf.feeBalance(), FEE - REWARD, "no new fee collected");
    }

    // EOA consumer：_deliver 直接跳过且记 CallbackOk（区别于合约成功回调的静默）
    function test_FulfillEoaConsumerSkipsCallback() public {
        address eoa = makeAddr("plainEoa"); // 无代码
        vm.prank(alice);
        uint256 id = vrf.requestFor{value: FEE}(eoa);
        _warpToRound(id);
        uint256 bobBal = bob.balance;
        vm.expectEmit(true, false, false, false, address(vrf));
        emit HoodVRF.CallbackOk(id); // EOA 跳过路径独有
        vm.prank(bob);
        vrf.fulfill(id, SIG48X, SIG48Y);
        assertEq(vrf.randomnessOf(id), vrf.mockRnd());
        assertEq(bob.balance, bobBal + REWARD, "reward still paid for EOA consumer");
        (,,,, bool fin) = vrf.getRequest(id);
        assertTrue(fin);
    }

    // vm.etch 两态：同一地址先是 EOA（跳过+CallbackOk），蚀刻代码后变非 consumer 合约
    // （0xfd = REVERT）→ 回调失败记 CallbackFailed，随机数仍落账，retryCallback 冒泡 revert
    function test_EoaThenEtchedConsumerTwoStates() public {
        address e = makeAddr("twoState");
        vm.prank(alice);
        uint256 id1 = vrf.requestFor{value: FEE}(e);
        _warpToRound(id1);
        vm.expectEmit(true, false, false, false, address(vrf));
        emit HoodVRF.CallbackOk(id1);
        vrf.fulfill(id1, SIG48X, SIG48Y); // EOA 态：跳过

        vm.etch(e, hex"fd"); // 合约态：代码存在但必然 revert
        vm.prank(alice);
        uint256 id2 = vrf.requestFor{value: FEE}(e);
        _warpToRound(id2);
        vm.expectEmit(true, true, false, false, address(vrf));
        emit HoodVRF.CallbackFailed(id2, e);
        vrf.fulfill(id2, SIG48X, SIG48Y);
        assertEq(vrf.randomnessOf(id2), vrf.mockRnd(), "randomness stored despite etched revert");
        vm.expectRevert(); // retryCallback 冒泡（空 revert 数据）
        vrf.retryCallback(id2);
    }

    // 履约方拒收补贴：补贴记账回滚（feeBalance 不动）、履约与回调照常完成
    function test_RejectingFulfillerRewardSkippedFulfillOk() public {
        Audit2026Rejecter rej = new Audit2026Rejecter();
        uint256 id = _paidRequest();
        _warpToRound(id);
        rej.fulfill(vrf, id, SIG48X, SIG48Y);
        assertEq(vrf.randomnessOf(id), vrf.mockRnd(), "fulfill succeeded");
        assertEq(address(rej).balance, 0, "rejecter got no reward");
        assertEq(vrf.feeBalance(), FEE, "reward bookkeeping rolled back");
        assertEq(consumer.calls(), 1, "callback still delivered");
    }

    // admin 是拒收 ETH 合约：withdrawFees revert WithdrawFailed 且 feeBalance 分文不少
    function test_WithdrawFeesRejectingAdminRevertsKeepsBalance() public {
        _paidRequest();
        Audit2026Rejecter rej = new Audit2026Rejecter();
        vrf.transferAdmin(address(rej));
        rej.acceptAdmin(vrf);
        assertEq(vrf.admin(), address(rej));
        vm.expectRevert(HoodVRF.WithdrawFailed.selector);
        rej.withdraw(vrf);
        assertEq(vrf.feeBalance(), FEE, "feeBalance restored after failed withdraw");
        vm.expectRevert(HoodVRF.NotAdmin.selector); // 旧 admin 已无权
        vrf.withdrawFees();
    }

    // requestFor 的超付退款只退付款人，consumer 分文不得
    function test_RequestForRefundsPayerNotConsumer() public {
        uint256 aliceBal = alice.balance;
        vm.prank(alice);
        vrf.requestFor{value: FEE + 0.003 ether}(address(consumer));
        assertEq(alice.balance, aliceBal - FEE, "excess refunded to payer");
        assertEq(address(consumer).balance, 0, "consumer receives no dust");
        assertEq(vrf.feeBalance(), FEE);
    }

    // retryCallback 对从未存在的 id 同样 NotFulfilled（既有套件只测了已请求未履约）
    function test_RetryCallbackUnknownIdReverts() public {
        vm.expectRevert(HoodVRF.NotFulfilled.selector);
        vrf.retryCallback(777_777);
    }
}

// ---------------------------------------------------------------------
// 3. core V4.4 攻击面
// ---------------------------------------------------------------------
contract Audit2026CoreTest is Test {
    Audit2026CoreHarness public jackpot;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public referrer = makeAddr("referrer");

    uint256 public constant PRICE = 0.001 ether;
    bytes32 public constant WIN_SEED = 0x0001020304050000000000000000000000000000000000000000000000000000; // → 0-1-2-3-4-5

    uint8[6] JACKPOT_NUMS = [0, 1, 2, 3, 4, 5];
    uint8[6] MISS_NUMS = [7, 7, 7, 7, 7, 7];
    uint8[6] LAST1_NUMS = [9, 9, 9, 9, 9, 5]; // 仅末位中（六等）

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.prank(admin);
        jackpot = new Audit2026CoreHarness(24 hours, 15 minutes, true); // 不注资，账务从零起算
        vm.deal(admin, 2000 ether);
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

    function _stake(address user, uint256 amt) internal {
        vm.deal(user, amt + 1 ether);
        vm.prank(user);
        jackpot.stakeEth{value: amt}();
    }

    // 两用户交错退出：alice 在轮 1 挂单、轮 1 结算后 bob 挂单（记轮 2）；
    // 逆序/乱序领取互不干扰，每步金额与总账精确到 wei
    function test_TwoUserInterleavedUnstakeExactAmounts() public {
        uint256 rid = jackpot.currentRoundId();
        _stake(alice, 1.5 ether);
        _stake(bob, 0.5 ether);
        assertEq(jackpot.totalEthStaked(), 2 ether);
        assertEq(jackpot.stakeCash(), 2 ether);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(jackpot));
        emit JackpotHood.UnstakeRequested(alice, 0.6 ether, uint64(rid));
        jackpot.requestUnstake(0.6 ether);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED); // 轮 1 终态（无票，纯结算）

        // bob 在轮 1 已终态后挂单 → 登记轮 2
        vm.prank(bob);
        jackpot.requestUnstake(0.2 ether);
        (, uint64 bobRid) = jackpot.unstakeReqOf(bob);
        assertEq(bobRid, uint64(rid + 1), "bob booked to next round");
        vm.prank(bob);
        vm.expectRevert("JPH: not matured");
        jackpot.finalizeUnstake();

        jackpot.startRound();
        // alice 先领（其登记轮已终态）：+0.6，余额 0.9
        uint256 aliceBal = alice.balance;
        vm.prank(alice);
        jackpot.finalizeUnstake();
        assertEq(alice.balance - aliceBal, 0.6 ether);
        assertEq(jackpot.ethStaked(alice), 0.9 ether);
        assertEq(jackpot.totalEthStaked(), 1.4 ether);
        assertEq(jackpot.stakeCash(), 1.4 ether);

        // 轮 2 结算后 bob 领：+0.2，余额 0.3；两人（部分退出）都仍在质押者数组
        uint256 rid2 = jackpot.currentRoundId();
        _warpToDraw(rid2);
        jackpot.settleWithSeed(rid2, WIN_SEED);
        uint256 bobBal = bob.balance;
        vm.prank(bob);
        jackpot.finalizeUnstake();
        assertEq(bob.balance - bobBal, 0.2 ether);
        assertEq(jackpot.ethStaked(bob), 0.3 ether);
        assertEq(jackpot.totalEthStaked(), 1.2 ether);
        assertEq(jackpot.stakeCash(), 1.2 ether);
    }

    // 挂单期间：照常按快照领奖（claimStakeRewards 不受挂单限制）、可追加质押；
    // finalize 实付 = min(申请额, 追加后余额)
    function test_PendingUnstakeClaimRewardsAndRestake() public {
        uint256 rid = jackpot.currentRoundId();
        _stake(alice, 1 ether);
        _buy(carol, MISS_NUMS, 100); // 买票抽水 0.01 ether

        vm.prank(alice);
        jackpot.requestUnstake(0.4 ether);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED); // 快照：alice 仍 1 ether 全份额
        assertEq(jackpot.pendingStakeRewards(alice), 0.01 ether, "full share while pending");

        // 挂单未领期间先领分红：到账且挂单子纹丝不动
        uint256 bal = alice.balance;
        vm.prank(alice);
        jackpot.claimStakeRewards();
        assertEq(alice.balance - bal, 0.01 ether);
        (uint256 reqAmt,) = jackpot.unstakeReqOf(alice);
        assertEq(reqAmt, 0.4 ether, "request intact after reward claim");
        assertEq(jackpot.ethStaked(alice), 1 ether, "stake untouched by reward claim");

        // 挂单期间追加质押 0.2 → finalize 按 min(0.4, 1.2) = 0.4 实付，余 0.8 继续生息
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        jackpot.stakeEth{value: 0.2 ether}();
        assertEq(jackpot.ethStaked(alice), 1.2 ether);
        bal = alice.balance;
        vm.prank(alice);
        jackpot.finalizeUnstake();
        assertEq(alice.balance - bal, 0.4 ether, "pays requested amount, not topped-up balance");
        assertEq(jackpot.ethStaked(alice), 0.8 ether);
        assertEq(jackpot.stakeCash(), 0.8 ether);
        assertEq(jackpot.totalEthStaked(), 0.8 ether);
    }

    // 推荐人是拒收合约：5% 立付失败 → 份额留在 ticketFee → settle 时全额（10%）分给质押者
    function test_RejectingReferrerShareFlowsToStakers() public {
        Audit2026Rejecter rej = new Audit2026Rejecter();
        uint256 rid = jackpot.currentRoundId();
        _stake(bob, 1 ether); // bob 为唯一质押者
        vm.prank(alice);
        jackpot.setReferrer(address(rej));
        _buy(alice, MISS_NUMS, 10); // fee = 0.001 ether；立付失败留在 ticketFee
        assertEq(address(rej).balance, 0, "rejecting referrer got nothing");
        assertEq(jackpot.getRound(rid).ticketFee, 0.001 ether, "full 10% stays booked");

        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);
        assertEq(jackpot.referralPaidPerRound(rid), 0);
        assertEq(jackpot.pendingStakeRewards(bob), 0.001 ether, "rejected 5% flows to stakers via pool");
        assertEq(jackpot.stakingPool(), 0, "pool fully distributed");
        uint256 bal = bob.balance;
        vm.prank(bob);
        jackpot.claimStakeRewards();
        assertEq(bob.balance - bal, 0.001 ether);
        assertEq(address(jackpot).balance, 1.009 ether, "conservation: stake + revenue - claimed reward");
    }

    // V4.5 修订后语义：推荐人拒收 ETH 时，中奖 claim 照常成功——refShare（5%）并入 stakingPool，
    // 中奖者净得 88% 不受影响（与购票侧容错口径一致）
    function test_ClaimFallbackWhenReferrerRejectsEth() public {
        Audit2026Rejecter rej = new Audit2026Rejecter();
        uint256 rid = jackpot.currentRoundId();
        vm.prank(alice);
        jackpot.setReferrer(address(rej));
        _buy(alice, JACKPOT_NUMS, 1);
        _buy(carol, MISS_NUMS, 1);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        (uint256 due,) = jackpot.previewClaim(rid, alice);
        assertGt(due, 0, "alice has winning prize");
        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        uint256 poolBefore = jackpot.stakingPool();
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        jackpot.claim(rid, idx);
        assertEq(alice.balance - balBefore, (due * 88) / 100, "winner nets 88%");
        assertEq(jackpot.stakingPool() - poolBefore, due - (due * 88) / 100, "pool gets full 12% (7% + 5% fallback)");
        JackpotHood.Ticket[] memory ts = jackpot.getUserTickets(rid, alice);
        assertTrue(ts[0].claimed, "ticket marked claimed");
        assertEq(jackpot.getRound(rid).tierClaimed[0], due, "booked");
    }

    // void 轮同样使挂单成熟（Drawn 之外的第二条终态路径）
    function test_VoidedRoundMaturesUnstake() public {
        uint256 rid = jackpot.currentRoundId();
        _stake(alice, 1 ether);
        vm.prank(alice);
        jackpot.requestUnstake(1 ether);
        vm.prank(admin);
        jackpot.voidRound(rid); // Open → Voided
        uint256 bal = alice.balance;
        vm.prank(alice);
        jackpot.finalizeUnstake();
        assertEq(alice.balance - bal, 1 ether);
        assertEq(jackpot.ethStaked(alice), 0);
        assertEq(jackpot.stakeCash(), 0);
        assertEq(jackpot.totalEthStaked(), 0);
    }

    // Committed（在飞）轮中申请：登记当轮而非下一轮，结算后即可领
    function test_RequestUnstakeDuringCommittedBooksCurrentRound() public {
        uint256 rid = jackpot.currentRoundId();
        _stake(bob, 0.5 ether);
        _warpToDraw(rid);
        jackpot.commitDraw(rid); // Open → Committed
        vm.prank(bob);
        jackpot.requestUnstake(0.5 ether);
        (, uint64 reqRid) = jackpot.unstakeReqOf(bob);
        assertEq(reqRid, uint64(rid), "committed round still in-flight: book current");
        jackpot.settleWithSeed(rid, WIN_SEED);
        uint256 bal = bob.balance;
        vm.prank(bob);
        jackpot.finalizeUnstake();
        assertEq(bob.balance - bal, 0.5 ether);
        assertEq(jackpot.ethStaked(bob), 0);
    }

    // 重复下标 claim：整笔原子回滚（第一张也不付），随后正常两张全付精确到 wei
    function test_ClaimDuplicateIndexAtomicRevert() public {
        uint256 rid = jackpot.currentRoundId();
        _buy(alice, JACKPOT_NUMS, 1); // idx 0
        _buy(alice, JACKPOT_NUMS, 1); // idx 1
        _buy(carol, MISS_NUMS, 1);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);
        JackpotHood.Round memory r = jackpot.getRound(rid);
        uint256 pot0 = r.tierPots[0]; // 1.08e15（pool 2.7e15 的 40%）
        assertEq(r.tierUnits[0], 2);

        uint256[] memory dup = new uint256[](2);
        dup[0] = 0;
        dup[1] = 0; // 同一张两次
        uint256 bal = alice.balance;
        vm.prank(alice);
        vm.expectRevert("JPH: ticket claimed");
        jackpot.claim(rid, dup);
        assertEq(alice.balance, bal, "atomic: first claim rolled back too");
        assertEq(jackpot.getRound(rid).tierClaimed[0], 0, "nothing booked");

        uint256[] memory both = new uint256[](2);
        both[0] = 0;
        both[1] = 1;
        vm.prank(alice);
        jackpot.claim(rid, both);
        uint256 dueTotal = pot0; // 两张各 pot0/2
        assertEq(alice.balance - bal, dueTotal - dueTotal * 1200 / 10000, "88% of full pot exact");
        assertEq(jackpot.getRound(rid).tierClaimed[0], pot0, "pot fully claimed");

        // 纯未中票 claim → JPHNothingToClaim
        uint256[] memory miss = new uint256[](1);
        miss[0] = 0;
        vm.prank(carol);
        vm.expectRevert(JackpotHood.JPHNothingToClaim.selector);
        jackpot.claim(rid, miss);
    }

    // 兑奖窗口精确边界：== claimDeadline 可领、+1s 即过期；sweep 前后守卫钉死
    function test_ClaimDeadlineBoundaryAndSweepGuards() public {
        uint256 rid = jackpot.currentRoundId();
        _buy(alice, JACKPOT_NUMS, 1);
        _buy(bob, JACKPOT_NUMS, 1);
        _buy(carol, MISS_NUMS, 1);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);
        JackpotHood.Round memory r = jackpot.getRound(rid);
        uint256 pot0 = r.tierPots[0];

        vm.expectRevert("JPH: not expired"); // 窗口内禁止 sweep
        jackpot.sweepUnclaimed(rid);

        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        vm.warp(r.claimDeadline); // == 截止：可领
        vm.prank(alice);
        jackpot.claim(rid, idx);
        assertEq(jackpot.getRound(rid).tierClaimed[0], pot0 / 2);

        vm.warp(r.claimDeadline + 1); // 过期 1s：bob 领不到
        vm.prank(bob);
        vm.expectRevert("JPH: claim expired");
        jackpot.claim(rid, idx);

        uint256 rollBefore = jackpot.pendingRollover();
        jackpot.sweepUnclaimed(rid); // 扫走 bob 的未领半池
        assertEq(jackpot.pendingRollover(), rollBefore + (pot0 - pot0 / 2), "unclaimed half swept exact");
        vm.expectRevert("JPH: already swept");
        jackpot.sweepUnclaimed(rid);
    }

    // 封顶档·池极小：独中六等档池 27,000,000,000,000 wei << 10×票价 → 不封顶，逐 wei 派彩/抽水/滚存
    function test_PayoutCapTinyPoolUncappedExactWei() public {
        uint256 rid = jackpot.currentRoundId();
        _buy(alice, LAST1_NUMS, 1); // 池仅 0.0009 ether
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);
        JackpotHood.Round memory r = jackpot.getRound(rid);

        uint256 pot5 = 27_000_000_000_000; // 9e14 × 3% 精确
        assertEq(r.tierUnits[5], 1, "solo last-digit winner");
        assertEq(r.tierPots[5], pot5, "uncapped: pot below 10x cap");
        assertEq(jackpot.pendingRollover(), 873_000_000_000_000, "empty tiers roll exact wei");
        assertEq(jackpot.ticketBank(), 873_000_000_000_000, "bank retains exact wei");

        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        uint256 bal = alice.balance;
        vm.prank(alice);
        jackpot.claim(rid, idx);
        assertEq(alice.balance - bal, 23_760_000_000_000, "net = 27e12 - 12% exact wei");
        assertEq(jackpot.stakingPool(), 103_240_000_000_000, "buy fee 1e14 + win fee 3.24e12 exact");
    }

    // 封顶档·池极大：注资 1000 ether 后独中六等 → 压到 10×票价，余量全滚存且守恒帽恰好绑死
    function test_PayoutCapHugePoolCappedExactWei() public {
        uint256 rid = jackpot.currentRoundId();
        vm.prank(admin);
        jackpot.injectPrizeEth{value: 1000 ether}();
        _buy(alice, LAST1_NUMS, 1); // pool = 1000.0009 ether
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);
        JackpotHood.Round memory r = jackpot.getRound(rid);

        assertEq(r.tierUnits[5], 1);
        assertEq(r.tierPots[5], 10 * PRICE, "capped at 10x ticket price");
        // 滚存 = 池 − 封顶档 = ticketBank（守恒帽恰好绑死，phantom = 0）
        assertEq(jackpot.pendingRollover(), 999_990_900_000_000_000_000, "rollover exact wei");
        assertEq(jackpot.ticketBank(), 999_990_900_000_000_000_000, "cap binds: bank == rollover");

        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        uint256 bal = alice.balance;
        vm.prank(alice);
        jackpot.claim(rid, idx);
        assertEq(alice.balance - bal, 8_800_000_000_000_000, "88% of capped 0.01 exact wei");
        assertEq(jackpot.stakingPool(), 1_300_000_000_000_000, "buy fee 1e14 + win fee 1.2e15 exact");
    }

    // void 轮 × 已立付推荐 ×（本会被封顶的）付费票：按全款退款，推荐份额已离场由注资兜底，
    // 预留/滚存/余额逐 wei 守恒（invariant 中 ghostVoidedRefPaid 容差的单位场景钉死）
    function test_VoidRoundReferralRefundExactConservation() public {
        uint256 rid = jackpot.currentRoundId();
        vm.prank(admin);
        jackpot.injectPrizeEth{value: 1 ether}();
        vm.prank(alice);
        jackpot.setReferrer(referrer);
        _buy(alice, LAST1_NUMS, 10); // 若结算会触发封顶的号码；void 下与帽无关
        assertEq(referrer.balance, 0.0005 ether, "5% paid upfront");
        assertEq(jackpot.getRound(rid).ticketFee, 0.0005 ether, "5% booked");

        vm.prank(admin);
        jackpot.voidRound(rid);
        assertEq(jackpot._voidedOwed(), 0.01 ether, "reserve = full revenue");
        assertEq(jackpot.ticketBank(), 1 ether, "90% reverted from bank");
        assertEq(jackpot.pendingRollover(), 1.0005 ether, "seed + fee rolled exact");

        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        uint256 bal = alice.balance;
        vm.prank(alice);
        jackpot.refundTickets(rid, idx);
        assertEq(alice.balance - bal, 0.01 ether, "full refund incl. fee part");
        assertEq(jackpot._voidedOwed(), 0, "reserve drained");
        assertEq(referrer.balance, 0.0005 ether, "referrer keeps upfront share");
        // 守恒：1 注资 + 0.01 票款 − 0.0005 推荐 − 0.01 退款 = 0.9995 ether
        assertEq(address(jackpot).balance, 0.9995 ether, "conservation exact wei");
    }

    // 承诺块越过 256 块窗口：快照/结算被拒之 → 重承诺（stale 分支）→ 新承诺块快照结算成功
    function test_StaleCommitRecommitThenSettle() public {
        uint256 rid = jackpot.currentRoundId();
        _buy(alice, MISS_NUMS, 1);
        _warpToDraw(rid);
        jackpot.commitDraw(rid);
        uint64 rb1 = jackpot.getRound(rid).randomBlock;

        vm.roll(block.number + 300); // 承诺块掉出 256 窗口
        vm.expectRevert("JPH: hash window passed, retry commitDraw");
        jackpot.snapshotCommitHash(rid);
        vm.expectRevert("JPH: snapshot first");
        jackpot.settleDraw(rid);

        jackpot.commitDraw(rid); // Committed stale 分支：重承诺
        uint64 rb2 = jackpot.getRound(rid).randomBlock;
        assertGt(rb2, rb1, "re-committed to a fresh block");
        vm.roll(block.number + 2);
        jackpot.snapshotCommitHash(rid);
        jackpot.settleDraw(rid);
        assertEq(uint8(jackpot.getRound(rid).status), uint8(JackpotHood.Status.Drawn), "settled after re-commit");
        vm.expectRevert(JackpotHood.JPHNotCommitted.selector); // 已终态不可再结算
        jackpot.settleDraw(rid);
    }

    // 无开放轮时注资：进 pendingRollover 而非任何轮次，startRound 后被新轮全额吸收
    function test_InjectWhenNoOpenRoundGoesPendingRollover() public {
        uint256 rid = jackpot.currentRoundId();
        _buy(alice, MISS_NUMS, 1);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED); // 全空档：0.0009 滚存
        assertEq(jackpot.pendingRollover(), 0.0009 ether);

        vm.prank(admin);
        jackpot.injectPrizeEth{value: 0.5 ether}(); // 当前轮已 Drawn（非 Open）
        assertEq(jackpot.pendingRollover(), 0.5009 ether, "injection queued, not credited");
        assertEq(jackpot.getRound(rid).prizePool, 0.0009 ether, "settled round untouched");

        jackpot.startRound();
        assertEq(jackpot.pendingRollover(), 0, "absorbed by new round");
        assertEq(jackpot.getRound(rid + 1).prizePool, 0.5009 ether, "new round opening pool exact");
        assertEq(jackpot.ticketBank(), 0.5009 ether, "bank matches pool");
    }

    // 锁定现状（自伤型锁死，见汇报）：拒收 ETH 的合约质押者 finalize 必 revert，
    // 且无 cancelUnstake 入口——挂单、本金永久滞留（仅能正常收款的地址才能退出）
    function test_FinalizeUnstakeRejectingReceiverLocked() public {
        Audit2026Rejecter rej = new Audit2026Rejecter();
        uint256 rid = jackpot.currentRoundId();
        rej.stake{value: 1 ether}(jackpot);
        rej.requestUnstake(jackpot, 1 ether);
        _warpToDraw(rid);
        jackpot.settleWithSeed(rid, WIN_SEED);

        vm.expectRevert("JPH: unstake failed");
        rej.finalizeUnstake(jackpot);
        (uint256 reqAmt,) = jackpot.unstakeReqOf(address(rej));
        assertEq(reqAmt, 1 ether, "request still pending (no cancel path)");
        assertEq(jackpot.ethStaked(address(rej)), 1 ether, "stake still booked");
        assertEq(jackpot.stakeCash(), 1 ether, "cash still locked");
        assertEq(address(rej).balance, 0, "nothing paid out");
    }

    // 停售点前后选轮：salesEnd-1s 买入记当轮；== salesEnd 买入顺延创建下一轮
    function test_PickRoundSalesEndBoundary() public {
        JackpotHood.Round memory r1 = jackpot.getRound(1);
        vm.warp(r1.salesEnd - 1);
        _buy(alice, MISS_NUMS, 1);
        assertEq(jackpot.currentRoundId(), 1);
        assertEq(jackpot.getUserTickets(1, alice).length, 1, "ticket in round 1");

        vm.warp(r1.salesEnd); // 整点即停售
        _buy(alice, MISS_NUMS, 1);
        assertEq(jackpot.currentRoundId(), 2, "rolled to next round");
        assertEq(jackpot.getUserTickets(2, alice).length, 1, "ticket in round 2");
        JackpotHood.Round memory r2 = jackpot.getRound(2);
        assertEq(r2.drawAt, r1.drawAt + 24 hours, "next round scheduled exactly +1 period");
        assertEq(r2.salesEnd, r1.salesEnd + 24 hours);
    }
}
