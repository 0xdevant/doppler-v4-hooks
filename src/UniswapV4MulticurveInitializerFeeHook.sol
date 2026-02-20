// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta } from "@v4-core/types/BeforeSwapDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { BeneficiaryData } from "doppler/src/initializers/UniswapV4MulticurveInitializer.sol";
import { WAD } from "doppler/src/types/Wad.sol";

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

/// @notice Thrown when the fee is not zero during pool initialization
error FeeMustBeZero();

interface IUniswapV4MulticurveInitializer {
    function getBeneficiaries(address asset) external view returns (BeneficiaryData[] memory);
}

/**
 * @title Uniswap V4 Multicurve Initializer Fee Hook
 * @author ant
 * @notice Hook used by the Uniswap V4 Multicurve Initializer to take fee from the numeraire amount in a Uniswap V4 pool,
 * other than that the base logic is same as `UniswapV4MulticurveInitializerHook`
 *
 * IMPORTANT: Given numeraire is assumed to be always token1, the contract logic is designed to take fee
 * from hardcoded Currency1 EXCEPT when native token is used as numeraire then the fee is taken from Currency0
 */
contract UniswapV4MulticurveInitializerFeeHook is BaseHook {
    uint256 public immutable HOOK_FEE_WAD;

    /// @notice Address of the Uniswap V4 Multicurve Initializer contract
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
     * @notice Constructor for the Fee Hook
     * @param manager Address of the Uniswap V4 Pool Manager
     * @param initializer Address of the Uniswap V4 Multicurve Initializer contract
     */
    constructor(IPoolManager manager, address initializer, uint256 hookFeeWad) BaseHook(manager) {
        // no input checkings for controlled deployment to save gas
        INITIALIZER = initializer;
        HOOK_FEE_WAD = hookFeeWad;
    }

    /// @dev For receiving ETH if the fee currency is address(0)
    receive() external payable { }

    /// @inheritdoc BaseHook
    function _beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160
    ) internal view override onlyInitializer(sender) returns (bytes4) {
        // ensure pool fee is always zero in order to enable hook fee
        require(key.fee == 0, FeeMustBeZero());
        return BaseHook.beforeInitialize.selector;
    }

    /// @inheritdoc BaseHook
    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 feeAmount;

        // NOTE: these are not mutually exclusive cases, so we need to check all
        bool isNumeraireNative = Currency.unwrap(key.currency0) == address(0);
        /* token0: native numeraire, token1: asset */
        bool nativeNumeraireForAssetExactIn = isNumeraireNative && params.zeroForOne && params.amountSpecified < 0;
        bool assetForNativeNumeraireExactOut = isNumeraireNative && !params.zeroForOne && params.amountSpecified > 0;
        /* token0: asset, token1: numeraire */
        bool numeraireForAssetExactIn = !isNumeraireNative && !params.zeroForOne && params.amountSpecified < 0;
        bool assetForNumeraireExactOut = !isNumeraireNative && params.zeroForOne && params.amountSpecified > 0;

        if (
            nativeNumeraireForAssetExactIn || assetForNativeNumeraireExactOut || numeraireForAssetExactIn
                || assetForNumeraireExactOut
        ) {
            // return early if there are no beneficiaries to distribute fee to
            BeneficiaryData[] memory beneficiaries = IUniswapV4MulticurveInitializer(INITIALIZER)
                .getBeneficiaries(Currency.unwrap(isNumeraireNative ? key.currency1 : key.currency0));
            if (beneficiaries.length == 0) return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

            uint256 swapAmount;
            // 1. Get the swap amount based on exactIn or exactOut
            if (numeraireForAssetExactIn || nativeNumeraireForAssetExactIn) {
                swapAmount = uint256(-params.amountSpecified);
            } else if (assetForNumeraireExactOut || assetForNativeNumeraireExactOut) {
                swapAmount = uint256(params.amountSpecified);
            }
            // 2. calculate fee amount from above swapping numeraire amount
            feeAmount = FullMath.mulDiv(swapAmount, HOOK_FEE_WAD, WAD);

            // ensure there is enough numeraire in Pool Manager to take fee from
            uint256 balanceOfNumeraire = isNumeraireNative
                ? key.currency0.balanceOf(address(poolManager))
                : key.currency1.balanceOf(address(poolManager));
            if (balanceOfNumeraire < feeAmount) {
                return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            }
            // 3a. `take` from PoolManager the fee amount from numeraire
            poolManager.take(isNumeraireNative ? key.currency0 : key.currency1, address(this), feeAmount);
            // 3b. distribute to beneficiaries
            // numeraire is always token1 except when native token is used as numeraire
            _distributeToBeneficiaries(beneficiaries, isNumeraireNative ? key.currency0 : key.currency1, feeAmount);
        }

        // 3c. return `BeforeSwapDelta` to reflect the fee taken from numeraire amount
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(int256(feeAmount)), 0), 0);
    }

    /// @inheritdoc BaseHook
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        uint256 feeAmount;

        // since we only get the desired amount of asset from the input for below cases, we can only get the result of numeraire amount at afterSwap
        // NOTE: these are not mutually exclusive cases, so we need to check all
        bool isNumeraireNative = Currency.unwrap(key.currency0) == address(0);
        /* token0: native numeraire, token1: asset */
        bool assetForNativeNumeraireExactIn = isNumeraireNative && !params.zeroForOne && params.amountSpecified < 0;
        bool nativeNumeraireForAssetExactOut = isNumeraireNative && params.zeroForOne && params.amountSpecified > 0;
        /* token0: asset, token1: numeraire */
        bool assetForNumeraireExactIn = !isNumeraireNative && params.zeroForOne && params.amountSpecified < 0;
        bool numeraireForAssetExactOut = !isNumeraireNative && !params.zeroForOne && params.amountSpecified > 0;

        // NOTE: if the conditions matched at beforeSwap the fee will already be taken,
        // here the conditions are the opposite of beforeSwap thus fee will not be taken again at afterSwap
        if (
            assetForNativeNumeraireExactIn || nativeNumeraireForAssetExactOut || assetForNumeraireExactIn
                || numeraireForAssetExactOut
        ) {
            // return early if there are no beneficiaries to distribute fee to
            BeneficiaryData[] memory beneficiaries = IUniswapV4MulticurveInitializer(INITIALIZER)
                .getBeneficiaries(Currency.unwrap(isNumeraireNative ? key.currency1 : key.currency0));
            if (beneficiaries.length == 0) return (BaseHook.afterSwap.selector, 0);

            // 1. Get the output amount based on exactIn or exactOut
            int256 outputAmount;
            if (assetForNativeNumeraireExactIn) {
                outputAmount = delta.amount0();
            } else if (nativeNumeraireForAssetExactOut) {
                outputAmount = -(delta.amount0());
            } else if (assetForNumeraireExactIn) {
                outputAmount = delta.amount1();
            } else if (numeraireForAssetExactOut) {
                outputAmount = -(delta.amount1());
            }
            if (outputAmount <= 0) {
                return (BaseHook.afterSwap.selector, 0);
            }

            // 2. calculate fee amount from above swapping numeraire amount
            feeAmount = FullMath.mulDiv(uint256(outputAmount), HOOK_FEE_WAD, WAD);
            // ensure there is enough numeraire in Pool Manager to take fee from
            uint256 balanceOfNumeraire = isNumeraireNative
                ? key.currency0.balanceOf(address(poolManager))
                : key.currency1.balanceOf(address(poolManager));
            if (balanceOfNumeraire < feeAmount) {
                return (BaseHook.afterSwap.selector, 0);
            }
            // 3a. `take` from PoolManager the fee amount from numeraire
            poolManager.take(isNumeraireNative ? key.currency0 : key.currency1, address(this), feeAmount);
            // 3b. distribute to beneficiaries
            _distributeToBeneficiaries(beneficiaries, isNumeraireNative ? key.currency0 : key.currency1, feeAmount);
        }

        emit Swap(sender, key, key.toId(), params, delta.amount0(), delta.amount1(), hookData);
        // 3c. return fee amount delta
        return (BaseHook.afterSwap.selector, int128(int256(feeAmount)));
    }

    function _distributeToBeneficiaries(
        BeneficiaryData[] memory beneficiaries,
        Currency currency,
        uint256 feeAmount
    ) internal {
        for (uint256 i; i < beneficiaries.length; i++) {
            currency.transfer(beneficiaries[i].beneficiary, FullMath.mulDiv(feeAmount, beneficiaries[i].shares, WAD));
        }
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
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
