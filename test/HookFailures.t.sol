// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {IMD6900Hook} from "src/IMD6900Hook.sol";
import {IMD6900LockedPool} from "src/IMD6900LockedPool.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

/// External-engine failure modes, including an ABI-short response. PoolManager
/// and hook remain real; this mock controls only the not-yet-deployed engine.
contract ScriptedSweepEngine {
    uint8 public beforeMode;
    uint8 public afterMode;
    uint8 public countMode;
    uint256 public positions;
    uint256 public preCalls;
    uint256 public postCalls;
    address public liquidator;
    int256 public specification;
    bool public buy;
    uint160 public limit;

    function configure(uint8 pre, uint8 post, uint8 count, uint256 open) external {
        (beforeMode, afterMode, countMode, positions) = (pre, post, count, open);
    }

    function openCount() external view returns (uint256) {
        if (countMode == 1) revert("cannot count");
        if (countMode == 2) {
            assembly ("memory-safe") { return(0, 1) }
        }
        return positions;
    }

    function sweepLiquidations(address who, int256 spec, bool isBuy, uint160 priceLimit) external returns (uint8) {
        uint8 mode = spec == 0 ? afterMode : beforeMode;
        if (mode == 3) revert("sweep unavailable");
        if (mode == 4) {
            assembly ("memory-safe") { return(0, 1) }
        }
        if (spec == 0) {
            ++postCalls;
        } else {
            ++preCalls;
            (liquidator, specification, buy, limit) = (who, spec, isBuy, priceLimit);
        }
        return mode;
    }
}

contract HookFailureTest is LaunchFixture {
    using PoolIdLibrary for PoolKey;
    ScriptedSweepEngine internal engine;

    function setUp() public override {
        super.setUp();
        _start();
        engine = new ScriptedSweepEngine();
        vm.prank(TIMELOCK);
        hook.setPerpEngine(address(engine));
    }

    function test_AllEnabledCallbacksRejectSpoofedPoolManager() public {
        PoolKey memory key = locked.poolKey();
        SwapParams memory swap = _swap();
        ModifyLiquidityParams memory position = ModifyLiquidityParams(-887_220, locked.upperTick(), 0, 0);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeInitialize(address(locked), key, TickMath.getSqrtPriceAtTick(OPENING_TICK));
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(locked), key, position, "");
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(address(locked), key, position, "");
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(address(trader), key, swap, "");
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(address(trader), key, swap, BalanceDelta.wrap(0), "");
    }

    function test_InitializeRejectsImpostorAndMismatchedKeyFields() public {
        PoolKey memory correct = locked.poolKey();
        bytes32 serving = PoolId.unwrap(hook.poolId());
        vm.prank(address(manager));
        vm.expectRevert(IMD6900Hook.OnlyPool.selector);
        hook.beforeInitialize(users[0], correct, 1 << 96);
        for (uint256 i; i < 5; ++i) {
            PoolKey memory bad = locked.poolKey();
            if (i == 0) bad.currency0 = Currency.wrap(users[0]);
            else if (i == 1) bad.currency1 = Currency.wrap(address(legacy));
            else if (i == 2) bad.fee = 0x800000; // v4's dynamic fee flag
            else if (i == 3) bad.fee = 33_300;
            else bad.tickSpacing = 1;
            vm.prank(address(manager));
            vm.expectRevert(IMD6900Hook.NotOurPool.selector);
            hook.beforeInitialize(address(locked), bad, 1 << 96);
            assertEq(PoolId.unwrap(hook.poolId()), serving);
        }
    }

    function test_LiquidityCallbacksRejectOtherOwnersAndWrongRanges() public {
        PoolKey memory key = locked.poolKey();
        ModifyLiquidityParams memory p = ModifyLiquidityParams(-887_220, locked.upperTick(), 1, 0);
        vm.prank(address(manager));
        vm.expectRevert(IMD6900Hook.OnlyPool.selector);
        hook.beforeAddLiquidity(users[0], key, p, "");
        p.liquidityDelta = -1;
        vm.prank(address(manager));
        vm.expectRevert(IMD6900Hook.OnlyPool.selector);
        hook.beforeRemoveLiquidity(users[0], key, p, "");
        p.tickLower += 60;
        vm.prank(address(manager));
        vm.expectRevert(IMD6900Hook.WrongRange.selector);
        hook.beforeRemoveLiquidity(address(locked), key, p, "");
        p.tickLower -= 60;
        p.tickUpper -= 60;
        vm.prank(address(manager));
        vm.expectRevert(IMD6900Hook.WrongRange.selector);
        hook.beforeAddLiquidity(address(locked), key, p, "");
    }

    function test_PreSweepReceivesTradeAndOriginAndReturnsNoDeltas() public {
        PoolKey memory key = locked.poolKey();
        SwapParams memory params = _swap();
        vm.prank(address(manager), users[1]);
        (bytes4 selector, BeforeSwapDelta delta, uint24 feeOverride) =
            hook.beforeSwap{gas: 2_000_000}(address(trader), key, params, "");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(feeOverride, 0, "no dynamic fee override");
        assertEq(engine.preCalls(), 1);
        assertEq(engine.liquidator(), users[1]);
        assertEq(engine.specification(), params.amountSpecified);
        assertEq(engine.buy(), params.zeroForOne);
        assertEq(engine.limit(), params.sqrtPriceLimitX96);
    }

    function test_UnavailableAndMalformedSweepsFailClosedUnlessTimelockOptsIn() public {
        for (uint8 mode = 3; mode <= 4; ++mode) {
            engine.configure(mode, 0, 0, 1);
            _expectBefore(IMD6900Hook.SweepUnavailable.selector, 2_000_000);
            vm.prank(TIMELOCK);
            hook.setSweepFailOpen(true);
            _before(2_000_000);
            vm.prank(TIMELOCK);
            hook.setSweepFailOpen(false);
        }
    }

    function test_ReportedUnsafeTradeCannotBypassSweepWithFailOpen() public {
        vm.prank(TIMELOCK);
        hook.setSweepFailOpen(true);
        engine.configure(1, 0, 0, 1);
        _expectBefore(IMD6900Hook.SweepGasStarved.selector, 2_000_000);
        engine.configure(2, 0, 0, 1);
        _expectBefore(IMD6900Hook.SweepTradeTooLarge.selector, 2_000_000);
        engine.configure(type(uint8).max, 0, 0, 1);
        _expectBefore(IMD6900Hook.SweepGasStarved.selector, 2_000_000);
    }

    function test_LowGasChecksPositionsInsteadOfTradingBlind() public {
        engine.configure(0, 0, 0, 1);
        _expectBefore(IMD6900Hook.SweepGasStarved.selector, 700_000);
        engine.configure(0, 0, 0, 0);
        _before(700_000);
        assertEq(engine.preCalls(), 0, "insufficient gas for sweep uses openCount");
        for (uint8 mode = 1; mode <= 2; ++mode) {
            engine.configure(0, 0, mode, 0);
            _expectBefore(IMD6900Hook.SweepUnavailable.selector, 700_000);
            vm.prank(TIMELOCK);
            hook.setSweepFailOpen(true);
            _before(700_000);
            vm.prank(TIMELOCK);
            hook.setSweepFailOpen(false);
        }
    }

    function test_AfterSweepIsBestEffortForEveryFailureModeAndLowGas() public {
        PoolKey memory key = locked.poolKey();
        SwapParams memory params = _swap();
        for (uint8 mode; mode <= 4; ++mode) {
            engine.configure(0, mode, 0, 1);
            vm.prank(address(manager));
            (bytes4 selector, int128 delta) =
                hook.afterSwap{gas: 2_000_000}(address(trader), key, params, BalanceDelta.wrap(0), "");
            assertEq(selector, IHooks.afterSwap.selector);
            assertEq(delta, 0);
        }
        uint256 calls = engine.postCalls();
        vm.prank(address(manager));
        hook.afterSwap{gas: 300_000}(address(trader), key, params, BalanceDelta.wrap(0), "");
        assertEq(engine.postCalls(), calls, "post-sweep leaves gas for settlement");
    }

    function test_EngineOwnSwapBypassesSweepEvenWhenSweepIsBroken() public {
        engine.configure(3, 3, 1, 1);
        PoolKey memory key = locked.poolKey();
        SwapParams memory params = _swap();
        vm.prank(address(manager));
        hook.beforeSwap{gas: 100_000}(address(engine), key, params, "");
        assertEq(engine.preCalls(), 0);
        vm.prank(TIMELOCK);
        hook.setPerpEngine(address(0));
        _before(100_000);
    }

    function test_FailedRealTradeRollsBackAndWorksAfterEngineRepair() public {
        engine.configure(2, 0, 0, 1);
        bytes32 state = _financialState();
        PoolKey memory key = locked.poolKey();
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(IMD6900Hook.SweepTradeTooLarge.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        trader.swap{gas: 3_000_000}(key, true, -1 ether);
        assertEq(_financialState(), state);
        engine.configure(0, 0, 0, 1);
        trader.swap{gas: 3_000_000}(key, true, -1 ether);
        assertGt(coin.balanceOf(address(trader)), 0);
        assertEq(engine.preCalls(), 1);
        assertEq(engine.postCalls(), 1);
    }

    function test_FeeMoveRefusesMalformedOrUnavailablePositionCountAtomically() public {
        bytes32 state = _financialState();
        for (uint8 mode; mode < 3; ++mode) {
            engine.configure(0, 0, mode, mode == 0 ? 1 : 0);
            vm.prank(TIMELOCK);
            vm.expectRevert(IMD6900LockedPool.PerpsOpen.selector);
            locked.lowerFee(33_300);
            assertEq(_financialState(), state);
        }
        engine.configure(0, 0, 0, 0);
        vm.prank(TIMELOCK);
        locked.lowerFee(33_300);
        assertEq(locked.fee(), 33_300);
    }

    function test_FormerPoolCannotTradeAfterFeeMove() public {
        PoolKey memory old = locked.poolKey();
        vm.prank(TIMELOCK);
        locked.lowerFee(33_300);
        SwapParams memory params = _swap();
        vm.prank(address(manager));
        vm.expectRevert(IMD6900Hook.NotOurPool.selector);
        hook.beforeSwap(address(trader), old, params, "");
        trader.swap(locked.poolKey(), true, -1 ether);
        assertGt(coin.balanceOf(address(trader)), 0);
    }

    function test_OnlyTimelockMayEnableSweepEscapeHatch() public {
        vm.prank(TEAM);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setSweepFailOpen(true);
        vm.prank(users[0]);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setPerpRefunded(true);
        assertFalse(hook.sweepFailOpen());
        assertFalse(hook.perpRefunded());
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_RefundedPerpQuoteRoundsWorstProtocolDirectionUp(uint16 first, uint16 second) public {
        uint24 a = uint24(bound(first, 0, 1000));
        uint24 b = uint24(bound(second, 0, 1000));
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(locked.poolKey(), a | (b << 12));
        vm.prank(TIMELOCK);
        hook.setPerpRefunded(true);
        uint256 quoteInPips = hook.perpFeeBps() * 100;
        assertGe(quoteInPips, a);
        assertGe(quoteInPips, b);
        uint256 worst = a > b ? a : b;
        assertLt(quoteInPips - worst, 100, "ceiling error is less than one basis point");
    }

    function _swap() internal pure returns (SwapParams memory) {
        return SwapParams(true, -int256(1 ether), TickMath.MIN_SQRT_PRICE + 1);
    }

    function _before(uint256 gasLimit) internal {
        PoolKey memory key = locked.poolKey();
        SwapParams memory params = _swap();
        vm.prank(address(manager));
        hook.beforeSwap{gas: gasLimit}(address(trader), key, params, "");
    }

    function _expectBefore(bytes4 reason, uint256 gasLimit) internal {
        PoolKey memory key = locked.poolKey();
        SwapParams memory params = _swap();
        vm.prank(address(manager));
        vm.expectRevert(reason);
        hook.beforeSwap{gas: gasLimit}(address(trader), key, params, "");
    }
}
