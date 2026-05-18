// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MiniLending} from "../src/MiniLending.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {RiskEngine} from "../src/RiskEngine.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockV3Aggregator} from "../src/mocks/MockV3Aggregator.sol";

contract MiniLendingHandler is StdInvariant {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MIN_HEALTH_FACTOR = 1e18;

    MiniLending public lending;
    MockERC20 public weth;
    MockERC20 public wbtc;
    MockERC20 public usdc;

    address[] internal actors;
    address internal liquidator = address(0x9999);

    uint256 public healthyLiquidations;
    uint256 public unhealthyRiskActions;
    uint256 public totalDebtGhost;

    constructor(MiniLending lending_, MockERC20 weth_, MockERC20 wbtc_, MockERC20 usdc_) {
        lending = lending_;
        weth = weth_;
        wbtc = wbtc_;
        usdc = usdc_;

        actors.push(address(0x1001));
        actors.push(address(0x1002));
        actors.push(address(0x1003));
    }

    function depositWeth(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 0.01 ether, 10 ether);

        vm.startPrank(actor);
        weth.approve(address(lending), amount);
        try lending.depositCollateral(address(weth), amount) {} catch {}
        vm.stopPrank();
    }

    function depositWbtc(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 0.001e8, 1e8);

        vm.startPrank(actor);
        wbtc.approve(address(lending), amount);
        try lending.depositCollateral(address(wbtc), amount) {} catch {}
        vm.stopPrank();
    }

    function borrow(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        (, uint256 borrowableUsd, uint256 debtUsd,) = lending.getAccountData(actor);
        if (borrowableUsd <= debtUsd) {
            return;
        }

        uint256 availableUsdc = (borrowableUsd - debtUsd) * 1e6 / 1e18;
        if (availableUsdc == 0) {
            return;
        }

        uint256 amount = bound(amountSeed, 1, availableUsdc);
        vm.prank(actor);
        lending.borrow(amount);
        totalDebtGhost += amount;
        _recordRiskAction(actor);
    }

    function repay(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        uint256 debt = lending.debtUsdc(actor);
        if (debt == 0) {
            return;
        }

        uint256 amount = bound(amountSeed, 1, debt);
        vm.startPrank(actor);
        usdc.approve(address(lending), amount);
        lending.repay(amount);
        vm.stopPrank();
        totalDebtGhost = amount > totalDebtGhost ? 0 : totalDebtGhost - amount;
    }

    function supplyBase(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        uint256 balance = usdc.balanceOf(actor);
        if (balance == 0) {
            return;
        }

        uint256 amount = bound(amountSeed, 1e6, balance);
        vm.startPrank(actor);
        usdc.approve(address(lending), amount);
        lending.supplyBase(amount);
        vm.stopPrank();
    }

    function withdrawBase(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        uint256 supplied = lending.suppliedUsdc(actor);
        if (supplied == 0) {
            return;
        }

        uint256 amount = bound(amountSeed, 1, supplied);
        vm.startPrank(actor);
        try lending.withdrawBase(amount) {
            vm.stopPrank();
        } catch {
            vm.stopPrank();
        }
    }

    function withdrawWeth(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        uint256 balance = lending.collateralBalance(actor, address(weth));
        if (balance == 0) {
            return;
        }

        uint256 amount = bound(amountSeed, 1, balance);
        vm.startPrank(actor);
        try lending.withdrawCollateral(address(weth), amount) {
            vm.stopPrank();
            _recordRiskAction(actor);
        } catch {
            vm.stopPrank();
        }
    }

    function withdrawWbtc(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        uint256 balance = lending.collateralBalance(actor, address(wbtc));
        if (balance == 0) {
            return;
        }

        uint256 amount = bound(amountSeed, 1, balance);
        vm.startPrank(actor);
        try lending.withdrawCollateral(address(wbtc), amount) {
            vm.stopPrank();
            _recordRiskAction(actor);
        } catch {
            vm.stopPrank();
        }
    }

    function liquidateWeth(uint256 borrowerSeed, uint256 repaySeed) external {
        address borrower = _actor(borrowerSeed);
        uint256 debt = lending.debtUsdc(borrower);
        if (debt < 2) {
            return;
        }

        uint256 maxRepay = debt * 5_000 / BPS;
        if (maxRepay == 0) {
            return;
        }

        uint256 repayAmount = bound(repaySeed, 1, maxRepay);
        uint256 healthFactorBefore = lending.getHealthFactor(borrower);

        vm.startPrank(liquidator);
        usdc.approve(address(lending), repayAmount);
        try lending.liquidate(borrower, address(weth), repayAmount) {
            if (healthFactorBefore >= MIN_HEALTH_FACTOR) {
                healthyLiquidations += 1;
            }
            totalDebtGhost = repayAmount > totalDebtGhost ? 0 : totalDebtGhost - repayAmount;
            vm.stopPrank();
        } catch {
            vm.stopPrank();
        }
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }

    function _actor(uint256 actorSeed) internal view returns (address) {
        return actors[actorSeed % actors.length];
    }

    function _recordRiskAction(address actor) internal {
        if (lending.debtUsdc(actor) > 0 && lending.getHealthFactor(actor) < MIN_HEALTH_FACTOR) {
            unhealthyRiskActions += 1;
        }
    }
}

contract MiniLendingInvariantTest is StdInvariant {
    MockERC20 internal weth;
    MockERC20 internal wbtc;
    MockERC20 internal usdc;
    MockV3Aggregator internal wethFeed;
    MockV3Aggregator internal wbtcFeed;
    MockV3Aggregator internal usdcFeed;
    PriceOracle internal oracle;
    RiskEngine internal riskEngine;
    MiniLending internal lending;
    MiniLendingHandler internal handler;

    function setUp() public {
        vm.warp(10 days);

        weth = new MockERC20("Mock WETH", "WETH", 18);
        wbtc = new MockERC20("Mock WBTC", "WBTC", 8);
        usdc = new MockERC20("Mock USDC", "USDC", 6);

        wethFeed = new MockV3Aggregator(8, 3_000e8);
        wbtcFeed = new MockV3Aggregator(8, 60_000e8);
        usdcFeed = new MockV3Aggregator(8, 1e8);

        address[] memory oracleAssets = new address[](3);
        address[] memory feedAddresses = new address[](3);
        oracleAssets[0] = address(weth);
        oracleAssets[1] = address(wbtc);
        oracleAssets[2] = address(usdc);
        feedAddresses[0] = address(wethFeed);
        feedAddresses[1] = address(wbtcFeed);
        feedAddresses[2] = address(usdcFeed);
        oracle = new PriceOracle(oracleAssets, feedAddresses, 1 days);

        address[] memory collateralAssets = new address[](2);
        RiskEngine.RiskConfig[] memory configs = new RiskEngine.RiskConfig[](2);
        collateralAssets[0] = address(weth);
        collateralAssets[1] = address(wbtc);
        configs[0] = RiskEngine.RiskConfig(7_500, 8_000, 1_000, 10_000 ether, 0, false, true);
        configs[1] = RiskEngine.RiskConfig(7_000, 7_500, 1_000, 1_000e8, 20_000e18, true, true);
        riskEngine = new RiskEngine(collateralAssets, configs);
        lending = new MiniLending(usdc, oracle, riskEngine, collateralAssets);

        usdc.mint(address(this), 100_000_000e6);
        usdc.approve(address(lending), 100_000_000e6);
        lending.supplyBase(100_000_000e6);

        address[3] memory actors = [address(0x1001), address(0x1002), address(0x1003)];
        for (uint256 i = 0; i < actors.length; i++) {
            weth.mint(actors[i], 1_000 ether);
            wbtc.mint(actors[i], 1_000e8);
            usdc.mint(actors[i], 10_000_000e6);
        }
        usdc.mint(address(0x9999), 100_000_000e6);

        handler = new MiniLendingHandler(lending, weth, wbtc, usdc);

        weth.setTransferOperator(address(lending));
        wbtc.setTransferOperator(address(lending));
        usdc.setTransferOperator(address(lending));

        weth.lock();
        wbtc.lock();
        usdc.lock();
        wethFeed.lock();
        wbtcFeed.lock();
        usdcFeed.lock();
        oracle.lock();
        riskEngine.lock();
    }

    function invariant_collateralAccountingMatchesTokenBalance() public view {
        address[] memory actors = handler.getActors();
        uint256 wethSum;
        uint256 wbtcSum;

        for (uint256 i = 0; i < actors.length; i++) {
            wethSum += lending.collateralBalance(actors[i], address(weth));
            wbtcSum += lending.collateralBalance(actors[i], address(wbtc));
        }
        assertEq(wethSum, lending.totalCollateral(address(weth)));
        assertEq(wbtcSum, lending.totalCollateral(address(wbtc)));

        wethSum += lending.protocolCollateralBalance(address(weth));
        wbtcSum += lending.protocolCollateralBalance(address(wbtc));

        assertEq(wethSum, weth.balanceOf(address(lending)));
        assertEq(wbtcSum, wbtc.balanceOf(address(lending)));
    }

    function invariant_healthyPositionCannotBeLiquidated() public view {
        assertEq(handler.healthyLiquidations(), 0);
    }

    function invariant_successfulBorrowAndWithdrawKeepAccountHealthy() public view {
        assertEq(handler.unhealthyRiskActions(), 0);
    }

    function invariant_debtWithInterestCoversGhostPrincipal() public view {
        address[] memory actors = handler.getActors();
        uint256 debtSum;

        for (uint256 i = 0; i < actors.length; i++) {
            debtSum += lending.debtUsdc(actors[i]);
        }

        assertGe(debtSum, handler.totalDebtGhost());
    }

    function invariant_basePoolAssetsCoverSupplierClaims() public view {
        uint256 cash = usdc.balanceOf(address(lending));
        uint256 borrowed = lending.totalBorrowedUsdc();
        uint256 discountedProtocolCollateral = _discountedProtocolCollateralUsdc();
        uint256 supplied = lending.totalSuppliedUsdc();
        uint256 reserves = lending.protocolReservesUsdc();
        uint256 assets = cash + borrowed + discountedProtocolCollateral;
        uint256 liabilities = supplied + reserves;

        if (assets < liabilities) {
            assertLe(liabilities - assets, lending.badDebtUsdc());
        } else {
            assertGe(assets, liabilities);
        }
    }

    function _discountedProtocolCollateralUsdc() internal view returns (uint256) {
        uint256 wethValue = lending.protocolCollateralBalance(address(weth)) * 3_000e6 / 1 ether;
        uint256 wbtcValue = lending.protocolCollateralBalance(address(wbtc)) * 60_000e6 / 1e8;

        return wethValue * 10_000 / 11_000 + wbtcValue * 10_000 / 11_000;
    }
}
