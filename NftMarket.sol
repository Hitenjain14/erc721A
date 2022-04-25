// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "ReentrancyGuard.sol";

interface IERC721 {
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function royaltyInfo(uint256 _tokenId, uint256 _salePrice)
        external
        view
        returns (address, uint256);

    function ownerOf(uint256 id) external view returns (address);
}

contract MarketPlace is ReentrancyGuard {
    event InstantBuy(
        address indexed from,
        address indexed to,
        uint256 price,
        uint256 indexed id
    );

    event Withdraw(address indexed receiver, uint256 val);
    event WithdrawBid(address indexed bidder, uint256 amount);
    event Bid(address indexed bidder, uint256 indexed nftId, uint256 bidAmount);
    event AssetClaimed(address indexed receiver, uint256 indexed nftId);

    event Start(address indexed owner, uint256 indexed id);
    event End(
        address indexed highestBidder,
        uint256 highestBid,
        uint256 indexed nftId
    );

    struct Auc {
        uint256 nftId;
        address creator;
        bool started;
        bool ended;
        uint32 endAt;
        address highestBidder;
        uint256 highestBid;
        uint256 startingBid;
        mapping(address => uint256) pendingReturns;
    }
    IERC721 public nftCollection;

    mapping(uint256 => Auc) public Auctions;

    mapping(address => uint256) public toPay;
    mapping(uint256 => uint256) public instantPrice;

    constructor(address _nft) {
        nftCollection = IERC721(_nft);
    }

    function setPrice(uint256 _id, uint256 _price) external {
        address owner = nftCollection.ownerOf(_id);

        require(msg.sender == owner, "not owner");

        instantPrice[_id] = _price;
    }

    function instantBuy(uint256 _id) external payable nonReentrant {
        require(instantPrice[_id] > 0, "Not on sale");
        require(msg.value >= instantPrice[_id], "Not enough ether");

        address owner = nftCollection.ownerOf(_id);

        nftCollection.transferFrom(owner, msg.sender, _id);

        (address royalty, uint256 royaltyFees) = nftCollection.royaltyInfo(
            _id,
            msg.value
        );

        toPay[royalty] += royaltyFees;
        toPay[owner] += (msg.value - royaltyFees);
        emit InstantBuy(owner, msg.sender, msg.value, _id);
    }

    function withdrawEth() external nonReentrant {
        require(toPay[msg.sender] > 0, "we owe no money");
        uint256 val = toPay[msg.sender];
        toPay[msg.sender] = 0;
        (bool success, ) = payable(msg.sender).call{value: val}("");
        require(success, "transaction failed");
        emit Withdraw(msg.sender, val);
    }

    function startAuction(
        uint256 _id,
        uint256 _starting,
        uint32 duration
    ) external {
        address owner = nftCollection.ownerOf(_id);
        require(msg.sender == owner, "Not owner");

        nftCollection.transferFrom(owner, address(this), _id);
        instantPrice[_id] = 0;

        Auc storage auc = Auctions[_id];
        auc.creator = owner;
        auc.endAt = uint32(block.timestamp + duration);
        auc.nftId = _id;
        auc.startingBid = _starting;
        auc.ended = false;
        auc.started = true;
        auc.highestBidder = owner;

        emit Start(owner, _id);
    }

    function endAuction(uint256 _id) external {
        Auc storage auc = Auctions[_id];

        require(auc.started, "Not started");
        require(auc.ended == false, "End already");
        require(auc.endAt <= block.timestamp, "Time left");
        auc.ended = true;
        if (auc.highestBid > 0) {
            (address royalty, uint256 royaltyFees) = nftCollection.royaltyInfo(
                _id,
                auc.highestBid
            );
            uint256 val = auc.highestBid - royaltyFees;
            toPay[auc.creator] += val;
            toPay[royalty] += royaltyFees;
        }

        emit End(auc.highestBidder, auc.highestBid, _id);
    }

    function bid(uint256 _id) external payable {
        Auc storage auc = Auctions[_id];
        require(auc.endAt > block.timestamp, "Ended");
        require(auc.started == true, "Not started");
        uint256 val = auc.pendingReturns[msg.sender] + msg.value;
        require(
            val > auc.highestBid && val > auc.startingBid,
            "Only higher than current bid"
        );
        auc.highestBid = val;
        auc.highestBidder = msg.sender;
        emit Bid(msg.sender, _id, msg.value);
    }

    function withdrawBid(uint256 _id) external nonReentrant {
        Auc storage auc = Auctions[_id];

        address winner = auc.highestBidder;
        require(msg.sender != winner, "Winner cannot withdraw");

        uint256 bal = auc.pendingReturns[msg.sender];
        require(bal > 0, "Not a bidder");
        auc.pendingReturns[msg.sender] = 0;
        (bool success, ) = payable(msg.sender).call{value: bal}("");
        require(success, "transaction failed");
        emit WithdrawBid(msg.sender, bal);
    }

    function claimAsset(uint256 _id) external nonReentrant {
        Auc storage auc = Auctions[_id];
        require(auc.endAt <= block.timestamp, "not ended");
        address winner = auc.highestBidder;

        require(winner != address(0), "WINNER_ZERO");

        nftCollection.transferFrom(address(this), winner, _id);
        emit AssetClaimed(winner, _id);
    }
}
