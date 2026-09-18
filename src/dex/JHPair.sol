// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice 测试网用最小常数乘积 AMM 交易对（x*y=k，Uniswap V2 同款数学）
/// @dev token0/token1 按地址排序；router 部署后由部署者一次性 setRouter；仅 Router 可调用 mint/swap
///      卖出税：仅对 quoteToken（WETH 侧）输出方向按 sellTaxBps 扣税——即「卖出 JACKPOTHOOD 换 ETH」被征税，
///      回购方向（ETH 换 JACKPOTHOOD，JACKPOTHOOD 侧输出）免税，保证 100% 回购进奖池不被侵蚀。
///      quoteToken 由构造参数指定，与代币排序无关，任何代币地址序都保证税只落在卖出方向。
contract JHPair {
    address public router;
    address public immutable token0;
    address public immutable token1;
    address public immutable quoteToken; // 被征税的输出侧代币（WETH 侧，即卖出方向）

    address public owner;       // 参数管理者（部署者）
    address public feeTo;       // 卖出税接收地址（未来指向质押奖励池）
    uint256 public sellTaxBps;  // 卖出税率（基点）：1000 = 10%
    uint256 public constant MAX_TAX_BPS = 2000; // 税率上限 20%

    uint256 public reserve0;
    uint256 public reserve1;

    event Mint(uint256 amount0, uint256 amount1);
    event Swap(address indexed caller, address indexed to, uint256 amount0Out, uint256 amount1Out, uint256 taxOut);
    event TaxParamsUpdated(address feeTo, uint256 sellTaxBps);

    modifier onlyRouter() {
        require(msg.sender == router, "PAIR: only router");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "PAIR: not owner");
        _;
    }

    constructor(address tokenA_, address tokenB_, address quoteToken_) {
        require(tokenA_ != address(0) && tokenB_ != address(0), "PAIR: zero token");
        require(quoteToken_ == tokenA_ || quoteToken_ == tokenB_, "PAIR: bad quote token");
        (token0, token1) = tokenA_ < tokenB_ ? (tokenA_, tokenB_) : (tokenB_, tokenA_);
        quoteToken = quoteToken_;
        owner = msg.sender;
    }

    /// @notice Router 部署后由部署者一次性设置（在设置前 mint/swap 均不可用）
    function setRouter(address router_) external {
        require(router == address(0), "PAIR: router already set");
        require(router_ != address(0), "PAIR: zero router");
        router = router_;
    }

    /// @notice 设置卖出税接收地址（0 = 停收税）
    function setFeeTo(address feeTo_) external onlyOwner {
        feeTo = feeTo_;
        emit TaxParamsUpdated(feeTo, sellTaxBps);
    }

    /// @notice 设置卖出税率（基点，上限 MAX_TAX_BPS）
    function setSellTaxBps(uint256 bps_) external onlyOwner {
        require(bps_ <= MAX_TAX_BPS, "PAIR: tax too high");
        sellTaxBps = bps_;
        emit TaxParamsUpdated(feeTo, sellTaxBps);
    }

    /// @notice 注入流动性（首次自由定价，之后按比例）
    function mint(uint256 amount0, uint256 amount1) external onlyRouter {
        require(amount0 > 0 && amount1 > 0, "PAIR: zero liquidity");
        if (reserve0 == 0 && reserve1 == 0) {
            reserve0 = amount0;
            reserve1 = amount1;
        } else {
            require(amount0 * reserve1 == amount1 * reserve0, "PAIR: ratio mismatch");
            reserve0 += amount0;
            reserve1 += amount1;
        }
        emit Mint(amount0, amount1);
    }

    /// @notice 恒定乘积兑换：Router 先转入 tokenIn，再指定 tokenOut 数量
    /// @dev 卖出税仅作用于 token1 输出方向（JACKPOTHOOD 卖出换 ETH）：
    ///      用户实收 = amount1Out * (1 - tax)，税转 feeTo；储备仍按全额减少，价格连续。
    function swap(uint256 amount0Out, uint256 amount1Out, address to) external onlyRouter {
        require(to != address(0), "PAIR: zero to");
        require(amount0Out > 0 || amount1Out > 0, "PAIR: zero out");
        require(amount0Out < reserve0 && amount1Out < reserve1, "PAIR: insufficient reserves");

        uint256 balance0 = IERC20Min(token0).balanceOf(address(this));
        uint256 balance1 = IERC20Min(token1).balanceOf(address(this));
        // 无手续费 AMM：兑换后乘积不得低于兑换前（x*y >= k）
        require(
            (balance0 - amount0Out) * (balance1 - amount1Out) >= reserve0 * reserve1,
            "PAIR: K"
        );

        uint256 tax = 0;
        if (feeTo != address(0) && sellTaxBps > 0) {
            if (quoteToken == token0 && amount0Out > 0) tax = amount0Out * sellTaxBps / 10000;
            else if (quoteToken == token1 && amount1Out > 0) tax = amount1Out * sellTaxBps / 10000;
        }
        uint256 tax0 = quoteToken == token0 ? tax : 0;
        uint256 tax1 = quoteToken == token1 ? tax : 0;

        if (amount0Out > 0) {
            require(IERC20Min(token0).transfer(to, amount0Out - tax0), "PAIR: transfer0 failed");
            if (tax0 > 0) {
                require(IERC20Min(token0).transfer(feeTo, tax0), "PAIR: tax transfer failed");
            }
        }
        if (amount1Out > 0) {
            require(IERC20Min(token1).transfer(to, amount1Out - tax1), "PAIR: transfer1 failed");
            if (tax1 > 0) {
                require(IERC20Min(token1).transfer(feeTo, tax1), "PAIR: tax transfer failed");
            }
        }
        reserve0 = balance0 - amount0Out;
        reserve1 = balance1 - amount1Out;

        emit Swap(msg.sender, to, amount0Out, amount1Out, tax);
    }

    /// @notice 给定 tokenIn 数量，返回可换出的 tokenOut 数量（含价格冲击）
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256 amountOut) {
        (uint256 rIn, uint256 rOut) = tokenIn == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
        require(amountIn > 0 && rIn > 0 && rOut > 0, "PAIR: no liquidity");
        // 无手续费常数乘积：out = rOut * in / (rIn + in)
        amountOut = amountIn * rOut / (rIn + amountIn);
    }

    function getReserves() external view returns (uint256, uint256) {
        return (reserve0, reserve1);
    }
}
