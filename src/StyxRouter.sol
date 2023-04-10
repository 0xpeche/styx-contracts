// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity 0.8.19;

import {ISignatureTransfer} from "./interfaces/ISignatureTransfer.sol";
import {IArbAddressTable} from "./interfaces/IArbAddressTable.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {SafeERC20} from "./libs/SafeERC20.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IAdapter} from "./interfaces/IAdapter.sol";

// &&&&&&&&&%%%&%#(((/,,,**,,,**,,,*******/*,,/%%%%%%#.,%%%%%%%%%%%%%%%% ./(#%%%%/. #%%/***,,*,*,,,,**,
// %&&&&&&&&&%%%/((((*,,,,,,,**/.,,,*****/%%#.      ,**,,%%%%%%%%%%%%%%%%%%#.     #%%%%%#*,,,,,,*,,,,,*
// ,.,,*(%&&%%/*/((((,,,,,,,,**((%%,,**,  .#%%/*%%%%%%%,*%%%%%%%%%%%%%%%%#%    ..  #%%%%%,*,*,,**,*,**,
// ..,.,,.,,.,.*((((,,,,,,,****(#%%%%%,*%%%%%. .(%%%%%#,#%%%%%%%%%%%%%%%%,  &@# . * (%%%%***,*,,*,*,,,,
// .,.,,..,.,.,/(((,,,,,*****/#%%%%%%%%%%%%%,         ,%%%%%%%%%%%%%%%%%% .    .  / *#%%#***,*,*,**,,**
// ,,.,,,,.,,.,/((,,,****/#%%%%%%%%%%%%%%,     , ....   #%%%%%%%%&&%%%%%, /  ...  ,(%%%%/****,****,*#%#
// .,,.,.,.,.,,/(##%%%%%%%%%%%%%%%%%%%%% , /, .......    %%%%%%%%&&%%%%%% /*  .  , @%%%%/*******/(##%##
// ,..,,..,.,,%%%%%%%%%%%%%%%%%%%%%%%%%(#@..(/ .....  /, %%%%%%%%&&&%%%%%(.*////  @%%%%%/****(#%%%%%%#/
// ,,,..,.,,,.%%%%%%%%%%%%%%%%%%%%%%%%%%%%@../(*     @ .,%%%%%%%%%%%%%%%%%%%%/ ./(%%%%%/*/(#%%%%%%%#**/
// .,,,,,,,,,,*,#%%%%%%%%%%%%%%%%%%%%%%%%%%&@, ,*/(/,. #%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%#(#%%%%%%%#//*///
// ,,.,,.,,,,,,,,,,#%%%%%%%%%%%%%%%%%%%%%%%%%%(    .#%%%%%%%%%%%%#%&&&%%%%%%%%%%%%%%%*%%%#%%%#(**(**//*
// .,,,,..,*..,.,,,,...*%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%,(%#%%%(*/*///*//#%

/// @title Styx Router
/// @author 0xpeche
/// @custom:experimental This is an experimental contract.
contract StyxEntrypoint {
    using SafeERC20 for IERC20;
    error InvalidMsgLength();
    error CallerNotKeeper();
    error InvalidFee();
    error InsufficentAmountOut();

    mapping(address => uint) internal permitNonce;
    ISignatureTransfer internal immutable permit2;
    IArbAddressTable internal immutable addressRegistry;
    uint48 internal constant SIG_DEADLINE = type(uint48).max; // never expire, saves 32-48 bits of calldata
    mapping(address => bool) internal isKeeper;
    address internal immutable owner;
    uint16 internal constant MAX_BPS = 10000;
    address internal immutable WETH9;
    mapping(uint8 => address) adapters;

    event Swap(
        uint amountIn,
        uint amountOut,
        uint minAmountOut,
        address tokenIn,
        address tokenOut,
        address from
    );

    string internal constant TRADE_WITNESS_TYPE =
        "TradeWitness(uint8 slippageId,uint16 swapFeeBps,uint256 amountOut,address tokenOut)";

    string internal constant WITNESS_TYPE_STRING =
        "TradeWitness witness)TradeWitness(uint8 slippageId,uint16 swapFeeBps,uint256 amountOut,address tokenOut)TokenPermissions(address token,uint256 amount)";

    struct TradeWitness {
        uint8 slippageId;
        uint16 swapFeeBps;
        uint256 amountOut;
        address tokenOut;
    }

    constructor(address _permit2, address _registry, address _weth9) {
        permit2 = ISignatureTransfer(_permit2);
        addressRegistry = IArbAddressTable(_registry);
        owner = msg.sender;
        WETH9 = _weth9;
    }

    // https://gist.github.com/zemse/0ea19dd9b4922cd68f096fc2eb4abf93
    function uncompress(uint64 cint) internal pure returns (uint256 full) {
        uint8 bits = uint8(cint % (1 << 9));
        full = uint256(cint >> 8) << bits;
    }

    fallback() external payable {
        if (msg.sender == owner) {
            uint method = abi.decode(msg.data, (uint));
            if (method == 0) {
                (, address token, uint amount, address receiver) = abi.decode(
                    msg.data,
                    (uint, address, uint, address)
                );
                if (token == address(0)) {
                    payable(receiver).transfer(address(this).balance);
                } else {
                    IERC20(token).transfer(receiver, amount);
                }
            } else if (method == 1) {
                (, address adapter, uint8 id) = abi.decode(
                    msg.data,
                    (uint, address, uint8)
                );
                adapters[id] = adapter;
            } else {
                (, address keeper, bool status) = abi.decode(
                    msg.data,
                    (uint, address, bool)
                );
                isKeeper[keeper] = status;
            }
            return;
        }

        uint8 adapterId;
        uint amountOut;
        uint amountIn;
        uint8 slippageId;
        address tokenIn;
        address tokenOut;
        uint16 swapFeeBps;
        address guy;
        bytes32 r;
        bytes32 vs;

        /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
        /*                    CALLDATA DECODING                       */
        /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

        if (msg.data.length == 77) {
            // Case: Not ETH -- AmountIn specified -- SwapFee
            /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
            /*                            MAP                             */
            /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
            // | Field          | Bits | Start Position |   End Position   |
            // |----------------|------|----------------|------------------|
            // | adapterId      |   8  |       0        |       7          |  ----
            // | slippageId     |   3  |       8        |      10          |     |
            // | swapFeeBps     |  13  |      11        |      23          |     |
            // | amountOutCint  |  64  |      24        |      87          |     |  Packed in a uint200
            // | amountInCint   |  64  |      88        |     151          |     |
            // | tokenInIndex   |  24  |     152        |     175          |     |
            // | tokenOutIndex  |  24  |     176        |     199          |  ----
            // | guy            | 160  |     200        |     359          |
            // | r              | 256  |     360        |     615          |
            // | vs             | 256  |     616        |     871          |
            // |----------------|------|----------------|------------------|

            uint64 amountOutCint;
            uint64 amountInCint;
            uint24 tokenInIndex;
            uint24 tokenOutIndex;

            assembly {
                let packedData := calldataload(0) // Dynamic array length trimmed off, we decode manually
                adapterId := and(shr(192, packedData), 0xFF)
                slippageId := and(shr(189, packedData), 0x07)
                swapFeeBps := and(shr(176, packedData), 0x1FFF)
                amountOutCint := and(shr(112, packedData), 0xFFFFFFFFFFFFFFFF)
                amountInCint := and(shr(48, packedData), 0xFFFFFFFFFFFFFFFF)
                tokenInIndex := and(shr(24, packedData), 0xFFFFFF)
                tokenOutIndex := and(packedData, 0xFFFFFF)

                guy := and(
                    calldataload(20),
                    0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
                )

                r := calldataload(40)
                vs := calldataload(72)
            }

            // Uncompress the amounts

            amountOut = uncompress(amountOutCint);
            amountIn = uncompress(amountInCint);

            // Get token addresses from ArbAddressTable

            tokenIn = addressRegistry.lookupIndex(tokenInIndex);
            tokenOut = addressRegistry.lookupIndex(tokenOutIndex);
        }

        /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
        /*                    SIGNATURE TRANSFER                      */
        /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

        // https://eips.ethereum.org/EIPS/eip-2098
        bytes memory signature;

        signature = bytes.concat(r, vs);

        TradeWitness memory witnessData = TradeWitness(
            slippageId,
            swapFeeBps,
            amountOut,
            tokenOut
        );

        bytes32 witness = keccak256(abi.encode(witnessData));

        uint nonce = permitNonce[guy] + 1337 + 420 + 69; // offset

        permit2.permitWitnessTransferFrom(
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({
                    token: tokenIn,
                    amount: amountIn
                }),
                nonce: nonce,
                deadline: uint(SIG_DEADLINE)
            }),
            ISignatureTransfer.SignatureTransferDetails({
                to: address(this),
                requestedAmount: amountIn
            }),
            guy,
            witness,
            WITNESS_TYPE_STRING,
            signature
        );

        ++permitNonce[guy];

        /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
        /*                           SWAP                             */
        /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

        uint slippageBps;
        assembly {
            let maxBps := MAX_BPS
            switch slippageId
            case 0 {
                slippageBps := sub(maxBps, 2) // 0.02
            }
            case 1 {
                slippageBps := sub(maxBps, 10) // 0.1
            }
            case 2 {
                slippageBps := sub(maxBps, 50) // 0.5
            }
            case 3 {
                slippageBps := sub(maxBps, 75) // 0.75
            }
            case 4 {
                slippageBps := sub(maxBps, 100) // 1
            }
            case 5 {
                slippageBps := sub(maxBps, 500) // 5
            }
            default {
                slippageBps := sub(maxBps, 25) // 0.25
            }
        }

        uint minAmountOut = (amountOut * slippageBps) / MAX_BPS;

        emit Swap(amountIn, amountOut, minAmountOut, tokenIn, tokenOut, guy);

        uint actualAmountOut = IAdapter(adapters[adapterId]).swap(
            amountIn,
            amountOut,
            tokenIn,
            tokenOut,
            guy
        );

        if (actualAmountOut < minAmountOut) revert InsufficentAmountOut();
    }
}
