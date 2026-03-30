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

The protocol is split across two contracts that share a single proxy address:

**`PredmartLendingPool`** — the main contract (UUPS proxy, ERC-1967) handling core lending operations:

- **ERC-4626 Vault** — manages lender USDC deposits, mints/burns pUSDC shares, and distributes yield
- **Collateral Manager** — tracks per-user, per-token ERC-1155 collateral deposits and loan positions
- **Meta-Transaction Relayer** — all borrow, withdraw, and leverage operations use EIP-712 signed intents submitted by a trusted relayer, eliminating the need for users to hold gas tokens
- **Leverage Engine** — `leverageStep()` enables iterative deposit-and-borrow loops: users sign a single `LeverageAuth` message authorizing a maximum borrow budget, and the relayer executes multiple steps within that budget. Borrowed USDC goes to the user's Safe (`auth.allowedFrom`), not the relayer
- **Interest Rate Model** — kinked utilization-based curve: low rates at low utilization, sharply rising rates above the kink to incentivize liquidity
- **Dynamic LTV Curve** — 7-anchor price interpolation that adjusts the loan-to-value ratio based on current collateral price; shares closer to $1.00 receive higher LTV
- **Oracle Verifier** — validates cryptographically signed, timestamp-bounded price data; rejects data older than 10 seconds
- **Liquidation Engine** — allows the relayer to repay unhealthy positions and seize collateral
- **Timelock Governance** — sensitive parameter changes (oracle, relayer, risk model, upgrades) require a mandatory waiting period before taking effect; the delay is a one-way ratchet (can only increase)

**`PredmartPoolExtension`** — admin governance and market resolution, called via `delegatecall` from the main contract's `fallback()`:

- **Timelocked Admin Functions** — propose/execute changes to oracle, relayer, risk anchors, and contract upgrades
- **Market Resolution** — permissionless functions to resolve Polymarket markets, close positions on resolved markets, redeem winning CTF shares for USDC, and settle borrower positions with pro-rata surplus distribution
- **Inline Helpers** — duplicates of internal interest accrual and borrow tracking functions (required because the extension cannot call the main contract's `internal` functions via delegatecall)

Both contracts share an identical storage layout to ensure safe delegatecall execution.

### Oracle Design

PredMart does not use on-chain price oracles. Instead, the backend fetches real-time prices from Polymarket's Central Limit Order Book (CLOB), signs them with an authorized oracle key using EIP-712, and submits them alongside user transactions. The contract verifies the signature and timestamp on-chain before executing any price-sensitive operation.

### Meta-Transaction Pattern

Users never submit transactions directly. Instead, they sign EIP-712 typed data messages (intents) off-chain, and a trusted relayer submits the transaction on their behalf. This means users don't need POL for gas — the relayer pays. The contract verifies every signature on-chain before executing:

- **BorrowIntent** — signed by the borrower, specifies amount, token, and destination
- **WithdrawIntent** — signed by the borrower, specifies amount, token, and withdrawal destination
- **LeverageAuth** — signed once per leverage operation, authorizes a cumulative borrow budget with an explicit `allowedFrom` address (user's Gnosis Safe) where USDC is sent

### Upgradeability

The contract uses the **UUPS (Universal Upgradeable Proxy Standard)** pattern. The proxy address never changes — only the implementation can be upgraded by the admin after a timelock delay. The extension contract is updated atomically during upgrades via a `reinitializer` callback in `upgradeToAndCall`. All upgrade transactions are recorded in the `broadcast/` directory with full on-chain verification.

---

## Repository Structure

```
predmart-contracts/
├── src/
│   ├── PredmartLendingPool.sol     # Core lending pool (ERC-4626 + collateral + leverage + liquidation)
│   ├── PredmartPoolExtension.sol   # Admin governance + market resolution (called via delegatecall)
│   ├── PredmartPoolLib.sol         # Interest rate model + liquidation math
│   ├── PredmartOracle.sol          # Oracle signature verification helpers
│   └── interfaces/
│       └── ICTF.sol                # Interface for Polymarket's CTF ERC-1155 contract
├── test/
│   ├── PredmartLendingPool.t.sol   # Comprehensive test suite (Foundry)
│   └── mocks/
│       ├── MockUSDC.sol            # Mock ERC-20 USDC for testing
│       └── MockCTF.sol             # Mock ERC-1155 CTF token for testing
├── script/
│   └── Deploy.s.sol                # Deployment & timelocked upgrade scripts (Foundry)
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

### Upgrade existing deployment (timelocked)

Upgrades are a two-step process with a mandatory timelock delay between proposal and execution:

```bash
# Step 1: Deploy new implementation + extension, propose upgrade (starts timelock)
./deploy.sh mainnet proposeUpgrade

# Step 2: Execute upgrade after timelock has elapsed
EXTENSION_ADDRESS=0x... ./deploy.sh mainnet executeUpgrade
```

The `proposeUpgrade` script deploys both a new `PredmartLendingPool` implementation and a new `PredmartPoolExtension`, then calls `proposeAddress(2, newImpl)` to start the timelock. After the delay, `executeUpgrade` calls `upgradeToAndCall` with a reinitializer that sets the new extension atomically.

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
| Transaction pattern | EIP-712 meta-transactions via trusted relayer |
| Oracle price freshness window | 10 seconds |
| LTV curve anchors | 7 price points |
| Per-token borrow cap | 5% of pool |
| Upgrade pattern | UUPS (ERC-1967) with timelock |

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

- **Non-custodial:** All funds are held by the smart contract. PredMart (the team) cannot access or move user funds. Leverage operations send borrowed USDC to the user's own Gnosis Safe, not to the relayer or any admin wallet.
- **EIP-712 signature verification:** Every relay operation (borrow, withdraw, leverage) requires a cryptographic signature from the user. The relayer cannot modify fund destinations — all recipient addresses are part of the signed message.
- **Cumulative borrow budgets:** Leverage operations enforce a user-signed maximum borrow amount. The contract tracks cumulative borrowing per authorization, preventing the relayer from exceeding the user's intent across multiple steps.
- **Oracle signature verification:** All price data is signed by an authorized oracle key and verified on-chain with a 10-second freshness requirement.
- **Timelock governance:** Sensitive parameter changes (oracle address, relayer address, risk parameters, contract upgrades) require a mandatory waiting period before taking effect. The timelock delay is a one-way ratchet — it can only be increased, never decreased.
- **Dynamic LTV:** Loan-to-value ratios adjust automatically based on real-time collateral prices, reducing risk from sudden price drops.
- **Depth-gated borrow caps:** Maximum borrowable amount per token is capped by that token's orderbook liquidity on Polymarket, preventing concentration in illiquid markets.
- **Emergency pause:** Admin can pause the protocol instantly. Pausing blocks new borrows, deposits, and leverage — but repayments, withdrawals, and liquidations remain open so users can exit.
- **Price drop guard:** New borrows are automatically blocked during rapid collateral price crashes.
- **Replay protection:** Separate nonce sequences for borrow, withdraw, and leverage operations prevent cross-operation replay attacks.

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
