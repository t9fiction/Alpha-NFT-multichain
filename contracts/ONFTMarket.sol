// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ONFT721} from "@layerzerolabs/lz-evm-oapp-v2/contracts/onft721/ONFT721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";

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
    error NotApproved(address operator, uint256 tokenId);
    error NoFundsToWithdraw();
    error InvalidURI(string uri);
    error MaxPriceExceeded(uint256 price, uint256 maxPrice);
    error InvalidRoyaltyInfo(address royaltyReceiver, uint256 royaltyAmount);
    error InvalidFeeBps(uint256 feeBps);
    error ChainIdTooLarge();
}

/**
 * @title ONFTMarket
 * @dev Multichain NFT Marketplace using LayerZero V2 ONFT721
 */
contract ONFTMarket is ONFT721, ERC721URIStorage, ReentrancyGuard, Ownable {
    // Immutable chain ID
    uint256 private immutable CHAIN_ID;

    // Sequential token ID counter
    uint256 private _tokenIdCounter;

    // Marketplace fee in basis points (e.g., 250 = 2.5%)
    uint256 public feeBps;
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant MAX_FEE_BPS = 1000; // 10% maximum fee
    uint256 public constant MAX_PRICE = 1000000 ether; // Maximum price limit
    uint256[] private listedTokenIds;
    uint256 private marketplaceFees;

    // Struct for market listings
    struct MarketItem {
        uint256 tokenId;
        address seller;
        uint256 price;
        bool isListed;
        address royaltyReceiver;
        uint256 royaltyAmount;
    }

    // Mapping of tokenId to listing
    mapping(uint256 => MarketItem) public idToMarketItem;
    mapping(uint256 => uint256) private listedTokenIdIndices;

    // Seller data tracking
    mapping(address => uint256[]) private sellerItems; // Tracks seller listings
    mapping(uint256 => uint256) private sellerItemIndices; // Maps tokenId to its index in the sellerItems array

    // Royalty information
    mapping(uint256 => address) private royaltyReceivers;
    mapping(uint256 => uint256) private royaltyAmounts; // in basis points

    uint256 private _itemsSold; // Tracks total sold items

    // For pagination in view functions
    uint256 public constant PAGE_SIZE = 50;

    // Events
    event TokenCreated(
        uint256 indexed tokenId,
        address indexed owner,
        string tokenURI,
        uint256 price,
        address royaltyReceiver,
        uint256 royaltyBps
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
        uint256 price,
        uint256 marketplaceFee,
        uint256 royaltyAmount
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
    event MarketplaceFeesWithdrawn(address indexed owner, uint256 amount);
    event FeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event RoyaltyInfoUpdated(
        uint256 indexed tokenId,
        address receiver,
        uint256 bps
    );

    /**
     * @dev Constructor
     * @param _name Name of the NFT
     * @param _symbol Symbol of the NFT
     * @param _lzEndpoint LayerZero endpoint address
     * @param _owner Owner of the contract
     * @param _chainId Current chain ID
     * @param _feeBps Initial marketplace fee in basis points
     */
    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _owner,
        uint256 _chainId,
        uint256 _feeBps
    ) ONFT721(_name, _symbol, _lzEndpoint, _owner) Ownable(_owner) {
        if (_chainId > type(uint128).max) revert ONFTMarket__Errors.ChainIdTooLarge();
        if (_feeBps > MAX_FEE_BPS)
            revert ONFTMarket__Errors.InvalidFeeBps(_feeBps);
        CHAIN_ID = _chainId;
        _tokenIdCounter = 1;
        feeBps = _feeBps;
    }

    /**
     * @dev Set marketplace fee (owner only)
     * @param _feeBps New fee in basis points (max 10%)
     */
    function setFeeBps(uint256 _feeBps) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS)
            revert ONFTMarket__Errors.InvalidFeeBps(_feeBps);
        uint256 oldFeeBps = feeBps;
        feeBps = _feeBps;
        emit FeeBpsUpdated(oldFeeBps, _feeBps);
    }

    /**
     * @dev Set royalty information for a token (token owner only)
     * @param tokenId Token ID
     * @param receiver Royalty receiver address
     * @param royaltyBps Royalty percentage in basis points
     */
    function setRoyaltyInfo(
        uint256 tokenId,
        address receiver,
        uint256 royaltyBps
    ) external {
        if (!_exists(tokenId))
            revert ONFTMarket__Errors.InvalidTokenId(tokenId);
        if (ownerOf(tokenId) != msg.sender)
            revert ONFTMarket__Errors.OnlyOwnerAllowed(msg.sender, tokenId);
        if (royaltyBps > MAX_FEE_BPS)
            revert ONFTMarket__Errors.InvalidRoyaltyInfo(receiver, royaltyBps);

        royaltyReceivers[tokenId] = receiver;
        royaltyAmounts[tokenId] = royaltyBps;
        emit RoyaltyInfoUpdated(tokenId, receiver, royaltyBps);
    }

    /**
     * @dev Create a new NFT
     * @param tokenURI Token URI for the new NFT
     * @param price Initial price for the NFT
     * @param royaltyReceiver Address to receive royalties
     * @param royaltyBps Royalty percentage in basis points
     * @return newTokenId The ID of the newly created token
     */
    function createToken(
        string memory tokenURI,
        uint256 price,
        address royaltyReceiver,
        uint256 royaltyBps
    ) external nonReentrant returns (uint256) {
        if (price <= 0) revert ONFTMarket__Errors.InvalidPrice(price);
        if (price > MAX_PRICE)
            revert ONFTMarket__Errors.MaxPriceExceeded(price, MAX_PRICE);
        if (_tokenIdCounter == type(uint256).max) revert("Token ID overflow");
        if (bytes(tokenURI).length == 0)
            revert ONFTMarket__Errors.InvalidURI(tokenURI);
        if (royaltyBps > MAX_FEE_BPS)
            revert ONFTMarket__Errors.InvalidRoyaltyInfo(
                royaltyReceiver,
                royaltyBps
            );

        // Generate chain-specific token ID to avoid cross-chain collisions
        uint256 newTokenId;
        unchecked {
            // Higher bits store chain ID, lower bits store token counter
            newTokenId = (CHAIN_ID << 128) | _tokenIdCounter++;
        }
        _safeMint(msg.sender, newTokenId);
        _setTokenURI(newTokenId, tokenURI);

        // Set royalty information
        royaltyReceivers[newTokenId] = royaltyReceiver;
        royaltyAmounts[newTokenId] = royaltyBps;

        idToMarketItem[newTokenId] = MarketItem({
            tokenId: newTokenId,
            seller: address(0),
            price: price,
            isListed: false,
            royaltyReceiver: royaltyReceiver,
            royaltyAmount: royaltyBps
        });

        emit TokenCreated(
            newTokenId,
            msg.sender,
            tokenURI,
            price,
            royaltyReceiver,
            royaltyBps
        );
        return newTokenId;
    }

    /**
     * @dev List an NFT for sale
     * @param tokenId Token ID to list
     * @param price Listing price
     */
    function listToken(uint256 tokenId, uint256 price) external nonReentrant {
        if (!_exists(tokenId))
            revert ONFTMarket__Errors.InvalidTokenId(tokenId);
        if (ownerOf(tokenId) != msg.sender)
            revert ONFTMarket__Errors.OnlyOwnerAllowed(msg.sender, tokenId);
        if (price <= 0) revert ONFTMarket__Errors.InvalidPrice(price);
        if (price > MAX_PRICE)
            revert ONFTMarket__Errors.MaxPriceExceeded(price, MAX_PRICE);
        if (idToMarketItem[tokenId].isListed)
            revert ONFTMarket__Errors.TokenAlreadyListed(tokenId);
        if (
            getApproved(tokenId) != address(this) &&
            !isApprovedForAll(msg.sender, address(this))
        ) revert ONFTMarket__Errors.NotApproved(address(this), tokenId);

        listedTokenIds.push(tokenId);
        listedTokenIdIndices[tokenId] = listedTokenIds.length - 1;

        idToMarketItem[tokenId].seller = msg.sender;
        idToMarketItem[tokenId].price = price;
        idToMarketItem[tokenId].isListed = true;

        // Add to seller's items list and track its index
        sellerItems[msg.sender].push(tokenId);
        sellerItemIndices[tokenId] = sellerItems[msg.sender].length - 1;

        _transfer(msg.sender, address(this), tokenId);

        emit TokenListed(tokenId, msg.sender, price);
    }

    /**
     * @dev Buy a listed NFT
     * @param tokenId Token ID to purchase
     */
    function createMarketSale(uint256 tokenId) external payable nonReentrant {
        if (!_exists(tokenId))
            revert ONFTMarket__Errors.InvalidTokenId(tokenId);

        MarketItem memory item = idToMarketItem[tokenId];
        if (!item.isListed) revert ONFTMarket__Errors.TokenNotListed(tokenId);
        if (msg.value < item.price)
            revert ONFTMarket__Errors.IncorrectPrice(item.price, msg.value);

        address seller = item.seller;
        uint256 price = item.price;

        // Update state first (checks-effects-interactions pattern)
        idToMarketItem[tokenId].seller = address(0);
        idToMarketItem[tokenId].price = 0;
        idToMarketItem[tokenId].isListed = false;
        _itemsSold++;

        // Remove from listedTokenIds array
        _removeFromListedTokens(tokenId);

        // Remove from seller's items
        _removeFromSellerItems(tokenId, seller);

        // Transfer NFT to buyer
        _transfer(address(this), msg.sender, tokenId);

        // Calculate fees and proceeds
        uint256 marketplaceFee = (price * feeBps) / BPS_DENOMINATOR;
        uint256 royaltyAmount = 0;
        address royaltyReceiver = royaltyReceivers[tokenId];

        // Calculate royalty if a receiver is set
        if (royaltyReceiver != address(0)) {
            royaltyAmount = (price * royaltyAmounts[tokenId]) / BPS_DENOMINATOR;
        }

        marketplaceFees += marketplaceFee;
        uint256 sellerProceeds = price - marketplaceFee - royaltyAmount;

        // Transfer proceeds using pull-over-push pattern for security
        if (sellerProceeds > 0) {
            (bool sellerSuccess, ) = seller.call{value: sellerProceeds}("");
            if (!sellerSuccess) revert ONFTMarket__Errors.TransferFailed();
        }

        if (royaltyAmount > 0 && royaltyReceiver != address(0)) {
            (bool royaltySuccess, ) = royaltyReceiver.call{
                value: royaltyAmount
            }("");
            if (!royaltySuccess) revert ONFTMarket__Errors.TransferFailed();
        }

        // Refund excess payment
        if (msg.value > price) {
            (bool refundSuccess, ) = msg.sender.call{value: msg.value - price}(
                ""
            );
            if (!refundSuccess) revert ONFTMarket__Errors.TransferFailed();
        }

        emit TokenSold(
            tokenId,
            seller,
            msg.sender,
            price,
            marketplaceFee,
            royaltyAmount
        );
    }

    /**
     * @dev Cancel a listing
     * @param tokenId Token ID to delist
     */
    function cancelListing(uint256 tokenId) external nonReentrant {
        if (!_exists(tokenId))
            revert ONFTMarket__Errors.InvalidTokenId(tokenId);

        MarketItem memory item = idToMarketItem[tokenId];
        if (!item.isListed) revert ONFTMarket__Errors.TokenNotListed(tokenId);
        if (item.seller != msg.sender)
            revert ONFTMarket__Errors.OnlySellerAllowed(msg.sender, tokenId);

        address seller = item.seller;

        // Update state
        idToMarketItem[tokenId].seller = address(0);
        idToMarketItem[tokenId].price = 0;
        idToMarketItem[tokenId].isListed = false;

        // Remove from listedTokenIds array
        _removeFromListedTokens(tokenId);

        // Remove from seller's items
        _removeFromSellerItems(tokenId, seller);

        _transfer(address(this), msg.sender, tokenId);

        emit ListingCancelled(tokenId, msg.sender);
    }

    /**
     * @dev Update listing price
     * @param tokenId Token ID to update
     * @param newPrice New price for the listing
     */
    function updateTokenPrice(
        uint256 tokenId,
        uint256 newPrice
    ) external nonReentrant {
        if (!_exists(tokenId))
            revert ONFTMarket__Errors.InvalidTokenId(tokenId);

        MarketItem memory item = idToMarketItem[tokenId];
        if (!item.isListed) revert ONFTMarket__Errors.TokenNotListed(tokenId);
        if (item.seller != msg.sender)
            revert ONFTMarket__Errors.OnlySellerAllowed(msg.sender, tokenId);
        if (newPrice <= 0) revert ONFTMarket__Errors.InvalidPrice(newPrice);
        if (newPrice > MAX_PRICE)
            revert ONFTMarket__Errors.MaxPriceExceeded(newPrice, MAX_PRICE);

        idToMarketItem[tokenId].price = newPrice;

        emit TokenPriceUpdated(tokenId, newPrice);
    }

    /**
     * @dev Bridge NFT to another chain
     * @param dstEid Destination chain endpoint ID
     * @param tokenId Token ID to bridge
     * @param adapterParams LayerZero adapter parameters
     */
    function sendOnft(
        uint32 dstEid,
        uint256 tokenId,
        bytes calldata adapterParams
    ) external payable nonReentrant {
        if (!_exists(tokenId))
            revert ONFTMarket__Errors.InvalidTokenId(tokenId);
        if (ownerOf(tokenId) != msg.sender)
            revert ONFTMarket__Errors.OnlyOwnerAllowed(msg.sender, tokenId);
        if (idToMarketItem[tokenId].isListed)
            revert ONFTMarket__Errors.TokenAlreadyListed(tokenId);

        // Capture token URI before burning
        string memory tokenURI = tokenURI(tokenId);

        // Get royalty info to send across chain
        address royaltyReceiver = royaltyReceivers[tokenId];
        uint256 royaltyBps = royaltyAmounts[tokenId];

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

        // Encode payload with tokenURI and royalty info
        bytes memory payload = abi.encode(
            msg.sender,
            tokenId,
            tokenURI,
            royaltyReceiver,
            royaltyBps
        );

        // Perform cross-chain transfer
        _lzSend(dstEid, payload, adapterParams, msg.value, payable(msg.sender));

        emit TokenBridged(tokenId, msg.sender, dstEid, tokenURI);
    }

    /**
     * @dev Override _lzSend to include custom payload
     */
    function _lzSend(
        uint32 _dstEid,
        bytes memory _payload,
        bytes calldata _adapterParams,
        uint256 _nativeFee,
        address payable _refundAddress
    ) internal virtual {
        // Send the message with the custom payload
        _lzSendBase(
            _dstEid,
            _payload,
            _adapterParams,
            _refundAddress,
            _nativeFee,
            false
        );
    }

    /**
     * @dev Override _debitFrom for cross-chain burn
     */
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

    /**
     * @dev Override _creditTo for cross-chain mint
     */
    function _creditTo(
        uint16,
        address _toAddress,
        uint256 _tokenId,
        bytes memory _payload
    ) internal virtual override {
        // Decode payload to get tokenURI and royalty info
        (
            address sender,
            uint256 tokenId,
            string memory tokenURI,
            address royaltyReceiver,
            uint256 royaltyBps
        ) = abi.decode(_payload, (address, uint256, string, address, uint256));

        _safeMint(_toAddress, _tokenId);
        _setTokenURI(_tokenId, tokenURI);

        // Set royalty info
        royaltyReceivers[_tokenId] = royaltyReceiver;
        royaltyAmounts[_tokenId] = royaltyBps;

        idToMarketItem[_tokenId] = MarketItem({
            tokenId: _tokenId,
            seller: address(0),
            price: 0,
            isListed: false,
            royaltyReceiver: royaltyReceiver,
            royaltyAmount: royaltyBps
        });

        emit TokenReceived(_tokenId, _toAddress, tokenURI);
    }

    /**
     * @dev Override _lzReceive to handle custom payload with error handling
     */
    function _lzReceive(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes memory _payload
    ) internal virtual override {
        try super._lzReceive(_srcChainId, _srcAddress, _nonce, _payload) {
            // Successfully processed
            // Decode payload for additional logic
            (
                address toAddress,
                uint256 tokenId,
                string memory tokenURI,
                address royaltyReceiver,
                uint256 royaltyBps
            ) = abi.decode(
                    _payload,
                    (address, uint256, string, address, uint256)
                );

            emit TokenReceived(tokenId, toAddress, tokenURI);
        } catch (bytes memory reason) {
            // Log the failure but don't revert - LayerZero will handle retry logic
            // Could add custom recovery logic here if needed
            // Following 2 lines and the recoverFailedMint function are for if LayerZero don't implement recover
             // (, uint256 tokenId,,,) = abi.decode(_payload, (address, uint256, string, address, uint256));
             // failedPayloads[tokenId] = _payload;
        }
    }

    /**
     * 
     * Check if LayerZero implements the failed mint otherwise use this function
     * 
     */
    /**
     * 
    function recoverFailedMint(uint256 tokenId) external onlyOwner {
        bytes memory payload = failedPayloads[tokenId];
        if (payload.length == 0) revert("No failed payload");
        (address toAddress, , string memory tokenURI, address royaltyReceiver, uint256 royaltyBps) = abi.decode(
            payload, (address, uint256, string, address, uint256)
        );
        delete failedPayloads[tokenId];
        _safeMint(toAddress, tokenId);
        _setTokenURI(tokenId, tokenURI);
        royaltyReceivers[tokenId] = royaltyReceiver;
        royaltyAmounts[tokenId] = royaltyBps;
        idToMarketItem[tokenId] = MarketItem({
            tokenId: tokenId,
            seller: address(0),
            price: 0,
            isListed: false,
            royaltyReceiver: royaltyReceiver,
            royaltyAmount: royaltyBps
        });
        emit TokenReceived(tokenId, toAddress, tokenURI);
    }
    */

    /**
     * @dev Fetch market items with pagination
     * @param page Page number (0-indexed)
     * @return items Array of listed market items for the requested page
     * @return totalPages Total number of pages
     */
    function fetchMarketItems(
        uint256 page
    ) external view returns (MarketItem[] memory items, uint256 totalPages) {
        uint256 totalItems = listedTokenIds.length;
        totalPages = (totalItems + PAGE_SIZE - 1) / PAGE_SIZE; // ceiling division

        uint256 startIdx = page * PAGE_SIZE;
        uint256 endIdx = startIdx + PAGE_SIZE;
        if (endIdx > totalItems) {
            endIdx = totalItems;
        }

        uint256 itemCount = endIdx - startIdx;
        items = new MarketItem[](itemCount);

        for (uint256 i = 0; i < itemCount; i++) {
            items[i] = idToMarketItem[listedTokenIds[startIdx + i]];
        }

        return (items, totalPages);
    }

    /**
     * @dev Fetch all market items (only for compatibility, use pagination for production)
     * @return items Array of all listed market items
     */
    function fetchAllMarketItems() external view returns (MarketItem[] memory) {
        MarketItem[] memory items = new MarketItem[](listedTokenIds.length);
        for (uint256 i = 0; i < listedTokenIds.length; i++) {
            items[i] = idToMarketItem[listedTokenIds[i]];
        }
        return items;
    }

    /**
     * @dev Fetch NFTs owned by the caller with pagination
     * @param page Page number (0-indexed)
     * @return items Array of owned NFTs for the requested page
     * @return totalPages Total number of pages
     */
    function fetchMyNFTs(
        uint256 page
    ) external view returns (MarketItem[] memory items, uint256 totalPages) {
        // First count total owned NFTs
        uint256 totalOwned = 0;
        for (uint256 i = 1; i < _tokenIdCounter; i++) {
            if (_exists(i) && ownerOf(i) == msg.sender) totalOwned++;
        }

        totalPages = (totalOwned + PAGE_SIZE - 1) / PAGE_SIZE; // ceiling division

        uint256 startIdx = page * PAGE_SIZE;
        if (startIdx >= totalOwned) {
            return (new MarketItem[](0), totalPages);
        }

        uint256 endIdx = startIdx + PAGE_SIZE;
        if (endIdx > totalOwned) {
            endIdx = totalOwned;
        }

        items = new MarketItem[](endIdx - startIdx);

        // Iterate and find owned tokens for the requested page
        uint256 currentItem = 0;
        uint256 itemsAdded = 0;

        for (
            uint256 i = 1;
            i < _tokenIdCounter && itemsAdded < items.length;
            i++
        ) {
            if (_exists(i) && ownerOf(i) == msg.sender) {
                if (currentItem >= startIdx && currentItem < endIdx) {
                    items[itemsAdded] = idToMarketItem[i];
                    itemsAdded++;
                }
                currentItem++;
            }
        }

        return (items, totalPages);
    }

    /**
     * @dev Fetch items listed by the caller
     * @return items Array of listed items by caller
     */
    function fetchItemsListed() external view returns (MarketItem[] memory) {
        uint256[] storage userItems = sellerItems[msg.sender];
        uint256 itemCount = userItems.length;

        MarketItem[] memory items = new MarketItem[](itemCount);
        for (uint256 i = 0; i < itemCount; i++) {
            uint256 tokenId = userItems[i];
            items[i] = idToMarketItem[tokenId];
        }

        return items;
    }

    /**
     * @dev Filter items by price range with pagination
     * @param minPrice Minimum price
     * @param maxPrice Maximum price
     * @param page Page number (0-indexed)
     * @return items Array of items within price range for the requested page
     * @return totalPages Total number of pages
     */
    function fetchItemsByPrice(
        uint256 minPrice,
        uint256 maxPrice,
        uint256 page
    ) external view returns (MarketItem[] memory items, uint256 totalPages) {
        // First count total items in price range
        uint256 totalInRange = 0;
        for (uint256 i = 0; i < listedTokenIds.length; i++) {
            uint256 tokenId = listedTokenIds[i];
            MarketItem storage item = idToMarketItem[tokenId];
            if (
                item.isListed &&
                item.price >= minPrice &&
                item.price <= maxPrice
            ) {
                totalInRange++;
            }
        }

        totalPages = (totalInRange + PAGE_SIZE - 1) / PAGE_SIZE; // ceiling division

        uint256 startIdx = page * PAGE_SIZE;
        if (startIdx >= totalInRange) {
            return (new MarketItem[](0), totalPages);
        }

        uint256 endIdx = startIdx + PAGE_SIZE;
        if (endIdx > totalInRange) {
            endIdx = totalInRange;
        }

        items = new MarketItem[](endIdx - startIdx);

        // Iterate and find items in price range for the requested page
        uint256 currentItem = 0;
        uint256 itemsAdded = 0;

        for (
            uint256 i = 0;
            i < listedTokenIds.length && itemsAdded < items.length;
            i++
        ) {
            uint256 tokenId = listedTokenIds[i];
            MarketItem storage item = idToMarketItem[tokenId];
            if (
                item.isListed &&
                item.price >= minPrice &&
                item.price <= maxPrice
            ) {
                if (currentItem >= startIdx && currentItem < endIdx) {
                    items[itemsAdded] = item;
                    itemsAdded++;
                }
                currentItem++;
            }
        }

        return (items, totalPages);
    }

    /**
     * @dev Get marketplace statistics
     * @return totalItems Total items created
     * @return totalSold Total items sold
     * @return totalUnsold Total unsold items
     * @return totalListed Total currently listed items
     * @return totalFees Total marketplace fees collected
     */
    function getMarketplaceStats()
        external
        view
        returns (
            uint256 totalItems,
            uint256 totalSold,
            uint256 totalUnsold,
            uint256 totalListed,
            uint256 totalFees
        )
    {
        totalItems = _tokenIdCounter - 1;
        totalSold = _itemsSold;
        totalUnsold = totalItems - totalSold;
        totalListed = listedTokenIds.length;
        totalFees = marketplaceFees;
        return (totalItems, totalSold, totalUnsold, totalListed, totalFees);
    }

    /**
     * @dev Withdraw marketplace fees
     */
    function withdrawMarketplaceFees() external onlyOwner nonReentrant {
        uint256 feesToWithdraw = marketplaceFees;
        if (feesToWithdraw == 0) revert ONFTMarket__Errors.NoFundsToWithdraw();

        marketplaceFees = 0; // Set to 0 before transfer to prevent reentrancy

        (bool success, ) = owner().call{value: feesToWithdraw}("");
        if (!success) revert ONFTMarket__Errors.TransferFailed();

        emit MarketplaceFeesWithdrawn(owner(), feesToWithdraw);
    }

    /**
     * @dev Withdraw entire contract balance (emergency function)
     */
    function withdrawAll() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) revert ONFTMarket__Errors.NoFundsToWithdraw();

        // Reset marketplace fees since we're withdrawing everything
        marketplaceFees = 0;

        (bool success, ) = owner().call{value: balance}("");
        if (!success) revert ONFTMarket__Errors.TransferFailed();

        emit Withdrawn(owner(), balance);
    }

    /**
     * @dev Helper function to remove token from listedTokenIds array
     * @param tokenId Token ID to remove
     */
    function _removeFromListedTokens(uint256 tokenId) internal {
        uint256 index = listedTokenIdIndices[tokenId];
        uint256 lastIndex = listedTokenIds.length - 1;

        // If this isn't the last item, swap with the last one
        if (index != lastIndex) {
            uint256 lastTokenId = listedTokenIds[lastIndex];
            listedTokenIds[index] = lastTokenId;
            listedTokenIdIndices[lastTokenId] = index;
        }

        // Remove the last item
        listedTokenIds.pop();
        delete listedTokenIdIndices[tokenId];
    }

    function royaltyInfo(
        uint256 tokenId,
        uint256 salePrice
    ) external view returns (address receiver, uint256 royaltyAmount) {
        receiver = royaltyReceivers[tokenId];
        royaltyAmount = (salePrice * royaltyAmounts[tokenId]) / BPS_DENOMINATOR;
    }

    /**
     * @dev Override supportsInterface
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ONFT721, ERC721) returns (bool) {
        return
            interfaceId == type(IERC2981).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /**
     * @dev Override tokenURI
     */
    function tokenURI(
        uint256 tokenId
    ) public view override(ONFT721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    /**
     * @dev Override _burn
     */
    function _burn(
        uint256 tokenId
    ) internal override(ONFT721, ERC721URIStorage) {
        if (idToMarketItem[tokenId].isListed) {
            _removeFromSellerItems(tokenId, idToMarketItem[tokenId].seller);
            _removeFromListedTokens(tokenId);
            idToMarketItem[tokenId].isListed = false;
            idToMarketItem[tokenId].seller = address(0);
        }
        super._burn(tokenId);
    }

    /**
     * @dev Override _update
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override(ONFT721, ERC721) returns (address) {
        return super._update(to, tokenId, auth);
    }

    /**
     * @dev Fallback to receive ETH
     */
    receive() external payable {}
}
