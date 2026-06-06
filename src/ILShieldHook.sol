// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

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

contract ILShieldHook is BaseHook {
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
        uint16 deductibleBps; // minimum IL before payout
        uint32 minLockSeconds; // minimum deposit duration
    }

    struct LPPosition {
        uint160 entrySqrtPriceX96; // price at entry
        uint128 entryAmount0;
        uint128 entryAmount1;
        uint128 entryLiquidity;
        uint256 entryTimestamp;
        int24 tickLower;
        int24 tickUpper;
        bool active;
    }

    // =========================================================================
    //  MAPPINGS
    // =========================================================================

    mapping(PoolId => address) public poolOwner;
    mapping(PoolId => PoolConfig) public poolConfig;
    mapping(PoolId => mapping(address => LPPosition)) public positions;
    mapping(PoolId => uint256) public insuranceReserve;
    mapping(PoolId => uint256) public totalInsuredValue;

    // =========================================================================
    //  EVENTS
    // =========================================================================

    event PoolInitialized(PoolId indexed poolId, address indexed owner);
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
        uint128 amt1,
        uint256 insuredValue
    );
    event NoPayoutLockNotMet(PoolId indexed poolId, address indexed lp);
    event NoPayoutBelowDeductible(
        PoolId indexed poolId,
        address indexed lp,
        uint256 ilBps
    );
    event NoPayoutReserveEmpty(PoolId indexed poolId, address indexed lp);
    event ILPayout(
        PoolId indexed poolId,
        address indexed lp,
        uint256 ilBps,
        uint256 payout
    );

    // =========================================================================
    //  CONSTRUCTOR
    // =========================================================================

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // =========================================================================
    //  HOOK PERMISSIONS
    //
    //  Flag bits (Hooks.sol):
    //    afterAddLiquidity         1 << 10 = 0x0400
    //    afterRemoveLiquidity      1 << 8  = 0x0100
    //    afterSwap                 1 << 6  = 0x0040
    //    afterSwapReturnDelta      1 << 2  = 0x0004
    //    Combined                           0x0544
    //
    //  Test deployment:
    //    address(uint160(
    //        Hooks.AFTER_ADD_LIQUIDITY_FLAG   |
    //        Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
    //        Hooks.AFTER_SWAP_FLAG            |
    //        Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    //    ) ^ (0x4444 << 144))
    // =========================================================================

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: true,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // =========================================================================
    //  POOL SETUP
    // =========================================================================

    function initializePool(PoolKey calldata key) external {
        PoolId pid = key.toId();
        require(poolOwner[pid] == address(0), "ILShield: already initialized");
        poolOwner[pid] = msg.sender;
        poolConfig[pid] = PoolConfig({
            premiumBps: 50,
            coveragePct: 5000,
            deductibleBps: 200,
            minLockSeconds: 86400
        });
        emit PoolInitialized(pid, msg.sender);
    }

    /// @notice Pool owner can update insurance parameters.
    function setPoolConfig(
        PoolKey calldata key,
        PoolConfig calldata cfg
    ) external {
        PoolId pid = key.toId();
        require(msg.sender == poolOwner[pid], "ILShield: not pool owner");
        require(cfg.coveragePct <= 10000, "ILShield: coveragePct > 100%");
        require(cfg.deductibleBps <= 10000, "ILShield: deductibleBps > 100%");
        require(cfg.premiumBps <= 10000, "ILShield: premiumBps > 100%");
        require(cfg.minLockSeconds > 0, "ILShield: minLockSeconds must be > 0");
        poolConfig[pid] = cfg;
    }

    // =========================================================================
    //  RESERVE MANAGEMENT — manual top-up (supplement to swap premiums)
    // =========================================================================

    /// @notice Manually deposit token1 ERC20 into the reserve.
    ///         Useful for initial seeding before swap premiums accumulate.
    ///         Caller must approve(address(hook), amount) first.
    function fundReserve(PoolKey calldata key, uint256 amount) external {
        require(amount > 0, "ILShield: amount must be > 0");
        PoolId pid = key.toId();
        require(poolOwner[pid] != address(0), "not initialized");

        bool ok = IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        require(ok, "ILShield: transferFrom failed");
        insuranceReserve[pid] += amount;
        emit ReserveFunded(pid, msg.sender, amount);
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
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

        require(poolOwner[pid] != address(0), "ILShield: pool not initialized");

        /// Known: any caller may pass any address in hookData (v4 pattern).
        // The require below prevents overwrite but allows a 1-wei DoS.
        // Production fix: track by (poolId, tokenId) instead of (poolId, lp)
        require(
            !positions[pid][lp].active,
            "ILShield: exit current position first"
        );

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(pid);

        uint128 amt0 = delta.amount0() < 0
            ? uint128(uint256(-int256(delta.amount0())))
            : 0;
        uint128 amt1 = delta.amount1() < 0
            ? uint128(uint256(-int256(delta.amount1())))
            : 0;

        uint256 insuredValue = computeInsuredValue(amt0, amt1, sqrtPriceX96);

        positions[pid][lp] = LPPosition({
            entrySqrtPriceX96: sqrtPriceX96,
            entryAmount0: amt0,
            entryAmount1: amt1,
            entryLiquidity: uint128(uint256(int256(params.liquidityDelta))),
            entryTimestamp: block.timestamp,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            active: true
        });
        totalInsuredValue[pid] += insuredValue;

        emit PositionRecorded(pid, lp, sqrtPriceX96, amt0, amt1, insuredValue);

        return (
            BaseHook.afterAddLiquidity.selector,
            BalanceDeltaLibrary.ZERO_DELTA
        );
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Premiums collected on zeroForOne only — reserve is denominated in token1.
        // oneForZero output is token0; collecting it would require on-chain conversion.
        // Phase 3: collect both directions, swap token0 premium to token1 via router.
        if (!params.zeroForOne) return (BaseHook.afterSwap.selector, 0);

        PoolId pid = key.toId();
        uint16 premiumBps = poolConfig[pid].premiumBps;
        if (premiumBps == 0) return (BaseHook.afterSwap.selector, 0);

        int128 amount1Delta = delta.amount1();
        if (amount1Delta <= 0) return (BaseHook.afterSwap.selector, 0);

        uint256 outputAmount = uint256(uint128(amount1Delta));
        uint256 premium = (outputAmount * premiumBps) / 10000;
        if (premium == 0) return (BaseHook.afterSwap.selector, 0);

        poolManager.take(key.currency1, address(this), premium);
        insuranceReserve[pid] += premium;

        emit ReserveFunded(pid, address(poolManager), premium);

        return (BaseHook.afterSwap.selector, int128(int256(premium)));
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        if (hookData.length == 0) {
            return (
                BaseHook.afterRemoveLiquidity.selector,
                BalanceDeltaLibrary.ZERO_DELTA
            );
        }

        address lp = abi.decode(hookData, (address));
        PoolId pid = key.toId();
        LPPosition memory pos = positions[pid][lp];

        if (!pos.active) {
            return (
                BaseHook.afterRemoveLiquidity.selector,
                BalanceDeltaLibrary.ZERO_DELTA
            );
        }

        PoolConfig memory cfg = poolConfig[pid];

        uint128 removedLiq = uint128(uint256(-params.liquidityDelta));
        bool fullExit = removedLiq >= pos.entryLiquidity;

        uint128 proportionalAmt0 = fullExit
            ? pos.entryAmount0
            : uint128(
                (uint256(pos.entryAmount0) * uint256(removedLiq)) /
                    uint256(pos.entryLiquidity)
            );
        uint128 proportionalAmt1 = fullExit
            ? pos.entryAmount1
            : uint128(
                (uint256(pos.entryAmount1) * uint256(removedLiq)) /
                    uint256(pos.entryLiquidity)
            );

        uint256 fullInsuredValue = computeInsuredValue(
            pos.entryAmount0,
            pos.entryAmount1,
            pos.entrySqrtPriceX96
        );

        uint256 propInsuredValue = fullExit
            ? fullInsuredValue
            : (fullInsuredValue * uint256(removedLiq)) /
                uint256(pos.entryLiquidity);

        uint256 totalInsuredBefore = totalInsuredValue[pid];

        // Gate 1: minimum lock duration
        if (block.timestamp < pos.entryTimestamp + cfg.minLockSeconds) {
            _applyPositionUpdate(
                pid,
                lp,
                fullExit,
                propInsuredValue,
                proportionalAmt0,
                proportionalAmt1,
                removedLiq
            );
            emit NoPayoutLockNotMet(pid, lp);
            return (
                BaseHook.afterRemoveLiquidity.selector,
                BalanceDeltaLibrary.ZERO_DELTA
            );
        }

        // Compute IL using sqrtPrice ratio (no external oracle needed)
        (uint160 currentSqrtPriceX96, , , ) = poolManager.getSlot0(pid);
        uint256 ilBps = computeILBpsConcentrated(
            pos.entrySqrtPriceX96,
            currentSqrtPriceX96,
            pos.tickLower,
            pos.tickUpper
        );

        // Gate 2: deductible
        if (ilBps <= cfg.deductibleBps) {
            _applyPositionUpdate(
                pid,
                lp,
                fullExit,
                propInsuredValue,
                proportionalAmt0,
                proportionalAmt1,
                removedLiq
            );
            emit NoPayoutBelowDeductible(pid, lp, ilBps);
            return (
                BaseHook.afterRemoveLiquidity.selector,
                BalanceDeltaLibrary.ZERO_DELTA
            );
        }

        // Gate 3: non-empty reserve
        uint256 reserve = insuranceReserve[pid];
        if (reserve == 0 || propInsuredValue == 0) {
            _applyPositionUpdate(
                pid,
                lp,
                fullExit,
                propInsuredValue,
                proportionalAmt0,
                proportionalAmt1,
                removedLiq
            );
            if (reserve == 0) emit NoPayoutReserveEmpty(pid, lp);
            return (
                BaseHook.afterRemoveLiquidity.selector,
                BalanceDeltaLibrary.ZERO_DELTA
            );
        }

        // Full IL in token1 = IL% * insured principal
        uint256 fullIL = (propInsuredValue * ilBps) / 10000;
        // Apply coverage ratio
        uint256 covered = (fullIL * cfg.coveragePct) / 10000;

        // Pro-rata cap: prevents first-come-first-served drain.
        // LP can claim at most (their insuredValue / total) * reserve.
        uint256 proRataCap = (totalInsuredBefore > 0)
            ? (reserve * propInsuredValue) / totalInsuredBefore
            : reserve;

        uint256 payout = _min(covered, _min(proRataCap, reserve));

        _applyPositionUpdate(
            pid,
            lp,
            fullExit,
            propInsuredValue,
            proportionalAmt0,
            proportionalAmt1,
            removedLiq
        );

        if (payout == 0) {
            return (
                BaseHook.afterRemoveLiquidity.selector,
                BalanceDeltaLibrary.ZERO_DELTA
            );
        }

        insuranceReserve[pid] -= payout;

        // Hook holds real token1 ERC20 (deposited via fundReserve).
        // Transfer directly to LP.
        bool ok = IERC20Minimal(Currency.unwrap(key.currency1)).transfer(
            lp,
            payout
        );
        require(ok, "ILShield: payout transfer failed");

        emit ILPayout(pid, lp, ilBps, payout);

        return (
            BaseHook.afterRemoveLiquidity.selector,
            BalanceDeltaLibrary.ZERO_DELTA
        );
    }

    // =========================================================================
    //  IL MATH — public so tests can verify independently
    //
    //  Formula: IL = 1 - 2*sqrt(k) / (1 + k)
    //  where  k = currentPrice / entryPrice
    //  and    sqrt(k) = currentSqrtPrice / entrySqrtPrice
    //
    //  Verified spot checks:
    //    k=1.0 (unchanged)          →    0 bps
    //    k=2.0 (price doubled)      →  572 bps  (5.72%)
    //    k=0.5 (price halved)       →  572 bps  (symmetric)
    //    k=4.0 (sqrtPrice doubled)  → 2000 bps  (20.00%)
    // =========================================================================

    function computeILBps(
        uint160 entrySqrtPriceX96,
        uint160 currentSqrtPriceX96
    ) public pure returns (uint256 ilBps) {
        if (entrySqrtPriceX96 == 0 || currentSqrtPriceX96 == 0) return 0;

        // sqrt(k) scaled by 1e18
        uint256 sqrtKScaled = (uint256(currentSqrtPriceX96) * 1e18) /
            uint256(entrySqrtPriceX96);

        // M5: Guard against overflow in sqrtKScaled². At sqrtKScaled = 1e30,
        // price ratio is ~10^24x — no real LP survives this. Return max IL.
        if (sqrtKScaled > 1e30) return 9999;

        // k = sqrtK^2, scaled by 1e18
        uint256 kScaled = (sqrtKScaled * sqrtKScaled) / 1e18;

        // poolValueRatio = 2*sqrt(k)/(1+k), scaled by 1e18.
        // Always ≤ 1e18 by AM-GM inequality.
        uint256 num = 2 * sqrtKScaled;
        uint256 denom = 1e18 + kScaled;
        uint256 poolValueRatio = (num * 1e18) / denom;

        if (poolValueRatio >= 1e18) return 0;

        ilBps = ((1e18 - poolValueRatio) * 10000) / 1e18;
    }

    // =========================================================================
    //  IL MATH — concentrated position
    //
    //  Handles all three price regimes:
    //    in-range:    V_lp = 2s1 - sa - s1²/sb
    //    below-range: V_lp = (sb-sa)·s1² / (sa·sb)
    //    above-range: V_lp = (sb-sa)
    //
    //  V_hodl = (sb-s0)·s1² / (s0·sb) + (s0-sa)
    //
    //  All computations are in sqrtPriceX96 units.
    //  FullMath.mulDiv handles the 512-bit intermediates.
    //
    //  Reduces to the full-range formula when tickLower = minUsableTick
    //  and tickUpper = maxUsableTick. (verified: sa→0, sb→∞ limit)
    //
    //  Returns 0 (not 9999) when entry was out of range — no coverage
    //  applies to a position that entered out of range.
    // =========================================================================

    function computeILBpsConcentrated(
        uint160 entrySqrtPriceX96,
        uint160 currentSqrtPriceX96,
        int24 tickLower,
        int24 tickUpper
    ) public pure returns (uint256 ilBps) {
        if (entrySqrtPriceX96 == 0 || currentSqrtPriceX96 == 0) return 0;

        uint256 s0 = uint256(entrySqrtPriceX96);
        uint256 s1 = uint256(currentSqrtPriceX96);
        uint256 sa = uint256(TickMath.getSqrtPriceAtTick(tickLower));
        uint256 sb = uint256(TickMath.getSqrtPriceAtTick(tickUpper));

        // Entry must have been in range. No coverage for out-of-range entry.
        if (s0 <= sa || s0 >= sb) return 0;
        // sb > sa guaranteed by TickMath for tickLower < tickUpper.

        // ── HODL value at s1 (in units of s, normalised by L/Q96) ──────────
        // V_hodl = (sb-s0)*s1²/(s0*sb) + (s0-sa)
        // Split into two FullMath calls to avoid overflow (each step ≤ 2^256)
        uint256 term1;
        {
            uint256 sbS0 = sb - s0; // > 0
            uint256 step = FullMath.mulDiv(sbS0, s1, s0); // (sb-s0)*s1 / s0
            term1 = FullMath.mulDiv(step, s1, sb); // × s1 / sb
        }
        // (s0-sa) > 0 since entry was in range
        uint256 vHodl = term1 + (s0 - sa);

        if (vHodl == 0) return 0; // degenerate

        // ── LP value at s1 ────────────────────────────────────────────────
        uint256 vLp;

        if (s1 < sa) {
            // Below range: LP holds only token0
            // V_lp = (sb-sa)*s1² / (sa*sb)
            uint256 sbSa = sb - sa;
            uint256 step = FullMath.mulDiv(sbSa, s1, sa);
            vLp = FullMath.mulDiv(step, s1, sb);
        } else if (s1 > sb) {
            // Above range: LP holds only token1
            // V_lp = (sb-sa)
            vLp = sb - sa;
        } else {
            // In range
            // V_lp = 2*s1 - sa - s1²/sb
            uint256 s1SqOverSb = FullMath.mulDiv(s1, s1, sb);
            // 2*s1 - sa ≥ s1 ≥ s1²/sb  (since s1 ≤ sb and s1 ≥ sa)
            vLp = 2 * s1 - sa - s1SqOverSb;
        }

        // IL is always ≥ 0 for a valid AMM position, but guard defensively.
        if (vLp >= vHodl) return 0;

        // ilBps = (vHodl - vLp) * 10000 / vHodl
        // Overflow guard: if (vHodl-vLp) is close to 2^256, cap at 9999
        if (vHodl - vLp > type(uint256).max / 10000) return 9999;

        ilBps = FullMath.mulDiv(vHodl - vLp, 10000, vHodl);
    }

    // =========================================================================
    //  INSURED VALUE — both tokens, in token1 terms, at entry price
    //
    //  token0InToken1 = amount0 × (sqrtPrice)²
    //                 = amount0 × sqrtPriceX96² / 2¹⁹²
    //
    //  Two-step FullMath.mulDiv (512-bit intermediate arithmetic, no overflow):
    //    step1 = amount0 × sqrtPriceX96 / 2⁹⁶  →  amount0 × sqrtPrice
    //    step2 = step1   × sqrtPriceX96 / 2⁹⁶  →  amount0 × price
    //
    // =========================================================================

    function computeInsuredValue(
        uint128 amount0,
        uint128 amount1,
        uint160 sqrtPriceX96
    ) public pure returns (uint256) {
        if (sqrtPriceX96 == 0 || amount0 == 0) {
            return uint256(amount1);
        }

        uint256 token0InToken1 = FullMath.mulDiv(
            FullMath.mulDiv(uint256(amount0), uint256(sqrtPriceX96), 1 << 96),
            uint256(sqrtPriceX96),
            1 << 96
        );

        return uint256(amount1) + token0InToken1;
    }

    // =========================================================================
    //  VIEW HELPER — returns PoolConfig as a struct (auto-generated getter
    //  returns individual fields, which can't be assigned to a struct directly)
    // =========================================================================

    function getPoolConfig(
        PoolId pid
    ) external view returns (PoolConfig memory) {
        return poolConfig[pid];
    }

    // =========================================================================
    //  INTERNAL HELPERS
    // =========================================================================

    function _applyPositionUpdate(
        PoolId pid,
        address lp,
        bool fullExit,
        uint256 propInsuredValue,
        uint128 proportionalAmt0,
        uint128 proportionalAmt1,
        uint128 removedLiq
    ) internal {
        _subtractInsuredValue(pid, propInsuredValue);
        if (fullExit) {
            delete positions[pid][lp];
        } else {
            positions[pid][lp].entryAmount0 -= proportionalAmt0;
            positions[pid][lp].entryAmount1 -= proportionalAmt1;
            positions[pid][lp].entryLiquidity -= removedLiq;
        }
    }

    function _subtractInsuredValue(PoolId pid, uint256 amount) internal {
        uint256 total = totalInsuredValue[pid];
        totalInsuredValue[pid] = (amount <= total) ? total - amount : 0;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
