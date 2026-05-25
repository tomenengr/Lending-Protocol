// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library InterestRateLogic {
    /// @notice Calculates utilization rate using the standard formula:
    ///         utilization = totalBorrows / (cash + totalBorrows - reserves)
    ///         This matches Compound V3 / Aave semantics: the denominator is the
    ///         total pool (funds currently available + funds lent out), not the
    ///         inflated supplier-side balance which includes accrued interest.
    /// @param cash        Current token balance held by the protocol (e.g. USDC.balanceOf)
    /// @param reserves    Protocol reserve balance (excluded from the pool)
    /// @param totalBorrowPrincipal  Stored borrow principal (index-scaled via borrowIndex)
    /// @param borrowIndex Current borrow index (WAD-scaled)
    /// @param wad         WAD constant (1e18)
    function utilization(
        uint256 cash,
        uint256 reserves,
        uint256 totalBorrowPrincipal,
        uint256 borrowIndex,
        uint256 wad
    ) internal pure returns (uint256) {
        uint256 borrowed = totalBorrowPrincipal * borrowIndex / wad;
        // Denominator: actual pool size = available cash (net of reserves) + outstanding borrows
        uint256 poolSize = (cash >= reserves ? cash - reserves : 0) + borrowed;
        if (poolSize == 0) {
            return 0;
        }

        // Cap at WAD (100%) to prevent rate explosion in edge cases (e.g. bad-debt scenarios)
        uint256 util = borrowed * wad / poolSize;
        return util > wad ? wad : util;
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
        // Supply index growth must be relative to the *current supply balance* (principal × index),
        // not the raw principal count. Using raw principal would overstate the index growth because
        // supplyIndex already embeds prior interest. Correct formula:
        //   Δ supplyIndex = supplierInterest × WAD / currentTotalSupplyBalance
        //   currentTotalSupplyBalance = totalSupplyPrincipal × supplyIndex / WAD
        // ⟹ Δ supplyIndex = supplierInterest × WAD² / (totalSupplyPrincipal × supplyIndex)
        uint256 currentTotalSupply = totalSupplyPrincipal * supplyIndex / wad;
        return supplyIndex + supplierInterest * wad / currentTotalSupply;
    }

    function principalForAmountRoundUp(uint256 amount, uint256 index, uint256 wad) internal pure returns (uint256) {
        return (amount * wad + index - 1) / index;
    }
}
