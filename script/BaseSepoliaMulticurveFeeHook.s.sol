// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";

import { Constants } from "../test/Constants.sol";
import { DeployMulticurveFeeHookScript } from "script/abstract/DeployMulticurveFeeHook.s.sol";

contract BaseSepoliaMulticurveFeeHookScript is DeployMulticurveFeeHookScript {
    function setUp() public virtual override {
        deployConfig = DeployConfig({
            airlock: Constants.BASE_SEPOLIA_AIRLOCK,
            manager: Constants.BASE_SEPOLIA_POOL_MANAGER,
            hookFeeWad: 0.01 ether // 1% fee
        });
        initializerName = "BaseSepoliaUniswapV4MulticurveInitializer";
        hookName = "BaseSepoliaUniswapV4MulticurveInitializerFeeHook";
    }
}
