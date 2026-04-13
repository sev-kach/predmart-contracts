// SPDX-License-Identifier: MIT
// contracts/src/PredmartPoolLib.sol
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PredmartPoolLib
/// @notice Extracted pure computation for the lending pool — deployed as a separate contract
///         to keep PredmartLendingPool under the 24 KB EIP-170 size limit.
/// @dev All functions are `external` so the library is linked via DELEGATECALL (not inlined).
library PredmartPoolLib {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Liquidation parameters
    uint256 public constant LIQUIDATION_BUFFER = 0.10e18;

    // Interest & reserve
    uint256 public constant RESERVE_FACTOR = 0.10e18;
    uint256 public constant SECONDS_PER_YEAR = 365.25 days;

    // Interest rate model (kink model)
    uint256 public constant BASE_RATE = 0.10e18;
    uint256 public constant KINK = 0.80e18;
    uint256 public constant RATE_AT_KINK = 0.42e18;
    uint256 public constant MAX_RATE = 3.17e18;
    uint256 public constant SLOPE1 = 0.40e18;
    uint256 public constant SLOPE2 = 13.75e18;

    // Profit fee — charged on borrower profit at position close
    uint256 public constant PROFIT_FEE = 0.10e18;          // 10% total
    uint256 public constant PROFIT_FEE_POOL = 0.07e18;     // 7% to lending pool
    uint256 public constant PROFIT_FEE_PROTOCOL = 0.03e18; // 3% to protocol

    // Liquidation incentive — paid to liquidator as % of debt
    uint256 public constant LIQUIDATOR_FEE = 0.05e18;

    /*//////////////////////////////////////////////////////////////
                     LIQUIDATION CALCULATION
    //////////////////////////////////////////////////////////////*/

    /// @notice v2 simplified liquidation — always seize ALL collateral
    function calcLiquidation(
        uint256 collateralAmount,
        uint256 debt
    ) external pure returns (uint256 seizeCollateral, uint256 repayAmount) {
        seizeCollateral = collateralAmount;
        repayAmount = debt;
    }

    /*//////////////////////////////////////////////////////////////
                        PROFIT FEE CALCULATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate profit fee split between pool and protocol
    /// @param surplus USDC returned to borrower after debt repayment
    /// @param initialEquity Borrower's original USDC investment (0 = legacy position, no fee)
    /// @return poolFee Amount added to lending pool (7% of profit)
    /// @return protocolFee Amount sent to protocol (3% of profit)
    function calcProfitFee(
        uint256 surplus,
        uint256 initialEquity
    ) external pure returns (uint256 poolFee, uint256 protocolFee) {
        if (initialEquity == 0 || surplus <= initialEquity) return (0, 0);
        uint256 profit = surplus - initialEquity;
        poolFee = profit.mulDiv(PROFIT_FEE_POOL, 1e18);
        protocolFee = profit.mulDiv(PROFIT_FEE_PROTOCOL, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                       RISK MODEL — INTERPOLATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Piecewise linear interpolation between 7 anchor points
    function interpolate(
        uint256[7] memory prices,
        uint256[7] memory values,
        uint256 price
    ) external pure returns (uint256) {
        if (price <= prices[0]) return values[0];
        if (price >= prices[6]) return values[6];

        for (uint256 i = 1; i < 7; i++) {
            if (price <= prices[i]) {
                return values[i - 1]
                    + (price - prices[i - 1]).mulDiv(values[i] - values[i - 1], prices[i] - prices[i - 1]);
            }
        }

        return values[6];
    }

    /*//////////////////////////////////////////////////////////////
                       INTEREST RATE MODEL
    //////////////////////////////////////////////////////////////*/

    /// @notice Kink-based borrow rate calculation
    function calcBorrowRate(uint256 utilization) external pure returns (uint256) {
        if (utilization <= KINK) {
            return BASE_RATE + utilization.mulDiv(SLOPE1, 1e18);
        } else {
            return RATE_AT_KINK + (utilization - KINK).mulDiv(SLOPE2, 1e18);
        }
    }

    /// @notice Compute pending interest and reserve share
    function calcPendingInterest(
        uint256 borrowAssets,
        uint256 elapsed,
        uint256 utilization
    ) external pure returns (uint256 interest, uint256 reserveShare) {
        if (elapsed == 0 || borrowAssets == 0) return (0, 0);

        uint256 rate;
        if (utilization <= KINK) {
            rate = BASE_RATE + utilization.mulDiv(SLOPE1, 1e18);
        } else {
            rate = RATE_AT_KINK + (utilization - KINK).mulDiv(SLOPE2, 1e18);
        }

        interest = borrowAssets.mulDiv(rate * elapsed, SECONDS_PER_YEAR * 1e18, Math.Rounding.Ceil);
        reserveShare = interest.mulDiv(RESERVE_FACTOR, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                       HEALTH FACTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Health factor = (collateralValue * threshold) / debt
    function calcHealthFactor(
        uint256 collateralAmount,
        uint256 debt,
        uint256 price,
        uint256 threshold
    ) external pure returns (uint256) {
        if (debt == 0) return type(uint256).max;
        uint256 collateralValue = collateralAmount.mulDiv(price, 1e18);
        return collateralValue.mulDiv(threshold, debt);
    }

}
