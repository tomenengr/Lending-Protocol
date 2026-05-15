// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "./interfaces/IERC20Metadata.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {RiskEngine} from "./RiskEngine.sol";

contract MiniLending {
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant CLOSE_FACTOR_BPS = 5_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant KINK_UTILIZATION = 0.8e18;
    uint256 public constant BASE_RATE_PER_SECOND = 634_195_839; // about 2% APR, scaled by 1e18
    uint256 public constant SLOPE_LOW_PER_SECOND = 2_536_783_358; // about 8% APR at 100% utilization
    uint256 public constant SLOPE_HIGH_PER_SECOND = 31_709_791_983; // about 100% APR after kink
    uint256 public constant RESERVE_FACTOR_BPS = 1_000; // 10% of interest goes to protocol reserves
    uint256 public constant GLOBAL_BORROW_CAP_USDC = 9_000_000e6;

    mapping(address user => mapping(address asset => uint256 amount)) public collateralBalance;
    mapping(address asset => uint256 amount) public totalCollateral;
    mapping(address asset => uint256 amount) public protocolCollateralBalance;
    mapping(address user => uint256 principal) private _baseSupplyPrincipal;
    mapping(address user => uint256 principal) private _borrowPrincipal;

    uint256 public totalSupplyPrincipal;
    uint256 public totalBorrowPrincipal;
    uint256 public borrowIndex;
    uint256 public supplyIndex;
    uint256 public lastAccrualTimestamp;
    uint256 public protocolReservesUSDC;
    uint256 public badDebtUSDC;

    address[] public collateralAssets;
    mapping(address asset => bool enabled) public isCollateralAsset;
    mapping(address asset => bool frozen) public assetFrozen;

    IERC20Metadata public immutable usdc;
    IPriceOracle public immutable oracle;
    RiskEngine public immutable riskEngine;
    address public owner;
    bool public paused;

    event CollateralDeposited(address indexed user, address indexed asset, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed asset, uint256 amount);
    event BaseSupplied(address indexed user, uint256 amountUSDC);
    event BaseWithdrawn(address indexed user, uint256 amountUSDC);
    event Borrowed(address indexed user, uint256 amountUSDC);
    event Repaid(address indexed user, uint256 amountUSDC);
    event InterestAccrued(
        uint256 borrowIndex, uint256 supplyIndex, uint256 interestAccruedUSDC, uint256 reservesAccruedUSDC
    );
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        address indexed collateralAsset,
        uint256 repaidUSDC,
        uint256 seizedCollateral
    );
    event Absorbed(
        address indexed absorber, address indexed borrower, uint256 debtAbsorbedUSDC, uint256 badDebtRecognizedUSDC
    );
    event CollateralPurchased(
        address indexed buyer, address indexed collateralAsset, uint256 paidUSDC, uint256 collateralPurchased
    );
    event ReservesWithdrawn(address indexed recipient, uint256 amountUSDC);
    event BadDebtRecapitalized(address indexed payer, uint256 amountUSDC);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PausedSet(bool paused);
    event AssetFrozenSet(address indexed asset, bool frozen);

    modifier onlyOwner() {
        require(msg.sender == owner, "ONLY_OWNER");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    constructor(
        IERC20Metadata usdc_,
        IPriceOracle oracle_,
        RiskEngine riskEngine_,
        address[] memory collateralAssets_
    ) {
        require(address(usdc_) != address(0), "ZERO_USDC");
        require(address(oracle_) != address(0), "ZERO_ORACLE");
        require(address(riskEngine_) != address(0), "ZERO_RISK_ENGINE");
        require(collateralAssets_.length > 0, "NO_COLLATERAL_ASSETS");

        usdc = usdc_;
        oracle = oracle_;
        riskEngine = riskEngine_;
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
        require(newOwner != address(0), "ZERO_OWNER");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setAssetFrozen(address asset, bool frozen) external onlyOwner {
        require(isCollateralAsset[asset], "UNSUPPORTED_ASSET");
        assetFrozen[asset] = frozen;
        emit AssetFrozenSet(asset, frozen);
    }

    function depositCollateral(address asset, uint256 amount) external whenNotPaused {
        require(isCollateralAsset[asset], "UNSUPPORTED_ASSET");
        require(!assetFrozen[asset], "ASSET_FROZEN");
        require(amount > 0, "ZERO_AMOUNT");
        RiskEngine.RiskConfig memory config = riskEngine.getRiskConfig(asset);
        require(totalCollateral[asset] + amount <= config.supplyCap, "SUPPLY_CAP_EXCEEDED");
        _enforceIsolationOnDeposit(msg.sender, asset, config);

        collateralBalance[msg.sender][asset] += amount;
        totalCollateral[asset] += amount;
        require(IERC20Metadata(asset).transferFrom(msg.sender, address(this), amount), "TRANSFER_FAILED");

        emit CollateralDeposited(msg.sender, asset, amount);
    }

    function supplyBase(uint256 amountUSDC) external whenNotPaused {
        require(amountUSDC > 0, "ZERO_AMOUNT");
        accrueInterest();

        uint256 principal = amountUSDC * WAD / supplyIndex;
        require(principal > 0, "ZERO_PRINCIPAL");

        _baseSupplyPrincipal[msg.sender] += principal;
        totalSupplyPrincipal += principal;

        require(usdc.transferFrom(msg.sender, address(this), amountUSDC), "TRANSFER_FAILED");
        emit BaseSupplied(msg.sender, amountUSDC);
    }

    function withdrawBase(uint256 amountUSDC) external whenNotPaused {
        require(amountUSDC > 0, "ZERO_AMOUNT");
        accrueInterest();

        uint256 supplied = suppliedUSDC(msg.sender);
        require(supplied >= amountUSDC, "INSUFFICIENT_SUPPLY");
        require(getAvailableLiquidity() >= amountUSDC, "INSUFFICIENT_LIQUIDITY");

        uint256 principal = _principalForAmountRoundUp(amountUSDC, supplyIndex);
        require(principal <= _baseSupplyPrincipal[msg.sender], "INSUFFICIENT_SUPPLY");

        _baseSupplyPrincipal[msg.sender] -= principal;
        totalSupplyPrincipal -= principal;

        require(usdc.transfer(msg.sender, amountUSDC), "TRANSFER_FAILED");
        emit BaseWithdrawn(msg.sender, amountUSDC);
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

    function borrow(uint256 amountUSDC) external whenNotPaused {
        require(amountUSDC > 0, "ZERO_AMOUNT");
        _requireNoFrozenCollateral(msg.sender);
        accrueInterest();
        require(getAvailableLiquidity() >= amountUSDC, "INSUFFICIENT_LIQUIDITY");
        require(totalBorrowedUSDC() + amountUSDC <= GLOBAL_BORROW_CAP_USDC, "BORROW_CAP_EXCEEDED");

        uint256 newDebt = debtUSDC(msg.sender) + amountUSDC;
        (, uint256 borrowableUsd, uint256 newDebtUsd, uint256 healthFactor) =
            _getAccountDataWithDebt(msg.sender, newDebt);

        require(newDebtUsd <= borrowableUsd, "BORROW_LIMIT_EXCEEDED");
        require(healthFactor >= MIN_HEALTH_FACTOR, "HF_TOO_LOW");

        uint256 principal = _principalForAmountRoundUp(amountUSDC, borrowIndex);
        _borrowPrincipal[msg.sender] += principal;
        totalBorrowPrincipal += principal;

        require(usdc.transfer(msg.sender, amountUSDC), "TRANSFER_FAILED");

        emit Borrowed(msg.sender, amountUSDC);
    }

    function repay(uint256 amountUSDC) external {
        require(amountUSDC > 0, "ZERO_AMOUNT");
        accrueInterest();

        uint256 debt = debtUSDC(msg.sender);
        require(debt > 0, "NO_DEBT");

        uint256 repayAmount = amountUSDC > debt ? debt : amountUSDC;
        uint256 principal;
        if (repayAmount == debt) {
            principal = _borrowPrincipal[msg.sender];
        } else {
            principal = repayAmount * WAD / borrowIndex;
            require(principal > 0, "ZERO_PRINCIPAL");
        }

        _borrowPrincipal[msg.sender] -= principal;
        totalBorrowPrincipal -= principal;

        require(usdc.transferFrom(msg.sender, address(this), repayAmount), "TRANSFER_FAILED");
        emit Repaid(msg.sender, repayAmount);
    }

    function liquidate(address borrower, address collateralAsset, uint256 repayAmountUSDC) external {
        require(isCollateralAsset[collateralAsset], "UNSUPPORTED_ASSET");
        require(repayAmountUSDC > 0, "ZERO_AMOUNT");
        accrueInterest();
        require(getHealthFactor(borrower) < MIN_HEALTH_FACTOR, "POSITION_HEALTHY");

        uint256 borrowerDebt = debtUSDC(borrower);
        uint256 maxRepay = borrowerDebt * CLOSE_FACTOR_BPS / BPS;
        uint256 actualRepay = repayAmountUSDC > maxRepay ? maxRepay : repayAmountUSDC;
        require(actualRepay > 0, "ZERO_REPAY");

        uint256 repayValueUsd = _debtToUsd(actualRepay);
        uint256 collateralPriceE18 = oracle.getPrice(collateralAsset);
        uint8 collateralDecimals = IERC20Metadata(collateralAsset).decimals();
        uint256 collateralToSeize =
            riskEngine.calculateSeizeAmount(collateralAsset, repayValueUsd, collateralPriceE18, collateralDecimals);

        require(collateralBalance[borrower][collateralAsset] >= collateralToSeize, "INSUFFICIENT_COLLATERAL_TO_SEIZE");

        uint256 principal;
        if (actualRepay == borrowerDebt) {
            principal = _borrowPrincipal[borrower];
        } else {
            principal = actualRepay * WAD / borrowIndex;
            require(principal > 0, "ZERO_PRINCIPAL");
        }

        _borrowPrincipal[borrower] -= principal;
        totalBorrowPrincipal -= principal;
        collateralBalance[borrower][collateralAsset] -= collateralToSeize;
        totalCollateral[collateralAsset] -= collateralToSeize;

        require(usdc.transferFrom(msg.sender, address(this), actualRepay), "TRANSFER_FAILED");
        require(IERC20Metadata(collateralAsset).transfer(msg.sender, collateralToSeize), "TRANSFER_FAILED");

        emit Liquidated(msg.sender, borrower, collateralAsset, actualRepay, collateralToSeize);
    }

    function absorb(address borrower) external {
        accrueInterest();
        require(getHealthFactor(borrower) < MIN_HEALTH_FACTOR, "POSITION_HEALTHY");

        uint256 borrowerDebt = debtUSDC(borrower);
        require(borrowerDebt > 0, "NO_DEBT");

        uint256 discountedCollateralValueUsd = 0;
        uint256 assetsLength = collateralAssets.length;
        for (uint256 i = 0; i < assetsLength; i++) {
            address asset = collateralAssets[i];
            uint256 balance = collateralBalance[borrower][asset];
            if (balance == 0) {
                continue;
            }

            uint256 collateralValueUsd = _assetToUsd(asset, balance);
            RiskEngine.RiskConfig memory config = riskEngine.getRiskConfig(asset);
            discountedCollateralValueUsd += collateralValueUsd * BPS / (BPS + config.liquidationBonusBps);

            collateralBalance[borrower][asset] = 0;
            totalCollateral[asset] -= balance;
            protocolCollateralBalance[asset] += balance;
        }

        uint256 borrowerDebtUsd = _debtToUsd(borrowerDebt);
        uint256 badDebtRecognized = 0;
        if (borrowerDebtUsd > discountedCollateralValueUsd) {
            badDebtRecognized = _usdToDebtRoundUp(borrowerDebtUsd - discountedCollateralValueUsd);
            _recognizeBadDebt(badDebtRecognized);
        }

        uint256 principal = _borrowPrincipal[borrower];
        _borrowPrincipal[borrower] = 0;
        totalBorrowPrincipal -= principal;

        emit Absorbed(msg.sender, borrower, borrowerDebt, badDebtRecognized);
    }

    function buyCollateral(address collateralAsset, uint256 amountUSDC, uint256 minCollateralAmount)
        external
        whenNotPaused
    {
        require(isCollateralAsset[collateralAsset], "UNSUPPORTED_ASSET");
        require(amountUSDC > 0, "ZERO_AMOUNT");
        accrueInterest();

        uint256 repayValueUsd = _debtToUsd(amountUSDC);
        uint256 collateralPriceE18 = oracle.getPrice(collateralAsset);
        uint8 collateralDecimals = IERC20Metadata(collateralAsset).decimals();
        uint256 collateralToBuy =
            riskEngine.calculateSeizeAmount(collateralAsset, repayValueUsd, collateralPriceE18, collateralDecimals);

        require(collateralToBuy >= minCollateralAmount, "SLIPPAGE");
        require(protocolCollateralBalance[collateralAsset] >= collateralToBuy, "INSUFFICIENT_PROTOCOL_COLLATERAL");

        protocolCollateralBalance[collateralAsset] -= collateralToBuy;

        require(usdc.transferFrom(msg.sender, address(this), amountUSDC), "TRANSFER_FAILED");
        require(IERC20Metadata(collateralAsset).transfer(msg.sender, collateralToBuy), "TRANSFER_FAILED");

        emit CollateralPurchased(msg.sender, collateralAsset, amountUSDC, collateralToBuy);
    }

    function withdrawReserves(address recipient, uint256 amountUSDC) external onlyOwner {
        require(recipient != address(0), "ZERO_RECIPIENT");
        require(amountUSDC > 0, "ZERO_AMOUNT");
        accrueInterest();
        require(amountUSDC <= protocolReservesUSDC, "INSUFFICIENT_RESERVES");
        require(usdc.balanceOf(address(this)) >= amountUSDC, "INSUFFICIENT_RESERVE_CASH");

        protocolReservesUSDC -= amountUSDC;

        require(usdc.transfer(recipient, amountUSDC), "TRANSFER_FAILED");
        emit ReservesWithdrawn(recipient, amountUSDC);
    }

    function recapitalizeBadDebt(uint256 amountUSDC) external {
        require(amountUSDC > 0, "ZERO_AMOUNT");
        accrueInterest();
        uint256 badDebt = badDebtUSDC;
        require(badDebt > 0, "NO_BAD_DEBT");

        uint256 actualAmount = amountUSDC > badDebt ? badDebt : amountUSDC;
        badDebtUSDC = badDebt - actualAmount;

        require(usdc.transferFrom(msg.sender, address(this), actualAmount), "TRANSFER_FAILED");
        emit BadDebtRecapitalized(msg.sender, actualAmount);
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
        protocolReservesUSDC += reservesAccrued;
        lastAccrualTimestamp = block.timestamp;

        emit InterestAccrued(newBorrowIndex, newSupplyIndex, interestAccrued, reservesAccrued);
    }

    function suppliedUSDC(address user) public view returns (uint256) {
        return _baseSupplyPrincipal[user] * getCurrentSupplyIndex() / WAD;
    }

    function debtUSDC(address user) public view returns (uint256) {
        return _borrowPrincipal[user] * getCurrentBorrowIndex() / WAD;
    }

    function totalSuppliedUSDC() public view returns (uint256) {
        return totalSupplyPrincipal * getCurrentSupplyIndex() / WAD;
    }

    function totalBorrowedUSDC() public view returns (uint256) {
        return totalBorrowPrincipal * getCurrentBorrowIndex() / WAD;
    }

    function getAvailableLiquidity() public view returns (uint256) {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance <= protocolReservesUSDC) {
            return 0;
        }

        return balance - protocolReservesUSDC;
    }

    function getUtilization() public view returns (uint256) {
        return _getStoredUtilization();
    }

    function getBorrowRatePerSecond() public view returns (uint256) {
        uint256 utilization = _getStoredUtilization();

        if (utilization <= KINK_UTILIZATION) {
            return BASE_RATE_PER_SECOND + utilization * SLOPE_LOW_PER_SECOND / WAD;
        }

        uint256 normalRate = BASE_RATE_PER_SECOND + KINK_UTILIZATION * SLOPE_LOW_PER_SECOND / WAD;
        uint256 excessUtilization = utilization - KINK_UTILIZATION;
        return normalRate + excessUtilization * SLOPE_HIGH_PER_SECOND / WAD;
    }

    function getCurrentBorrowIndex() public view returns (uint256) {
        if (block.timestamp <= lastAccrualTimestamp || totalBorrowPrincipal == 0) {
            return borrowIndex;
        }

        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        uint256 interestFactor = getBorrowRatePerSecond() * elapsed;
        return borrowIndex + borrowIndex * interestFactor / WAD;
    }

    function getCurrentSupplyIndex() public view returns (uint256) {
        if (block.timestamp <= lastAccrualTimestamp || totalBorrowPrincipal == 0 || totalSupplyPrincipal == 0) {
            return supplyIndex;
        }

        uint256 currentBorrowIndex = getCurrentBorrowIndex();
        uint256 interestAccrued = totalBorrowPrincipal * (currentBorrowIndex - borrowIndex) / WAD;
        uint256 supplierInterest = interestAccrued * (BPS - RESERVE_FACTOR_BPS) / BPS;
        return supplyIndex + supplierInterest * WAD / totalSupplyPrincipal;
    }

    function getHealthFactor(address user) public view returns (uint256) {
        (,,, uint256 healthFactor) = _getAccountDataWithDebt(user, debtUSDC(user));
        return healthFactor;
    }

    function getAccountData(address user)
        external
        view
        returns (uint256 totalCollateralUsd, uint256 borrowableUsd, uint256 debtUsd, uint256 healthFactor)
    {
        return _getAccountDataWithDebt(user, debtUSDC(user));
    }

    function getCollateralAssets() external view returns (address[] memory) {
        return collateralAssets;
    }

    function _getAccountDataWithDebt(address user, uint256 debtAmountUSDC)
        internal
        view
        returns (uint256 totalCollateralUsd, uint256 borrowableUsd, uint256 debtUsd, uint256 healthFactor)
    {
        uint256 adjustedCollateralUsd = 0;
        uint256 isolationDebtCeilingUsd = type(uint256).max;

        uint256 assetsLength = collateralAssets.length;
        for (uint256 i = 0; i < assetsLength; i++) {
            address asset = collateralAssets[i];
            uint256 balance = collateralBalance[user][asset];
            if (balance == 0) {
                continue;
            }

            uint256 collateralValueUsd = _assetToUsd(asset, balance);
            RiskEngine.RiskConfig memory config = riskEngine.getRiskConfig(asset);
            totalCollateralUsd += collateralValueUsd;
            borrowableUsd += collateralValueUsd * config.collateralFactorBps / BPS;
            adjustedCollateralUsd += riskEngine.calculateLiquidationThresholdUsd(asset, collateralValueUsd);
            if (config.isolated && config.debtCeilingUsd < isolationDebtCeilingUsd) {
                isolationDebtCeilingUsd = config.debtCeilingUsd;
            }
        }

        if (borrowableUsd > isolationDebtCeilingUsd) {
            borrowableUsd = isolationDebtCeilingUsd;
        }

        debtUsd = _debtToUsd(debtAmountUSDC);
        healthFactor = debtUsd == 0 ? type(uint256).max : adjustedCollateralUsd * WAD / debtUsd;
    }

    function _assetToUsd(address asset, uint256 amount) internal view returns (uint256) {
        uint256 priceE18 = oracle.getPrice(asset);
        uint8 decimals = IERC20Metadata(asset).decimals();
        return amount * priceE18 / (10 ** decimals);
    }

    function _debtToUsd(uint256 amountUSDC) internal view returns (uint256) {
        uint256 priceE18 = oracle.getPrice(address(usdc));
        return amountUSDC * priceE18 / (10 ** usdc.decimals());
    }

    function _enforceIsolationOnDeposit(address user, address depositAsset, RiskEngine.RiskConfig memory depositConfig)
        internal
        view
    {
        uint256 assetsLength = collateralAssets.length;
        for (uint256 i = 0; i < assetsLength; i++) {
            address asset = collateralAssets[i];
            if (asset == depositAsset || collateralBalance[user][asset] == 0) {
                continue;
            }

            RiskEngine.RiskConfig memory existingConfig = riskEngine.getRiskConfig(asset);
            require(!depositConfig.isolated && !existingConfig.isolated, "ISOLATION_MODE_COLLATERAL");
        }
    }

    function _requireNoFrozenCollateral(address user) internal view {
        uint256 assetsLength = collateralAssets.length;
        for (uint256 i = 0; i < assetsLength; i++) {
            address asset = collateralAssets[i];
            if (assetFrozen[asset] && collateralBalance[user][asset] > 0) {
                revert("FROZEN_COLLATERAL");
            }
        }
    }

    function _usdToDebtRoundUp(uint256 valueUsd) internal view returns (uint256) {
        uint256 priceE18 = oracle.getPrice(address(usdc));
        uint256 debtUnit = 10 ** usdc.decimals();
        return (valueUsd * debtUnit + priceE18 - 1) / priceE18;
    }

    function _recognizeBadDebt(uint256 amountUSDC) internal {
        uint256 reservesUsed = amountUSDC > protocolReservesUSDC ? protocolReservesUSDC : amountUSDC;
        protocolReservesUSDC -= reservesUsed;
        badDebtUSDC += amountUSDC - reservesUsed;
    }

    function _getStoredUtilization() internal view returns (uint256) {
        uint256 supplied = totalSupplyPrincipal * supplyIndex / WAD;
        if (supplied == 0) {
            return 0;
        }

        uint256 borrowed = totalBorrowPrincipal * borrowIndex / WAD;
        return borrowed * WAD / supplied;
    }

    function _principalForAmountRoundUp(uint256 amount, uint256 index) internal pure returns (uint256) {
        return (amount * WAD + index - 1) / index;
    }
}
