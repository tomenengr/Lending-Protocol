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
    uint256 public protocolReservesUsdc;
    uint256 public badDebtUsdc;

    address[] public collateralAssets;
    mapping(address asset => bool enabled) public isCollateralAsset;
    mapping(address asset => bool frozen) public assetFrozen;

    IERC20Metadata public immutable USDC;
    IPriceOracle public immutable ORACLE;
    RiskEngine public immutable RISK_ENGINE;
    address public owner;
    bool public paused;

    event CollateralDeposited(address indexed user, address indexed asset, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed asset, uint256 amount);
    event BaseSupplied(address indexed user, uint256 amountUsdc);
    event BaseWithdrawn(address indexed user, uint256 amountUsdc);
    event Borrowed(address indexed user, uint256 amountUsdc);
    event Repaid(address indexed user, uint256 amountUsdc);
    event InterestAccrued(
        uint256 borrowIndex, uint256 supplyIndex, uint256 interestAccruedUsdc, uint256 reservesAccruedUsdc
    );
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        address indexed collateralAsset,
        uint256 repaidUsdc,
        uint256 seizedCollateral
    );
    event Absorbed(
        address indexed absorber, address indexed borrower, uint256 debtAbsorbedUsdc, uint256 badDebtRecognizedUsdc
    );
    event CollateralPurchased(
        address indexed buyer, address indexed collateralAsset, uint256 paidUsdc, uint256 collateralPurchased
    );
    event ReservesWithdrawn(address indexed recipient, uint256 amountUsdc);
    event BadDebtRecapitalized(address indexed payer, uint256 amountUsdc);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PausedSet(bool paused);
    event AssetFrozenSet(address indexed asset, bool frozen);

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    modifier whenNotPaused() {
        _whenNotPaused();
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

        USDC = usdc_;
        ORACLE = oracle_;
        RISK_ENGINE = riskEngine_;
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

        uint256 principal = amountUsdc * WAD / supplyIndex;
        require(principal > 0, "ZERO_PRINCIPAL");

        _baseSupplyPrincipal[msg.sender] += principal;
        totalSupplyPrincipal += principal;

        require(USDC.transferFrom(msg.sender, address(this), amountUsdc), "TRANSFER_FAILED");
        emit BaseSupplied(msg.sender, amountUsdc);
    }

    function withdrawBase(uint256 amountUsdc) external whenNotPaused {
        require(amountUsdc > 0, "ZERO_AMOUNT");
        accrueInterest();

        uint256 supplied = suppliedUsdc(msg.sender);
        require(supplied >= amountUsdc, "INSUFFICIENT_SUPPLY");
        require(getAvailableLiquidity() >= amountUsdc, "INSUFFICIENT_LIQUIDITY");

        uint256 principal = _principalForAmountRoundUp(amountUsdc, supplyIndex);
        require(principal <= _baseSupplyPrincipal[msg.sender], "INSUFFICIENT_SUPPLY");

        _baseSupplyPrincipal[msg.sender] -= principal;
        totalSupplyPrincipal -= principal;

        require(USDC.transfer(msg.sender, amountUsdc), "TRANSFER_FAILED");
        emit BaseWithdrawn(msg.sender, amountUsdc);
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
        _requireNoFrozenCollateral(msg.sender);
        accrueInterest();
        require(getAvailableLiquidity() >= amountUsdc, "INSUFFICIENT_LIQUIDITY");
        require(totalBorrowedUsdc() + amountUsdc <= GLOBAL_BORROW_CAP_USDC, "BORROW_CAP_EXCEEDED");

        uint256 newDebt = debtUsdc(msg.sender) + amountUsdc;
        (, uint256 borrowableUsd, uint256 newDebtUsd, uint256 healthFactor) =
            _getAccountDataWithDebt(msg.sender, newDebt);

        require(newDebtUsd <= borrowableUsd, "BORROW_LIMIT_EXCEEDED");
        require(healthFactor >= MIN_HEALTH_FACTOR, "HF_TOO_LOW");

        uint256 principal = _principalForAmountRoundUp(amountUsdc, borrowIndex);
        _borrowPrincipal[msg.sender] += principal;
        totalBorrowPrincipal += principal;

        require(USDC.transfer(msg.sender, amountUsdc), "TRANSFER_FAILED");

        emit Borrowed(msg.sender, amountUsdc);
    }

    function repay(uint256 amountUsdc) external {
        require(amountUsdc > 0, "ZERO_AMOUNT");
        accrueInterest();

        uint256 debt = debtUsdc(msg.sender);
        require(debt > 0, "NO_DEBT");

        uint256 repayAmount = amountUsdc > debt ? debt : amountUsdc;
        uint256 principal;
        if (repayAmount == debt) {
            principal = _borrowPrincipal[msg.sender];
        } else {
            principal = repayAmount * WAD / borrowIndex;
            require(principal > 0, "ZERO_PRINCIPAL");
        }

        _borrowPrincipal[msg.sender] -= principal;
        totalBorrowPrincipal -= principal;

        require(USDC.transferFrom(msg.sender, address(this), repayAmount), "TRANSFER_FAILED");
        emit Repaid(msg.sender, repayAmount);
    }

    function liquidate(address borrower, address collateralAsset, uint256 repayAmountUsdc) external {
        require(isCollateralAsset[collateralAsset], "UNSUPPORTED_ASSET");
        require(repayAmountUsdc > 0, "ZERO_AMOUNT");
        accrueInterest();
        require(getHealthFactor(borrower) < MIN_HEALTH_FACTOR, "POSITION_HEALTHY");

        uint256 borrowerDebt = debtUsdc(borrower);
        uint256 maxRepay = borrowerDebt * CLOSE_FACTOR_BPS / BPS;
        uint256 actualRepay = repayAmountUsdc > maxRepay ? maxRepay : repayAmountUsdc;
        require(actualRepay > 0, "ZERO_REPAY");

        uint256 repayValueUsd = _debtToUsd(actualRepay);
        uint256 collateralPriceE18 = ORACLE.getPrice(collateralAsset);
        uint8 collateralDecimals = IERC20Metadata(collateralAsset).decimals();
        uint256 collateralToSeize =
            RISK_ENGINE.calculateSeizeAmount(collateralAsset, repayValueUsd, collateralPriceE18, collateralDecimals);

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

        require(USDC.transferFrom(msg.sender, address(this), actualRepay), "TRANSFER_FAILED");
        require(IERC20Metadata(collateralAsset).transfer(msg.sender, collateralToSeize), "TRANSFER_FAILED");

        emit Liquidated(msg.sender, borrower, collateralAsset, actualRepay, collateralToSeize);
    }

    function absorb(address borrower) external {
        accrueInterest();
        require(getHealthFactor(borrower) < MIN_HEALTH_FACTOR, "POSITION_HEALTHY");

        uint256 borrowerDebt = debtUsdc(borrower);
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
            RiskEngine.RiskConfig memory config = RISK_ENGINE.getRiskConfig(asset);
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

    function buyCollateral(address collateralAsset, uint256 amountUsdc, uint256 minCollateralAmount)
        external
        whenNotPaused
    {
        require(isCollateralAsset[collateralAsset], "UNSUPPORTED_ASSET");
        require(amountUsdc > 0, "ZERO_AMOUNT");
        accrueInterest();

        uint256 repayValueUsd = _debtToUsd(amountUsdc);
        uint256 collateralPriceE18 = ORACLE.getPrice(collateralAsset);
        uint8 collateralDecimals = IERC20Metadata(collateralAsset).decimals();
        uint256 collateralToBuy =
            RISK_ENGINE.calculateSeizeAmount(collateralAsset, repayValueUsd, collateralPriceE18, collateralDecimals);

        require(collateralToBuy >= minCollateralAmount, "SLIPPAGE");
        require(protocolCollateralBalance[collateralAsset] >= collateralToBuy, "INSUFFICIENT_PROTOCOL_COLLATERAL");

        protocolCollateralBalance[collateralAsset] -= collateralToBuy;

        require(USDC.transferFrom(msg.sender, address(this), amountUsdc), "TRANSFER_FAILED");
        require(IERC20Metadata(collateralAsset).transfer(msg.sender, collateralToBuy), "TRANSFER_FAILED");

        emit CollateralPurchased(msg.sender, collateralAsset, amountUsdc, collateralToBuy);
    }

    function withdrawReserves(address recipient, uint256 amountUsdc) external onlyOwner {
        require(recipient != address(0), "ZERO_RECIPIENT");
        require(amountUsdc > 0, "ZERO_AMOUNT");
        accrueInterest();
        require(amountUsdc <= protocolReservesUsdc, "INSUFFICIENT_RESERVES");
        require(USDC.balanceOf(address(this)) >= amountUsdc, "INSUFFICIENT_RESERVE_CASH");

        protocolReservesUsdc -= amountUsdc;

        require(USDC.transfer(recipient, amountUsdc), "TRANSFER_FAILED");
        emit ReservesWithdrawn(recipient, amountUsdc);
    }

    function recapitalizeBadDebt(uint256 amountUsdc) external {
        require(amountUsdc > 0, "ZERO_AMOUNT");
        accrueInterest();
        uint256 badDebt = badDebtUsdc;
        require(badDebt > 0, "NO_BAD_DEBT");

        uint256 actualAmount = amountUsdc > badDebt ? badDebt : amountUsdc;
        badDebtUsdc = badDebt - actualAmount;

        require(USDC.transferFrom(msg.sender, address(this), actualAmount), "TRANSFER_FAILED");
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

    function _getAccountDataWithDebt(address user, uint256 debtAmountUsdc)
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
            RiskEngine.RiskConfig memory config = RISK_ENGINE.getRiskConfig(asset);
            totalCollateralUsd += collateralValueUsd;
            borrowableUsd += collateralValueUsd * config.collateralFactorBps / BPS;
            adjustedCollateralUsd += RISK_ENGINE.calculateLiquidationThresholdUsd(asset, collateralValueUsd);
            if (config.isolated && config.debtCeilingUsd < isolationDebtCeilingUsd) {
                isolationDebtCeilingUsd = config.debtCeilingUsd;
            }
        }

        if (borrowableUsd > isolationDebtCeilingUsd) {
            borrowableUsd = isolationDebtCeilingUsd;
        }

        debtUsd = _debtToUsd(debtAmountUsdc);
        healthFactor = debtUsd == 0 ? type(uint256).max : adjustedCollateralUsd * WAD / debtUsd;
    }

    function _assetToUsd(address asset, uint256 amount) internal view returns (uint256) {
        uint256 priceE18 = ORACLE.getPrice(asset);
        uint8 decimals = IERC20Metadata(asset).decimals();
        return amount * priceE18 / (10 ** decimals);
    }

    function _debtToUsd(uint256 amountUsdc) internal view returns (uint256) {
        uint256 priceE18 = ORACLE.getPrice(address(USDC));
        return amountUsdc * priceE18 / (10 ** USDC.decimals());
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

            RiskEngine.RiskConfig memory existingConfig = RISK_ENGINE.getRiskConfig(asset);
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
        uint256 priceE18 = ORACLE.getPrice(address(USDC));
        uint256 debtUnit = 10 ** USDC.decimals();
        return (valueUsd * debtUnit + priceE18 - 1) / priceE18;
    }

    function _recognizeBadDebt(uint256 amountUsdc) internal {
        uint256 reservesUsed = amountUsdc > protocolReservesUsdc ? protocolReservesUsdc : amountUsdc;
        protocolReservesUsdc -= reservesUsed;
        badDebtUsdc += amountUsdc - reservesUsed;
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

    function _onlyOwner() internal view {
        require(msg.sender == owner, "ONLY_OWNER");
    }

    function _whenNotPaused() internal view {
        require(!paused, "PAUSED");
    }
}
