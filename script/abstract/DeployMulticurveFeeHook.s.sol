// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { IHooks, IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { HookMiner } from "@v4-periphery/utils/HookMiner.sol";
import { UniswapV4MulticurveInitializer } from "doppler/src/initializers/UniswapV4MulticurveInitializer.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { Log } from "script/Log.sol";
import { UniswapV4MulticurveInitializerFeeHook } from "src/UniswapV4MulticurveInitializerFeeHook.sol";
import { Constants } from "test/Constants.sol";

abstract contract DeployMulticurveFeeHookScript is Script, Constants, Log {
    struct DeployConfig {
        address airlock;
        address manager;
        uint256 hookFeeWad;
    }

    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    DeployConfig public deployConfig;

    string public initializerName;
    string public hookName;

    function setUp() public virtual {
        // TODO: Update these configs in each deployment script
        deployConfig = DeployConfig({ airlock: address(0), manager: address(0), hookFeeWad: 0 ether });
        initializerName = "UniswapV4MulticurveInitializerFeeHook";
        hookName = "UniswapV4MulticurveInitializerFeeHook";
    }

    function run() public {
        require(deployConfig.airlock != address(0), "AIRLOCK_ADDRESS_IS_ZERO");
        require(address(deployConfig.manager) != address(0), "MANAGER_ADDRESS_IS_ZERO");
        require(deployConfig.hookFeeWad != 0, "HOOK_FEE_WAD_IS_ZERO");

        // Using `CREATE` we can pre-compute the UniswapV4MulticurveInitializer address for mining the hook address
        address precomputedInitializer = vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(UniswapV4MulticurveInitializerFeeHook).creationCode,
            abi.encode(IPoolManager(deployConfig.manager), precomputedInitializer, deployConfig.hookFeeWad)
        );

        vm.startBroadcast();
        // Deploy Initializer with pre-mined hook address
        UniswapV4MulticurveInitializer initializer = new UniswapV4MulticurveInitializer(
            deployConfig.airlock, IPoolManager(deployConfig.manager), IHooks(hookAddress)
        );
        UniswapV4MulticurveInitializerFeeHook multicurveFeeHook = new UniswapV4MulticurveInitializerFeeHook{
            salt: salt
        }(
            IPoolManager(deployConfig.manager), address(initializer), deployConfig.hookFeeWad
        );
        vm.stopBroadcast();

        require(address(initializer) == precomputedInitializer, "INITIALIZER_ADDRESS_MISMATCH");
        require(address(multicurveFeeHook) == hookAddress, "HOOK_ADDRESS_MISMATCH");

        recordDeployment(address(initializer), initializerName);
        recordDeployment(address(multicurveFeeHook), hookName);
    }
}
