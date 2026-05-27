// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function approve(address spender, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);
}

abstract contract ILShieldHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    // =========================================================================
    //  STRUCTS
    // =========================================================================

    struct PoolConfig {
        uint16 premiumBps; // % of swap output to reserve
        uint16 coveragePct; // % of IL that is covered
        uint16 deductableBps; // minimum IL before payout
        uint32 minLockSeconds; // minimum deposit duration
    }

    struct LPPosition {
        uint160 entrySqrtPriceX96; // price at entry
        uint128 entryAmount0;
        uint128 entryAmount1;
        uint256 entryTimestamp;
        bool active;
    }

    // =========================================================================
    //  MAPPINGS
    // =========================================================================

    mapping(PoolId => PoolConfig) public poolConfig;
    mapping(PoolId => mapping(address => LPPosition)) public positions;
    mapping(PoolId => uint256) public insuranceReserve;
    mapping(PoolId => uint256) public totalInsuredValue;

    // =========================================================================
    //  EVENTS
    // =========================================================================

    event PoolInitialized(PoolId indexed poolId);
    event ReserveFunded(
        PoolId indexed poolId,
        address indexed funder,
        uint256 amount
    );
    event PositionRecorded(
        PoolId indexed poolId,
        address indexed lp,
        uint160 sqrtPriceX96,
        uint128 amt0,
        uint128 amt1
    );

    // =========================================================================
    //  CONSTRUCTOR
    // =========================================================================

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function initializePool(PoolKey calldata key) external {
        PoolId pid = key.toId();
        poolConfig[pid] = PoolConfig({
            premiumBps: 50,
            coveragePct: 5000,
            deductableBps: 200,
            minLockSeconds: 86400
        });
        emit PoolInitialized(pid);
    }

    //Right now — manually filled. Someone just sends money in via fundReserve().
    // Phase 2 — every swap automatically donates a tiny cut to the reserve.

    function fundReserve(PoolKey calldata key, uint256 amount) external {
        require(amount > 0, "ILShield: amount must be > 0");
        PoolId pid = key.toId();

        bool ok = IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        require(ok, "ILSield: transferFrom failed");
        insuranceReserve[pid] += amount;

        emit ReserveFunded(pid, msg.sender, amount);
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        if (hookData.length == 0) {
            return (
                BaseHook.afterAddLiquidity.selector,
                BalanceDeltaLibrary.ZERO_DELTA
            );
        }

        address lp = abi.decode(hookData, (address));
        PoolId pid = key.toId();

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(pid);

        uint128 amt0 = delta.amount0() > 0
            ? uint128(uint256(int256(delta.amount0())))
            : 0;
        uint128 amt1 = delta.amount1() > 0
            ? uint128(uint256(int256(delta.amount1())))
            : 0;

        // MVP : If LP already has a position, subtract its old insured value first 
        if (positions[pid][lp].active) {
            _subtractInsuredValue(pid, positions[pid][lp].entryAmount1);
        }

        positions[pid][lp] = LPPosition({
            entrySqrtPriceX96: sqrtPriceX96,
            entryAmount0: amt0,
            entryAmount1: amt1,
            entryTimestamp: block.timestamp,
            active: true
        });
        totalInsuredValue[pid] += amt1;

        emit PositionRecorded(pid, lp, sqrtPriceX96, amt0, amt1);

        return (
            BaseHook.afterAddLiquidity.selector,
            BalanceDeltaLibrary.ZERO_DELTA
        );
    }

    // =========================================================================
    //  INTERNAL HELPERS
    // =========================================================================

    function _subtractInsuredValue(PoolId pid, uint128 amount) internal {}
}
