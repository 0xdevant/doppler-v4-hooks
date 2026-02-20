// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { IHooks, IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { HookMiner } from "@v4-periphery/utils/HookMiner.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { Log } from "script/Log.sol";
import { MilestoneUnlockUniswapV4MulticurveInitializer } from "src/MilestoneUnlockUniswapV4MulticurveInitializer.sol";
import { SSLMilestoneUnlockHook } from "src/SSLMilestoneUnlockHook.sol";
import { Constants } from "test/Constants.sol";

abstract contract DeployMilestoneUnlockHookScript is Script, Constants, Log {
    struct DeployConfig {
        address airlock;
        address manager;
    }

    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    DeployConfig public deployConfig;

    string public initializerName;
    string public hookName;

    function setUp() public virtual {
        // TODO: Update these configs in each deployment script
        deployConfig = DeployConfig({ airlock: address(0), manager: address(0) });
        initializerName = "MilestoneUnlockUniswapV4MulticurveInitializer";
        hookName = "SSLMilestoneUnlockHook";
    }

    function run() public {
        require(deployConfig.airlock != address(0), "AIRLOCK_ADDRESS_IS_ZERO");
        require(address(deployConfig.manager) != address(0), "MANAGER_ADDRESS_IS_ZERO");

        // Using `CREATE` we can pre-compute the UniswapV4MulticurveInitializer address for mining the hook address
        address precomputedInitializer = vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender));

        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_SWAP_FLAG
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(SSLMilestoneUnlockHook).creationCode,
            abi.encode(IPoolManager(deployConfig.manager), precomputedInitializer)
        );

        vm.startBroadcast();
        // Deploy Initializer with pre-mined hook address
        MilestoneUnlockUniswapV4MulticurveInitializer initializer = new MilestoneUnlockUniswapV4MulticurveInitializer(
            deployConfig.airlock, IPoolManager(deployConfig.manager), IHooks(hookAddress)
        );
        SSLMilestoneUnlockHook sslMilestoneUnlockHook =
            new SSLMilestoneUnlockHook{ salt: salt }(IPoolManager(deployConfig.manager), address(initializer));
        vm.stopBroadcast();

        require(address(initializer) == precomputedInitializer, "INITIALIZER_ADDRESS_MISMATCH");
        require(address(sslMilestoneUnlockHook) == hookAddress, "HOOK_ADDRESS_MISMATCH");

        recordDeployment(address(initializer), initializerName);
        recordDeployment(address(sslMilestoneUnlockHook), hookName);
    }
}
