//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract ArbAddressTable {
    mapping(address => uint256) tableFromAddr;
    mapping(uint256 => address) tableFromIndex;
    uint256 currIndex;

    // Register an address in the address table
    function register(address addr) external returns (uint256) {
        if (addressExists(addr)) return lookup(addr);
        currIndex++;
        tableFromAddr[addr] = currIndex;
        tableFromIndex[currIndex] = addr;
        return tableFromAddr[addr];
    }

    // Return index of an address in the address table (revert if address isn't in the table)
    function lookup(address addr) public view returns (uint256) {
        return tableFromAddr[addr];
    }

    // Check whether an address exists in the address table
    function addressExists(address addr) public view returns (bool) {
        return tableFromAddr[addr] == 0 ? false : true;
    }

    // Return address at a given index in address table (revert if index is beyond end of table)
    function lookupIndex(uint256 index) external view returns (address) {
        return tableFromIndex[index];
    }
}
