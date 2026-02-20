// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Constants } from "../test/Constants.sol";
import { DeployMilestoneUnlockHookScript } from "script/abstract/DeployMilestoneUnlockHook.s.sol";

contract BaseSepoliaMilestoneUnlockHookScript is DeployMilestoneUnlockHookScript {
    function setUp() public virtual override {
        deployConfig =
            DeployConfig({ airlock: Constants.BASE_SEPOLIA_AIRLOCK, manager: Constants.BASE_SEPOLIA_POOL_MANAGER });
        initializerName = "BaseSepoliaMilestoneUnlockUniswapV4MulticurveInitializer";
        hookName = "BaseSepoliaSSLMilestoneUnlockHook";
    }
}
