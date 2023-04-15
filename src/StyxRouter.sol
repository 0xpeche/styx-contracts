// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity 0.8.19;

import {ISignatureTransfer} from "./interfaces/ISignatureTransfer.sol";
import {IArbAddressTable} from "./interfaces/IArbAddressTable.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {SafeERC20} from "./libs/SafeERC20.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IAdapter} from "./interfaces/IAdapter.sol";
import "hardhat/console.sol";

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
contract StyxRouter {
    using SafeERC20 for IERC20;

    mapping(address => uint) internal permitNonce; // storage slot 0x0
    mapping(uint8 => address) adapters; // 0x01?
    mapping(address => bool) internal isKeeper; // 0x02?
    ISignatureTransfer internal immutable permit2;
    IArbAddressTable internal immutable addressRegistry;
    uint256 internal constant SIG_DEADLINE = type(uint256).max; // never expire, saves 32-48 bits of calldata
    address internal immutable owner;
    uint16 internal constant MAX_BPS = 10000;
    address internal immutable WETH9;

    error InvalidMsgLength();
    error CallerNotKeeper();
    error InvalidFee();
    error InsufficentAmountOut();

    event Swap(
        uint amountIn,
        uint amountOut,
        uint actualAmountOut,
        address tokenIn,
        address tokenOut,
        address guy
    );

    struct Witness {
        address guy;
        address tokenOut;
        uint256 amountOut;
        uint16 swapFeeBps;
        uint8 slippageId;
        uint8 adapterId;
    }

    string private constant WITNESS_TYPE_STRING =
        "Witness witness)TokenPermissions(address token,uint256 amount)Witness(address guy,address tokenOut,uint256 amountOut,uint16 swapFeeBps,uint8 slippageId,uint8 adapterId)";

    bytes32 private WITNESS_TYPEHASH =
        keccak256(
            "Witness(address guy,address tokenOut,uint256 amountOut,uint16 swapFeeBps,uint8 slippageId,uint8 adapterId)"
        );

    constructor(
        address _permit2,
        address _registry,
        address _weth9,
        address ownerHelper
    ) {
        permit2 = ISignatureTransfer(_permit2);
        addressRegistry = IArbAddressTable(_registry);
        owner = ownerHelper;
        WETH9 = _weth9;
    }

    // https://gist.github.com/zemse/0ea19dd9b4922cd68f096fc2eb4abf93
    function uncompress(uint64 cint) internal pure returns (uint256 full) {
        uint8 bits = uint8(cint % (1 << 9));
        full = uint256(cint >> 8) << bits;
    }

    receive() external payable {}

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
                (, address _adapter, uint8 id) = abi.decode(
                    msg.data,
                    (uint, address, uint8)
                );
                adapters[id] = _adapter;
            } else {
                (, address keeper, bool status) = abi.decode(
                    msg.data,
                    (uint, address, bool)
                );
                isKeeper[keeper] = status;
            }
            return;
        }

        uint24 tokenInIndex;
        uint24 tokenOutIndex;
        uint8 adapterId;
        uint amountOut;
        uint amountIn;
        uint8 slippageId;
        uint16 swapFeeBps;
        address guy;
        uint256 packedData;

        /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
        /*                    CALLDATA DECODING                       */
        /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

        uint64 amountOutCint;
        uint64 amountInCint;

        assembly {
            packedData := calldataload(0)
            adapterId := and(shr(248, packedData), 0xFF)
            slippageId := and(shr(245, packedData), 0x07)
            swapFeeBps := and(shr(232, packedData), 0x1FFF)
            amountOutCint := and(shr(168, packedData), 0xFFFFFFFFFFFFFFFF)
            tokenOutIndex := and(shr(144, packedData), 0xFFFFFF)
            tokenInIndex := and(shr(120, packedData), 0xFFFFFF)
        }

        address adapter = adapters[adapterId];

        amountOut = uncompress(amountOutCint);

        // Get token addresses from ArbAddressTable
        IERC20 tokenIn = IERC20(addressRegistry.lookupIndex(tokenInIndex));
        IERC20 tokenOut = IERC20(addressRegistry.lookupIndex(tokenOutIndex));

        if (address(tokenIn) == WETH9 && msg.value > 0) {
            amountIn = msg.value;
            IWETH weth = IWETH(WETH9);
            weth.deposit{value: amountIn}();
            guy = msg.sender;
        } else {
            bytes32 r;
            bytes32 vs;
            if (msg.data.length == 122) {
                assembly {
                    amountInCint := and(shr(56, packedData), 0xFFFFFFFFFFFFFFFF)
                    guy := and(
                        calldataload(26),
                        0xffffffffffffffffffffffffffffffffffffffff
                    )

                    r := calldataload(58)
                    vs := calldataload(90)
                }
                amountIn = uncompress(amountInCint);
            } else if (msg.data.length == 114) {
                assembly {
                    guy := and(
                        calldataload(18),
                        0xffffffffffffffffffffffffffffffffffffffff
                    )

                    r := calldataload(50)
                    vs := calldataload(82)
                }
                amountIn = tokenIn.balanceOf(guy);
            } else {
                revert InvalidMsgLength();
            }

            /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
            /*                    SIGNATURE TRANSFER                      */
            /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

            // https://eips.ethereum.org/EIPS/eip-2098
            bytes memory signature = bytes.concat(r, vs);

            // permitTransferFrom uses unordered nonce, we use a fixed offset to limit potential collision
            uint nonce = permitNonce[guy] + 1337 + 420 + 69;

            ISignatureTransfer.SignatureTransferDetails
                memory transferDetails = getTransferDetails(
                    address(this), // transfer to adapter instead?
                    amountIn
                );

            ISignatureTransfer.PermitTransferFrom
                memory permit = defaultERC20PermitTransfer(
                    address(tokenIn),
                    nonce,
                    amountIn
                );

            permit2.permitWitnessTransferFrom(
                permit,
                transferDetails,
                guy,
                keccak256(
                    abi.encode(
                        WITNESS_TYPEHASH,
                        Witness(
                            guy,
                            address(tokenOut),
                            amountOut,
                            swapFeeBps,
                            slippageId,
                            adapterId
                        )
                    )
                ),
                WITNESS_TYPE_STRING,
                signature
            );

            // increment the nonce
            ++permitNonce[guy];
        }

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

        if (isKeeper[msg.sender]) {
            if (swapFeeBps == 0) revert InvalidFee();
            uint feeAmount = (amountIn * swapFeeBps) / MAX_BPS;

            IERC20(tokenIn).transfer(msg.sender, feeAmount);

            amountIn = amountIn - feeAmount;
        }

        IERC20(tokenIn).transfer(adapter, amountIn);

        uint actualAmountOut = IAdapter(adapters[adapterId]).swap(
            address(tokenIn),
            address(tokenOut),
            amountIn,
            amountOut,
            guy
        );

        emit Swap(
            amountIn,
            amountOut,
            actualAmountOut,
            address(tokenIn),
            address(tokenOut),
            guy
        );

        if (actualAmountOut < minAmountOut) revert InsufficentAmountOut();
    }

    function defaultERC20PermitTransfer(
        address token0,
        uint256 nonce,
        uint256 amount
    ) internal pure returns (ISignatureTransfer.PermitTransferFrom memory) {
        return
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({
                    token: token0,
                    amount: amount
                }),
                nonce: nonce,
                deadline: SIG_DEADLINE
            });
    }

    function getTransferDetails(
        address to,
        uint256 amount
    )
        internal
        pure
        returns (ISignatureTransfer.SignatureTransferDetails memory)
    {
        return
            ISignatureTransfer.SignatureTransferDetails({
                to: to,
                requestedAmount: amount
            });
    }
}
