// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "./interfaces/IERC20Metadata.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {InterestRateLogic} from "./libraries/InterestRateLogic.sol";
import {LendingCore} from "./logic/LendingCore.sol";
import {RiskEngine} from "./RiskEngine.sol";

contract MiniLending is LendingCore {
    constructor(
        IERC20Metadata usdc_,
        IPriceOracle oracle_,
        RiskEngine riskEngine_,
        address[] memory collateralAssets_
    ) LendingCore(usdc_, oracle_, riskEngine_) {
        require(address(usdc_) != address(0), "ZERO_USDC");
        require(address(oracle_) != address(0), "ZERO_ORACLE");
        require(address(riskEngine_) != address(0), "ZERO_RISK_ENGINE");
        require(collateralAssets_.length > 0, "NO_COLLATERAL_ASSETS");

        borrowIndex = WAD;
        supplyIndex = WAD;
        lastAccrualTimestamp = block.timestamp;
        owner = msg.sender;

        for (uint256 i = 0; i < collateralAssets_.length; i++) {
            address asset = collateralAssets_[i];
            require(asset != address(0), "ZERO_ASSET");
            require(!isCollateralAsset[asset], "DUPLICATE_ASSET");
            require(riskEngine_.isEnabled(asset), "UNSUPPORTED_ASSET");

            isCollateralAsset[asset] = true;
            collateralAssets.push(asset);
        }

        emit OwnershipTransferred(address(0), msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        _executeTransferOwnership(newOwner);
    }

    function setPaused(bool paused_) external onlyOwner {
        _executeSetPaused(paused_);
    }

    function setAssetFrozen(address asset, bool frozen) external onlyOwner {
        _executeSetAssetFrozen(asset, frozen);
    }

    function depositCollateral(address asset, uint256 amount) external whenNotPaused {
        require(isCollateralAsset[asset], "UNSUPPORTED_ASSET");
        require(!assetFrozen[asset], "ASSET_FROZEN");
        require(amount > 0, "ZERO_AMOUNT");
        RiskEngine.RiskConfig memory config = RISK_ENGINE.getRiskConfig(asset);
        require(totalCollateral[asset] + amount <= config.supplyCap, "SUPPLY_CAP_EXCEEDED");
        _enforceIsolationOnDeposit(msg.sender, asset, config);

        collateralBalance[msg.sender][asset] += amount;
        totalCollateral[asset] += amount;
        require(IERC20Metadata(asset).transferFrom(msg.sender, address(this), amount), "TRANSFER_FAILED");

        emit CollateralDeposited(msg.sender, asset, amount);
    }

    function supplyBase(uint256 amountUsdc) external whenNotPaused {
        require(amountUsdc > 0, "ZERO_AMOUNT");
        accrueInterest();

        _executeSupplyBase(msg.sender, amountUsdc);
    }

    function withdrawBase(uint256 amountUsdc) external whenNotPaused {
        require(amountUsdc > 0, "ZERO_AMOUNT");
        accrueInterest();

        _executeWithdrawBase(msg.sender, amountUsdc);
    }

    function withdrawCollateral(address asset, uint256 amount) external whenNotPaused {
        require(isCollateralAsset[asset], "UNSUPPORTED_ASSET");
        require(amount > 0, "ZERO_AMOUNT");
        accrueInterest();
        require(collateralBalance[msg.sender][asset] >= amount, "INSUFFICIENT_COLLATERAL");

        collateralBalance[msg.sender][asset] -= amount;
        totalCollateral[asset] -= amount;
        require(getHealthFactor(msg.sender) >= MIN_HEALTH_FACTOR, "HF_TOO_LOW");

        require(IERC20Metadata(asset).transfer(msg.sender, amount), "TRANSFER_FAILED");
        emit CollateralWithdrawn(msg.sender, asset, amount);
    }

    function borrow(uint256 amountUsdc) external whenNotPaused {
        require(amountUsdc > 0, "ZERO_AMOUNT");
        accrueInterest();

        _executeBorrow(msg.sender, amountUsdc);
    }

    function repay(uint256 amountUsdc) external {
        require(amountUsdc > 0, "ZERO_AMOUNT");
        accrueInterest();

        _executeRepay(msg.sender, amountUsdc);
    }

    function liquidate(address borrower, address collateralAsset, uint256 repayAmountUsdc) external {
        require(repayAmountUsdc > 0, "ZERO_AMOUNT");
        accrueInterest();

        _executeLiquidate(msg.sender, borrower, collateralAsset, repayAmountUsdc);
    }

    function absorb(address borrower) external {
        accrueInterest();

        _executeAbsorb(msg.sender, borrower);
    }

    function buyCollateral(address collateralAsset, uint256 amountUsdc, uint256 minCollateralAmount)
        external
        whenNotPaused
    {
        require(amountUsdc > 0, "ZERO_AMOUNT");
        accrueInterest();

        _executeBuyCollateral(msg.sender, collateralAsset, amountUsdc, minCollateralAmount);
    }

    function withdrawReserves(address recipient, uint256 amountUsdc) external onlyOwner {
        require(amountUsdc > 0, "ZERO_AMOUNT");
        accrueInterest();

        _executeWithdrawReserves(recipient, amountUsdc);
    }

    function recapitalizeBadDebt(uint256 amountUsdc) external {
        require(amountUsdc > 0, "ZERO_AMOUNT");
        accrueInterest();

        _executeRecapitalizeBadDebt(msg.sender, amountUsdc);
    }

    function accrueInterest() public {
        uint256 newBorrowIndex = getCurrentBorrowIndex();
        uint256 newSupplyIndex = getCurrentSupplyIndex();
        uint256 interestAccrued = 0;
        uint256 reservesAccrued = 0;

        if (newBorrowIndex > borrowIndex && totalBorrowPrincipal > 0) {
            interestAccrued = totalBorrowPrincipal * (newBorrowIndex - borrowIndex) / WAD;
            reservesAccrued = interestAccrued * RESERVE_FACTOR_BPS / BPS;
        }

        borrowIndex = newBorrowIndex;
        supplyIndex = newSupplyIndex;
        protocolReservesUsdc += reservesAccrued;
        lastAccrualTimestamp = block.timestamp;

        emit InterestAccrued(newBorrowIndex, newSupplyIndex, interestAccrued, reservesAccrued);
    }

    function suppliedUsdc(address user) public view returns (uint256) {
        return _baseSupplyPrincipal[user] * getCurrentSupplyIndex() / WAD;
    }

    function debtUsdc(address user) public view returns (uint256) {
        return _borrowPrincipal[user] * getCurrentBorrowIndex() / WAD;
    }

    function totalSuppliedUsdc() public view returns (uint256) {
        return totalSupplyPrincipal * getCurrentSupplyIndex() / WAD;
    }

    function totalBorrowedUsdc() public view returns (uint256) {
        return totalBorrowPrincipal * getCurrentBorrowIndex() / WAD;
    }

    function getAvailableLiquidity() public view returns (uint256) {
        uint256 balance = USDC.balanceOf(address(this));
        if (balance <= protocolReservesUsdc) {
            return 0;
        }

        return balance - protocolReservesUsdc;
    }

    function usdc() external view returns (IERC20Metadata) {
        return USDC;
    }

    function oracle() external view returns (IPriceOracle) {
        return ORACLE;
    }

    function riskEngine() external view returns (RiskEngine) {
        return RISK_ENGINE;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function protocolReservesUSDC() external view returns (uint256) {
        return protocolReservesUsdc;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function badDebtUSDC() external view returns (uint256) {
        return badDebtUsdc;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function suppliedUSDC(address user) external view returns (uint256) {
        return suppliedUsdc(user);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function debtUSDC(address user) external view returns (uint256) {
        return debtUsdc(user);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function totalSuppliedUSDC() external view returns (uint256) {
        return totalSuppliedUsdc();
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function totalBorrowedUSDC() external view returns (uint256) {
        return totalBorrowedUsdc();
    }

    function getUtilization() public view returns (uint256) {
        return _getStoredUtilization();
    }

    function getBorrowRatePerSecond() public view returns (uint256) {
        return InterestRateLogic.borrowRate(
            _getStoredUtilization(),
            KINK_UTILIZATION,
            BASE_RATE_PER_SECOND,
            SLOPE_LOW_PER_SECOND,
            SLOPE_HIGH_PER_SECOND,
            WAD
        );
    }

    function getCurrentBorrowIndex() public view returns (uint256) {
        return InterestRateLogic.currentBorrowIndex(
            block.timestamp, lastAccrualTimestamp, totalBorrowPrincipal, borrowIndex, getBorrowRatePerSecond(), WAD
        );
    }

    function getCurrentSupplyIndex() public view returns (uint256) {
        if (block.timestamp <= lastAccrualTimestamp || totalBorrowPrincipal == 0 || totalSupplyPrincipal == 0) {
            return supplyIndex;
        }

        return InterestRateLogic.currentSupplyIndex(
            totalBorrowPrincipal,
            totalSupplyPrincipal,
            getCurrentBorrowIndex(),
            borrowIndex,
            supplyIndex,
            RESERVE_FACTOR_BPS,
            BPS,
            WAD
        );
    }

    function getHealthFactor(address user) public view returns (uint256) {
        (,,, uint256 healthFactor) = _getAccountDataWithDebt(user, debtUsdc(user));
        return healthFactor;
    }

    function getAccountData(address user)
        external
        view
        returns (uint256 totalCollateralUsd, uint256 borrowableUsd, uint256 debtUsd, uint256 healthFactor)
    {
        return _getAccountDataWithDebt(user, debtUsdc(user));
    }

    function getCollateralAssets() external view returns (address[] memory) {
        return collateralAssets;
    }

    function _getStoredUtilization() internal view returns (uint256) {
        return InterestRateLogic.utilization(totalSupplyPrincipal, supplyIndex, totalBorrowPrincipal, borrowIndex, WAD);
    }
}
