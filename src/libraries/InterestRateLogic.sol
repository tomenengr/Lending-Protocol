// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library InterestRateLogic {
    function utilization(
        uint256 totalSupplyPrincipal,
        uint256 supplyIndex,
        uint256 totalBorrowPrincipal,
        uint256 borrowIndex,
        uint256 wad
    ) internal pure returns (uint256) {
        uint256 supplied = totalSupplyPrincipal * supplyIndex / wad;
        if (supplied == 0) {
            return 0;
        }

        uint256 borrowed = totalBorrowPrincipal * borrowIndex / wad;
        return borrowed * wad / supplied;
    }

    function borrowRate(
        uint256 utilization_,
        uint256 kinkUtilization,
        uint256 baseRatePerSecond,
        uint256 slopeLowPerSecond,
        uint256 slopeHighPerSecond,
        uint256 wad
    ) internal pure returns (uint256) {
        if (utilization_ <= kinkUtilization) {
            return baseRatePerSecond + utilization_ * slopeLowPerSecond / wad;
        }

        uint256 normalRate = baseRatePerSecond + kinkUtilization * slopeLowPerSecond / wad;
        uint256 excessUtilization = utilization_ - kinkUtilization;
        return normalRate + excessUtilization * slopeHighPerSecond / wad;
    }

    function currentBorrowIndex(
        uint256 blockTimestamp,
        uint256 lastAccrualTimestamp,
        uint256 totalBorrowPrincipal,
        uint256 borrowIndex,
        uint256 borrowRatePerSecond,
        uint256 wad
    ) internal pure returns (uint256) {
        if (blockTimestamp <= lastAccrualTimestamp || totalBorrowPrincipal == 0) {
            return borrowIndex;
        }

        uint256 elapsed = blockTimestamp - lastAccrualTimestamp;
        uint256 interestFactor = borrowRatePerSecond * elapsed;
        return borrowIndex + borrowIndex * interestFactor / wad;
    }

    function currentSupplyIndex(
        uint256 totalBorrowPrincipal,
        uint256 totalSupplyPrincipal,
        uint256 currentBorrowIndex_,
        uint256 borrowIndex,
        uint256 supplyIndex,
        uint256 reserveFactorBps,
        uint256 bps,
        uint256 wad
    ) internal pure returns (uint256) {
        if (totalBorrowPrincipal == 0 || totalSupplyPrincipal == 0) {
            return supplyIndex;
        }

        uint256 interestAccrued = totalBorrowPrincipal * (currentBorrowIndex_ - borrowIndex) / wad;
        uint256 supplierInterest = interestAccrued * (bps - reserveFactorBps) / bps;
        return supplyIndex + supplierInterest * wad / totalSupplyPrincipal;
    }

    function principalForAmountRoundUp(uint256 amount, uint256 index, uint256 wad) internal pure returns (uint256) {
        return (amount * wad + index - 1) / index;
    }
}
