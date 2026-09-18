// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {JackpotHood} from "../src/JackpotHood.sol";
import {JackpotHoodPerks} from "../src/JackpotHoodPerks.sol";

/// @notice V3.7 部署：核心（无 JPH）+ Perks（JPH 质押免费票）+ 桥接
contract Deploy is Script {
    function run() external returns (JackpotHood jackpot, JackpotHoodPerks perks) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address jphToken = vm.envOr("JPH_TOKEN", address(0x61F2B7B38712205bab1a62F0b7400E015BAF5E19));
        uint256 seedPool = vm.envOr("SEED_POOL_WEI", uint256(0));
        uint256 roundSec = vm.envOr("ROUND_SECONDS", uint256(86400));
        uint64 lockMin = uint64(vm.envOr("LOCK_MINUTES", uint256(15)));
        bool anchorFirst = vm.envOr("ANCHOR_FIRST_UTC", true);

        vm.startBroadcast(pk);

        jackpot = new JackpotHood(roundSec, lockMin * 60, anchorFirst);
        console2.log("JackpotHood V3.7:", address(jackpot));

        perks = new JackpotHoodPerks(jphToken, address(jackpot));
        console2.log("JackpotHoodPerks:", address(perks));

        jackpot.setPerkContract(address(perks)); // 桥：Perks 可代用户发免费票

        if (seedPool > 0) {
            jackpot.injectPrizeEth{value: seedPool}();
            console2.log("Seed:", seedPool);
        }

        vm.stopBroadcast();
    }
}
