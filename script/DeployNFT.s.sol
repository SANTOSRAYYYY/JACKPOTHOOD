// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {JackpotHoodNFT, IERC20Quota} from "../src/JackpotHoodNFT.sol";


/// @notice 部署创世 NFT（铸造式代币产出凭证）
/// @dev 环境变量：
///      DEPLOYER_PRIVATE_KEY  部署私钥（必填）
///      NFT_TOKEN            配额代币地址（默认测试网 JACKPOTHOOD mock）
///      NFT_QUOTA            每个 NFT 配额（默认 1000 JPH）
///      NFT_PRICE            铸造价 wei（默认 0.1 ETH）
///      NFT_SUPPLY           总量（默认 1000）
///      NFT_FUND_QUOTA       是否注入全额配额代币（默认 true：1000×配额 锁定进合约）
interface IERC20Approval {
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract DeployNFT is Script {
    function run() external returns (JackpotHoodNFT nft) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address token = vm.envOr("NFT_TOKEN", address(0x61F2B7B38712205bab1a62F0b7400E015BAF5E19));
        uint256 quota = vm.envOr("NFT_QUOTA", uint256(1000 ether));
        uint256 price = vm.envOr("NFT_PRICE", uint256(0.1 ether));
        uint256 supply = vm.envOr("NFT_SUPPLY", uint256(1000));
        bool fundQuota = vm.envOr("NFT_FUND_QUOTA", true);

        vm.startBroadcast(pk);

        nft = new JackpotHoodNFT(IERC20Quota(token), quota, price, supply);
        console2.log("JackpotHoodNFT deployed:", address(nft));

        if (fundQuota) {
            IERC20Approval(token).approve(address(nft), supply * quota);
            nft.depositQuotaTokens(supply * quota);
            console2.log("Quota funded:", supply * quota);
        }

        // 默认铸造关闭；确认配额锁定后再开启
        nft.setMintParams(price, quota, true);
        console2.log("Mint opened, price:", price);

        vm.stopBroadcast();
    }
}
