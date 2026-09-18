// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {HoodVRF} from "../src/vrf/HoodVRF.sol";
import {HoodBLS} from "../src/vrf/HoodBLS.sol";
import {IVrfConsumer} from "../src/vrf/IVrfConsumer.sol";

/// @dev 测试桩：覆盖验签为 mock（本地 anvil 无 EIP-2537 预编译，真实验签走 fork 脚本 VerifyDrand）
contract HoodVRFHarness is HoodVRF {
    bool public mockOk = true;
    bytes32 public mockRnd = bytes32(uint256(0xbeef));

    constructor(bytes memory pk, uint256 f, uint256 r) HoodVRF(pk, f, r) {}

    function setMock(bool ok, bytes32 rnd) external {
        mockOk = ok;
        mockRnd = rnd;
    }

    function _verifyAndDerive(uint64, bytes calldata, bytes calldata) internal view override returns (bytes32) {
        if (!mockOk) revert HoodBLS.NotOnCurve();
        return mockRnd;
    }

    /// @dev 直接构造履约状态（测试 _storeRandomness 写入路径）
    function storeRaw(uint256 id, uint64 round, bytes32 rnd) external {
        _storeRandomness(id, round, rnd);
    }
}

/// @dev 标准 consumer：记录回调，可切换失败
contract MockConsumer is IVrfConsumer {
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

/// @dev 回调里烧光 gas 的恶意 consumer
contract GasGriefConsumer is IVrfConsumer {
    function onRandom(uint256, bytes32) external pure {
        uint256 x = 1;
        while (true) {
            unchecked {
                x = x * 7 + 1;
            }
        }
    }
}

/// @dev 无 receive 的请求方：测试退款失败路径
contract NoReceiveCaller {
    function doRequest(HoodVRF vrf, uint256 v) external returns (uint256) {
        return vrf.request{value: v}();
    }
}

/// @dev 暴露库内部函数做本地单元测试（sha256/modexp 预编译本地可用）
contract BLSExposer {
    function hashToField2(bytes32 m) external view returns (bytes memory, bytes memory) {
        return HoodBLS.hashToField2(m);
    }

    function isOnCurve(bytes memory x, bytes memory y) external view returns (bool) {
        return HoodBLS.isOnCurveG1(x, y);
    }

    function compress(bytes memory x, bytes memory y) external pure returns (bytes memory) {
        return HoodBLS.compressG1(x, y);
    }
}

/// @notice HoodVRF 单元测试：状态机/费用/权限/降级 + 本地可跑的密码学组件（hash_to_field、压缩、曲线上校验）
/// @dev 完整配对验签在 fork 测试网的 script/VerifyDrand.s.sol 实测
contract HoodVRFTest is Test {
    HoodVRFHarness public vrf;
    MockConsumer public consumer;
    BLSExposer public expo;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob"); // keeper/履约方

    uint256 constant FEE = 0.0002 ether;
    uint256 constant REWARD = 0.00005 ether;

    // quicknet 非压缩公钥（同 VerifyDrand 脚本）
    bytes constant PK = hex"0d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a"
        hex"03cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d106451"
        hex"0e5db2b6bfbb01c867749cadffca88b36c24f3012ba09fc4d3022c5c37dce0f977d3adb5d183c7477c442b1f04515273"
        hex"01a714f2edb74119a2f2b0d5a7c75ba902d163700a61bc224ededd8e63aef7be1aaf8e93d7a9718b047ccddb3eb5d68b";
    // 真实 σ（round 1000000）坐标与压缩编码
    bytes constant SIG_X = hex"03ad29e4c409f9470fc2ef02f90214df49e02b441a1a241a82d622d9f608ef98fd8b11a029f1bee9d9e83b45088abe72";
    bytes constant SIG_Y = hex"01776ff7408b39c5f6f9fa50746efd7eea17fbb61f2e7b9c849ff0528e5a3deeedd029d0df345199963d75ba93b5a02a";
    bytes constant SIG_COMPRESSED = hex"83ad29e4c409f9470fc2ef02f90214df49e02b441a1a241a82d622d9f608ef98fd8b11a029f1bee9d9e83b45088abe72";
    bytes32 constant RND1 = 0x32b119d66526cbc890429fae95c9083a216660ddc37344929f6937832302ad0a;

    function setUp() public {
        vm.warp(1_700_000_000); // 2023-11，已过 quicknet 创世
        vrf = new HoodVRFHarness(PK, FEE, REWARD);
        consumer = new MockConsumer();
        expo = new BLSExposer();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 1 ether);
    }

    receive() external payable {}

    // ---------------------------------------------------------------
    // drand 轮次时间换算
    // ---------------------------------------------------------------

    function test_RoundMath() public view {
        uint64 g = vrf.DRAND_GENESIS();
        assertEq(vrf.roundAtTime(g), 1);
        assertEq(vrf.roundAtTime(g + 2), 1);
        assertEq(vrf.roundAtTime(g + 3), 2);
        assertEq(vrf.timeOfRound(1), g);
        assertEq(vrf.timeOfRound(1000000), 1695803364); // g + 999999*3
        assertEq(vrf.roundAtTime(1695803364), 1000000);
    }

    function test_RoundMathReverts() public {
        uint64 g = vrf.DRAND_GENESIS();
        vm.expectRevert(HoodVRF.BeforeGenesis.selector);
        vrf.roundAtTime(g - 1);
        vm.expectRevert(HoodVRF.BadRound.selector);
        vrf.timeOfRound(0);
    }

    // ---------------------------------------------------------------
    // 请求与费用
    // ---------------------------------------------------------------

    function test_RequestPaysFeeAndRefundsExcess() public {
        uint256 bal0 = alice.balance;
        vm.expectEmit(true, true, false, true, address(vrf));
        emit HoodVRF.Requested(1, alice, vrf.roundAtTime(uint64(block.timestamp) + 60), true, false);
        vm.prank(alice);
        uint256 id = vrf.request{value: 0.001 ether}();
        assertEq(id, 1);
        assertEq(vrf.feeBalance(), FEE);
        assertEq(alice.balance, bal0 - FEE, "excess refunded");
        (address c, uint64 r, uint64 ts, bool paid, bool fin) = vrf.getRequest(id);
        assertEq(c, alice);
        assertEq(r, vrf.roundAtTime(uint64(block.timestamp) + 60));
        assertEq(ts, uint64(block.timestamp));
        assertTrue(paid);
        assertFalse(fin);
        assertEq(vrf.nextId(), 2);
    }

    function test_RequestExactFee() public {
        vm.prank(alice);
        vrf.request{value: FEE}();
        assertEq(vrf.feeBalance(), FEE);
    }

    function test_RequestInsufficientFeeReverts() public {
        vm.prank(alice);
        vm.expectRevert(HoodVRF.FeeTooLow.selector);
        vrf.request{value: FEE - 1}();
    }

    function test_RequestWhitelistSenderFree() public {
        vm.expectEmit(true, false, false, true, address(vrf));
        emit HoodVRF.WhitelistSet(alice, true);
        vrf.setFreeWhitelist(alice, true);
        uint256 bal0 = alice.balance;
        vm.prank(alice);
        uint256 id = vrf.request{value: 0}();
        assertEq(vrf.feeBalance(), 0);
        assertEq(alice.balance, bal0);
        (,,, bool paid,) = vrf.getRequest(id);
        assertFalse(paid);
        // 白名单误转钱也全额退
        vm.prank(alice);
        vrf.request{value: 1 ether}();
        assertEq(alice.balance, bal0, "whitelisted value refunded");
    }

    function test_RequestWhitelistConsumerFree() public {
        vrf.setFreeWhitelist(address(consumer), true);
        vm.prank(alice); // alice 未入列，但 consumer 入列 → 免费
        vrf.requestFor{value: 0}(address(consumer));
        assertEq(vrf.feeBalance(), 0);
    }

    function test_RequestForZeroConsumerReverts() public {
        vm.expectRevert(HoodVRF.BadConsumer.selector);
        vrf.requestFor(address(0));
    }

    function test_RequestRefundFailureReverts() public {
        NoReceiveCaller c = new NoReceiveCaller();
        vm.deal(address(c), 1 ether);
        vm.expectRevert(HoodVRF.RefundFailed.selector);
        c.doRequest(vrf, FEE + 1); // 多付 1 wei，退款被拒 → 整笔 revert
    }

    function test_ZeroFeeRequestsFree() public {
        vrf.setFee(0);
        vm.prank(alice);
        uint256 id = vrf.request{value: 0}();
        (,,, bool paid,) = vrf.getRequest(id);
        assertFalse(paid);
    }

    function testFuzz_RequestRefund(uint256 extra) public {
        extra = bound(extra, 0, 10 ether);
        uint256 bal0 = alice.balance;
        vm.prank(alice);
        vrf.request{value: FEE + extra}();
        assertEq(alice.balance, bal0 - FEE);
        assertEq(vrf.feeBalance(), FEE);
    }

    // ---------------------------------------------------------------
    // 履约状态机（mock 验签）
    // ---------------------------------------------------------------

    function _paidRequest() internal returns (uint256 id) {
        vm.prank(alice);
        id = vrf.requestFor{value: FEE}(address(consumer));
    }

    function _warpToRound(uint256 id) internal {
        (, uint64 r,,,) = vrf.getRequest(id);
        vm.warp(vrf.timeOfRound(r));
    }

    function test_FulfillSuccess() public {
        uint256 id = _paidRequest();
        _warpToRound(id);
        uint256 bobBal0 = bob.balance;
        vm.expectEmit(true, false, false, true, address(vrf));
        emit HoodVRF.Fulfilled(id, vrf.roundAtTime(uint64(block.timestamp)), vrf.mockRnd(), bob);
        vm.prank(bob);
        vrf.fulfill(id, SIG_X, SIG_Y);
        assertEq(vrf.randomnessOf(id), vrf.mockRnd());
        assertEq(consumer.calls(), 1);
        assertEq(consumer.lastId(), id);
        assertEq(consumer.lastRnd(), vrf.mockRnd());
        assertEq(bob.balance, bobBal0 + REWARD, "fulfill reward");
        assertEq(vrf.feeBalance(), FEE - REWARD);
    }

    function test_FulfillTooEarlyReverts() public {
        uint256 id = _paidRequest();
        vm.expectRevert(HoodVRF.RoundNotYetEmitted.selector);
        vrf.fulfill(id, SIG_X, SIG_Y);
    }

    function test_FulfillUnknownReverts() public {
        vm.expectRevert(HoodVRF.UnknownRequest.selector);
        vrf.fulfill(999, SIG_X, SIG_Y);
    }

    function test_FulfillTwiceReverts() public {
        uint256 id = _paidRequest();
        _warpToRound(id);
        vrf.fulfill(id, SIG_X, SIG_Y);
        vm.expectRevert(HoodVRF.AlreadyFulfilled.selector);
        vrf.fulfill(id, SIG_X, SIG_Y);
    }

    function test_FulfillBadSigLengthReverts() public {
        uint256 id = _paidRequest();
        _warpToRound(id);
        vm.expectRevert(HoodBLS.BadLength.selector);
        vrf.fulfill(id, hex"1234", SIG_Y);
        vm.expectRevert(HoodBLS.BadLength.selector);
        vrf.fulfill(id, SIG_X, hex"");
    }

    function test_FulfillMockVerifyFailReverts() public {
        uint256 id = _paidRequest();
        _warpToRound(id);
        vrf.setMock(false, bytes32(0));
        vm.expectRevert(HoodBLS.NotOnCurve.selector);
        vrf.fulfill(id, SIG_X, SIG_Y);
    }

    function test_FulfillFreeRequestNoReward() public {
        vrf.setFreeWhitelist(alice, true);
        vm.prank(alice);
        uint256 id = vrf.requestFor{value: 0}(address(consumer));
        _warpToRound(id);
        uint256 bobBal0 = bob.balance;
        vm.prank(bob);
        vrf.fulfill(id, SIG_X, SIG_Y);
        assertEq(bob.balance, bobBal0, "free request: no reward");
        assertEq(vrf.feeBalance(), 0);
    }

    function test_RewardSkippedWhenBalanceLow() public {
        vrf.setFulfillReward(0.01 ether); // 补贴高于累计费用
        uint256 id = _paidRequest();
        _warpToRound(id);
        uint256 bobBal0 = bob.balance;
        vm.prank(bob);
        vrf.fulfill(id, SIG_X, SIG_Y);
        assertEq(bob.balance, bobBal0, "insufficient feeBalance: skip reward");
        assertEq(vrf.feeBalance(), FEE);
    }

    function test_CallbackFailureCaughtAndRetry() public {
        consumer.setFailing(true);
        uint256 id = _paidRequest();
        _warpToRound(id);
        vm.expectEmit(true, true, false, false, address(vrf));
        emit HoodVRF.CallbackFailed(id, address(consumer));
        vrf.fulfill(id, SIG_X, SIG_Y); // 回调失败不 revert
        assertEq(vrf.randomnessOf(id), vrf.mockRnd(), "randomness stored despite callback failure");
        assertEq(consumer.calls(), 0);
        // 修好后重投
        consumer.setFailing(false);
        vm.expectEmit(true, false, false, false, address(vrf));
        emit HoodVRF.CallbackOk(id);
        vrf.retryCallback(id);
        assertEq(consumer.calls(), 1);
        assertEq(consumer.lastRnd(), vrf.mockRnd());
    }

    function test_RetryCallbackNotFulfilledReverts() public {
        uint256 id = _paidRequest();
        vm.expectRevert(HoodVRF.NotFulfilled.selector);
        vrf.retryCallback(id);
    }

    function test_RetryCallbackBubblesFailure() public {
        consumer.setFailing(true);
        uint256 id = _paidRequest();
        _warpToRound(id);
        vrf.fulfill(id, SIG_X, SIG_Y);
        vm.expectRevert(bytes("consumer fail"));
        vrf.retryCallback(id);
    }

    function test_CallbackGasGriefContained() public {
        GasGriefConsumer grief = new GasGriefConsumer();
        vm.prank(alice);
        uint256 id = vrf.requestFor{value: FEE}(address(grief));
        _warpToRound(id);
        vm.expectEmit(true, true, false, false, address(vrf));
        emit HoodVRF.CallbackFailed(id, address(grief));
        vrf.fulfill(id, SIG_X, SIG_Y); // 回调 OOG 被 cap 住，履约照常
        assertEq(vrf.randomnessOf(id), vrf.mockRnd());
    }

    // ---------------------------------------------------------------
    // _storeRandomness 直接写入路径
    // ---------------------------------------------------------------

    function test_StoreRawPath() public {
        uint256 id = _paidRequest();
        bytes32 rnd = bytes32(uint256(0x1234));
        vm.expectEmit(true, false, false, true, address(vrf));
        emit HoodVRF.Fulfilled(id, 42, rnd, address(this));
        vrf.storeRaw(id, 42, rnd);
        assertEq(vrf.randomnessOf(id), rnd);
        (,,,, bool fin) = vrf.getRequest(id);
        assertEq(fin, true);
        vm.expectRevert(HoodVRF.AlreadyFulfilled.selector);
        vrf.fulfill(id, SIG_X, SIG_Y);
        // 重投走已存随机数
        vrf.retryCallback(id);
        assertEq(consumer.lastRnd(), rnd);
    }

    // ---------------------------------------------------------------
    // admin
    // ---------------------------------------------------------------

    function test_AdminTwoStepTransfer() public {
        vm.expectEmit(true, true, false, false, address(vrf));
        emit HoodVRF.AdminTransferStarted(address(this), alice);
        vrf.transferAdmin(alice);
        assertEq(vrf.pendingAdmin(), alice);
        assertEq(vrf.admin(), address(this), "not yet");
        vm.prank(bob);
        vm.expectRevert(HoodVRF.NotPendingAdmin.selector);
        vrf.acceptAdmin();
        vm.expectEmit(true, true, false, false, address(vrf));
        emit HoodVRF.AdminTransferred(address(this), alice);
        vm.prank(alice);
        vrf.acceptAdmin();
        assertEq(vrf.admin(), alice);
        assertEq(vrf.pendingAdmin(), address(0));
        vm.expectRevert(HoodVRF.NotAdmin.selector);
        vrf.setFee(1); // 旧 admin 已失效
    }

    function test_OnlyAdminGuards() public {
        vm.startPrank(alice);
        vm.expectRevert(HoodVRF.NotAdmin.selector);
        vrf.setFee(1);
        vm.expectRevert(HoodVRF.NotAdmin.selector);
        vrf.setFulfillReward(1);
        vm.expectRevert(HoodVRF.NotAdmin.selector);
        vrf.setFreeWhitelist(alice, true);
        vm.expectRevert(HoodVRF.NotAdmin.selector);
        vrf.setFallbackMode(true);
        vm.expectRevert(HoodVRF.NotAdmin.selector);
        vrf.withdrawFees();
        vm.expectRevert(HoodVRF.NotAdmin.selector);
        vrf.transferAdmin(alice);
        vm.stopPrank();
    }

    function test_WithdrawFees() public {
        _paidRequest();
        _paidRequest();
        assertEq(vrf.feeBalance(), 2 * FEE);
        uint256 bal0 = address(this).balance;
        vm.expectEmit(true, false, false, true, address(vrf));
        emit HoodVRF.FeesWithdrawn(address(this), 2 * FEE);
        vrf.withdrawFees();
        assertEq(vrf.feeBalance(), 0);
        assertEq(address(this).balance, bal0 + 2 * FEE);
        vrf.withdrawFees(); // 0 也允许
    }

    function test_SetParamsEmit() public {
        vm.expectEmit(false, false, false, true, address(vrf));
        emit HoodVRF.FeeSet(0.001 ether);
        vrf.setFee(0.001 ether);
        assertEq(vrf.fee(), 0.001 ether);
        vm.expectEmit(false, false, false, true, address(vrf));
        emit HoodVRF.RewardSet(0.001 ether);
        vrf.setFulfillReward(0.001 ether);
        assertEq(vrf.fulfillReward(), 0.001 ether);
        vm.expectEmit(false, false, false, true, address(vrf));
        emit HoodVRF.CallbackGasSet(500_000);
        vrf.setCallbackGas(500_000);
        assertEq(vrf.callbackGas(), 500_000);
        // 新费用对后续请求生效
        vm.prank(alice);
        vrf.request{value: 0.001 ether}();
        assertEq(vrf.feeBalance(), 0.001 ether);
    }

    // ---------------------------------------------------------------
    // 降级开关
    // ---------------------------------------------------------------

    function test_FallbackMode() public {
        vm.expectEmit(false, false, false, true, address(vrf));
        emit HoodVRF.FallbackSet(true);
        vrf.setFallbackMode(true);
        assertTrue(vrf.fallbackMode());
        vm.expectEmit(true, true, false, true, address(vrf));
        emit HoodVRF.Requested(1, alice, vrf.roundAtTime(uint64(block.timestamp) + 60), true, true);
        vm.prank(alice);
        vrf.request{value: FEE}(); // 降级模式下照常记录
        vrf.setFallbackMode(false);
        assertFalse(vrf.fallbackMode());
    }

    // ---------------------------------------------------------------
    // 本地可验证的密码学组件（sha256 / modexp 预编译）
    // ---------------------------------------------------------------

    /// @dev hash_to_field 对拍 noble/curves 参考值（round 1000000 的消息）
    function test_HashToFieldMatchesNoble() public view {
        bytes32 m = sha256(abi.encodePacked(uint64(1000000)));
        assertEq(m, 0xce59b701970051bef0d7efdc1a4196c49ce1bbaaf9c5403626ad7adcc41737e7, "msg");
        (bytes memory u0, bytes memory u1) = expo.hashToField2(m);
        assertEq(
            keccak256(u0),
            keccak256(hex"16468f66eb172d70cfafac794eddcd7a34c20a0f1509693fbd5e08dc01e5a7676e010f194278e2dc5bb159fdacd30c9d")
        );
        assertEq(
            keccak256(u1),
            keccak256(hex"0923cb3c137f776f1a4d1434af4d0d92e90e02940ba28612e87569548e64ab786ef8cc8b970c3cd1c96a19d070eff3b6")
        );
    }

    /// @dev 曲线上校验：真实 σ 通过；篡改/越界/无穷远拒绝
    function test_OnCurveCheck() public view {
        assertTrue(expo.isOnCurve(SIG_X, SIG_Y), "real sig on curve");
        bytes memory badY = abi.encodePacked(SIG_Y);
        badY[47] = bytes1(uint8(uint8(badY[47]) + 1)); // y+1
        assertFalse(expo.isOnCurve(SIG_X, badY), "tampered y");
        assertFalse(expo.isOnCurve(SIG_Y, SIG_X), "swapped");
        assertFalse(expo.isOnCurve(new bytes(48), new bytes(48)), "infinity");
        // 坐标 = p 本身（越界）
        assertFalse(
            expo.isOnCurve(
                hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab", SIG_Y
            ),
            "x >= p"
        );
    }

    /// @dev 压缩编码与 drand 官方输出逐字节一致 → keccak256 即链下可复算的随机数
    function test_CompressMatchesDrand() public view {
        bytes memory c = expo.compress(SIG_X, SIG_Y);
        assertEq(keccak256(c), keccak256(SIG_COMPRESSED), "compressed bytes match drand");
        assertEq(keccak256(c), RND1, "rnd = keccak256(compressed)");
    }
}
