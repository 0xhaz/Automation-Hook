// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import {EIP712} from "lib/v4-periphery/lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";

abstract contract AutoMateEIP712 is EIP712 {
    constructor(string memory name, string memory version) EIP712(name, version) {}

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
