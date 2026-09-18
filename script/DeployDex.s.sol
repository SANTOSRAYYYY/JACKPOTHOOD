// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {JHWETH9} from "../src/dex/JHWETH9.sol";
import {JHPair} from "../src/dex/JHPair.sol";
import {JHRouter} from "../src/dex/JHRouter.sol";


/// @notice 在 Robinhood Chain 测试网部署测试用 AMM（WETH + JACKPOTHOOD/WETH 交易对 + Router），
///         并注入流动性，使回购环节可以走真实 DEX 市价兑换。
interface IERC20Approval {
    function approve(address spender, uint256 amount) external returns (bool);
}

contract DeployDex is Script {
    // 已部署的 JACKPOTHOOD 演示代币与 WETH（复用）
    address constant TOKEN = 0x61F2B7B38712205bab1a62F0b7400E015BAF5E19;
    address constant WETH = 0x9eB818e23E02f23dfD7e6b34f26A5E5Ebd698B99;

    function run() external returns (address weth, address pair, address router) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 liquidityEth = 0.006 ether;      // ETH 侧流动性
        uint256 liquidityTokens = 60_000 ether;  // 代币侧流动性（演示定价：1 ETH ≈ 1000 万 JACKPOTHOOD）

        vm.startBroadcast(pk);

        // 部署顺序：Pair → Router → Pair.setRouter（解除循环依赖），WETH 复用
        weth = WETH;
        JHPair p = new JHPair(TOKEN, weth, weth); // quoteToken = WETH：卖出税只落在 WETH 输出侧
        pair = address(p);
        JHRouter r = new JHRouter(TOKEN, weth, pair);
        router = address(r);
        p.setRouter(router);

        // 卖出税 10%：仅作用于卖出方向（WETH 输出 = 卖出 JACKPOTHOOD），回购买入免税
        p.setSellTaxBps(1000);
        p.setFeeTo(msg.sender); // 测试网税先归集到部署者，主网指向质押奖励池

        // 注入流动性：JACKPOTHOOD/ETH
        IERC20Approval(TOKEN).approve(router, liquidityTokens);
        r.addLiquidityETH{value: liquidityEth}(
            TOKEN,
            liquidityTokens,
            0, // amountTokenMin
            0, // amountETHMin
            msg.sender,
            block.timestamp + 600
        );

        vm.stopBroadcast();

        console2.log("WETH  :", weth);
        console2.log("Pair  :", pair);
        console2.log("Router:", router);
    }
}
