// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {HoodVRF} from "../src/vrf/HoodVRF.sol";

/// @title DeployVRF —— 部署 HoodVRF（drand quicknet 链上验签 VRF）
/// @dev 运行：
///        forge script script/DeployVRF.s.sol --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast
///      env：
///        DEPLOYER_PRIVATE_KEY  广播私钥（必填，绝不打印）
///        VRF_PK_G2             可选，默认 quicknet 实测值；自定义链时传非压缩 G2 公钥
///                              192 字节 hex（x_c0||x_c1||y_c0||y_c1 各 48B）
///        VRF_FEE               可选，默认 0.0002 ether
///        FULFILL_REWARD        可选，默认 0.00005 ether
///
///      VRF_PK_G2 生成方法（quicknet；勿手算，用参考实现解压）：
///        1) curl https://api.drand.sh/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971/info
///           → public_key 为 96 字节压缩 G2
///        2) 用 noble/curves 解压并拼接（注意压缩格式 c1 在前、EIP-2537 需要 c0 在前）：
///           const { bls12_381 } = require('noble-curves/bls12-381.js');
///           const p = bls12_381.G2.ProjectivePoint.fromHex('<96B压缩公钥>').toAffine();
///           // VRF_PK_G2 = x.c0 || x.c1 || y.c0 || y.c1（各 48 字节大端，hex 拼接）
///        3) 合法性验证（在曲线 + 在子群）：部署后运行 script/VerifyDrand.s.sol 用真实签名
///           走完整验签；pairing 预编译会对错误子群直接报错，等于隐式校验。
///      2026-09-18 quicknet 实测值（可直接用）：
///        VRF_PK_G2 = 0d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a
///                    03cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d106451
///                    0e5db2b6bfbb01c867749cadffca88b36c24f3012ba09fc4d3022c5c37dce0f977d3adb5d183c7477c442b1f04515273
///                    01a714f2edb74119a2f2b0d5a7c75ba902d163700a61bc224ededd8e63aef7be1aaf8e93d7a9718b047ccddb3eb5d68b
contract DeployVRF is Script {
    /// @dev quicknet 实测非压缩公钥（2026-09-18 /info 解压，默认即可直接用）
    bytes constant QUICKNET_PK = hex"0d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a"
        hex"03cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d106451"
        hex"0e5db2b6bfbb01c867749cadffca88b36c24f3012ba09fc4d3022c5c37dce0f977d3adb5d183c7477c442b1f04515273"
        hex"01a714f2edb74119a2f2b0d5a7c75ba902d163700a61bc224ededd8e63aef7be1aaf8e93d7a9718b047ccddb3eb5d68b";

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        bytes memory pkG2 = vm.envOr("VRF_PK_G2", QUICKNET_PK);
        uint256 fee = vm.envOr("VRF_FEE", uint256(0.0002 ether));
        uint256 reward = vm.envOr("FULFILL_REWARD", uint256(0.00005 ether));
        require(pkG2.length == 192, "VRF_PK_G2 must be 192 bytes");

        vm.startBroadcast(deployerKey);
        HoodVRF vrf = new HoodVRF(pkG2, fee, reward);
        vm.stopBroadcast();

        console.log("HoodVRF:", address(vrf));
        console.log("admin:", vrf.admin());
        console.log("fee:", vrf.fee());
        console.log("fulfillReward:", vrf.fulfillReward());
    }
}
