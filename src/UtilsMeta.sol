// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity 0.8.19;

import {IAdapter} from "./interfaces/IAdapter.sol";

contract StyxUtils {
    function compress(uint256 full) public pure returns (uint64 cint) {
        uint8 bits = mostSignificantBit(full);
        if (bits <= 55) {
            cint = uint64(full) << 8;
        } else {
            bits -= 55;
            cint = (uint64(full >> bits) << 8) + bits;
        }
    }

    function mostSignificantBit(uint256 val) public pure returns (uint8 bit) {
        if (val >= 0x100000000000000000000000000000000) {
            val >>= 128;
            bit += 128;
        }
        if (val >= 0x10000000000000000) {
            val >>= 64;
            bit += 64;
        }
        if (val >= 0x100000000) {
            val >>= 32;
            bit += 32;
        }
        if (val >= 0x10000) {
            val >>= 16;
            bit += 16;
        }
        if (val >= 0x100) {
            val >>= 8;
            bit += 8;
        }
        if (val >= 0x10) {
            val >>= 4;
            bit += 4;
        }
        if (val >= 0x4) {
            val >>= 2;
            bit += 2;
        }
        if (val >= 0x2) bit += 1;
    }

    function getCompactSignature(
        uint8 vRaw,
        bytes32 rRaw,
        bytes32 sRaw
    ) internal pure returns (bytes32 r, bytes32 vs) {
        uint8 v = vRaw - 27; // 27 is 0, 28 is 1
        vs = bytes32(uint256(v) << 255) | sRaw;
        return (rRaw, vs);
    }

    function encodeData(
        uint8 slippageId,
        uint8 adapterId,
        uint16 swapFeeBps,
        uint256 amountOut,
        uint256 amountIn,
        uint24 tokenInIndex,
        uint24 tokenOutIndex,
        address guy,
        uint8 vRaw,
        bytes32 rRaw,
        bytes32 sRaw
    ) public pure returns (bytes memory) {
        bytes memory encoded = new bytes(77);

        (bytes32 r, bytes32 vs) = getCompactSignature(vRaw, rRaw, sRaw);
        uint64 amountOutCint = compress(amountOut);
        uint64 amountInCint = compress(amountIn);

        assembly {
            let packedData := 0
            packedData := or(packedData, shl(192, adapterId))
            packedData := or(packedData, shl(189, slippageId))
            packedData := or(packedData, shl(176, swapFeeBps))
            packedData := or(packedData, shl(112, amountOutCint))
            packedData := or(packedData, shl(48, amountInCint))
            packedData := or(packedData, shl(24, tokenInIndex))
            packedData := or(packedData, tokenOutIndex)
            mstore(add(encoded, 32), packedData)

            mstore(add(encoded, 56), guy)

            mstore(add(encoded, 76), r)
            mstore(add(encoded, 108), vs)
        }
        return encoded;
    }
}
