// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {JackpotHoodPerks} from "../src/JackpotHoodPerks.sol";
import {PerkRouter} from "../src/presale/PerkRouter.sol";
import {JackpotHoodPresale} from "../src/presale/JackpotHoodPresale.sol";
import {GenesisNFT2} from "../src/presale/GenesisNFT2.sol";

interface ICorePerkSlot {
    function setPerkContract(address c) external;
}

interface IERC20Fund {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice 社区轮预售部署：PerkRouter（占据 core.perkContract 单槽）→ Presale → GenesisNFT2 → 接线。
/// @dev env（私钥只从 env 读，不写死）：
///      DEPLOYER_PRIVATE_KEY  必填；deployer 必须是 CORE 的 admin（要调 setPerkContract）
///      JPH_TOKEN             必填，JACKPOTHOOD 代币地址
///      CORE                  默认 0x9fCB876196586B828A5c42e4287fFCB3BAACc806
///      PRESALE_DURATION      秒，默认 259200（3 天）；startTime = 广播时刻
///      LIQUIDITY_TO / TREASURY_TO / MARKETING_TO   默认 deployer
///      PRESALE_JPH_FUND      充给预售合约的 JPH（wei），默认 0 = 不充
///      DEPLOY_PERKS          默认 false；true 时顺手部署新 JackpotHoodPerks(jph, router) 并加白
///      例：forge script script/DeployPresale.s.sol --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast
contract DeployPresale is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address jphToken = vm.envAddress("JPH_TOKEN");
        address core = vm.envOr("CORE", address(0x9fCB876196586B828A5c42e4287fFCB3BAACc806));
        uint64 duration = uint64(vm.envOr("PRESALE_DURATION", uint256(3 days)));
        address liquidityTo = vm.envOr("LIQUIDITY_TO", deployer);
        address treasuryTo = vm.envOr("TREASURY_TO", deployer);
        address marketingTo = vm.envOr("MARKETING_TO", deployer);
        uint256 fund = vm.envOr("PRESALE_JPH_FUND", uint256(0));
        bool deployPerks = vm.envOr("DEPLOY_PERKS", false);

        vm.startBroadcast(pk);

        PerkRouter router = new PerkRouter(core);
        JackpotHoodPresale presale = new JackpotHoodPresale(
            jphToken, address(router), uint64(block.timestamp), duration,
            liquidityTo, treasuryTo, marketingTo, core
        );
        GenesisNFT2 nft = new GenesisNFT2(address(presale));

        ICorePerkSlot(core).setPerkContract(address(router)); // router 占据唯一 perk 槽位
        router.setAllowed(address(presale), true);

        address perks;
        if (deployPerks) {
            perks = address(new JackpotHoodPerks(jphToken, address(router)));
            router.setAllowed(perks, true);
        }

        if (fund > 0) {
            require(IERC20Fund(jphToken).transfer(address(presale), fund), "JPH fund transfer failed");
        }

        vm.stopBroadcast();

        console2.log("PerkRouter       :", address(router));
        console2.log("Presale          :", address(presale));
        console2.log("GenesisNFT2      :", address(nft));
        if (deployPerks) console2.log("Perks (new)      :", perks);
        console2.log("startTime        :", presale.startTime());
        console2.log("endTime          :", presale.endTime());
        console2.log("JPH funded       :", fund);
        console2.log("deployer         :", deployer);
    }
}
