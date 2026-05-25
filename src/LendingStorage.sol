// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "./interfaces/IERC20Metadata.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {RiskEngine} from "./RiskEngine.sol";

abstract contract LendingStorage {
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
    /// @notice Global borrow cap in USDC (6-decimal). Configurable by owner via setGlobalBorrowCap().
    uint256 public globalBorrowCapUsdc = 9_000_000e6;

    mapping(address user => mapping(address asset => uint256 amount)) public collateralBalance;
    mapping(address asset => uint256 amount) public totalCollateral;
    mapping(address asset => uint256 amount) public protocolCollateralBalance;
    mapping(address user => uint256 principal) internal _baseSupplyPrincipal;
    mapping(address user => uint256 principal) internal _borrowPrincipal;

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
    bool private _unlocked = true;

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
    event GlobalBorrowCapSet(uint256 newCapUsdc);
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

    modifier nonReentrant() {
        require(_unlocked, "REENTRANT");
        _unlocked = false;
        _;
        _unlocked = true;
    }

    constructor(IERC20Metadata usdc_, IPriceOracle oracle_, RiskEngine riskEngine_) {
        USDC = usdc_;
        ORACLE = oracle_;
        RISK_ENGINE = riskEngine_;
    }

    function _onlyOwner() internal view {
        require(msg.sender == owner, "ONLY_OWNER");
    }

    function _whenNotPaused() internal view {
        require(!paused, "PAUSED");
    }
}
