// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MiniLendingTestBase} from "./helpers/MiniLendingTestBase.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract MiniLendingDepositTest is MiniLendingTestBase {
    event CollateralDeposited(address indexed user, address indexed asset, uint256 amount);

    function test_depositWETH() public {
        _depositWeth(alice, 1 ether);

        assertEq(lending.collateralBalance(alice, address(weth)), 1 ether);
    }

    function test_depositWBTC() public {
        _depositWbtc(alice, 1e8);

        assertEq(lending.collateralBalance(alice, address(wbtc)), 1e8);
    }

    function test_revertDepositUnsupportedAsset() public {
        MockERC20 dai = new MockERC20("Mock DAI", "DAI", 18);
        dai.mint(alice, 100 ether);

        vm.startPrank(alice);
        dai.approve(address(lending), 1 ether);
        vm.expectRevert(bytes("UNSUPPORTED_ASSET"));
        lending.depositCollateral(address(dai), 1 ether);
        vm.stopPrank();
    }

    function test_revertDepositZeroAmount() public {
        vm.startPrank(alice);
        weth.approve(address(lending), 1 ether);
        vm.expectRevert(bytes("ZERO_AMOUNT"));
        lending.depositCollateral(address(weth), 0);
        vm.stopPrank();
    }

    function test_depositUpdatesUserBalance() public {
        _depositWeth(alice, 2 ether);

        assertEq(lending.collateralBalance(alice, address(weth)), 2 ether);
    }

    function test_depositTransfersTokenToProtocol() public {
        _depositWeth(alice, 3 ether);

        assertEq(weth.balanceOf(address(lending)), 3 ether);
        assertEq(weth.balanceOf(alice), 97 ether);
    }

    function test_depositEmitsEvent() public {
        vm.startPrank(alice);
        weth.approve(address(lending), 1 ether);
        vm.expectEmit(true, true, false, true);
        emit CollateralDeposited(alice, address(weth), 1 ether);
        lending.depositCollateral(address(weth), 1 ether);
        vm.stopPrank();
    }

    function test_multipleDepositsAccumulate() public {
        _depositWeth(alice, 1 ether);
        _depositWeth(alice, 2 ether);

        assertEq(lending.collateralBalance(alice, address(weth)), 3 ether);
        assertEq(weth.balanceOf(address(lending)), 3 ether);
    }

    function test_revertDepositWithoutApproval() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ERC20_INSUFFICIENT_ALLOWANCE"));
        lending.depositCollateral(address(weth), 1 ether);
    }
}
