// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ONFT721} from "@layerzerolabs/lz-evm-oapp-v2/contracts/onft721/ONFT721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Custom errors
library ONFTMarket__Errors {
    error TokenAlreadyExists(uint256 tokenId);
    error Unauthorized(address caller);
    error IncorrectPrice(uint256 expected, uint256 received);
    error TransferFailed();
    error OnlyOwnerAllowed(address caller, uint256 tokenId);
    error OnlySellerAllowed(address caller, uint256 tokenId);
    error InvalidTokenId(uint256 tokenId);
    error TokenNotListed(uint256 tokenId);
    error TokenAlreadyListed(uint256 tokenId);
    error InsufficientFee(uint256 required, uint256 provided);
    error InvalidPrice(uint256 price);
}

// Multichain NFT Marketplace using LayerZero V2 ONFT721
contract ONFTMarket is ONFT721, ERC721URIStorage, ReentrancyGuard, Ownable {
    // Immutable chain ID
    uint256 private immutable CHAIN_ID;

    // Sequential token ID counter
    uint256 private _tokenIdCounter;

    // Marketplace fee in basis points (e.g., 250 = 2.5%)
    uint256 public constant FEE_BPS = 250;
    uint256 public constant BPS_DENOMINATOR = 10000;

    // Struct for market listings
    struct MarketItem {
        uint256 tokenId;
        address seller;
        uint256 price;
        bool isListed;
    }

    // Mapping of tokenId to listing
    mapping(uint256 => MarketItem) public idToMarketItem;

    // Events
    event TokenCreated(
        uint256 indexed tokenId,
        address indexed owner,
        string tokenURI,
        uint256 price
    );
    event TokenListed(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 price
    );
    event TokenSold(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        uint256 price
    );
    event ListingCancelled(uint256 indexed tokenId, address indexed seller);
    event TokenPriceUpdated(uint256 indexed tokenId, uint256 newPrice);
    event TokenBridged(
        uint256 indexed tokenId,
        address indexed owner,
        uint32 dstEid,
        string tokenURI
    );
    event TokenReceived(
        uint256 indexed tokenId,
        address indexed owner,
        string tokenURI
    );
    event Withdrawn(address indexed owner, uint256 amount);

    // Constructor
    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _owner,
        uint256 _chainId
    ) ONFT721(_name, _symbol, _lzEndpoint, _owner) Ownable(_owner) {
        CHAIN_ID = _chainId;
        _tokenIdCounter = 1;
    }

    // Create a new NFT
    function createToken(
        string memory tokenURI,
        uint256 price
    ) external nonReentrant returns (uint256) {
        if (price <= 0) revert ONFTMarket__Errors.InvalidPrice(price);

        uint256 newTokenId = _tokenIdCounter++;
        _safeMint(msg.sender, newTokenId);
        _setTokenURI(newTokenId, tokenURI);

        idToMarketItem[newTokenId] = MarketItem({
            tokenId: newTokenId,
            seller: address(0),
            price: price,
            isListed: false
        });

        emit TokenCreated(newTokenId, msg.sender, tokenURI, price);
        return newTokenId;
    }

    // List an NFT for sale
    function listToken(uint256 tokenId, uint256 price) external nonReentrant {
        if (!_exists(tokenId)) revert ONFTMarket__Errors.InvalidTokenId(tokenId);
        if (ownerOf(tokenId) != msg.sender)
            revert ONFTMarket__Errors.OnlyOwnerAllowed(msg.sender, tokenId);
        if (price <= 0) revert ONFTMarket__Errors.InvalidPrice(price);
        if (idToMarketItem[tokenId].isListed)
            revert ONFTMarket__Errors.TokenAlreadyListed(tokenId);

        idToMarketItem[tokenId].seller = msg.sender;
        idToMarketItem[tokenId].price = price;
        idToMarketItem[tokenId].isListed = true;

        _transfer(msg.sender, address(this), tokenId);

        emit TokenListed(tokenId, msg.sender, price);
    }

    // Buy a listed NFT
    function createMarketSale(uint256 tokenId) external payable nonReentrant {
        if (!_exists(tokenId)) revert ONFTMarket__Errors.InvalidTokenId(tokenId);
        MarketItem memory item = idToMarketItem[tokenId];
        if (!item.isListed) revert ONFTMarket__Errors.TokenNotListed(tokenId);
        if (msg.value < item.price)
            revert ONFTMarket__Errors.IncorrectPrice(item.price, msg.value);

        address seller = item.seller;
        uint256 price = item.price;

        // Calculate fee and seller proceeds
        uint256 fee = (price * FEE_BPS) / BPS_DENOMINATOR;
        uint256 sellerProceeds = price - fee;

        // Update listing
        idToMarketItem[tokenId].seller = address(0);
        idToMarketItem[tokenId].price = 0;
        idToMarketItem[tokenId].isListed = false;

        // Transfer NFT to buyer
        _transfer(address(this), msg.sender, tokenId);

        // Transfer proceeds to seller
        (bool sellerSuccess, ) = seller.call{value: sellerProceeds}("");
        if (!sellerSuccess) revert ONFTMarket__Errors.TransferFailed();

        // Transfer fee to contract (for owner withdrawal)
        (bool feeSuccess, ) = address(this).call{value: fee}("");
        if (!feeSuccess) revert ONFTMarket__Errors.TransferFailed();

        // Refund excess payment
        if (msg.value > price) {
            (bool refundSuccess, ) = msg.sender.call{value: msg.value - price}(
                ""
            );
            if (!refundSuccess) revert ONFTMarket__Errors.TransferFailed();
        }

        emit TokenSold(tokenId, seller, msg.sender, price);
    }

    // Cancel a listing
    function cancelListing(uint256 tokenId) external nonReentrant {
        if (!_exists(tokenId)) revert ONFTMarket__Errors.InvalidTokenId(tokenId);
        MarketItem memory item = idToMarketItem[tokenId];
        if (!item.isListed) revert ONFTMarket__Errors.TokenNotListed(tokenId);
        if (item.seller != msg.sender)
            revert ONFTMarket__Errors.OnlySellerAllowed(msg.sender, tokenId);

        idToMarketItem[tokenId].seller = address(0);
        idToMarketItem[tokenId].price = 0;
        idToMarketItem[tokenId].isListed = false;

        _transfer(address(this), msg.sender, tokenId);

        emit ListingCancelled(tokenId, msg.sender);
    }

    // Update listing price
    function updateTokenPrice(
        uint256 tokenId,
        uint256 newPrice
    ) external nonReentrant {
        if (!_exists(tokenId)) revert ONFTMarket__Errors.InvalidTokenId(tokenId);
        MarketItem memory item = idToMarketItem[tokenId];
        if (!item.isListed) revert ONFTMarket__Errors.TokenNotListed(tokenId);
        if (item.seller != msg.sender)
            revert ONFTMarket__Errors.OnlySellerAllowed(msg.sender, tokenId);
        if (newPrice <= 0) revert ONFTMarket__Errors.InvalidPrice(newPrice);

        idToMarketItem[tokenId].price = newPrice;

        emit TokenPriceUpdated(tokenId, newPrice);
    }

    // Bridge NFT to another chain
    function sendOnft(
        uint32 dstEid,
        uint256 tokenId,
        bytes calldata adapterParams
    ) external payable nonReentrant {
        if (!_exists(tokenId)) revert ONFTMarket__Errors.InvalidTokenId(tokenId);
        if (ownerOf(tokenId) != msg.sender)
            revert ONFTMarket__Errors.OnlyOwnerAllowed(msg.sender, tokenId);
        if (idToMarketItem[tokenId].isListed)
            revert ONFTMarket__Errors.TokenAlreadyListed(tokenId);

        string memory tokenURI = tokenURI(tokenId);

        // Estimate LayerZero fees
        (uint256 nativeFee, ) = estimateSendFee(
            dstEid,
            msg.sender,
            tokenId,
            false,
            adapterParams
        );
        if (msg.value < nativeFee)
            revert ONFTMarket__Errors.InsufficientFee(nativeFee, msg.value);

        // Perform cross-chain transfer
        _lzSend(
            dstEid,
            msg.sender,
            tokenId,
            false,
            adapterParams,
            msg.value,
            payable(msg.sender)
        );

        emit TokenBridged(tokenId, msg.sender, dstEid, tokenURI);
    }

    // Override _debitFrom for cross-chain burn
    function _debitFrom(
        address _from,
        uint16,
        bytes memory,
        uint256 _tokenId
    ) internal virtual override {
        if (!_exists(_tokenId))
            revert ONFTMarket__Errors.InvalidTokenId(_tokenId);
        if (ownerOf(_tokenId) != _from)
            revert ONFTMarket__Errors.OnlyOwnerAllowed(_from, _tokenId);
        if (idToMarketItem[_tokenId].isListed)
            revert ONFTMarket__Errors.TokenAlreadyListed(_tokenId);

        _burn(_tokenId);
    }

    // Override _creditTo for cross-chain mint
    function _creditTo(
        uint16,
        address _toAddress,
        uint256 _tokenId
    ) internal virtual override {
        _safeMint(_toAddress, _tokenId);

        // Restore token URI and market item (if it exists)
        string memory tokenURI = tokenURI(_tokenId);
        idToMarketItem[_tokenId] = MarketItem({
            tokenId: _tokenId,
            seller: address(0),
            price: 0,
            isListed: false
        });

        emit TokenReceived(_tokenId, _toAddress, tokenURI);
    }

    // Fetch all listed market items
    function fetchMarketItems() external view returns (MarketItem[] memory) {
        uint256 itemCount = 0;
        for (uint256 i = 1; i < _tokenIdCounter; i++) {
            if (idToMarketItem[i].isListed) itemCount++;
        }

        MarketItem[] memory items = new MarketItem[](itemCount);
        uint256 currentIndex = 0;
        for (uint256 i = 1; i < _tokenIdCounter; i++) {
            if (idToMarketItem[i].isListed) {
                items[currentIndex] = idToMarketItem[i];
                currentIndex++;
            }
        }

        return items;
    }

    // Fetch NFTs owned by the caller
    function fetchMyNFTs() external view returns (MarketItem[] memory) {
        uint256 itemCount = 0;
        for (uint256 i = 1; i < _tokenIdCounter; i++) {
            if (_exists(i) && ownerOf(i) == msg.sender) itemCount++;
        }

        MarketItem[] memory items = new MarketItem[](itemCount);
        uint256 currentIndex = 0;
        for (uint256 i = 1; i < _tokenIdCounter; i++) {
            if (_exists(i) && ownerOf(i) == msg.sender) {
                items[currentIndex] = idToMarketItem[i];
                currentIndex++;
            }
        }

        return items;
    }

    // Fetch items listed by the caller
    function fetchItemsListed() external view returns (MarketItem[] memory) {
        uint256 itemCount = 0;
        for (uint256 i = 1; i < _tokenIdCounter; i++) {
            if (idToMarketItem[i].isListed && idToMarketItem[i].seller == msg.sender)
                itemCount++;
        }

        MarketItem[] memory items = new MarketItem[](itemCount);
        uint256 currentIndex = 0;
        for (uint256 i = 1; i < _tokenIdCounter; i++) {
            if (idToMarketItem[i].isListed && idToMarketItem[i].seller == msg.sender) {
                items[currentIndex] = idToMarketItem[i];
                currentIndex++;
            }
        }

        return items;
    }

    // Get market item details
    function getMarketItem(
        uint256 tokenId
    ) external view returns (MarketItem memory) {
        if (!_exists(tokenId)) revert ONFTMarket__Errors.InvalidTokenId(tokenId);
        return idToMarketItem[tokenId];
    }

    // Get current token ID counter
    function getCurrentTokenId() external view returns (uint256) {
        return _tokenIdCounter;
    }

    // Withdraw contract balance
    function withdraw() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) revert ONFTMarket__Errors.TransferFailed();

        (bool success, ) = owner().call{value: balance}("");
        if (!success) revert ONFTMarket__Errors.TransferFailed();

        emit Withdrawn(owner(), balance);
    }

    // Override supportsInterface
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ONFT721, ERC721) returns (bool) {
        return
            interfaceId == type(IONFT721).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // Override tokenURI
    function tokenURI(
        uint256 tokenId
    ) public view override(ONFT721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    // Override _burn
    function _burn(
        uint256 tokenId
    ) internal override(ONFT721, ERC721URIStorage) {
        super._burn(tokenId);
    }

    // Override _update
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override(ONFT721, ERC721) returns (address) {
        return super._update(to, tokenId, auth);
    }

    // Fallback to receive ETH
    receive() external payable {}
}