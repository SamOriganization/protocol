// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "contracts/libraries/Fixed.sol";
import "contracts/plugins/assets/AbstractCollateral.sol";

/**
 * @title EURFiatCollateral
 * @notice Collateral plugin for a EURO fiatcoin collateral, like EURT
 * Expected: {tok} == {ref}, {ref} is pegged to {target} or defaults, {target} != {UoA}
 */
contract EURFiatCollateral is Collateral {
    using FixLib for uint192;
    using OracleLib for AggregatorV3Interface;

    AggregatorV3Interface public immutable uoaPerTargetFeed; // {UoA/target}

    uint192 public immutable defaultThreshold; // {%} e.g. 0.05

    /// @param uoaPerRefFeed_ {UoA/ref}
    /// @param uoaPerTargetFeed_ {UoA/target}
    /// @param maxTradeVolume_ {UoA} The max trade volume, in UoA
    /// @param oracleTimeout_ {s} The number of seconds until a oracle value becomes invalid
    /// @param defaultThreshold_ {%} A value like 0.05 that represents a deviation tolerance
    /// @param delayUntilDefault_ {s} The number of seconds deviation must occur before default
    constructor(
        uint192 fallbackPrice_,
        AggregatorV3Interface uoaPerRefFeed_,
        AggregatorV3Interface uoaPerTargetFeed_,
        IERC20Metadata erc20_,
        IERC20Metadata rewardERC20_,
        uint192 maxTradeVolume_,
        uint48 oracleTimeout_,
        bytes32 targetName_,
        uint192 defaultThreshold_,
        uint256 delayUntilDefault_
    )
        Collateral(
            fallbackPrice_,
            uoaPerRefFeed_,
            erc20_,
            rewardERC20_,
            maxTradeVolume_,
            oracleTimeout_,
            targetName_,
            delayUntilDefault_
        )
    {
        require(defaultThreshold_ > 0, "defaultThreshold zero");
        require(address(uoaPerTargetFeed_) != address(0), "missing uoaPerTarget feed");
        defaultThreshold = defaultThreshold_;
        uoaPerTargetFeed = uoaPerTargetFeed_;
    }

    /// @return {UoA/tok} Our best guess at the market price of 1 whole token in UoA
    function strictPrice() public view virtual override returns (uint192) {
        // {UoA/tok} = {UoA/ref} * {ref/tok}
        return chainlinkFeed.price(oracleTimeout);
    }

    /// Refresh exchange rates and update default status.
    /// @dev This default check assumes that the collateral's price() value is expected
    /// to stay close to pricePerTarget() * targetPerRef(). If that's not true for the
    /// collateral you're defining, you MUST redefine refresh()!!
    function refresh() external virtual override {
        if (whenDefault <= block.timestamp) return;
        CollateralStatus oldStatus = status();

        bool ok;

        // solhint-disable no-empty-blocks

        // p1 {UoA/ref}
        try chainlinkFeed.price_(oracleTimeout) returns (uint192 p1) {
            // We don't need the return value from this next feed, but it should still function
            // p2 {UoA/target}
            try uoaPerTargetFeed.price_(oracleTimeout) returns (uint192 p2) {
                if (p2 > 0) {
                    // {target/ref}
                    uint192 peg = targetPerRef();

                    // D18{target/ref}= D18{target/ref} * D18{1} / D18
                    uint192 delta = (peg * defaultThreshold) / FIX_ONE;

                    // {target/ref} = {UoA/ref} / {UoA/target}
                    uint192 p = p1.div(p2);

                    // If the price is below the default-threshold price, default eventually
                    if (p >= peg - delta && p <= peg + delta) ok = true;
                }
            } catch {}
        } catch {}

        // solhint-enable no-empty-blocks

        if (ok) {
            whenDefault = NEVER;
        } else {
            whenDefault = Math.min(block.timestamp + delayUntilDefault, whenDefault);
        }

        CollateralStatus newStatus = status();
        if (oldStatus != newStatus) {
            emit DefaultStatusChanged(oldStatus, newStatus);
        }
    }

    /// @return {UoA/target} The price of a target unit in UoA
    function pricePerTarget() public view override returns (uint192) {
        return uoaPerTargetFeed.price(oracleTimeout);
    }
}
