// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity 0.8.19;

interface IAdapter {
    function name() external view returns (string memory);

    function swapGasEstimate() external view returns (uint256);

    function swap(
        uint256 amountIn,
        uint256 amountOut,
        address fromToken,
        address toToken,
        address to
    ) external returns (uint);

    function query(uint256, address, address) external view returns (uint256);
}
