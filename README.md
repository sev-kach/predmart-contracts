# PredMart Lending Pool — Smart Contracts

**PredMart** is a non-custodial lending protocol built for the prediction market ecosystem. It allows users to deposit [Polymarket](https://polymarket.com) outcome shares as collateral and borrow USDC against them — unlocking liquidity from positions that would otherwise sit idle until a market resolves.

> **Live protocol:** [predmart.com](https://predmart.com) · **Docs:** [predmart.com/docs](https://predmart.com/docs)

---

## What is PredMart?

Prediction market traders face a fundamental capital efficiency problem: once you buy shares on Polymarket, your USDC is locked until the market resolves. PredMart solves this by creating a lending market around Polymarket outcome shares.

**For borrowers:** Deposit your Polymarket shares (ERC-1155 CTF tokens) as collateral and borrow USDC. Use that USDC to buy more shares — enabling leveraged trading on any prediction market on Polygon.

**For lenders:** Supply USDC to the lending pool and earn yield generated from borrower interest payments. Receive pUSDC — ERC-4626 vault shares that automatically accrue interest over time.

---

## Deployed Contracts

### Polygon Mainnet (Chain ID: 137)

| Contract | Address |
|---|---|
| **PredmartLendingPool (Proxy)** | [`0xD90D012990F0245cAD29823bDF0B4C9AF207d9ee`](https://polygonscan.com/address/0xD90D012990F0245cAD29823bDF0B4C9AF207d9ee) |
| USDC.e (Collateral currency) | [`0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174`](https://polygonscan.com/address/0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174) |
| Polymarket CTF (ERC-1155) | [`0x4D97DCd97eC945f40cF65F87097ACe5EA0476045`](https://polygonscan.com/address/0x4D97DCd97eC945f40cF65F87097ACe5EA0476045) |

The proxy contract is verified on Polygonscan. You can read the full source code and interact with it directly through the Polygonscan UI.

---

## Architecture

### Contract Design

The core contract is `PredmartLendingPool` — a single upgradeable contract (UUPS proxy pattern via ERC-1967) that handles all protocol operations:

- **ERC-4626 Vault** — manages lender USDC deposits, mints/burns pUSDC shares, and distributes yield
- **Collateral Manager** — tracks per-user, per-token ERC-1155 collateral deposits and loan positions
- **Interest Rate Model** — kinked utilization-based curve: low rates at low utilization, sharply rising rates above the kink to incentivize liquidity
- **Dynamic LTV Curve** — 7-anchor price interpolation that adjusts the loan-to-value ratio based on current collateral price; shares closer to $1.00 receive higher LTV
- **Oracle Verifier** — validates cryptographically signed, timestamp-bounded price data from the PredMart relayer; rejects data older than 10 seconds
- **Liquidation Engine** — allows authorized liquidators to repay unhealthy positions and seize collateral
- **Timelock Governance** — sensitive parameter changes require a mandatory waiting period before taking effect

### Oracle Design

PredMart does not use on-chain price oracles. Instead, the backend fetches real-time prices from Polymarket's Central Limit Order Book (CLOB), signs them with an authorized oracle key using EIP-712, and submits them alongside user transactions. The contract verifies the signature and timestamp on-chain before executing any price-sensitive operation.

### Upgradeability

The contract uses the **UUPS (Universal Upgradeable Proxy Standard)** pattern. The proxy address never changes — only the implementation can be upgraded by the admin. All upgrade transactions are recorded in the `broadcast/` directory with full on-chain verification.

---

## Repository Structure

```
predmart-contracts/
├── src/
│   ├── PredmartLendingPool.sol     # Core lending pool (ERC-4626 + collateral + liquidation)
│   ├── PredmartOracle.sol          # Oracle signature verification helpers
│   └── interfaces/
│       └── ICTF.sol                # Interface for Polymarket's CTF ERC-1155 contract
├── test/
│   ├── PredmartLendingPool.t.sol   # Comprehensive test suite (Foundry)
│   └── mocks/
│       ├── MockUSDC.sol            # Mock ERC-20 USDC for testing
│       └── MockCTF.sol             # Mock ERC-1155 CTF token for testing
├── script/
│   └── Deploy.s.sol                # Deployment & upgrade scripts (Foundry)
├── broadcast/                      # On-chain deployment records (tx hashes & addresses)
│   ├── Deploy.s.sol/137/           # Polygon Mainnet deployment history
│   └── Deploy.s.sol/80002/         # Polygon Amoy testnet deployment history
├── foundry.toml                    # Foundry configuration (solc 0.8.27, via_ir, optimizer)
├── remappings.txt                  # Solidity import remappings
└── deploy.sh                       # Deployment wrapper script
```

---

## Development Setup

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) — `curl -L https://foundry.paradigm.xyz | bash`
- Git (for submodules)

### Installation

```bash
git clone https://github.com/sev-kach/predmart-contracts.git
cd predmart-contracts
git submodule update --init --recursive
```

### Build

```bash
forge build
```

### Run Tests

```bash
forge test
```

Run with gas reports:

```bash
forge test --gas-report
```

Run a specific test:

```bash
forge test --match-test testBorrowAndRepay -vvv
```

---

## Deployment

Deployments use the `deploy.sh` wrapper, which loads environment variables from the backend's `.env` file (single source of truth for credentials). Required environment variables:

| Variable | Description |
|---|---|
| `ADMIN_WALLET_PRIVATE_KEY` | Deployer/admin wallet private key |
| `POLYGONSCAN_API_KEY` | For automatic contract verification |
| `POLYGON_MAINNET_RPC_URL` | Mainnet RPC endpoint |
| `POLYGON_AMOY_RPC_URL` | Testnet RPC endpoint |

### Deploy a fresh instance

```bash
./deploy.sh testnet deployLendingPool   # Polygon Amoy
./deploy.sh mainnet deployLendingPool   # Polygon Mainnet
```

### Upgrade existing deployment

```bash
./deploy.sh mainnet upgradePool         # Generic upgrade (no reinitialization)
```

### Retry Polygonscan verification (no redeployment, no gas cost)

```bash
./deploy.sh mainnet verify <IMPL_ADDRESS>
```

> **Note:** `foundry.toml` uses `solc = "0.8.27"` with `via_ir = true`. Solc versions below 0.8.27 have a non-determinism bug in the Yul IR pipeline that causes bytecode mismatch on Polygonscan verification. Do not downgrade.

---

## Key Protocol Parameters

| Parameter | Value |
|---|---|
| Collateral token standard | ERC-1155 (Polymarket CTF shares) |
| Borrow currency | USDC.e (Polygon) |
| Vault share token | pUSDC (ERC-4626) |
| Blockchain | Polygon (PoS) |
| Oracle price freshness window | 10 seconds |
| LTV curve anchors | 7 price points |
| Upgrade pattern | UUPS (ERC-1967) |

---

## Dependencies

Managed as git submodules via Foundry:

| Library | Purpose |
|---|---|
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | ERC-4626, ERC-1967 proxy, EIP-712 |
| [OpenZeppelin Upgradeable](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable) | Upgradeable contract base classes |
| [forge-std](https://github.com/foundry-rs/forge-std) | Foundry testing utilities |
| [solady](https://github.com/vectorized/solady) | Gas-optimized utilities |

---

## Security

- **Non-custodial:** All funds are held by the smart contract. PredMart (the team) cannot access or move user funds.
- **Oracle signature verification:** All price data is signed by an authorized oracle key and verified on-chain with a 10-second freshness requirement.
- **Timelock governance:** Sensitive parameter changes (oracle address, risk parameters, fee rates) require a mandatory waiting period before taking effect.
- **Dynamic LTV:** Loan-to-value ratios adjust automatically based on real-time collateral prices, reducing risk from sudden price drops.
- **Depth-gated borrow caps:** Maximum borrowable amount per token is capped by that token's orderbook liquidity on Polymarket, preventing concentration in illiquid markets.
- **Emergency pause:** Admin can pause the protocol instantly in case of a critical vulnerability.
- **Price drop guard:** New borrows are automatically blocked during rapid collateral price crashes.

For a full security breakdown, see the [Security documentation](https://predmart.com/docs/security).

---

## Links

- **Protocol:** [predmart.com](https://predmart.com)
- **Documentation:** [predmart.com/docs](https://predmart.com/docs)
- **API:** [api.predmart.com/docs](https://api.predmart.com/docs)
- **Polygonscan:** [PredmartLendingPool on Polygonscan](https://polygonscan.com/address/0xD90D012990F0245cAD29823bDF0B4C9AF207d9ee)

---

## License

Copyright (c) 2025 PredMart. All rights reserved.

This code is made available for viewing, auditing, and non-commercial use only. Commercial use, deployment as a competing protocol, or forking for revenue-generating purposes is prohibited without prior written permission. See [LICENSE](./LICENSE) for full terms.
