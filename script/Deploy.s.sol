// SPDX-License-Identifier: MIT
// contracts/script/Deploy.s.sol
//
// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║  WARNING: Do NOT create a .env file in the contracts/ directory!          ║
// ║  All environment variables are loaded from project/.env.* files.          ║
// ║  Use deploy.sh wrapper script which handles env loading automatically.    ║
// ║  This maintains single source of truth for all configuration.             ║
// ╚═══════════════════════════════════════════════════════════════════════════╝
//
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { PredmartLendingPool } from "../src/PredmartLendingPool.sol";
import { MockUSDC } from "../test/mocks/MockUSDC.sol";
import { MockCTF } from "../test/mocks/MockCTF.sol";

/// @title Deploy
/// @notice Unified deployment script for Predmart contracts
/// @dev Usage: forge script script/Deploy.s.sol --sig "functionName()" --rpc-url <network> --broadcast --verify
contract Deploy is Script {
    /*//////////////////////////////////////////////////////////////
                            NETWORK CONFIG
    //////////////////////////////////////////////////////////////*/

    struct Config {
        address usdc;
        address ctf;
        address lendingPoolProxy;
    }

    /// @notice Get config based on chain ID (auto-detected from RPC)
    function _getConfig() internal view returns (Config memory) {
        if (block.chainid == 137) {
            // Polygon Mainnet
            return Config({
                usdc: 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174, // USDC.e
                ctf: 0x4D97DCd97eC945f40cF65F87097ACe5EA0476045, // Polymarket CTF
                lendingPoolProxy: 0xD90D012990F0245cAD29823bDF0B4C9AF207d9ee
            });
        } else if (block.chainid == 80002) {
            // Polygon Amoy (Testnet) — mock addresses set via env after deployMocks()
            return Config({
                usdc: vm.envOr("MOCK_USDC", address(0)),
                ctf: vm.envOr("MOCK_CTF", address(0)),
                lendingPoolProxy: 0xAFF720A9660A2384920C7A2b22e21883C3F58F8A
            });
        } else {
            revert("Unsupported chain");
        }
    }

    /// @notice Get network name for logging
    function _getNetworkName() internal view returns (string memory) {
        if (block.chainid == 137) return "Polygon Mainnet";
        if (block.chainid == 80002) return "Polygon Amoy";
        return "Unknown";
    }

    /*//////////////////////////////////////////////////////////////
                      DEPLOY LENDING POOL (Fresh)
    //////////////////////////////////////////////////////////////*/

    /// @notice Fresh deployment: LendingPool implementation + proxy
    /// @dev forge script script/Deploy.s.sol --sig "deployLendingPool()" --rpc-url polygon_amoy --broadcast --verify
    function deployLendingPool() external {
        uint256 deployerPrivateKey = vm.envUint("ADMIN_WALLET_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== DEPLOY LENDING POOL ===");
        console.log("Network:", _getNetworkName());
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy implementation
        PredmartLendingPool implementation = new PredmartLendingPool();
        console.log("Implementation:", address(implementation));

        // 2. Deploy proxy with initialization
        bytes memory initData = abi.encodeWithSelector(PredmartLendingPool.initialize.selector, deployer);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console.log("Proxy:", address(proxy));

        // 3. Verify admin
        PredmartLendingPool pool = PredmartLendingPool(address(proxy));
        console.log("Admin:", pool.admin());
        console.log("Name:", pool.NAME());
        console.log("Version:", pool.VERSION());

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("LENDING_POOL_ADDRESS=", address(proxy));
        console.log("");
        console.log("Update .env with this address!");
    }

    /*//////////////////////////////////////////////////////////////
                    DEPLOY MOCK TOKENS (Testnet Only)
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy mock USDC and CTF contracts for testnet testing
    /// @dev forge script script/Deploy.s.sol --sig "deployMocks()" --rpc-url polygon_amoy --broadcast
    function deployMocks() external {
        uint256 deployerPrivateKey = vm.envUint("ADMIN_WALLET_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        require(block.chainid == 80002, "Mocks only on testnet");

        console.log("=== DEPLOY MOCK TOKENS ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        MockUSDC mockUsdc = new MockUSDC();
        console.log("MockUSDC:", address(mockUsdc));

        MockCTF mockCtf = new MockCTF();
        console.log("MockCTF:", address(mockCtf));

        // Mint 1M USDC to deployer for testing
        mockUsdc.mint(deployer, 1_000_000e6);
        console.log("Minted 1M USDC to deployer");

        vm.stopBroadcast();

        console.log("");
        console.log("=== MOCKS DEPLOYED ===");
        console.log("Set these in your env:");
        console.log("MOCK_USDC=", address(mockUsdc));
        console.log("MOCK_CTF=", address(mockCtf));
    }

    /*//////////////////////////////////////////////////////////////
                        UPGRADE LENDING POOL
    //////////////////////////////////////////////////////////////*/

    /// @notice Generic upgrade (for future upgrades, no reinitialization)
    /// @dev forge script script/Deploy.s.sol --sig "upgradePool()" --rpc-url polygon_mainnet --broadcast --verify
    function upgradePool() external {
        uint256 adminPrivateKey = vm.envUint("ADMIN_WALLET_PRIVATE_KEY");
        address adminAddr = vm.addr(adminPrivateKey);
        Config memory cfg = _getConfig();

        require(cfg.lendingPoolProxy != address(0), "No lending pool proxy configured");

        console.log("=== UPGRADE LENDING POOL ===");
        console.log("Network:", _getNetworkName());
        console.log("Proxy:", cfg.lendingPoolProxy);

        PredmartLendingPool proxy = PredmartLendingPool(cfg.lendingPoolProxy);
        require(proxy.admin() == adminAddr, "Not admin");

        vm.startBroadcast(adminPrivateKey);

        PredmartLendingPool newImpl = new PredmartLendingPool();
        console.log("New implementation:", address(newImpl));

        proxy.upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        console.log("=== UPGRADE COMPLETE ===");
    }

    /// @notice Upgrade to v0.8.0 — meta-transaction relayer pattern
    /// @dev Initializes EIP-712 domain + sets relayer address (admin wallet = relayer)
    /// forge script script/Deploy.s.sol --sig "upgradeToV8()" --rpc-url polygon_mainnet --broadcast --verify
    function upgradeToV8() external {
        uint256 adminPrivateKey = vm.envUint("ADMIN_WALLET_PRIVATE_KEY");
        address adminAddr = vm.addr(adminPrivateKey);
        Config memory cfg = _getConfig();

        require(cfg.lendingPoolProxy != address(0), "No lending pool proxy configured");

        console.log("=== UPGRADE TO V0.8.0 (Meta-Transaction Relayer) ===");
        console.log("Network:", _getNetworkName());
        console.log("Proxy:", cfg.lendingPoolProxy);
        console.log("Relayer (admin wallet):", adminAddr);

        PredmartLendingPool proxy = PredmartLendingPool(cfg.lendingPoolProxy);
        require(proxy.admin() == adminAddr, "Not admin");

        vm.startBroadcast(adminPrivateKey);

        PredmartLendingPool newImpl = new PredmartLendingPool();
        console.log("New implementation:", address(newImpl));

        // upgradeToAndCall with initializeV4(relayer) — admin wallet is the relayer
        bytes memory initData = abi.encodeWithSelector(PredmartLendingPool.initializeV4.selector, adminAddr);
        proxy.upgradeToAndCall(address(newImpl), initData);

        // Verify
        console.log("Version:", proxy.VERSION());
        console.log("Relayer:", proxy.relayer());

        vm.stopBroadcast();

        console.log("=== UPGRADE TO V0.8.0 COMPLETE ===");
    }

    /*//////////////////////////////////////////////////////////////
                          SHOW ADDRESSES
    //////////////////////////////////////////////////////////////*/

    /// @notice Print addresses for manual verification
    /// @dev forge script script/Deploy.s.sol --sig "showAddresses()" --rpc-url polygon_amoy
    function showAddresses() external view {
        Config memory cfg = _getConfig();

        console.log("=== CONTRACT ADDRESSES ===");
        console.log("Network:", _getNetworkName());
        console.log("Lending Pool Proxy:", cfg.lendingPoolProxy);
        console.log("USDC:", cfg.usdc);
        console.log("CTF:", cfg.ctf);
    }
}
