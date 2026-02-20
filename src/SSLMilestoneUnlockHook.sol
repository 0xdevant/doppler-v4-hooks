// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { TransientStateLibrary } from "@v4-core/libraries/TransientStateLibrary.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { Currency, PoolKey } from "@v4-core/types/PoolKey.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";

import { MilestonePositionDetails } from "src/MilestoneUnlockUniswapV4MulticurveInitializer.sol";

/**
 * @notice Emitted when liquidity is modified
 * @param key Key of the related pool
 * @param params Parameters of the liquidity modification
 */
event ModifyLiquidity(PoolKey key, IPoolManager.ModifyLiquidityParams params);

/**
 * @notice Emitted when a Swap occurs
 * @param sender Address calling the PoolManager
 * @param poolKey Key of the related pool
 * @param poolId Id of the related pool
 * @param params Parameters of the swap
 * @param amount0 Balance denominated in token0
 * @param amount1 Balance denominated in token1
 * @param hookData Data passed to the hook
 */
event Swap(
    address indexed sender,
    PoolKey indexed poolKey,
    PoolId indexed poolId,
    IPoolManager.SwapParams params,
    int128 amount0,
    int128 amount1,
    bytes hookData
);

/// @notice Thrown when the caller is not the Uniswap V4 Multicurve Initializer
error OnlyInitializer();

interface IMilestoneUnlockUniswapV4MulticurveInitializer {
    function getMilestonePositionDetails(address asset) external view returns (MilestonePositionDetails[] memory);

    function unlockPosition(Currency asset, Currency numeraire, uint256 positionIndex) external;
}

/**
 * @title SSL Milestone Unlock Hook
 * @author ant
 * @notice Hook used by the Milestone Unlock Uniswap V4 Multicurve Initializer to automatically unlock SSL positions when the price of the asset reaches the upper tick of the position
 *
 * IMPORTANT: Given asset is assumed to be always token0, the contract logic is designed to check the tick
 * from hardcoded Currency0 EXCEPT when numeraire is native i.e. address(0) then the tick is checked from Currency1
 */
contract SSLMilestoneUnlockHook is BaseHook {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /// @notice Address of the Milestone Unlock Uniswap V4 Multicurve Initializer contract
    address public immutable INITIALIZER;

    /**
     *
     * @dev Modifier to ensure the caller is the Uniswap V4 Multicurve Initializer
     * @param sender Address of the caller
     */
    modifier onlyInitializer(address sender) {
        if (sender != INITIALIZER) revert OnlyInitializer();
        _;
    }

    /**
     * @notice Constructor for the SSL Milestone Unlock Hook
     * @param manager Address of the Uniswap V4 Pool Manager
     * @param initializer Address of the Uniswap V4 Multicurve Initializer contract
     */
    constructor(IPoolManager manager, address initializer) BaseHook(manager) {
        // no input checkings for controlled deployment to save gas
        INITIALIZER = initializer;
    }

    // /// @inheritdoc BaseHook
    // function _beforeInitialize(
    //     address sender,
    //     PoolKey calldata key,
    //     uint160
    // ) internal view override onlyInitializer(sender) returns (bytes4) {
    //     // ensure at least one milestone position is set
    //     require(
    //         IMilestoneUnlockUniswapV4MulticurveInitializer(INITIALIZER)
    //         .getMilestonePositionDetails(
    //             Currency.unwrap(key.currency0) == address(0)
    //                 ? Currency.unwrap(key.currency1)
    //                 : Currency.unwrap(key.currency0)
    //         )
    //         .length > 0,
    //         EmptyMilestonePositions()
    //     );
    //     return BaseHook.beforeInitialize.selector;
    // }

    /// @inheritdoc BaseHook
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        bool isAssetToken0 = Currency.unwrap(key.currency0) != address(0);

        IMilestoneUnlockUniswapV4MulticurveInitializer initializer =
            IMilestoneUnlockUniswapV4MulticurveInitializer(INITIALIZER);
        MilestonePositionDetails[] memory positionDetails = isAssetToken0
            ? initializer.getMilestonePositionDetails(Currency.unwrap(key.currency0))
            : initializer.getMilestonePositionDetails(Currency.unwrap(key.currency1));

        // read current tick based sqrtPrice as its more accurate in extreme edge cases
        (uint160 sqrtPrice,,,) = poolManager.getSlot0(key.toId());
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPrice);
        for (uint256 i; i < positionDetails.length; i++) {
            if (isAssetToken0) {
                // unlock if the current tick > upper tick of the position when asset is token0
                if (currentTick > positionDetails[i].tickUpper) {
                    initializer.unlockPosition(key.currency0, key.currency1, i);
                }
            } else {
                // unlock if the current tick < lower tick of the position when asset is token1
                if (currentTick < positionDetails[i].tickLower) {
                    initializer.unlockPosition(key.currency1, key.currency0, i);
                }
            }
        }

        emit Swap(sender, key, key.toId(), params, delta.amount0(), delta.amount1(), hookData);
        return (BaseHook.afterSwap.selector, 0);
    }

    /// @inheritdoc BaseHook
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view virtual override onlyInitializer(sender) returns (bytes4) {
        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @inheritdoc BaseHook
    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        emit ModifyLiquidity(key, params);
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @inheritdoc BaseHook
    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        emit ModifyLiquidity(key, params);
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
