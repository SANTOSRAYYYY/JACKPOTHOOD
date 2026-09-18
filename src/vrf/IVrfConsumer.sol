// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice VRF 回调接口：consumer 实现它以接收随机数
/// @dev 回调有 gas 上限（见 HoodVRF.CALLBACK_GAS）；失败不阻断履约，可经 retryCallback 重投
interface IVrfConsumer {
    /// @param id HoodVRF 请求 id
    /// @param rnd keccak256(drand 签名压缩编码) 派生的随机数
    function onRandom(uint256 id, bytes32 rnd) external;
}
