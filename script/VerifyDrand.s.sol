// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {HoodVRF} from "../src/vrf/HoodVRF.sol";
import {IVrfConsumer} from "../src/vrf/IVrfConsumer.sol";

/// @dev 脚本内 consumer（fork 模拟不允许对无代码地址带 calldata 调用，回调目标必须是真合约）
contract ScriptConsumer is IVrfConsumer {
    uint256 public lastId;
    bytes32 public lastRnd;

    function onRandom(uint256 id, bytes32 rnd) external {
        lastId = id;
        lastRnd = rnd;
    }
}

/// @title VerifyDrand —— 用真实 drand quicknet 向量在 fork 的 Robinhood 测试网上实测链上验签
/// @dev 运行（本地 anvil 没有 EIP-2537 预编译，必须 fork 测试网）：
///        forge script script/VerifyDrand.s.sol:VerifyDrand --fork-url https://rpc.testnet.chain.robinhood.com -vv
///      新向量可用 env 覆盖：DRAND_ROUND / DRAND_SIG_X / DRAND_SIG_Y / DRAND_PK_G2 / DRAND_EXPECTED_RND
///      （48 字节坐标 hex；rnd = keccak256(σ 压缩编码)）。
///
///      内置向量（2026-09-18 抓自 api.drand.sh quicknet，链哈希 52db9ba7…c84e971）：
///        GET …/public/1000000 →
///          {"round":1000000,
///           "randomness":"b22aad4794f7451896f7a371aa46106fd84d919f3f569acd5b2fddf1d1440af3",  // = sha256(sig)
///           "signature":"83ad29e4c409f9470fc2ef02f90214df49e02b441a1a241a82d622d9f608ef98fd8b11a029f1bee9d9e83b45088abe72"}
///        σ 解压（noble/curves G1.fromHex → toAffine）：
///          x = 03ad29e4…（压缩首字节 0x83 去掉 0x80 标志位）；y = 01776ff7…
///        keccak256(压缩σ) = 0x32b119d66526cbc890429fae95c9083a216660ddc37344929f6937832302ad0a
///      公钥：GET …/info → "public_key":"83cf0f28…"（96B 压缩 G2），解压为 192B 非压缩
///      （注意：压缩格式 c1 在前且首字节带标志位；EIP-2537 编码是 c0 在前）。
contract VerifyDrand is Script {
    // quicknet 公钥（非压缩 G2，192 字节 x_c0||x_c1||y_c0||y_c1）
    bytes constant DEFAULT_PK = hex"0d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a"
        hex"03cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d106451"
        hex"0e5db2b6bfbb01c867749cadffca88b36c24f3012ba09fc4d3022c5c37dce0f977d3adb5d183c7477c442b1f04515273"
        hex"01a714f2edb74119a2f2b0d5a7c75ba902d163700a61bc224ededd8e63aef7be1aaf8e93d7a9718b047ccddb3eb5d68b";
    // 向量 1：round 1000000
    bytes constant SIG1_X = hex"03ad29e4c409f9470fc2ef02f90214df49e02b441a1a241a82d622d9f608ef98fd8b11a029f1bee9d9e83b45088abe72";
    bytes constant SIG1_Y = hex"01776ff7408b39c5f6f9fa50746efd7eea17fbb61f2e7b9c849ff0528e5a3deeedd029d0df345199963d75ba93b5a02a";
    bytes32 constant RND1 = 0x32b119d66526cbc890429fae95c9083a216660ddc37344929f6937832302ad0a;
    // 向量 2：round 32290338（2026-09-18 /public/latest 实测，signature = 930ef860…c9e3）
    bytes constant SIG2_X = hex"130ef8601c8d22ef3b741ce5e00b1b12d2387a07cc0275ecad111aa2a38395929e8d960d5df50e6fb8f0d88d3631c9e3";
    bytes constant SIG2_Y = hex"0992434cb76dabddcd4b2d5d99cd095781a030e471d96cb90312db03a7388a6f7f3b87a2f694fcf5214d7a01204b3a35";
    bytes32 constant RND2 = 0xa31b471f9f268443ec7385c0d71debbca7a2ba57e0457374423f8116aa8027a6;

    // round 1000000 的 H(m) = hashToG1(sha256(round)) 期望编码（noble/curves 参考实现对拍值）
    bytes constant H1 = hex"000000000000000000000000000000000533fbfd488393ea4e2fe335e2b768d112934e2477f335d4360c1ed8b96907740b49a16947fe30f7fc76433c70d0940b"
        hex"0000000000000000000000000000000005cf7470bbc5e814f87f58627718949c2ba851c3f1e29220da68829d3502953f3b557c97d72fc76caf341ea244730002";

    function run() external {
        address keeper = vm.addr(0xA11CE); // 脚本地址不允许 address(this)，用固定测试地址当请求方/履约方
        vm.deal(keeper, 1 ether);
        HoodVRF vrf = new HoodVRF(DEFAULT_PK, 0.0002 ether, 0.00005 ether);
        console.log("HoodVRF deployed:", address(vrf));

        // 1) hash_to_G1 与 noble 参考实现对拍（验证 expand_message_xmd + hash_to_field + MAP 链）
        bytes memory h = vrf.hashToG1(sha256(abi.encodePacked(uint64(1000000))));
        require(keccak256(h) == keccak256(H1), "HASH_TO_G1 MISMATCH");
        console.log("hashToG1 matches noble reference");

        // 2) 两组内置真实向量完整验签（on-curve + hash-to-curve + 配对）
        require(vrf.verifyDrandSignature(1000000, SIG1_X, SIG1_Y) == RND1, "SIG1 VERIFY FAIL");
        require(vrf.verifyDrandSignature(32290338, SIG2_X, SIG2_Y) == RND2, "SIG2 VERIFY FAIL");
        console.log("two real drand vectors verified");

        // 3) env 覆盖的新向量（如有）
        uint64 round = uint64(vm.envOr("DRAND_ROUND", uint256(1000000)));
        bytes memory sigX = vm.envOr("DRAND_SIG_X", SIG1_X);
        bytes memory sigY = vm.envOr("DRAND_SIG_Y", SIG1_Y);
        bytes32 expectedRnd = vm.envOr("DRAND_EXPECTED_RND", RND1);
        if (round != 1000000 || keccak256(sigX) != keccak256(SIG1_X)) {
            bytes memory pkEnv = vm.envOr("DRAND_PK_G2", DEFAULT_PK);
            HoodVRF vrf2 = new HoodVRF(pkEnv, 0.0002 ether, 0.00005 ether);
            require(vrf2.verifyDrandSignature(round, sigX, sigY) == expectedRnd, "ENV SIG VERIFY FAIL");
            console.log("env vector verified, round:", round);
            vrf = vrf2;
        }

        // 4) 端到端：warp 回该轮产出前 60s 发起请求，快进到产出时刻履约，量 gas
        ScriptConsumer consumer = new ScriptConsumer();
        uint64 tRound = vrf.timeOfRound(round);
        vm.warp(tRound - 60); // request 锁定 now+60 所在轮 = round
        vm.prank(keeper);
        uint256 id = vrf.requestFor{value: 0.0002 ether}(address(consumer));
        (, uint64 lockedRound,, bool paid,) = vrf.getRequest(id);
        require(lockedRound == round && paid, "REQUEST ROUND MISMATCH");
        vm.warp(tRound);
        uint256 g0 = gasleft();
        vm.prank(keeper);
        vrf.fulfill(id, sigX, sigY);
        console.log("fulfill gas used:", g0 - gasleft());
        require(vrf.randomnessOf(id) == expectedRnd, "FULFILL RND MISMATCH");
        require(consumer.lastRnd() == expectedRnd && consumer.lastId() == id, "CALLBACK NOT DELIVERED");

        console.log("DRAND VERIFY OK");
    }
}
