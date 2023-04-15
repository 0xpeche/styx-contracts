// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity 0.8.19;

contract OwnerHelperRouter {
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "!owner");
        _;
    }

    function setOwner(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    function sweepTokensFromRouter(
        address router,
        address token,
        uint amount,
        address receiver
    ) external onlyOwner {
        (bool success, ) = router.call(
            abi.encode(uint(0), token, amount, receiver)
        );
        require(success);
    }

    function setAdapter(
        address router,
        address _adapter,
        uint8 id
    ) external onlyOwner {
        (bool success, ) = router.call(abi.encode(uint(1), _adapter, id));
        require(success);
    }

    function setKeeper(
        address router,
        address keeper,
        bool status
    ) external onlyOwner {
        (bool success, ) = router.call(abi.encode(uint(2), keeper, status));
        require(success);
    }
}
