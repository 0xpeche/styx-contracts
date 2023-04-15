// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

interface IAdapter {
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address to
    ) external returns (uint);

    function getQuote(
        uint256 amountIn,
        address tokenIn,
        address tokenOut
    ) external view returns (uint);
}
