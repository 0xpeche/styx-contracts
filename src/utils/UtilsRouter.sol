// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity 0.8.19;

import "hardhat/console.sol";

contract UtilsRouter {
    // https://gist.github.com/zemse/0ea19dd9b4922cd68f096fc2eb4abf93
    function uncompress(uint64 cint) public pure returns (uint256 full) {
        uint8 bits = uint8(cint % (1 << 9));
        full = uint256(cint >> 8) << bits;
    }

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
    ) public pure returns (bytes32 r, bytes32 vs) {
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
        uint tokenInIndex,
        uint tokenOutIndex,
        uint160 guy,
        bytes32 r,
        bytes32 vs
    ) external pure returns (bytes memory) {
        bytes memory encoded = new bytes(122);

        uint64 amountOutCint = compress(amountOut);
        uint64 amountInCint = compress(amountIn);

        assembly {
            let packedData := 0
            packedData := or(packedData, shl(248, adapterId))
            packedData := or(packedData, shl(245, slippageId))
            packedData := or(packedData, shl(232, swapFeeBps))
            packedData := or(packedData, shl(168, amountOutCint))
            packedData := or(packedData, shl(144, tokenOutIndex))
            packedData := or(packedData, shl(120, tokenInIndex))
            packedData := or(packedData, shl(56, amountInCint))

            mstore(add(encoded, 32), packedData)

            mstore(add(encoded, 58), guy)
            mstore(add(encoded, 90), r)
            mstore(add(encoded, 122), vs)
        }
        return encoded;
    }

    function encodeData2(
        uint8 slippageId,
        uint8 adapterId,
        uint16 swapFeeBps,
        uint256 amountOut,
        uint tokenInIndex,
        uint tokenOutIndex,
        uint160 guy,
        bytes32 r,
        bytes32 vs
    ) external pure returns (bytes memory) {
        bytes memory encoded = new bytes(114);

        uint64 amountOutCint = compress(amountOut);

        assembly {
            let packedData := 0
            packedData := or(packedData, shl(248, adapterId))
            packedData := or(packedData, shl(245, slippageId))
            packedData := or(packedData, shl(232, swapFeeBps))
            packedData := or(packedData, shl(168, amountOutCint))
            packedData := or(packedData, shl(144, tokenOutIndex))
            packedData := or(packedData, shl(120, tokenInIndex))

            mstore(add(encoded, 32), packedData)

            mstore(add(encoded, 50), guy)
            mstore(add(encoded, 82), r)
            mstore(add(encoded, 114), vs)
        }
        return encoded;
    }

    function encodeData3(
        uint8 slippageId,
        uint8 adapterId,
        uint16 swapFeeBps,
        uint256 amountOut,
        uint tokenInIndex,
        uint tokenOutIndex
    ) external pure returns (bytes memory) {
        bytes memory encoded = new bytes(94);

        uint64 amountOutCint = compress(amountOut);

        assembly {
            let packedData := 0
            packedData := or(packedData, shl(248, adapterId))
            packedData := or(packedData, shl(245, slippageId))
            packedData := or(packedData, shl(232, swapFeeBps))
            packedData := or(packedData, shl(168, amountOutCint))
            packedData := or(packedData, shl(144, tokenOutIndex))
            packedData := or(packedData, shl(120, tokenInIndex))

            mstore(add(encoded, 32), packedData)
        }
        return encoded;
    }
}
