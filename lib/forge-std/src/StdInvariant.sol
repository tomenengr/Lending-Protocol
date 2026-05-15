// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, FuzzSelector} from "./Test.sol";

abstract contract StdInvariant is Test {
    function targetContract(address newTargetedContract) internal {
        vm.targetContract(newTargetedContract);
    }

    function targetSelector(FuzzSelector memory newTargetedSelector) internal {
        vm.targetSelector(newTargetedSelector);
    }
}
