// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

struct FuzzSelector {
    address addr;
    bytes4[] selectors;
}

interface Vm {
    function warp(uint256 newTimestamp) external;
    function roll(uint256 newHeight) external;
    function prank(address msgSender) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;
    function expectRevert() external;
    function expectRevert(bytes calldata revertData) external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData) external;
    function assume(bool condition) external;
    function targetContract(address newTargetedContract) external;
    function targetSelector(FuzzSelector calldata newTargetedSelector) external;
    function label(address account, string calldata newLabel) external;
    function addr(uint256 privateKey) external returns (address);
}

abstract contract Test {
    bool public IS_TEST = true;

    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertTrue(bool condition) internal pure {
        require(condition, "assertTrue failed");
    }

    function assertTrue(bool condition, string memory message) internal pure {
        require(condition, message);
    }

    function assertFalse(bool condition) internal pure {
        require(!condition, "assertFalse failed");
    }

    function assertEq(uint256 left, uint256 right) internal pure {
        require(left == right, "assertEq(uint256) failed");
    }

    function assertEq(uint256 left, uint256 right, string memory message) internal pure {
        require(left == right, message);
    }

    function assertEq(address left, address right) internal pure {
        require(left == right, "assertEq(address) failed");
    }

    function assertEq(bool left, bool right) internal pure {
        require(left == right, "assertEq(bool) failed");
    }

    function assertGt(uint256 left, uint256 right) internal pure {
        require(left > right, "assertGt failed");
    }

    function assertGe(uint256 left, uint256 right) internal pure {
        require(left >= right, "assertGe failed");
    }

    function assertLt(uint256 left, uint256 right) internal pure {
        require(left < right, "assertLt failed");
    }

    function assertLe(uint256 left, uint256 right) internal pure {
        require(left <= right, "assertLe failed");
    }

    function assertApproxEqAbs(uint256 left, uint256 right, uint256 maxDelta) internal pure {
        if (left > right) {
            require(left - right <= maxDelta, "assertApproxEqAbs failed");
        } else {
            require(right - left <= maxDelta, "assertApproxEqAbs failed");
        }
    }

    function bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256 result) {
        require(min <= max, "bound max < min");
        uint256 size = max - min + 1;
        if (size == 0) {
            return x;
        }
        return min + (x % size);
    }

    function makeAddr(string memory name) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(name)))));
    }
}
