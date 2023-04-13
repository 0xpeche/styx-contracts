// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity 0.8.19;

import {IAdapter} from "./interfaces/IAdapter.sol";

contract StyxUtilsPermit {
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

    function mcopy(uint dst, uint src, uint len) internal pure {
        for (uint i = 0; i < len; i += 32) {
            assembly {
                mstore(add(dst, i), mload(add(src, i)))
            }
        }
    }

    function encodeData(
        uint8 routerId,
        uint256 amountIn,
        uint24 tokenInIndex,
        uint24 tokenOutIndex,
        bytes memory swapCalldata,
        uint8 vRaw,
        bytes32 rRaw,
        bytes32 sRaw
    ) external pure returns (bytes memory) {
        uint packedDataLength = 79 + swapCalldata.length;
        bytes memory encoded = new bytes(packedDataLength);

        uint64 amountInCint = compress(amountIn);

        (bytes32 r, bytes32 vs) = getCompactSignature(vRaw, rRaw, sRaw);

        assembly {
            let packedData := 0
            packedData := or(packedData, shl(112, routerId))
            packedData := or(packedData, shl(48, amountInCint))
            packedData := or(packedData, shl(24, tokenInIndex))
            packedData := or(packedData, tokenOutIndex)
            mstore(add(encoded, 32), packedData)

            mstore(add(encoded, 15), r)
            mstore(add(encoded, 47), vs)

            let src := add(swapCalldata, 32) // Skip the length prefix of swapCalldata
            let dst := add(encoded, 79)
            let len := mload(swapCalldata) // Get the length of swapCalldata

            for {
                let end := add(src, len)
            } lt(src, end) {
                src := add(src, 32)
                dst := add(dst, 32)
            } {
                mstore(dst, mload(src))
            }
        }

        return encoded;
    }
}
