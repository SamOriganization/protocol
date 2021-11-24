// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "contracts/p0/interfaces/IMarket.sol";
import "contracts/libraries/Fixed.sol";

interface ITrading {
    /// @param auctionId An internal auction id, not the one from AssetManager
    /// @param bid A Bid
    function setBid(uint256 auctionId, Bid memory bid) external;
}

struct MockAuction {
    address origin;
    address sell;
    address buy;
    uint256 sellAmount; // {qSellTok}
    uint256 minBuyAmount; // {qBuyTok}
    uint256 startTime; // {sec}
    uint256 endTime; // {sec}
    bool isOpen;
}

struct Bid {
    address bidder;
    uint256 sellAmount; // MockAuction.sell
    uint256 buyAmount; // MockAuction.buy
}

/// A very simple trading partner that only supports 1 bid per auction
contract TradingMock is IMarket, ITrading {
    using FixLib for Fix;
    using SafeERC20 for IERC20;

    MockAuction[] internal _auctions;
    mapping(uint256 => Bid) _bids; // auctionId -> Bid

    /// @return auctionId The internal auction id
    function initiateAuction(
        address sell,
        address buy,
        uint256 sellAmount,
        uint256 minBuyAmount,
        uint256 auctionDuration
    ) external override returns (uint256 auctionId) {
        auctionId = _auctions.length;
        _auctions.push(
            MockAuction(
                msg.sender,
                sell,
                buy,
                sellAmount,
                minBuyAmount,
                block.timestamp,
                block.timestamp + auctionDuration,
                true
            )
        );
    }

    /// @dev Requires allowances
    function setBid(uint256 auctionId, Bid memory bid) external override {
        IERC20(_auctions[auctionId].buy).transferFrom(bid.bidder, address(this), bid.buyAmount);
        _bids[auctionId] = bid;
    }

    /// Can only be called after an auction.endTime is past
    function clear(uint256 auctionId)
        external
        override
        returns (uint256 clearingSellAmount, uint256 clearingBuyAmount)
    {
        MockAuction storage auction = _auctions[auctionId];
        require(msg.sender == auction.origin, "only origin can claim");
        require(auction.isOpen, "auction already closed");
        require(auction.endTime <= block.timestamp, "too early to close auction");

        Bid storage bid = _bids[auctionId];
        if (bid.sellAmount > 0) {
            Fix a = toFix(auction.minBuyAmount).divu(auction.sellAmount);
            Fix b = toFix(bid.buyAmount).divu(bid.sellAmount);

            // The bid is at an acceptable price
            if (a.lte(b)) {
                clearingSellAmount = Math.min(bid.sellAmount, auction.sellAmount);
                clearingBuyAmount = b.mulu(clearingSellAmount).toUint();
            }
        }

        // Transfer tokens
        IERC20(auction.sell).transfer(bid.bidder, clearingSellAmount);
        IERC20(auction.sell).transfer(auction.origin, auction.sellAmount - clearingSellAmount);
        IERC20(auction.buy).transfer(bid.bidder, bid.buyAmount - clearingBuyAmount);
        IERC20(auction.buy).transfer(auction.origin, clearingBuyAmount);
        auction.isOpen = false;
    }
}
