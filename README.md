# 🧬 Alpha - Multichain NFT Marketplace

**Alpha** is a decentralized NFT marketplace built on top of [LayerZero](https://layerzero.network/) for seamless cross-chain NFT transfers. It supports ERC-721 NFTs that can be minted, bought, and transferred across multiple EVM-compatible blockchains.

---

## 🚀 Tech Stack

- **Smart Contracts**: Solidity `^0.8.28`
- **Cross-chain**: [LayerZero ONFT721](https://layerzero.gitbook.io/docs/evm-guides/advanced-guides/onft721)
- **Frontend**: [Next.js](https://nextjs.org/) 14
- **Wallet Integration**: Wagmi + Viem (Ethers compatible)
- **Deployment**: Multichain-ready via LayerZero endpoints

---

## 🔁 Key Features

### 🛒 NFT Marketplace
- Mint new NFTs (`createToken`)
- List NFTs on marketplace
- Buy NFTs with `createMarketSale`
- Display available NFTs
- Show purchased NFTs per user

### 🌐 Multichain Support via LayerZero
- Send NFTs to another chain with `sendOnft`
- Receive NFTs from another chain using LayerZero's `_nonblockingLzReceive`

---

## 🧠 Smart Contract Overview

### 📂 Contract: `ONFTMarket.sol`

**Inherits from:**
- `ONFT721Core` (LayerZero core logic for ONFT721)
- `ERC721URIStorage` (for metadata)
- `IONFT721` interface (for cross-chain compliance)

### 📌 Highlights

| Function | Description |
|---------|-------------|
| `createToken()` | Mints a new NFT with URI and price |
| `createMarketSale()` | Allows users to purchase NFTs |
| `sendOnft()` | Bridges NFTs to other chains |
| `reciveONFT()` | Handles the receiving logic on target chain |
| `fetchMarketItems()` | Retrieves available NFTs in the marketplace |
| `fetchMyNFTs()` | Returns NFTs owned by the caller |

### ⛓️ Cross-Chain Logic

The contract uses LayerZero `_lzSend()` and `_nonblockingLzReceive()` to enable sending NFTs from one EVM chain to another. Each token's ownership and metadata are maintained through `MarketItem` mappings and reinitialized if the token doesn't exist on the receiving chain.

---

## 🧪 Project Structure

```
Alpha/
│
├── contracts/              # ONFTMarket and LayerZero logic
│
├── frontend/               # Next.js frontend app
│   ├── components/         # React components (Card, Navbar, etc.)
│   ├── pages/              # Next.js routes
│   ├── hooks/              # Wagmi + Viem hooks
│   ├── utils/              # LayerZero endpoint configs, chain mappings
│   └── public/             # Static assets
│
├── deployments/            # Scripts for deploying to multiple chains
├── scripts/                # Hardhat tasks (minting, bridging)
├── hardhat.config.ts       # Hardhat setup for multichain
└── README.md               # You're here!
```

---

## ⚙️ Deployment

### 🔧 Environment Setup

```bash
npm install
```

### 📡 Configure Hardhat Networks

Update your `hardhat.config.ts` or `.env` with LayerZero endpoints and RPC URLs for each chain.

### 🚀 Deploy to Each Chain

```bash
npx hardhat run scripts/deploy.ts --network goerli
npx hardhat run scripts/deploy.ts --network polygonMumbai
```

### 🧪 Local Testing

Run test cases using:

```bash
npx hardhat test
```

---

## 🌍 Supported Chains

Alpha supports any EVM-compatible chains integrated with LayerZero. By default, we support:

- Ethereum Goerli
- Polygon Mumbai
- BNB Testnet
- More can be added via LayerZero config

---

## 🛠️ To-Do

- [ ] Auction-style listings
- [ ] Lazy minting support
- [ ] IPFS metadata support
- [ ] UI for bridging NFTs across chains
- [ ] Improved UX with transaction feedback

---

## 🤝 Contributing

PRs, issues, and forks are welcome. If you’d like to collaborate on expanding the LayerZero features, reach out!

---

## 📜 License

MIT

---

## 🧠 Credits

- [LayerZero Labs](https://layerzero.network/)
- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [Hardhat](https://hardhat.org/)
