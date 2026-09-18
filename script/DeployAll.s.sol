// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {JackpotHood} from "../src/JackpotHood.sol";
import {JackpotHoodPerks} from "../src/JackpotHoodPerks.sol";
import {JackpotHoodToken} from "../src/mocks/JackpotHoodToken.sol";
import {JackpotHoodNFT, IERC20Quota} from "../src/JackpotHoodNFT.sol";
import {JHPair} from "../src/dex/JHPair.sol";
import {JHRouter} from "../src/dex/JHRouter.sol";

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice V4 全套一键部署（合约拆分版）：
///         新 JACKPOTHOOD 代币 → 创世 NFT（配额锁定） → JackpotHood core（无 JPH）
///         + Perks（JPH 质押免费票，桥接 core）→ DEX pair/router + 流动性。
contract DeployAll is Script {
    address public jph;
    address public nft;
    address public jackpot;
    address public perks;
    address public pair;
    address public router;
    address public weth;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);
        _deployTokenNft(deployer);
        _deployCore();
        _deployDex(deployer);
        vm.stopBroadcast();
        console2.log("JPH token     :", jph);
        console2.log("NFT           :", nft);
        console2.log("JackpotHood   :", jackpot);
        console2.log("Perks         :", perks);
        console2.log("DEX pair      :", pair);
        console2.log("DEX router    :", router);
        console2.log("WETH          :", weth);
        console2.log("deployer      :", deployer);
    }

    function _deployTokenNft(address deployer) internal {
        uint256 jphSupply = vm.envOr("JPH_SUPPLY", uint256(2_000_000 ether));
        uint256 nftSupply = vm.envOr("NFT_SUPPLY", uint256(1000));
        uint256 nftQuota = vm.envOr("NFT_QUOTA", uint256(1000 ether));
        uint256 nftPrice = vm.envOr("NFT_PRICE", uint256(0.1 ether));
        bool nftFund = vm.envOr("NFT_FUND", true);

        JackpotHoodToken t = new JackpotHoodToken(jphSupply);
        jph = address(t);
        JackpotHoodNFT n = new JackpotHoodNFT(IERC20Quota(jph), nftQuota, nftPrice, nftSupply);
        nft = address(n);
        if (nftFund) {
            uint256 quotaTotal = nftSupply * nftQuota;
            IERC20Like(jph).approve(nft, quotaTotal);
            n.depositQuotaTokens(quotaTotal);
            console2.log("NFT quota fund:", quotaTotal);
        }
        n.setMintParams(nftPrice, nftQuota, true);
        console2.log("mintFee collector:", deployer);
    }

    function _deployCore() internal {
        uint256 roundSec = vm.envOr("ROUND_SECONDS", uint256(600));
        uint64 lockMin = uint64(vm.envOr("LOCK_MINUTES", uint256(2)));
        bool anchorFirst = vm.envOr("ANCHOR_FIRST_UTC", true);
        uint256 seedPool = vm.envOr("SEED_POOL_WEI", uint256(0));

        JackpotHood core = new JackpotHood(roundSec, lockMin * 60, anchorFirst);
        jackpot = address(core);
        JackpotHoodPerks perkC = new JackpotHoodPerks(jph, jackpot);
        perks = address(perkC);
        core.setPerkContract(perks);
        if (seedPool > 0) core.injectPrizeEth{value: seedPool}();
    }

    function _deployDex(address deployer) internal {
        weth = vm.envOr("WETH_ADDRESS", address(0x9eB818e23E02f23dfD7e6b34f26A5E5Ebd698B99));
        uint256 liqEth = vm.envOr("LIQ_ETH", uint256(0.006 ether));
        uint256 liqTokens = vm.envOr("LIQ_TOKENS", uint256(60_000 ether));

        JHPair p = new JHPair(jph, weth, weth);
        pair = address(p);
        JHRouter r = new JHRouter(jph, weth, pair);
        router = address(r);
        p.setRouter(router);
        p.setSellTaxBps(1000);
        p.setFeeTo(deployer);
        IERC20Like(jph).approve(router, liqTokens);
        r.addLiquidityETH{value: liqEth}(jph, liqTokens, 0, 0, deployer, block.timestamp + 600);
    }
}
