// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ============================================================
//  ILShieldHookTest - Foundry test suite
//  Run:  forge test --match-contract ILShieldHookTest -vv
// ============================================================

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {BaseTest} from "test/utils/BaseTest.sol";

import {ILShieldHook} from "../src/ILShieldHook.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  Minimal ERC20 interface for the test (approve + balanceOf)
// ─────────────────────────────────────────────────────────────────────────────
interface IERC20Test {
    function approve(address spender, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────

contract ILShieldHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ── pool ──────────────────────────────────────────────────────────────────
    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;

    // ── hook ──────────────────────────────────────────────────────────────────
    ILShieldHook hook;

    // ── tick range (set in setUp) ─────────────────────────────────────────────
    int24 tickLower;
    int24 tickUpper;

    // ── LP addresses - these just RECEIVE payouts via ERC20.transfer() ────────
    // They never sign transactions. The test contract adds positions on their
    // behalf, encoding these addresses in hookData.
    address constant LP_ALICE = address(0xA11CE);
    address constant LP_BOB = address(0xB0B);

    // ── liquidity amounts ─────────────────────────────────────────────────────
    uint128 constant SEED_LIQUIDITY = 5e18; // untracked pool depth
    uint128 constant TEST_LIQUIDITY = 50e18; // insured test positions

    // ── reserve seed ─────────────────────────────────────────────────────────
    // Funded explicitly into the hook's reserve so payouts can happen.
    // (Phase 2 will auto-collect from swap fees - see ILShieldHook.sol)
    uint256 constant RESERVE_SEED = 20e18;

    // =========================================================================
    //  SETUP
    // =========================================================================

    function setUp() public {
        // 1. Deploy PoolManager, PositionManager, routers, permit2.
        deployArtifactsAndLabel();

        // 2. Create two ERC20 test tokens (minted + approved for this contract).
        (currency0, currency1) = deployCurrencyPair();

        address hookAddr = address(
            uint160(
                Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                    Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
                    Hooks.AFTER_SWAP_FLAG |
                    Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );

        deployCodeTo(
            "ILShieldHook.sol:ILShieldHook",
            abi.encode(poolManager),
            hookAddr
        );
        hook = ILShieldHook(hookAddr);

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        hook.initializePool(poolKey);

        // 7. Seed the insurance reserve with real token1 ERC20.
        //    The hook's fundReserve() calls transferFrom, so we approve first.
        IERC20Test(Currency.unwrap(currency1)).approve(
            address(hook),
            RESERVE_SEED
        );
        hook.fundReserve(poolKey, RESERVE_SEED);
        assertEq(
            hook.insuranceReserve(poolId),
            RESERVE_SEED,
            "setUp: reserve should be seeded"
        );

        // 8. Add untracked seed liquidity (hookData = ZERO_BYTES -> no insurance).
        //    This gives the pool enough depth so swaps don't revert.
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        (uint256 s0, uint256 s1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            SEED_LIQUIDITY
        );

        positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            SEED_LIQUIDITY,
            s0 + 1,
            s1 + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES // <- untracked, no LP address
        );
    }

    // =========================================================================
    //  HELPERS
    // =========================================================================

    /// @dev Add an insured position. Returns the PositionManager tokenId.
    function _addInsuredPosition(
        address lpAddr,
        uint128 liq
    ) internal returns (uint256 tokenId) {
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liq
        );
        (tokenId, ) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liq,
            a0 + 1,
            a1 + 1,
            address(this),
            block.timestamp,
            abi.encode(lpAddr) // LP address tracked by hook
        );
    }

    /// @dev Remove an insured position, triggering IL calculation and payout.
    function _removeInsuredPosition(
        uint256 tokenId,
        address lpAddr,
        uint128 liq
    ) internal {
        positionManager.decreaseLiquidity(
            tokenId,
            liq,
            0,
            0, // min amounts (max slippage)
            address(this),
            block.timestamp,
            abi.encode(lpAddr) // same LP address as at deposit
        );
    }

    /// @dev Do N zeroForOne swaps to move the price (creates IL on LP positions).
    function _doSwaps(uint256 count, uint256 amountIn) internal {
        for (uint256 i = 0; i < count; i++) {
            swapRouter.swapExactTokensForTokens({
                amountIn: amountIn,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }
    }

    /// @dev Returns token1 ERC20 balance of an address.
    function _bal1(address who) internal view returns (uint256) {
        return IERC20Test(Currency.unwrap(currency1)).balanceOf(who);
    }

    // =========================================================================
    //  TEST 1 - Full lifecycle: payout issued when IL exceeds deductible
    // =========================================================================

    function test_ILPayout_WhenPriceMoves() public {
        uint256 reserveBefore = hook.insuranceReserve(poolId); // = RESERVE_SEED

        uint256 tokenId = _addInsuredPosition(LP_ALICE, TEST_LIQUIDITY);

        // Verify position recorded
        (, , , , , , , bool active) = hook.positions(poolId, LP_ALICE);
        assertTrue(active, "Position should be active after mint");

        // Move price with 30 swaps -> creates IL > 2% deductible
        _doSwaps(30, 1e18);

        // Warp past 24-hour lock
        vm.warp(block.timestamp + 86401);

        // Read IL
        (uint160 entrySqrtPrice, , , , , , , ) = hook.positions(
            poolId,
            LP_ALICE
        );
        (uint160 currentSqrtPrice, , , ) = poolManager.getSlot0(poolId);
        // uint256 ilBps = hook.computeILBps(entrySqrtPrice, currentSqrtPrice);
        uint256 ilBps = hook.computeILBpsConcentrated(
            entrySqrtPrice,
            currentSqrtPrice,
            tickLower,
            tickUpper
        );
        emit log_named_uint("IL bps at exit", ilBps);

        uint256 aliceBefore = _bal1(LP_ALICE);
        _removeInsuredPosition(tokenId, LP_ALICE, TEST_LIQUIDITY);

        // Position cleared
        (, , , , , , , bool activeAfter) = hook.positions(poolId, LP_ALICE);
        assertFalse(activeAfter, "Position must be cleared after removal");

        ILShieldHook.PoolConfig memory cfg = hook.getPoolConfig(poolId);
        if (ilBps > cfg.deductibleBps) {
            uint256 aliceAfter = _bal1(LP_ALICE);
            assertGt(aliceAfter, aliceBefore, "LP_ALICE should receive payout");
            assertLt(
                hook.insuranceReserve(poolId),
                reserveBefore,
                "Reserve should decrease after payout"
            );
            emit log_named_uint("Payout to LP_ALICE", aliceAfter - aliceBefore);
            emit log_named_uint(
                "Reserve remaining",
                hook.insuranceReserve(poolId)
            );
        } else {
            emit log_string("IL still below deductible - increase swap count");
        }
    }

    // =========================================================================
    //  TEST 2 - No payout when IL is below deductible
    // =========================================================================

    function test_NoPayout_WhenBelowDeductible() public {
        uint256 tokenId = _addInsuredPosition(LP_ALICE, TEST_LIQUIDITY);

        // Tiny swap: negligible price movement
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e14,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        vm.warp(block.timestamp + 86401);

        (uint160 e, , , , , , , ) = hook.positions(poolId, LP_ALICE);
        (uint160 c, , , ) = poolManager.getSlot0(poolId);
        uint256 ilBps = hook.computeILBps(e, c);
        emit log_named_uint("IL bps (expect <= 200)", ilBps);

        ILShieldHook.PoolConfig memory cfg = hook.getPoolConfig(poolId);
        assertLe(ilBps, cfg.deductibleBps, "IL should be at/below deductible");

        uint256 reserveSnapshot = hook.insuranceReserve(poolId);
        _removeInsuredPosition(tokenId, LP_ALICE, TEST_LIQUIDITY);

        assertEq(
            hook.insuranceReserve(poolId),
            reserveSnapshot,
            "Reserve must not change when IL below deductible"
        );
    }

    // =========================================================================
    //  TEST 3 - No payout when lock period not met
    // =========================================================================

    function test_NoPayout_WhenLockNotMet() public {
        uint256 tokenId = _addInsuredPosition(LP_ALICE, TEST_LIQUIDITY);

        // Move price significantly
        _doSwaps(20, 2e18);

        uint256 reserveBefore = hook.insuranceReserve(poolId);

        // Exit without warping - within the 24-hour lock
        _removeInsuredPosition(tokenId, LP_ALICE, TEST_LIQUIDITY);

        assertEq(
            hook.insuranceReserve(poolId),
            reserveBefore,
            "Reserve must not change when lock not met"
        );

        (, , , , , , , bool active) = hook.positions(poolId, LP_ALICE);
        assertFalse(active, "Position must be cleared even without payout");

        assertEq(_bal1(LP_ALICE), 0, "LP_ALICE should receive zero payout");
    }

    // =========================================================================
    //  TEST 4 - Pro-rata split: two LPs, reserve split fairly
    //
    //  Both positions added by address(this) with different LP addresses
    //  in hookData. Hook tracks them separately and pays each their share.
    // =========================================================================

    function test_ProRata_TwoLPs_FairSplit() public {
        uint256 aliceId = _addInsuredPosition(LP_ALICE, TEST_LIQUIDITY);
        uint256 bobId = _addInsuredPosition(LP_BOB, TEST_LIQUIDITY);

        (
            uint160 aliceSqrt,
            uint128 aliceAmt0,
            uint128 aliceAmt1,
            ,
            ,
            ,
            ,

        ) = hook.positions(poolId, LP_ALICE);
        (uint160 bobSqrt, uint128 bobAmt0, uint128 bobAmt1, , , , , ) = hook
            .positions(poolId, LP_BOB);

        uint256 aliceInsured = hook.computeInsuredValue(
            aliceAmt0,
            aliceAmt1,
            aliceSqrt
        );
        uint256 bobInsured = hook.computeInsuredValue(
            bobAmt0,
            bobAmt1,
            bobSqrt
        );

        assertEq(
            hook.totalInsuredValue(poolId),
            aliceInsured + bobInsured,
            "totalInsuredValue should sum both positions (both tokens in token1 terms)"
        );

        // Move price to create IL
        _doSwaps(40, 2e18);

        uint256 totalReserve = hook.insuranceReserve(poolId);
        emit log_named_uint("Reserve before exits", totalReserve);

        vm.warp(block.timestamp + 86401);

        _removeInsuredPosition(aliceId, LP_ALICE, TEST_LIQUIDITY);
        _removeInsuredPosition(bobId, LP_BOB, TEST_LIQUIDITY);

        uint256 alicePayout = _bal1(LP_ALICE);
        uint256 bobPayout = _bal1(LP_BOB);
        emit log_named_uint("Alice payout", alicePayout);
        emit log_named_uint("Bob payout", bobPayout);
        emit log_named_uint("Reserve left", hook.insuranceReserve(poolId));

        // Combined payouts cannot exceed the reserve
        assertLe(
            alicePayout + bobPayout,
            totalReserve,
            "Combined payouts cannot exceed total reserve"
        );

        // Reserve can only decrease
        assertLe(
            hook.insuranceReserve(poolId),
            totalReserve,
            "Reserve cannot increase"
        );

        // Equal deposits -> payouts should be roughly equal (within 10%)
        if (alicePayout > 0 && bobPayout > 0) {
            uint256 diff = alicePayout > bobPayout
                ? alicePayout - bobPayout
                : bobPayout - alicePayout;
            assertLe(
                diff,
                alicePayout / 10,
                "Payouts should be roughly equal for equal-sized positions"
            );
        }
    }

    // =========================================================================
    //  TEST 5 - IL math: verified against known formula outputs
    //
    //  Formula: IL = 1 - 2*sqrt(k)/(1+k)  where k = currentPrice/entryPrice
    // =========================================================================

    function test_ILMath_SpotChecks() public {
        uint160 base = Constants.SQRT_PRICE_1_1; // price = 1.0

        // k=1 (unchanged) -> IL = 0
        assertEq(
            hook.computeILBps(base, base),
            0,
            "IL must be 0 when price unchanged"
        );

        // sqrtPrice doubles -> price quadruples (k=4) -> IL = 2000 bps (20%)
        uint256 il_4x = hook.computeILBps(base, uint160(uint256(base) * 2));
        emit log_named_uint("IL for 4x price (sqrtPrice x2)", il_4x);
        assertApproxEqAbs(il_4x, 2000, 5, "IL for k=4 must be ~2000 bps");

        // sqrtPrice * sqrt(2) -> price doubles (k=2) -> IL ≈ 572 bps
        uint160 sqrt2x = uint160((uint256(base) * 141421356) / 100000000);
        uint256 il_2x = hook.computeILBps(base, sqrt2x);
        emit log_named_uint("IL for 2x price", il_2x);
        assertApproxEqAbs(il_2x, 572, 30, "IL for k=2 must be ~572 bps");

        // price halves (k=0.5) -> same as k=2 (formula is symmetric)
        uint160 sqrtHalf = uint160((uint256(base) * 70710678) / 100000000);
        uint256 il_half = hook.computeILBps(base, sqrtHalf);
        emit log_named_uint("IL for 0.5x price (expect ~572)", il_half);
        assertApproxEqAbs(il_half, 572, 30, "IL must be symmetric");

        // zero entry price -> must not revert
        assertEq(
            hook.computeILBps(0, base),
            0,
            "Zero entry must return 0 safely"
        );
    }

    // =========================================================================
    //  TEST 6 - fundReserve: reserve grows correctly, getPoolConfig works
    // =========================================================================

    function test_FundReserve_AndGetConfig() public {
        // Reserve was seeded in setUp
        assertEq(
            hook.insuranceReserve(poolId),
            RESERVE_SEED,
            "Reserve = seed amount"
        );

        // Add more funding
        uint256 extra = 5e18;
        IERC20Test(Currency.unwrap(currency1)).approve(address(hook), extra);
        hook.fundReserve(poolKey, extra);

        assertEq(
            hook.insuranceReserve(poolId),
            RESERVE_SEED + extra,
            "Reserve must grow by funded amount"
        );

        // Verify getPoolConfig returns the struct correctly
        ILShieldHook.PoolConfig memory cfg = hook.getPoolConfig(poolId);
        assertEq(cfg.coveragePct, 5000, "coveragePct should be 5000");
        assertEq(cfg.deductibleBps, 200, "deductibleBps should be 200");
        assertEq(cfg.minLockSeconds, 86400, "minLockSeconds should be 86400");

        emit log_named_uint("Final reserve", hook.insuranceReserve(poolId));
    }

    // test 7

    function test_PartialRemoval_PositionUpdated() public {
        uint256 tokenId = _addInsuredPosition(LP_ALICE, TEST_LIQUIDITY);
        (, , uint128 originalAmt1, , , , , ) = hook.positions(poolId, LP_ALICE);

        _doSwaps(30, 1e18);
        vm.warp(block.timestamp + 86401);

        // Remove half
        uint128 halfLiq = TEST_LIQUIDITY / 2;
        _removeInsuredPosition(tokenId, LP_ALICE, halfLiq);

        // Position should still be active with reduced values
        (
            ,
            ,
            uint128 remainingAmt1,
            uint128 remainingLiq,
            ,
            ,
            ,
            bool active
        ) = hook.positions(poolId, LP_ALICE);

        assertTrue(active, "Position should still be active");
        assertGt(remainingLiq, 0, "Liquidity should remain");
        assertLt(remainingAmt1, originalAmt1, "Amount1 should be reduced");
    }

    // test 8 & 9

    function test_ILMathConcentrated_FullRangeMatchesOriginal() public view {
        int24 lo = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 hi = TickMath.maxUsableTick(poolKey.tickSpacing);
        uint160 base = Constants.SQRT_PRICE_1_1;

        // k=1 -> 0 bps for both
        assertEq(hook.computeILBpsConcentrated(base, base, lo, hi), 0);

        // k=4 (sqrtPrice×2) -> ~2000 bps - must match old formula
        uint160 sq2x = uint160(uint256(base) * 2);
        uint256 oldBps = hook.computeILBps(base, sq2x);
        uint256 newBps = hook.computeILBpsConcentrated(base, sq2x, lo, hi);
        assertApproxEqAbs(
            oldBps,
            newBps,
            5,
            "Full-range should match for both"
        );
    }

    function test_ILMathConcentrated_AboveRange() public {
        // Narrow range: [0.5x, 2x] around current price
        // sqrtPrice of 0.5× price = base / sqrt(2) = base * 70710678 / 100000000
        uint160 sqrtHalf = uint160(
            (uint256(Constants.SQRT_PRICE_1_1) * 70710678) / 100000000
        );
        uint160 sqrt2x = uint160(
            (uint256(Constants.SQRT_PRICE_1_1) * 141421356) / 100000000
        );

        int24 lo = TickMath.getTickAtSqrtPrice(sqrtHalf);
        int24 hi = TickMath.getTickAtSqrtPrice(sqrt2x);

        // Align to tickSpacing
        lo = (lo / poolKey.tickSpacing) * poolKey.tickSpacing;
        hi = ((hi / poolKey.tickSpacing) + 1) * poolKey.tickSpacing;

        uint160 base = Constants.SQRT_PRICE_1_1;

        // Entry in range, price goes above upper bound
        // Above range: V_lp = (sb-sa) constant
        uint160 wayAbove = uint160((uint256(base) * 3)); // way above sb
        uint256 ilBps = hook.computeILBpsConcentrated(base, wayAbove, lo, hi);
        emit log_named_uint("IL bps above range (concentrated)", ilBps);
        assertGt(
            ilBps,
            5000,
            "Concentrated above-range IL should be significant"
        );
    }

    // 10 & 11

    function test_ReserveGrows_FromSwapPremiums() public {
        _addInsuredPosition(LP_ALICE, TEST_LIQUIDITY);
        uint256 before = hook.insuranceReserve(poolId);

        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertGt(
            hook.insuranceReserve(poolId),
            before,
            "Reserve must grow from swap premium"
        );
    }

    // =========================================================================
    //  TEST 11 - afterSwap premium collection: exact formula verification
    //
    //  For each swap: premium = floor(grossOutput * premiumBps / 10000)
    //  where grossOutput = swapper_received + premium
    //
    //  This is self-consistent and exact (assertEq, no tolerance):
    //    received      = bal1After - bal1Before    (measured)
    //    actualPremium = reserveAfter - reserveBefore (measured)
    //    grossOutput   = received + actualPremium   (total pool output)
    //    expectedPremium = floor(grossOutput * premiumBps / 10000)
    //    assertEq(actualPremium, expectedPremium)  -> always exact, no rounding gap
    //
    //  Cumulative: total reserve == RESERVE_SEED + Σ premiums
    // =========================================================================

    function test_AfterSwap_PremiumIsExact() public {
        ILShieldHook.PoolConfig memory cfg = hook.getPoolConfig(poolId);
        uint256 numSwaps = 5;
        uint256 amountIn = 1e18;

        // Precondition: no swaps have run yet this test
        assertEq(
            hook.insuranceReserve(poolId),
            RESERVE_SEED,
            "Precondition: reserve must equal seed before any swap"
        );

        uint256 totalPremium;

        for (uint256 i = 0; i < numSwaps; i++) {
            uint256 reserveBefore = hook.insuranceReserve(poolId);
            uint256 bal1Before = _bal1(address(this));

            swapRouter.swapExactTokensForTokens({
                amountIn: amountIn,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp + 1
            });

            uint256 actualPremium = hook.insuranceReserve(poolId) -
                reserveBefore;
            uint256 received = _bal1(address(this)) - bal1Before;

            // 1. Something must have been collected
            assertGt(actualPremium, 0, "Premium must be > 0");

            // 2. Reserve accounting: grew by exactly the premium
            assertEq(
                hook.insuranceReserve(poolId),
                reserveBefore + actualPremium,
                "Reserve must grow by exactly the collected premium"
            );

            // 3. Exact formula check
            //    grossOutput = received + actualPremium  (total pool output before hook cut)
            //    expectedPremium = floor(grossOutput * premiumBps / 10000)
            uint256 grossOutput = received + actualPremium;
            uint256 expectedPremium = (grossOutput * cfg.premiumBps) / 10000;
            assertEq(
                actualPremium,
                expectedPremium,
                "Premium must equal floor(grossOutput * premiumBps / 10000)"
            );

            totalPremium += actualPremium;
        }

        // 4. Cumulative: reserve = seed + all premiums
        assertEq(
            hook.insuranceReserve(poolId),
            RESERVE_SEED + totalPremium,
            "Total reserve must equal RESERVE_SEED + accumulated premiums"
        );

        emit log_named_uint("Total premium (5 swaps)", totalPremium);
        emit log_named_uint(
            "Final reserve           ",
            hook.insuranceReserve(poolId)
        );
    }

    // =========================================================================
    //  TEST 12 - active position cannot be overwritten via hookData
    //
    //  The require(!positions[pid][lp].active) guard fires when the same
    //  lp address is passed in hookData while a position is already active.
    //
    //  Fix from failing version: drop the bytes() cast.
    //  vm.expectRevert(bytes("msg")) passes raw ASCII and defeats Foundry's
    //  Error(string) smart-matching. vm.expectRevert("msg") works correctly.
    // =========================================================================

    function test_CannotOverwrite_ActivePosition() public {
        _addInsuredPosition(LP_ALICE, TEST_LIQUIDITY);

        (, , , , , , , bool active) = hook.positions(poolId, LP_ALICE);
        assertTrue(active, "Precondition: LP_ALICE position must be active");

        vm.startPrank(address(poolManager));
        vm.expectRevert("ILShield: exit current position first");
        hook.afterAddLiquidity(
            address(this), // sender (not checked by guard)
            poolKey,
            ModifyLiquidityParams({ // values don't matter - revert
                tickLower: tickLower, // happens before any are read
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(1e15)),
                salt: bytes32(0)
            }),
            BalanceDeltaLibrary.ZERO_DELTA, // not read before guard fires
            BalanceDeltaLibrary.ZERO_DELTA,
            abi.encode(LP_ALICE) // <- the guard key
        );
        vm.stopPrank();
    }
}
