// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { TransientStateLibrary } from "@v4-core/libraries/TransientStateLibrary.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { ImmutableState } from "@v4-periphery/base/ImmutableState.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";

import {
    BeneficiaryData,
    Curve,
    FeesManager,
    IPoolInitializer,
    ImmutableAirlock,
    MIN_PROTOCOL_OWNER_SHARES,
    MiniV4Manager,
    Position,
    adjustCurves,
    calculatePositions
} from "doppler/src/initializers/UniswapV4MulticurveInitializer.sol";
import { concat } from "doppler/src/libraries/Multicurve.sol";

import { console } from "forge-std/console.sol";

/**
 * @notice Emitted when a new pool is locked
 * @param pool Address of the Uniswap V4 pool key
 * @param beneficiaries Array of beneficiaries with their shares
 */
event Lock(address indexed pool, BeneficiaryData[] beneficiaries);

/**
 * @notice Emitted when a milestone position is unlocked
 * @param asset Address of the asset
 * @param positionIndex Index of the milestone position
 */
event PositionUnlocked(address indexed asset, uint256 indexed positionIndex);

/// @notice Thrown when the pool is already initialized
error PoolAlreadyInitialized();

/// @notice Thrown when the pool is already exited
error PoolAlreadyExited();

/// @notice Thrown when the pool is not locked but collect is called
error PoolNotLocked();

/// @notice Thrown when the current tick is not sufficient to migrate
error CannotMigrateInsufficientTick(int24 targetTick, int24 currentTick);

/// @notice Thrown when the array of milestone positions is empty
error EmptyMilestonePositions();
/// @notice Thrown when the configs for milestone positions tick range is invalid
error InvalidMilestonePositionsTickRange();
/// @notice Thrown when the configs for milestone positions tick is bigger or smaller than the current tick based on if asset is token0 or token1
error InvalidMilestonePositionsTickBasedOnCurrentTick();
/// @notice Thrown when the milestone position is already withdrawn
error MilestonePositionAlreadyWithdrawn();
/// @notice Thrown when the caller is not the SSL milestone unlock hook
error OnlyFromSSLMilestoneUnlockHook();

/**
 * @notice Data used to initialize the Uniswap V4 pool
 * @param fee Fee of the Uniswap V4 pool (capped at 1_000_000)
 * @param tickSpacing Tick spacing for the Uniswap V4 pool
 * @param curves Array of curves to distribute liquidity across
 * @param beneficiaries Array of beneficiaries with their shares
 * @param milestonePositionsInfo Array of milestone position data
 */
struct InitData {
    uint24 fee;
    int24 tickSpacing;
    Curve[] curves;
    BeneficiaryData[] beneficiaries;
    MilestonePositionData[] milestonePositionsInfo;
}

/// @notice Possible status of a pool, note a locked pool cannot be exited
enum PoolStatus {
    Uninitialized,
    Initialized,
    Locked,
    Exited
}

/**
 * @notice State of a pool
 * @param numeraire Address of the numeraire currency
 * @param beneficiaries Array of beneficiaries with their shares
 * @param positions Array of positions held in the pool
 * @param status Current status of the pool
 * @param poolKey Key of the Uniswap V4 pool
 * @param farTick The farthest tick that must be reached to allow exiting liquidity
 * @param milestonePositionStartIndex Index of the first milestone position in the `positions` array
 */
struct PoolState {
    address numeraire;
    BeneficiaryData[] beneficiaries;
    Position[] positions;
    PoolStatus status;
    PoolKey poolKey;
    int24 farTick;
}

struct MilestonePositionData {
    uint256 amount;
    int24 tickLower;
    int24 tickUpper;
    address recipient;
}

struct MilestonePositionDetails {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    bytes32 salt;
    address recipient;
    bool withdrawn;
}

/**
 * @title Milestone Unlock Uniswap V4 Multicurve Initializer
 * @author ant
 * @notice Built on top of the Uniswap V4 Multicurve Initializer, this initializer is designed to allow unlocking Single Sided Liquidity (SSL) positions
 * in a milestone-based manner by checking the FDV of the asset which will be handled by the Milestone Unlock Hook specified in `HOOK`.
 * Other than that, it follows the same flow as the Uniswap V4 Multicurve Initializer.
 */
contract MilestoneUnlockUniswapV4MulticurveInitializer is
    IPoolInitializer,
    FeesManager,
    ImmutableAirlock,
    MiniV4Manager
{
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using TransientStateLibrary for IPoolManager;

    /// @notice Address of the Uniswap V4 Multicurve hook
    IHooks public immutable HOOK;

    /// @notice Returns the state of a pool
    mapping(address asset => PoolState state) public getState;

    /// @notice Maps a Uniswap V4 poolId to its associated asset
    mapping(PoolId poolId => address asset) internal getAsset;

    /// @notice Maps an asset to its milestone position details
    mapping(address asset => MilestonePositionDetails[] details) public milestonePositionDetails;

    /**
     * @param airlock_ Address of the Airlock contract
     * @param poolManager_ Address of the Uniswap V4 pool manager
     * @param hook_ Address of the UniswapV4MulticurveInitializerHook
     */
    constructor(
        address airlock_,
        IPoolManager poolManager_,
        IHooks hook_
    ) ImmutableAirlock(airlock_) ImmutableState(poolManager_) {
        HOOK = hook_;
    }

    /// @inheritdoc IPoolInitializer
    function initialize(
        address asset,
        address numeraire,
        uint256 totalTokensOnBondingCurve,
        bytes32,
        bytes calldata data
    ) external virtual onlyAirlock returns (address) {
        require(getState[asset].status == PoolStatus.Uninitialized, PoolAlreadyInitialized());

        InitData memory initData = abi.decode(data, (InitData));

        (
            uint24 fee,
            int24 tickSpacing,
            Curve[] memory curves,
            BeneficiaryData[] memory beneficiaries,
            MilestonePositionData[] memory milestonePositionsInfo
        ) = (
            initData.fee, initData.tickSpacing, initData.curves, initData.beneficiaries, initData.milestonePositionsInfo
        );
        require(initData.milestonePositionsInfo.length > 0, EmptyMilestonePositions());

        PoolKey memory poolKey = PoolKey({
            currency0: asset < numeraire ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: asset < numeraire ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: HOOK,
            fee: fee,
            tickSpacing: tickSpacing
        });
        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);

        (Curve[] memory adjustedCurves, int24 tickLower, int24 tickUpper) =
            adjustCurves(curves, 0, tickSpacing, isToken0);

        int24 startTick = isToken0 ? tickLower : tickUpper;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(startTick);
        poolManager.initialize(poolKey, sqrtPriceX96);

        // only creating these positions for minting purposes
        // as they should be claimable only when fully unlocked so shouldn't save this to pool state for `_collectFees`
        (Position[] memory milestonePositions, uint256 amountForMilestonePositions) =
            _constructAndStoreMilestonePositions(asset, poolKey, milestonePositionsInfo);

        Position[] memory positions = calculatePositions(
            adjustedCurves, tickSpacing, totalTokensOnBondingCurve - amountForMilestonePositions, 0, isToken0
        );

        PoolState memory state = PoolState({
            numeraire: numeraire,
            beneficiaries: beneficiaries,
            positions: positions,
            status: beneficiaries.length != 0 ? PoolStatus.Locked : PoolStatus.Initialized,
            poolKey: poolKey,
            farTick: isToken0 ? tickUpper : tickLower
        });

        getState[asset] = state;
        getAsset[poolKey.toId()] = asset;

        SafeTransferLib.safeTransferFrom(asset, address(airlock), address(this), totalTokensOnBondingCurve);
        // Concatenate the positions and the milestone positions
        _mint(poolKey, concat(positions, milestonePositions));

        emit Create(address(poolManager), asset, numeraire);

        if (beneficiaries.length != 0) {
            _storeBeneficiaries(poolKey, beneficiaries, airlock.owner(), MIN_PROTOCOL_OWNER_SHARES);
            emit Lock(asset, beneficiaries);
        }

        // If any dust asset tokens are left in this contract after providing liquidity, we send them
        // back to the Airlock so they'll be transferred to the associated governance or burnt
        if (Currency.wrap(asset).balanceOfSelf() > 0) {
            Currency.wrap(asset).transfer(address(airlock), Currency.wrap(asset).balanceOfSelf());
        }

        // Uniswap V4 pools don't have addresses, so we are returning the asset address
        // instead to retrieve the associated state later during the `exitLiquidity` call
        return asset;
    }

    /* @notice Constructs the array of position struct and stores the positions to `MilestonePositionDetails`
    * @param asset Address of the asset
    * @param poolKey Key of the Uniswap V4 pool
    * @param positionsInfo Array of position information
    * @return positions Array of positions to be minted together with the original positions
    */
    function _constructAndStoreMilestonePositions(
        address asset,
        PoolKey memory poolKey,
        MilestonePositionData[] memory positionsInfo
    ) internal returns (Position[] memory positions, uint256 amountForMilestonePositions) {
        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);
        positions = new Position[](positionsInfo.length);

        for (uint256 i; i < positionsInfo.length; i++) {
            // Validate tick ranges
            require(positionsInfo[i].tickLower < positionsInfo[i].tickUpper, InvalidMilestonePositionsTickRange());
            (, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());
            if (isToken0) {
                // Token0: positions must be above current tick
                require(positionsInfo[i].tickLower > currentTick, InvalidMilestonePositionsTickBasedOnCurrentTick());
            } else {
                // Token1: positions must be below current tick
                require(positionsInfo[i].tickUpper < currentTick, InvalidMilestonePositionsTickBasedOnCurrentTick());
            }

            amountForMilestonePositions += positionsInfo[i].amount;
            uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(positionsInfo[i].tickLower);
            uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(positionsInfo[i].tickUpper);
            uint128 liquidity = isToken0
                ? LiquidityAmounts.getLiquidityForAmount0(sqrtPriceLowerX96, sqrtPriceUpperX96, positionsInfo[i].amount)
                : LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLowerX96, sqrtPriceUpperX96, positionsInfo[i].amount);

            bytes32 salt = bytes32(uint256(keccak256(abi.encode(asset, i))));

            // construct the positions to be minted
            positions[i] = Position({
                tickLower: positionsInfo[i].tickLower,
                tickUpper: positionsInfo[i].tickUpper,
                liquidity: liquidity,
                salt: salt
            });

            // store the milestone position details
            milestonePositionDetails[asset].push(
                MilestonePositionDetails({
                    tickLower: positionsInfo[i].tickLower,
                    tickUpper: positionsInfo[i].tickUpper,
                    liquidity: liquidity,
                    salt: salt,
                    recipient: positionsInfo[i].recipient,
                    withdrawn: false
                })
            );
        }
    }

    function unlockPosition(Currency asset, Currency numeraire, uint256 positionIndex) external {
        require(msg.sender == address(HOOK), OnlyFromSSLMilestoneUnlockHook());

        address assetAddress = Currency.unwrap(asset);
        MilestonePositionDetails memory positionDetails = milestonePositionDetails[assetAddress][positionIndex];
        require(!positionDetails.withdrawn, MilestonePositionAlreadyWithdrawn());

        uint256 numeraireBalanceBefore = numeraire.balanceOfSelf();
        _burnPosition(getState[assetAddress].poolKey, positionDetails);
        uint256 numeraireBalanceAfter = numeraire.balanceOfSelf();
        console.log("unlockPosition numeraireBalanceAfter", numeraireBalanceAfter);
        uint256 numeraireReceived = numeraireBalanceAfter - numeraireBalanceBefore;

        milestonePositionDetails[assetAddress][positionIndex].withdrawn = true;

        if (numeraireReceived > 0) {
            numeraire.transfer(positionDetails.recipient, numeraireReceived);
        }

        emit PositionUnlocked(assetAddress, positionIndex);
    }

    function _burnPosition(PoolKey memory poolKey, MilestonePositionDetails memory positionDetails) internal {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: positionDetails.tickLower,
            tickUpper: positionDetails.tickUpper,
            liquidityDelta: -int128(positionDetails.liquidity),
            salt: positionDetails.salt
        });

        (BalanceDelta balanceDelta,) = poolManager.modifyLiquidity(poolKey, params, new bytes(0));
        // console.log("feesAccrued.amount0()", feesAccrued.amount0());
        // console.log("feesAccrued.amount1()", feesAccrued.amount1());
        console.log("before take currency0 delta", poolManager.currencyDelta(address(this), poolKey.currency0));
        console.log("before take currency1 delta", poolManager.currencyDelta(address(this), poolKey.currency1));
        // if not native numeraire will take currency1
        if (poolKey.currency0 == Currency.wrap(address(0))) {
            poolManager.take(poolKey.currency0, address(this), uint256(uint128(balanceDelta.amount0())));
        } else {
            poolManager.take(poolKey.currency1, address(this), uint256(uint128(balanceDelta.amount1())));
        }
        console.log("after take currency0 delta", poolManager.currencyDelta(address(this), poolKey.currency0));
        console.log("after take currency1 delta", poolManager.currencyDelta(address(this), poolKey.currency1));
    }

    /// @inheritdoc IPoolInitializer
    function exitLiquidity(address asset)
        external
        onlyAirlock
        returns (
            uint160 sqrtPriceX96,
            address token0,
            uint128 fees0,
            uint128 balance0,
            address token1,
            uint128 fees1,
            uint128 balance1
        )
    {
        PoolState memory state = getState[asset];
        require(state.status == PoolStatus.Initialized, PoolAlreadyExited());
        getState[asset].status = PoolStatus.Exited;

        token0 = Currency.unwrap(state.poolKey.currency0);
        token1 = Currency.unwrap(state.poolKey.currency1);

        (, int24 tick,,) = poolManager.getSlot0(state.poolKey.toId());
        int24 farTick = state.farTick;
        require(asset == token0 ? tick >= farTick : tick <= farTick, CannotMigrateInsufficientTick(farTick, tick));
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(farTick);

        (BalanceDelta balanceDelta, BalanceDelta feesAccrued) = _burn(state.poolKey, state.positions);
        balance0 = uint128(balanceDelta.amount0());
        balance1 = uint128(balanceDelta.amount1());
        fees0 = uint128(feesAccrued.amount0());
        fees1 = uint128(feesAccrued.amount1());

        state.poolKey.currency0.transfer(msg.sender, balance0);
        state.poolKey.currency1.transfer(msg.sender, balance1);
    }

    /**
     * @notice Returns the number of active (non-withdrawn) LP unlock positions for an asset
     * @param asset Token address
     * @return activePositions Active Milestone positions that are not withdrawn
     */
    function getActiveMilestonePositions(address asset) external view returns (Position[] memory activePositions) {
        uint256 totalNumOfPositions = milestonePositionDetails[asset].length;
        activePositions = new Position[](totalNumOfPositions);
        uint256 activeIndex;

        for (uint256 i; i < totalNumOfPositions; i++) {
            if (milestonePositionDetails[asset][i].withdrawn) {
                continue;
            }
            Position memory position = Position({
                tickLower: milestonePositionDetails[asset][i].tickLower,
                tickUpper: milestonePositionDetails[asset][i].tickUpper,
                liquidity: milestonePositionDetails[asset][i].liquidity,
                salt: milestonePositionDetails[asset][i].salt
            });
            activePositions[activeIndex] = position;
            activeIndex++;
        }
    }

    /**
     * @notice Returns the number of active (non-withdrawn) LP unlock positions for an asset
     * @param asset Token address
     * @return count Number of active milestone positions
     */
    function getNumOfActiveMilestonePositions(address asset) external view returns (uint256 count) {
        MilestonePositionDetails[] memory details = milestonePositionDetails[asset];
        for (uint256 i; i < details.length; i++) {
            if (!details[i].withdrawn) {
                count++;
            }
        }
    }

    function getMilestonePositionDetails(address asset) external view returns (MilestonePositionDetails[] memory) {
        return milestonePositionDetails[asset];
    }

    /**
     * @notice Returns the positions currently held in the Uniswap V4 pool for the given `asset`
     * @param asset Address of the asset used for the Uniswap V4 pool
     * @return Array of positions currently held in the Uniswap V4 pool
     */
    function getPositions(address asset) external view returns (Position[] memory) {
        return getState[asset].positions;
    }

    /**
     * @notice Returns the beneficiaries and their shares for the given `asset`
     * @param asset Address of the asset used for the Uniswap V4 pool
     * @return Array of beneficiaries with their shares
     */
    function getBeneficiaries(address asset) external view returns (BeneficiaryData[] memory) {
        return getState[asset].beneficiaries;
    }

    /// @inheritdoc FeesManager
    function _collectFees(PoolId poolId) internal override returns (BalanceDelta fees) {
        PoolState memory state = getState[getAsset[poolId]];
        require(state.status == PoolStatus.Locked, PoolNotLocked());
        fees = _collect(state.poolKey, state.positions);
    }
}
