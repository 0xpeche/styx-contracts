// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity 0.8.19;

import {ISignatureTransfer} from "./interfaces/ISignatureTransfer.sol";
import {IArbAddressTable} from "./interfaces/IArbAddressTable.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {SafeERC20} from "./libs/SafeERC20.sol";
import {IWETH} from "./interfaces/IWETH.sol";
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

/// @title Styx Permit2 Proxy
/// @author 0xpeche
/// @custom:experimental This is an experimental contract.
contract StyxPermitProxy {
    using SafeERC20 for IERC20;
    mapping(address => uint) internal permitNonce; // storage slot #0
    ISignatureTransfer internal immutable permit2;
    IArbAddressTable internal immutable addressRegistry;
    uint256 internal constant SIG_DEADLINE = type(uint256).max; // never expire, saves 32-48 bits of calldata
    mapping(uint8 => address) routers;
    address internal immutable owner;
    address internal constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    error SwapFailed();

    constructor(address _permit2, address _registry, address ownerHelper) {
        permit2 = ISignatureTransfer(_permit2);
        addressRegistry = IArbAddressTable(_registry);
        owner = ownerHelper;
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
            } else {
                (, address aggregator, uint8 id) = abi.decode(
                    msg.data,
                    (uint, address, uint8)
                );
                routers[id] = aggregator;
            }
            return;
        }
        uint8 routerId;
        uint64 amountInCint;
        uint24 tokenInIndex;
        uint24 tokenOutIndex;
        bytes32 r;
        bytes32 vs;

        /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
        /*                    CALLDATA DECODING                       */
        /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

        uint swapCalldataLength = msg.data.length - 96; // Subtract the length of the packed data + r + vs
        bytes memory swapCalldata = new bytes(swapCalldataLength);

        /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*:*/
        /*                          MAP                           */
        /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.•*/

        // | Field         | Bytes | Start Position | End Position |
        // |---------------|-------|----------------|--------------|
        // | routerId      |   1   |       0        |       0      | ----
        // | amountInCint  |   8   |       1        |       8      |     | Packed in a uint120
        // | tokenInIndex  |   3   |       9        |      11      |     |
        // | tokenOutIndex |   3   |      12        |      14      | ----
        // | r             |   32  |      32        |      63      |
        // | vs            |   32  |      64        |      95      |
        // |---------------|-------|----------------|--------------|
        // | swapCalldata  |  var  |      96        |   N-1        |

        assembly {
            let packedData := calldataload(0)
            routerId := and(shr(112, packedData), 0xFF)
            amountInCint := and(shr(48, packedData), 0xFFFFFFFFFFFFFFFF)
            tokenInIndex := and(shr(24, packedData), 0xFFFFFF)
            tokenOutIndex := and(packedData, 0xFFFFFF)

            r := calldataload(32)
            vs := calldataload(64)

            let src := 96 // Start position of swapCalldata in msg.data
            let dst := add(swapCalldata, 32)
            calldatacopy(dst, src, swapCalldataLength)
        }

        address router = routers[routerId];

        IERC20 tokenIn = IERC20(addressRegistry.lookupIndex(tokenInIndex));
        IERC20 tokenOut = IERC20(addressRegistry.lookupIndex(tokenOutIndex));
        uint amountIn = uncompress(amountInCint);

        // // If this is the first time this token and router have been used, we'll approve it permanently.
        // // This contract should never hold any balance of token.
        if (tokenIn.allowance(address(this), router) < amountIn) {
            // Use inlined _callOptionalReturn to do the approve, rather than `safeApprove`,
            // because we've already done sufficient checks on the balance
            _callOptionalReturn(
                tokenIn,
                abi.encodeWithSelector(
                    tokenIn.approve.selector,
                    router,
                    type(uint256).max
                )
            );
        }

        // /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
        // /*                    SIGNATURE TRANSFER                      */
        // /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

        // // https://eips.ethereum.org/EIPS/eip-2098
        bytes memory signature = bytes.concat(r, vs);

        // permitTransferFrom uses unordered nonce, we use a fixed offset to avoid potential collision
        uint nonce = permitNonce[msg.sender] + 1337 + 420 + 69 + 15537393;

        ISignatureTransfer.SignatureTransferDetails
            memory transferDetails = getTransferDetails(
                address(this),
                amountIn
            );

        ISignatureTransfer.PermitTransferFrom
            memory permit = defaultERC20PermitTransfer(
                address(tokenIn),
                nonce,
                amountIn
            );

        permit2.permitTransferFrom(
            permit,
            transferDetails,
            msg.sender,
            signature
        );

        // increment the nonce
        ++permitNonce[msg.sender];

        // /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
        // /*                           SWAP                             */
        // /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

        // If tokenIn is ETH, then this contract is useless so we don't care about that case.

        if (address(tokenOut) != ETH) {
            uint256 tokenOutStartBal = tokenOut.balanceOf(address(this));

            (bool success, ) = router.call{value: msg.value}(swapCalldata);

            if (!success) revert SwapFailed();

            tokenOut.transfer(
                msg.sender,
                tokenOut.balanceOf(address(this)) - tokenOutStartBal
            );
        } else {
            uint256 outStartBal = address(this).balance;

            (bool success, ) = router.call{value: msg.value}(swapCalldata);

            if (!success) revert SwapFailed();

            payable(msg.sender).transfer(address(this).balance - outStartBal);
        }
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

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) internal {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves.

        // A Solidity high level call has three parts:
        //  1. The target address is checked to verify it contains contract code
        //  2. The call itself is made, and success asserted
        //  3. The return value is decoded, which in turn checks the size of the returned data.
        // solhint-disable-next-line max-line-length

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = address(token).call(data);
        require(success, "SafeERC20: low-level call failed");

        if (returndata.length > 0) {
            // Return data is optional
            // solhint-disable-next-line max-line-length
            require(
                abi.decode(returndata, (bool)),
                "SafeERC20: ERC20 operation did not succeed"
            );
        }
    }
}
