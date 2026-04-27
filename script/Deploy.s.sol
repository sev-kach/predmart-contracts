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
import { PredmartPoolExtension } from "../src/PredmartPoolExtension.sol";
import { PredmartLeverageModule } from "../src/PredmartLeverageModule.sol";

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
        } else {
            revert("Unsupported chain");
        }
    }

    /// @notice Get network name for logging
    function _getNetworkName() internal view returns (string memory) {
        if (block.chainid == 137) return "Polygon Mainnet";
        return "Unknown";
    }

    /*//////////////////////////////////////////////////////////////
                      DEPLOY LENDING POOL (Fresh)
    //////////////////////////////////////////////////////////////*/

    /// @notice Fresh deployment: LendingPool implementation + proxy
    /// @dev forge script script/Deploy.s.sol --sig "deployLendingPool()" --rpc-url polygon_mainnet --broadcast --verify
    function deployLendingPool() external {
        uint256 deployerPrivateKey = vm.envUint("RELAYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== DEPLOY LENDING POOL ===");
        console.log("Network:", _getNetworkName());
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy implementation
        PredmartLendingPool implementation = new PredmartLendingPool();
        console.log("Implementation:", address(implementation));

        // 2. Deploy proxy with initialization (function signature used directly — removed from impl after mainnet init)
        bytes memory initData = abi.encodeWithSignature("initialize(address)", deployer);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console.log("Proxy:", address(proxy));

        // 3. Verify admin
        PredmartLendingPool pool = PredmartLendingPool(address(proxy));
        console.log("Admin:", pool.admin());

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("LENDING_POOL_ADDRESS=", address(proxy));
        console.log("");
        console.log("Update .env with this address!");
    }

    /*//////////////////////////////////////////////////////////////
                        UPGRADE LENDING POOL
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy new impl + extension only (no proposeAddress — use when admin is a Safe)
    /// @dev forge script script/Deploy.s.sol --sig "deployUpgrade()" --rpc-url polygon_mainnet --broadcast --verify
    function deployUpgrade() external {
        uint256 deployerPrivateKey = vm.envUint("RELAYER_PRIVATE_KEY");

        console.log("=== DEPLOY UPGRADE (contracts only, no propose) ===");
        console.log("Network:", _getNetworkName());

        vm.startBroadcast(deployerPrivateKey);

        PredmartPoolExtension newExt = new PredmartPoolExtension();
        PredmartLendingPool newImpl = new PredmartLendingPool();

        vm.stopBroadcast();

        console.log("New extension:", address(newExt));
        console.log("New implementation:", address(newImpl));
        console.log("");
        console.log("=== NEXT STEPS (via Gnosis Safe UI) ===");
        console.log("1. proposeAddress(2, <new impl address>)  -- starts 6h timelock");
        console.log("2. After 6h: upgradeToAndCall(<new impl>, setExtension(<new ext>))");
    }

    /// @notice Step 1: Deploy new impl + extension + propose upgrade (starts timelock)
    /// @dev forge script script/Deploy.s.sol --sig "proposeUpgrade()" --rpc-url polygon_mainnet --broadcast --verify
    function proposeUpgrade() external {
        uint256 adminPrivateKey = vm.envUint("RELAYER_PRIVATE_KEY");
        Config memory cfg = _getConfig();

        require(cfg.lendingPoolProxy != address(0), "No lending pool proxy configured");

        PredmartPoolExtension ext = PredmartPoolExtension(cfg.lendingPoolProxy);

        console.log("=== PROPOSE UPGRADE ===");
        console.log("Network:", _getNetworkName());
        console.log("Proxy:", cfg.lendingPoolProxy);

        vm.startBroadcast(adminPrivateKey);

        // Deploy new extension + implementation
        PredmartPoolExtension newExt = new PredmartPoolExtension();
        PredmartLendingPool newImpl = new PredmartLendingPool();
        console.log("New extension:", address(newExt));
        console.log("New implementation:", address(newImpl));

        // Propose upgrade via extension (proposeAddress kind=2=upgrade)
        ext.proposeAddress(2, address(newImpl));

        vm.stopBroadcast();

        console.log("=== UPGRADE PROPOSED ===");
        console.log("Save extension address for executeUpgrade: ", address(newExt));
    }

    /// @notice Step 2: Execute upgrade + set extension after timelock has elapsed
    /// @dev EXTENSION_ADDRESS=0x... forge script script/Deploy.s.sol --sig "executeUpgrade()" --rpc-url polygon_mainnet --broadcast
    function executeUpgrade() external {
        uint256 adminPrivateKey = vm.envUint("RELAYER_PRIVATE_KEY");
        Config memory cfg = _getConfig();

        require(cfg.lendingPoolProxy != address(0), "No lending pool proxy configured");

        PredmartLendingPool proxy = PredmartLendingPool(cfg.lendingPoolProxy);

        address pendingImpl = proxy.pendingUpgrade();
        require(pendingImpl != address(0), "No pending upgrade");

        address extensionAddr = vm.envAddress("EXTENSION_ADDRESS");
        require(extensionAddr != address(0), "Set EXTENSION_ADDRESS env var");

        console.log("=== EXECUTE UPGRADE ===");
        console.log("Pending implementation:", pendingImpl);
        console.log("Extension:", extensionAddr);

        vm.startBroadcast(adminPrivateKey);

        // upgradeToAndCall with setExtension in the callback — sets extension atomically during upgrade
        bytes memory initData = abi.encodeWithSelector(PredmartLendingPool.setExtension.selector, extensionAddr);
        proxy.upgradeToAndCall(pendingImpl, initData);
        console.log("Upgrade executed + extension set");

        vm.stopBroadcast();

        console.log("=== UPGRADE COMPLETE ===");
    }

    /// @notice Upgrade to v0.8.0 — meta-transaction relayer pattern
    /// @dev Initializes EIP-712 domain + sets relayer address (admin wallet = relayer)
    /// forge script script/Deploy.s.sol --sig "upgradeToV8()" --rpc-url polygon_mainnet --broadcast --verify
    function upgradeToV8() external {
        uint256 adminPrivateKey = vm.envUint("RELAYER_PRIVATE_KEY");
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

        // upgradeToAndCall with initializeV4(relayer) — admin wallet is the relayer (historical — V4 ran long ago)
        bytes memory initData = abi.encodeWithSignature("initializeV4(address)", adminAddr);
        proxy.upgradeToAndCall(address(newImpl), initData);

        // Verify
        console.log("Upgrade applied");
        console.log("Relayer:", proxy.relayer());

        vm.stopBroadcast();

        console.log("=== UPGRADE TO V0.8.0 COMPLETE ===");
    }

    /*//////////////////////////////////////////////////////////////
                       DEPLOY LEVERAGE MODULE (Standalone)
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy PredmartLeverageModule — Safe module that verifies the borrower
    ///         sig, pulls Safe USDC to relayer, and triggers pool's pullUsdcForLeverage
    ///         in a single tx.
    /// @dev forge script script/Deploy.s.sol --sig "deployLeverageModule()" --rpc-url polygon_mainnet --broadcast --verify
    function deployLeverageModule() external {
        Config memory cfg = _getConfig();
        uint256 deployerPrivateKey = vm.envUint("RELAYER_PRIVATE_KEY");
        address relayerAddr = vm.envAddress("RELAYER_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        PredmartLeverageModule module = new PredmartLeverageModule(
            cfg.lendingPoolProxy,
            relayerAddr,
            cfg.usdc
        );

        console.log("=== LEVERAGE MODULE DEPLOYED ===");
        console.log("Module:", address(module));
        console.log("Version:", module.VERSION());
        console.log("Lending Pool:", module.LENDING_POOL());
        console.log("Relayer:", module.RELAYER());
        console.log("USDC:", module.USDC());
        console.logBytes32(module.POOL_DOMAIN_SEPARATOR());

        vm.stopBroadcast();

        console.log("");
        console.log("Next: set LEVERAGE_MODULE_ADDRESS in backend .env");
        console.log("Then: wire into pool via initializeV17 (during pool upgrade) or setLeverageModule (fresh deploy)");
        console.log("Onboarding bundles Safe.enableModule(module) for new users");
    }

    /*//////////////////////////////////////////////////////////////
                  DEPLOY UPGRADE WITH MODULE (Path B)
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy new pool implementation + extension + leverage module.
    ///         The Safe upgrade tx then calls upgradeToAndCall(newImpl, initializeV17(ext, module)).
    /// @dev forge script script/Deploy.s.sol --sig "deployUpgradeWithModule()" --rpc-url polygon_mainnet --broadcast --verify
    function deployUpgradeWithModule() external {
        Config memory cfg = _getConfig();
        uint256 deployerPrivateKey = vm.envUint("RELAYER_PRIVATE_KEY");
        address relayerAddr = vm.envAddress("RELAYER_ADDRESS");

        console.log("=== DEPLOY UPGRADE + MODULE (Path B) ===");
        console.log("Network:", _getNetworkName());

        vm.startBroadcast(deployerPrivateKey);

        PredmartPoolExtension newExt = new PredmartPoolExtension();
        PredmartLendingPool newImpl = new PredmartLendingPool();
        PredmartLeverageModule module = new PredmartLeverageModule(
            cfg.lendingPoolProxy,
            relayerAddr,
            cfg.usdc
        );

        vm.stopBroadcast();

        console.log("New extension:    ", address(newExt));
        console.log("New implementation:", address(newImpl));
        console.log("New module:       ", address(module));
        console.log("Module VERSION:   ", module.VERSION());
        console.log("");
        console.log("=== NEXT STEPS (via Gnosis Safe UI) ===");
        console.log("1. proposeAddress(2, <new impl>) on extension -- starts 6h timelock");
        console.log("2. After 6h: upgradeToAndCall(<new impl>, initializeV17(<new ext>, <module>))");
        console.log("3. Verify: leverageModule() returns module address; module.VERSION() returns 2.0.0");
    }

    /*//////////////////////////////////////////////////////////////
                          SHOW ADDRESSES
    //////////////////////////////////////////////////////////////*/

    /// @notice Print addresses for manual verification
    /// @dev forge script script/Deploy.s.sol --sig "showAddresses()" --rpc-url polygon_mainnet
    function showAddresses() external view {
        Config memory cfg = _getConfig();

        console.log("=== CONTRACT ADDRESSES ===");
        console.log("Network:", _getNetworkName());
        console.log("Lending Pool Proxy:", cfg.lendingPoolProxy);
        console.log("USDC:", cfg.usdc);
        console.log("CTF:", cfg.ctf);
    }
}
