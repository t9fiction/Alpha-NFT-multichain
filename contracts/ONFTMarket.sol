// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IONFT721} from "@layerzerolabs/onft-evm/contracts/onft721/interfaces/IONFT721.sol";
import {ONFT721Core} from "@layerzerolabs/onft-evm/contracts/onft721/ONFT721Core.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

library ONFTMarket__Errors {
    error TokenAlreadyExists(uint256 tokenId);
    error Unauthorized(address caller);
    error IncorrectPrice(uint256 expected, uint256 received);
    error TransferFailed();
    error OnlyOwnerAllowed(address caller, uint256 tokenId);
    error OnlySellerAllowed(address caller, uint256 tokenId);
    error InvalidTokenId(uint256 tokenId);
}

contract ONFTMarket is ONFT721Core, IONFT721, ERC721URIStorage, ReentrancyGuard, Ownable {
    // Immutable variables
    uint private immutable CHAIN_ID;
    
    // Sequential token ID counter
    uint256 private _tokenIdCounter;
    
    // Events
    event TokenCreated(
        uint indexed tokenId,
        address indexed owner,
        string tokenURI,
        uint price
    );

    event TokenSent(
        uint indexed tokenId,
        address indexed sender,
        uint16 indexed dstChainId,
        string tokenURI
    );

    event TokenReceived(
        uint indexed tokenId,
        address indexed sender,
        string tokenURI
    );

    event MarketSale(
        uint indexed tokenId,
        address indexed seller,
        address indexed owner
    );

    event LzReceive(bytes indexed payload);
    
    event ListingCancelled(uint indexed tokenId, address seller);
    
    event TokenResold(uint indexed tokenId, address seller, uint price);

    // MarketItem struct to represent a market item
    struct MarketItem {
        uint tokenId;
        address payable seller;
        address payable owner;
        uint price;
        bool sold;
        uint creationTimestamp;
    }

    mapping(uint => MarketItem) private idToMarketItem;
    mapping(uint => address) private lockedOwnerToken;
    mapping(uint => uint[]) private rangeToTokens;
    mapping(uint => uint[]) private lengthMarketTokens;

    constructor(
        string memory _name,
        string memory _symbol,
        uint _minGasToTransfer,
        address _lzEndpoint,
        uint _chainId
    ) ERC721(_name, _symbol) ONFT721Core(_minGasToTransfer, _lzEndpoint) Ownable(msg.sender) {
        CHAIN_ID = _chainId;
        _tokenIdCounter = 1; // Start token IDs at 1
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ONFT721Core, ERC721) returns (bool) {
        return
            interfaceId == type(IONFT721).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /**
     * @dev Creates a new NFT token with sequential ID
     * @param tokenURI Token URI pointing to metadata
     * @param price Initial price of the token
     */
    function createToken(
        string memory tokenURI,
        uint price
    ) external payable returns (uint) {
        uint256 newTokenId = _tokenIdCounter;
        _tokenIdCounter++;

        _mint(msg.sender, newTokenId);
        _setTokenURI(newTokenId, tokenURI);
        emit TokenCreated(newTokenId, msg.sender, tokenURI, price);

        idToMarketItem[newTokenId] = MarketItem(
            newTokenId,
            payable(address(0)),
            payable(msg.sender),
            price,
            false,
            block.timestamp
        );
        lengthMarketTokens[CHAIN_ID].push(newTokenId);

        return newTokenId;
    }

    /**
     * @dev Purchases an NFT that is listed on the marketplace
     * @param tokenId Token ID to purchase
     */
    function createMarketSale(uint tokenId) public payable nonReentrant {
        uint price = idToMarketItem[tokenId].price;
        uint marketValue = 0.00005 ether;
        uint totalAmount = price + marketValue;
        
        if (msg.value != totalAmount) {
            revert ONFTMarket__Errors.IncorrectPrice(totalAmount, msg.value);
        }

        address payable seller = idToMarketItem[tokenId].seller;
        
        idToMarketItem[tokenId].owner = payable(msg.sender);
        idToMarketItem[tokenId].sold = true;
        idToMarketItem[tokenId].seller = payable(address(0));
        _transfer(address(this), msg.sender, tokenId);

        emit MarketSale(tokenId, seller, msg.sender);

        (bool sellerTransferSuccess, ) = seller.call{value: price}("");
        if (!sellerTransferSuccess) {
            revert ONFTMarket__Errors.TransferFailed();
        }

        (bool marketTransferSuccess, ) = address(this).call{value: marketValue}("");
        if (!marketTransferSuccess) {
            revert ONFTMarket__Errors.TransferFailed();
        }
    }

    /**
     * @dev Sends an NFT to another chain using LayerZero
     * @param destChainId Destination chain ID
     * @param tokenId Token ID to send
     * @param adapter Adapter parameters for LayerZero
     */
    function sendOnft(
        uint16 destChainId,
        uint tokenId,
        bytes memory adapter
    ) external payable nonReentrant {
        if (idToMarketItem[tokenId].owner != msg.sender) {
            revert ONFTMarket__Errors.OnlyOwnerAllowed(msg.sender, tokenId);
        }

        string memory _tokenURI = tokenURI(tokenId);
        address _tokenOwner = ownerOf(tokenId);
        bytes memory payload = abi.encode(_tokenURI, _tokenOwner, tokenId);

        lockedOwnerToken[tokenId] = _tokenOwner;
        idToMarketItem[tokenId].owner = payable(address(0));
        transferFrom(msg.sender, address(this), tokenId);

        uint sendValue = 0.0001 ether;

        // Transfer value to contract
        (bool appValueTransferSuccess, ) = address(this).call{value: sendValue}("");
        if (!appValueTransferSuccess) {
            revert ONFTMarket__Errors.TransferFailed();
        }

        uint bridgeValue = msg.value - sendValue;

        emit TokenSent(tokenId, msg.sender, destChainId, _tokenURI);
        _lzSend(
            destChainId,
            payload,
            payable(msg.sender),
            address(0x0),
            adapter,
            bridgeValue
        );
    }

    function _debitFrom(
        address _from,
        uint16,
        bytes memory,
        uint _tokenId
    ) internal virtual override {}

    function _creditTo(
        uint16,
        address _toAddress,
        uint _tokenId
    ) internal virtual override {}

    function _nonblockingLzReceive(
        uint16,
        bytes memory,
        uint64,
        bytes memory _payload
    ) internal override {
        emit LzReceive(_payload);
        reciveONFT(_payload);
    }

    /**
     * @dev Receives NFT from another chain
     * @param _payload Encoded data from source chain
     */
    function reciveONFT(bytes memory _payload) internal {
        (string memory _tokenURI, address _tokenOwner, uint _tokenId) = abi
            .decode(_payload, (string, address, uint));

        if (lockedOwnerToken[_tokenId] == _tokenOwner) {
            idToMarketItem[_tokenId].owner = payable(_tokenOwner);
            transferFrom(address(this), _tokenOwner, _tokenId);
        } else {
            {
                _safeMint(_tokenOwner, _tokenId);
                _setTokenURI(_tokenId, _tokenURI);
                idToMarketItem[_tokenId] = MarketItem(
                    _tokenId,
                    payable(address(0)),
                    payable(_tokenOwner),
                    0,
                    false,
                    block.timestamp
                );
                rangeToTokens[CHAIN_ID].push(_tokenId);
            }
        }
        emit TokenReceived(_tokenId, _tokenOwner, _tokenURI);
    }

    /**
     * @dev Fetches all market items available for sale
     */
    function fetchMarketItems() external view returns (MarketItem[] memory) {
        uint itemCount = 0;

        uint[] memory tokensInMarket = lengthMarketTokens[CHAIN_ID];

        for (uint i = 0; i < tokensInMarket.length; i++) {
            uint tokenId = tokensInMarket[i];
            if (idToMarketItem[tokenId].owner == address(this)) {
                itemCount += 1;
            }
        }

        // Loop through the tokens received from other chains
        uint[] memory tokensInCurrentRange = rangeToTokens[CHAIN_ID];
        for (uint i = 0; i < tokensInCurrentRange.length; i++) {
            uint currentId = tokensInCurrentRange[i];
            if (idToMarketItem[currentId].owner == address(this)) {
                itemCount += 1;
            }
        }

        // Initialize the items array with the calculated itemCount
        MarketItem[] memory items = new MarketItem[](itemCount);

        // Loop through your own NFTs on the current chain
        uint currentIndex = 0;
        for (uint i = 0; i < tokensInMarket.length; i++) {
            uint tokenId = tokensInMarket[i];
            if (idToMarketItem[tokenId].owner == address(this)) {
                items[currentIndex] = idToMarketItem[tokenId];
                currentIndex += 1;
            }
        }

        // Loop through the tokens received from other chains
        for (uint i = 0; i < tokensInCurrentRange.length; i++) {
            uint currentId = tokensInCurrentRange[i];
            if (idToMarketItem[currentId].owner == address(this)) {
                items[currentIndex] = idToMarketItem[currentId];
                currentIndex += 1;
            }
        }

        return items;
    }

    /**
     * @dev Fetches NFTs owned by the caller
     */
    function fetchMyNFTs() external view returns (MarketItem[] memory) {
        uint itemCount = 0;

        uint[] memory tokensInMarket = lengthMarketTokens[CHAIN_ID];

        for (uint i = 0; i < tokensInMarket.length; i++) {
            uint tokenId = tokensInMarket[i];
            if (idToMarketItem[tokenId].owner == msg.sender) {
                itemCount += 1;
            }
        }

        // Loop through the tokens received from other chains
        uint[] memory tokensInCurrentRange = rangeToTokens[CHAIN_ID];
        for (uint i = 0; i < tokensInCurrentRange.length; i++) {
            uint currentId = tokensInCurrentRange[i];
            if (idToMarketItem[currentId].owner == msg.sender) {
                itemCount += 1;
            }
        }

        // Initialize the items array with the calculated itemCount
        MarketItem[] memory items = new MarketItem[](itemCount);

        // Loop through your own NFTs on the current chain
        uint currentIndex = 0;
        for (uint i = 0; i < tokensInMarket.length; i++) {
            uint tokenId = tokensInMarket[i];
            if (idToMarketItem[tokenId].owner == msg.sender) {
                items[currentIndex] = idToMarketItem[tokenId];
                currentIndex += 1;
            }
        }

        // Loop through the tokens received from other chains
        for (uint i = 0; i < tokensInCurrentRange.length; i++) {
            uint currentId = tokensInCurrentRange[i];
            if (idToMarketItem[currentId].owner == msg.sender) {
                items[currentIndex] = idToMarketItem[currentId];
                currentIndex += 1;
            }
        }

        return items;
    }

    /**
     * @dev Fetches items listed by the caller
     */
    function fetchItemsListed() external view returns (MarketItem[] memory) {
        uint itemCount = 0;

        uint[] memory tokensInMarket = lengthMarketTokens[CHAIN_ID];

        for (uint i = 0; i < tokensInMarket.length; i++) {
            uint tokenId = tokensInMarket[i];
            if (idToMarketItem[tokenId].seller == msg.sender) {
                itemCount += 1;
            }
        }

        // Loop through the tokens received from other chains
        uint[] memory tokensInCurrentRange = rangeToTokens[CHAIN_ID];
        for (uint i = 0; i < tokensInCurrentRange.length; i++) {
            uint currentId = tokensInCurrentRange[i];
            if (idToMarketItem[currentId].seller == msg.sender) {
                itemCount += 1;
            }
        }

        // Initialize the items array with the calculated itemCount
        MarketItem[] memory items = new MarketItem[](itemCount);

        // Loop through your own NFTs on the current chain
        uint currentIndex = 0;
        for (uint i = 0; i < tokensInMarket.length; i++) {
            uint tokenId = tokensInMarket[i];
            if (idToMarketItem[tokenId].seller == msg.sender) {
                items[currentIndex] = idToMarketItem[tokenId];
                currentIndex += 1;
            }
        }

        // Loop through the tokens received from other chains
        for (uint i = 0; i < tokensInCurrentRange.length; i++) {
            uint currentId = tokensInCurrentRange[i];
            if (idToMarketItem[currentId].seller == msg.sender) {
                items[currentIndex] = idToMarketItem[currentId];
                currentIndex += 1;
            }
        }

        return items;
    }

    /**
     * @dev Cancels an active listing
     * @param tokenId Token ID to cancel
     */
    function cancelListing(uint tokenId) external payable {
        if (idToMarketItem[tokenId].seller != msg.sender) {
            revert ONFTMarket__Errors.OnlySellerAllowed(msg.sender, tokenId);
        }

        idToMarketItem[tokenId].sold = false;
        idToMarketItem[tokenId].price = 0;
        idToMarketItem[tokenId].seller = payable(address(0));
        idToMarketItem[tokenId].owner = payable(msg.sender);

        _transfer(address(this), msg.sender, tokenId);
        
        emit ListingCancelled(tokenId, msg.sender);
    }

    /**
     * @dev Puts a token back on sale
     * @param tokenId Token ID to resell
     * @param price New listing price
     */
    function resellToken(uint tokenId, uint price) external payable {
        if (idToMarketItem[tokenId].owner != msg.sender) {
            revert ONFTMarket__Errors.OnlyOwnerAllowed(msg.sender, tokenId);
        }

        idToMarketItem[tokenId].sold = false;
        idToMarketItem[tokenId].price = price;
        idToMarketItem[tokenId].seller = payable(msg.sender);
        idToMarketItem[tokenId].owner = payable(address(this));
        _transfer(msg.sender, address(this), tokenId);
        
        emit TokenResold(tokenId, msg.sender, price);
    }

    /**
     * @dev Updates price for a token
     * @param tokenId Token ID to update
     * @param newPrice New price
     */
    function updateTokenPrice(uint tokenId, uint newPrice) external {
        if (idToMarketItem[tokenId].seller != msg.sender) {
            revert ONFTMarket__Errors.OnlySellerAllowed(msg.sender, tokenId);
        }
        
        idToMarketItem[tokenId].price = newPrice;
    }
    
    /**
     * @dev Gets details for a specific token
     * @param tokenId Token ID to query
     */
    function getMarketItem(uint tokenId) external view returns (MarketItem memory) {
        if (!_exists(tokenId)) {
            revert ONFTMarket__Errors.InvalidTokenId(tokenId);
        }
        return idToMarketItem[tokenId];
    }
    
    /**
     * @dev Gets current token ID counter value
     * @return Current token counter value
     */
    function getCurrentTokenId() external view returns (uint256) {
        return _tokenIdCounter;
    }

    /**
     * @dev Withdraws contract balance to owner
     */
    function withdraw() public payable onlyOwner {
        (bool success, ) = payable(owner()).call{
            value: address(this).balance
        }("");
        if (!success) {
            revert ONFTMarket__Errors.TransferFailed();
        }
    }

    /**
     * @dev Override _update from ERC721 to ensure proper updating of URI info
     */
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    /**
     * @dev Override tokenURI function to combine ERC721URIStorage with custom handling
     */
    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }
    
    /**
     * @dev Override _burn function
     */
    function _burn(uint256 tokenId) internal override(ERC721, ERC721URIStorage) {
        super._burn(tokenId);
    }
    
    receive() external payable {}
}