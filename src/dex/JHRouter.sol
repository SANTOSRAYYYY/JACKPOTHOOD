// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {JHPair} from "./JHPair.sol";
import {JHWETH9} from "./JHWETH9.sol";

interface IERC20Transfer {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice 测试网用最小 Router（接口与 Uniswap V2 Router02 对齐：swapExactETHForTokens / swapExactTokensForETH / getAmountsOut）
/// @dev 单交易对（JACKPOTHOOD/WETH），回购走买入方向（免税），用户卖出走卖出方向（税后报价）
contract JHRouter {
    address public immutable jackpotToken;
    JHWETH9 public immutable weth;
    JHPair public immutable pair;

    event AddLiquidityETH(address indexed provider, uint256 amountToken, uint256 amountETH);
    event SwapETHForTokens(address indexed caller, address indexed to, uint256 amountIn, uint256 amountOut);
    event SwapTokensForETH(address indexed caller, address indexed to, uint256 amountIn, uint256 amountOut);

    // 接收 WETH.withdraw 返还的 ETH（卖出路径解包用）
    receive() external payable {}

    constructor(address jackpotToken_, address weth_, address pair_) {
        jackpotToken = jackpotToken_;
        weth = JHWETH9(payable(weth_));
        pair = JHPair(pair_);
        require(
            pair.token0() == jackpotToken_ && pair.token1() == weth_ ||
            pair.token0() == weth_ && pair.token1() == jackpotToken_,
            "ROUTER: wrong pair tokens"
        );
    }

    /// @notice 注入 ETH+JACKPOTHOOD 流动性
    function addLiquidityETH(
        address token,
        uint256 amountToken,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountTokenAdded, uint256 amountETHAdded) {
        require(token == jackpotToken, "ROUTER: wrong token");
        require(deadline >= block.timestamp, "ROUTER: expired");
        require(msg.value >= amountETHMin && amountToken >= amountTokenMin, "ROUTER: below min");
        require(to != address(0), "ROUTER: zero to");

        require(IERC20Transfer(jackpotToken).transferFrom(msg.sender, address(pair), amountToken), "ROUTER: token transfer failed");
        weth.deposit{value: msg.value}();
        weth.transfer(address(pair), msg.value);
        // pair 按 token0/token1 顺序记账：按实际代币顺序传入数量
        bool token0IsJackpot = pair.token0() == jackpotToken;
        pair.mint(token0IsJackpot ? amountToken : msg.value, token0IsJackpot ? msg.value : amountToken);

        emit AddLiquidityETH(msg.sender, amountToken, msg.value);
        return (amountToken, msg.value);
    }

    /// @notice 用 ETH 兑换 JACKPOTHOOD（真实市价 + 滑点保护）
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "ROUTER: expired");
        require(path.length == 2 && path[0] == address(weth) && path[1] == jackpotToken, "ROUTER: invalid path");
        require(to != address(0), "ROUTER: zero to");

        uint256 out = _quote(msg.value, address(weth));
        require(out >= amountOutMin, "ROUTER: slippage");

        weth.deposit{value: msg.value}();
        weth.transfer(address(pair), msg.value);

        bool token0IsJackpot = pair.token0() == jackpotToken;
        pair.swap(token0IsJackpot ? out : 0, token0IsJackpot ? 0 : out, to);

        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = out;
        emit SwapETHForTokens(msg.sender, to, msg.value, out);
    }

    /// @notice 用 JACKPOTHOOD 兑换 ETH（卖出方向：报价与滑点保护均已扣除卖出税）
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "ROUTER: expired");
        require(path.length == 2 && path[0] == jackpotToken && path[1] == address(weth), "ROUTER: invalid path");
        require(to != address(0), "ROUTER: zero to");

        uint256 outGross = _quote(amountIn, jackpotToken);
        uint256 outNet = _netSell(outGross);
        require(outNet >= amountOutMin, "ROUTER: slippage");

        require(IERC20Transfer(jackpotToken).transferFrom(msg.sender, address(pair), amountIn), "ROUTER: token transfer failed");

        bool token0IsJackpot = pair.token0() == jackpotToken;
        // pair 把 WETH 净额转给本合约，税直接转 feeTo；再解包成 ETH 给用户
        pair.swap(token0IsJackpot ? 0 : outGross, token0IsJackpot ? outGross : 0, address(this));
        weth.withdraw(outNet);
        (bool ok, ) = to.call{value: outNet}("");
        require(ok, "ROUTER: ETH transfer failed");

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = outNet;
        emit SwapTokensForETH(msg.sender, to, amountIn, outNet);
    }

    /// @notice 模拟报价：给定数量，返回可换得的数量（卖出方向已扣除卖出税）
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        require(path.length == 2, "ROUTER: invalid path");
        uint256 out = path[0] == address(weth)
            ? _quote(amountIn, address(weth))
            : _netSell(_quote(amountIn, jackpotToken));
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }

    /// @dev 卖出方向税后实收：out * (1 - sellTaxBps/10000)
    function _netSell(uint256 outGross) internal view returns (uint256) {
        uint256 bps = pair.sellTaxBps();
        if (bps == 0 || pair.feeTo() == address(0)) return outGross;
        return outGross - outGross * bps / 10000;
    }

    /// @dev 无手续费常数乘积报价：out = rOut * in / (rIn + in)
    function _quote(uint256 amountIn, address tokenIn) internal view returns (uint256) {
        (uint256 r0, uint256 r1) = pair.getReserves();
        bool inIsToken0 = tokenIn == pair.token0();
        uint256 rIn = inIsToken0 ? r0 : r1;
        uint256 rOut = inIsToken0 ? r1 : r0;
        require(amountIn > 0 && rIn > 0 && rOut > 0, "ROUTER: no liquidity");
        return amountIn * rOut / (rIn + amountIn);
    }
}
