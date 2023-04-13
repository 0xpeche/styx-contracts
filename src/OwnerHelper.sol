// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity 0.8.19;

contract OwnerHelper {
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

    function setAggregator(
        address router,
        address aggregator,
        uint8 id
    ) external onlyOwner {
        (bool success, ) = router.call(abi.encode(uint(1), aggregator, id));
        require(success);
    }
}
