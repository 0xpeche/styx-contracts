// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "../interfaces/IERC20.sol";
import {SafeERC20} from "../libs/SafeERC20.sol";
import {IUniswapPair} from "../interfaces/adapters/IUniswapPair.sol";
import {IUniswapFactory} from "../interfaces/adapters/IUniswapFactory.sol";
import {IWETH} from "../interfaces/IWETH.sol";

contract UniswapV2Adapter {
    using SafeERC20 for IERC20;

    address public immutable factory;
    uint256 internal constant FEE_DENOMINATOR = 1e3;
    uint256 public immutable feeCompliment;
    address internal immutable WETH9;

    constructor(address _factory, uint _fee, address weth) {
        feeCompliment = FEE_DENOMINATOR - _fee;
        factory = _factory;
        WETH9 = weth;
    }

    receive() external payable {}

    function safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, "STE");
    }

    function getAmountOut(
        uint amountIn,
        uint reserveIn,
        uint reserveOut
    ) internal view returns (uint amountOut) {
        uint256 amountInWithFee = amountIn * feeCompliment;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * FEE_DENOMINATOR + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function getQuote(
        uint amountIn,
        address tokenIn,
        address tokenOut
    ) public view returns (uint amountOut) {
        if (tokenIn == tokenOut || amountIn == 0) {
            return 0;
        }
        address pair = IUniswapFactory(factory).getPair(tokenIn, tokenOut);
        if (pair == address(0)) {
            return 0;
        }
        (uint256 r0, uint256 r1, ) = IUniswapPair(pair).getReserves();
        (uint256 reserveIn, uint256 reserveOut) = tokenIn < tokenOut
            ? (r0, r1)
            : (r1, r0);
        if (reserveIn > 0 && reserveOut > 0) {
            amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
        }
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address to
    ) public returns (uint actualAmountOut) {
        if (tokenOut != WETH9) {
            uint startBal = IERC20(tokenOut).balanceOf(to);
            address pair = IUniswapFactory(factory).getPair(tokenIn, tokenOut);
            (uint256 amount0Out, uint256 amount1Out) = (tokenIn < tokenOut)
                ? (uint256(0), amountOut)
                : (amountOut, uint256(0));
            IERC20(tokenIn).safeTransfer(pair, amountIn);
            IUniswapPair(pair).swap(amount0Out, amount1Out, to, new bytes(0));
            uint postBal = IERC20(tokenOut).balanceOf(to);
            return postBal - startBal;
        } else {
            uint startBal = IERC20(tokenOut).balanceOf(address(this));
            address pair = IUniswapFactory(factory).getPair(tokenIn, tokenOut);
            (uint256 amount0Out, uint256 amount1Out) = (tokenIn < tokenOut)
                ? (uint256(0), amountOut)
                : (amountOut, uint256(0));
            IERC20(tokenIn).safeTransfer(pair, amountIn);
            IUniswapPair(pair).swap(
                amount0Out,
                amount1Out,
                address(this),
                new bytes(0)
            );
            uint postBal = IERC20(tokenOut).balanceOf(address(this));
            actualAmountOut = postBal - startBal;
            IWETH(WETH9).withdraw(actualAmountOut);
            safeTransferETH(to, actualAmountOut);
        }
    }
}
