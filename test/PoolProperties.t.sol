// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {IMD6900} from "src/IMD6900.sol";
import {IMD6900Hook} from "src/IMD6900Hook.sol";
import {IMD6900LockedPool} from "src/IMD6900LockedPool.sol";
import {IMD6900RobinhoodLaunch} from "src/IMD6900RobinhoodLaunch.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract ForeignRefundCaller {
    function refund(IMD6900LockedPool pool) external {
        pool.feeRefund(address(this));
    }
}

/// Runs the real checkpoint/refund protocol inside a real Manager unlock.
contract RefundProtocolDriver {
    IPoolManager immutable manager;
    IMD6900LockedPool immutable pool;
    ForeignRefundCaller immutable foreignCaller = new ForeignRefundCaller();

    constructor(IPoolManager manager_, IMD6900LockedPool pool_) {
        (manager, pool) = (manager_, pool_);
    }

    function run(uint8 mode, uint256 amount) external returns (uint256 eth, uint256 coins) {
        return abi.decode(manager.unlock(abi.encode(mode, amount)), (uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 mode, uint256 amount) = abi.decode(data, (uint8, uint256));
        if (mode != 3) pool.feeCheckpoint();
        PoolKey memory key = pool.poolKey();
        if (amount != 0) {
            BalanceDelta delta = manager.swap(key, SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1), "");
            manager.settle{value: uint128(-delta.amount0())}();
            manager.take(key.currency1, address(this), uint128(delta.amount1()));
        }
        if (mode == 2) foreignCaller.refund(pool);
        (uint256 eth, uint256 coins) = pool.feeRefund(address(this));
        if (mode == 1) pool.feeRefund(address(this));
        return abi.encode(eth, coins);
    }

    function openCount() external pure returns (uint256) {
        return 0;
    }

    function sweepLiquidations(address, int256, bool, uint160) external pure returns (uint8) {
        return 0;
    }
    receive() external payable {}
}

contract RefundProtocolTest is LaunchFixture {
    RefundProtocolDriver internal engine;

    function setUp() public override {
        super.setUp();
        _start();
        engine = new RefundProtocolDriver(manager, locked);
        vm.deal(address(engine), 10 ether);
        vm.prank(TIMELOCK);
        hook.setPerpEngine(address(engine));
    }

    function test_CheckpointWithoutSwapCannotTakePreviousTradersFees() public {
        trader.swap(locked.poolKey(), true, -1 ether);
        uint256 beforeEngine = address(engine).balance;
        (uint256 refund, uint256 coins) = engine.run(0, 0);
        assertEq(refund, 0);
        assertEq(coins, 0);
        assertEq(address(engine).balance, beforeEngine);
        (uint256 fees,) = locked.collect();
        assertApproxEqAbs(fees, (OPENING_BUY + 1 ether) * 444 / 10_000, 2);
    }

    function test_RefundCannotBeReplayedAndFailedReplayRollsBackSwap() public {
        bytes32 state = _financialState();
        uint256 beforeEngine = address(engine).balance;
        vm.expectRevert(IMD6900LockedPool.NoCheckpoint.selector);
        engine.run(1, 1 ether);
        assertEq(_financialState(), state);
        assertEq(address(engine).balance, beforeEngine);
        assertEq(coin.balanceOf(address(engine)), 0);
        (uint256 refund,) = engine.run(0, 1 ether);
        assertApproxEqAbs(refund, 0.0444 ether, 1);
        vm.expectRevert(IMD6900LockedPool.NoCheckpoint.selector);
        engine.run(3, 0); // another unlock in the same transaction has no remaining checkpoint
    }

    function test_CheckpointCannotBeUsedByAnotherCaller() public {
        bytes32 state = _financialState();
        vm.expectRevert(IMD6900LockedPool.NoCheckpoint.selector);
        engine.run(2, 1 ether);
        assertEq(_financialState(), state);
        assertEq(coin.balanceOf(address(engine)), 0);
    }

    function test_CheckpointRequiresUnlockedManagerAndLiveAuthorization() public {
        vm.prank(address(engine));
        vm.expectRevert(IPoolManager.ManagerLocked.selector);
        locked.feeCheckpoint();
        vm.prank(TIMELOCK);
        hook.setPerpEngine(address(0));
        vm.expectRevert(IMD6900LockedPool.NotRefunded.selector);
        engine.run(0, 1 ether);
        assertEq(address(engine).balance, 10 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_RefundIsOnlyThisTradeAndOrdinaryFeesRemainCollectible(uint256 amount) public {
        amount = bound(amount, 1, 5 ether);
        trader.swap(locked.poolKey(), true, -1 ether);
        (uint256 refund, uint256 coins) = engine.run(0, amount);
        assertEq(coins, 0);
        // One rounding for the swap charge and one for fee-growth realization.
        assertApproxEqAbs(refund, amount * 444 / 10_000, 2);
        assertEq(address(engine).balance, 10 ether - amount + refund);
        trader.swap(locked.poolKey(), true, -1 ether);
        (uint256 ordinaryFees,) = locked.collect();
        assertApproxEqAbs(ordinaryFees, (OPENING_BUY + 2 ether) * 444 / 10_000, 4);
    }
}

contract LockedPoolPropertyTest is LaunchFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// Valid amounts and ticks are selected to stay within v4's per-tick
    /// liquidity limit. This isolates the one-sided opening and tick rounding.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_OpeningLocksSupplyAsCoinOnlyAndFloorsOntoTick(int24 tickSeed) public {
        int24 requested = int24(bound(int256(tickSeed), -300_000, 800_000));
        IMD6900 token = new IMD6900(address(launch));
        uint160 requestedPrice = TickMath.getSqrtPriceAtTick(requested);
        vm.startPrank(address(launch));
        token.approve(address(locked), SUPPLY);
        locked.open(address(token), requestedPrice, SUPPLY);
        vm.stopPrank();
        (uint160 actualPrice,,) = locked.state();
        int24 upper = locked.upperTick();
        assertEq(upper % 60, 0);
        assertLe(upper, requested);
        assertLt(requested - upper, 60, "rounds down, including negative ticks");
        assertEq(actualPrice, TickMath.getSqrtPriceAtTick(upper));
        assertEq(address(manager).balance, 0, "opening liquidity needs no ETH");
        assertEq(token.balanceOf(address(locked)), 0, "no principal stays outside the pool");
        uint256 dust = token.balanceOf(address(launch));
        // Subtracting one unit of liquidity leaves at most one liquidity unit
        // plus rounding, measured in tokens at the opening square-root price.
        assertLe(dust, (uint256(actualPrice) >> 96) * 2 + 2);
        assertEq(token.balanceOf(address(manager)) + dust, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        (uint128 position,,) = manager.getPositionInfo(locked.poolId(), address(locked), locked.LOWER_TICK(), upper, 0);
        assertEq(position, locked.liquidity());
        assertGt(position, 0);
        vm.prank(address(launch));
        vm.expectRevert(IMD6900LockedPool.AlreadyOpen.selector);
        locked.open(address(token), requestedPrice, SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_OrdinaryBuySellRoundTripCannotCreateEth(uint256 seed) public {
        _start();
        uint256 amount = bound(seed, 1, 20 ether);
        uint256 beforeEth = address(trader).balance;
        uint128 liquidity = locked.liquidity();
        trader.swap(locked.poolKey(), true, -int256(amount));
        uint256 tokens = coin.balanceOf(address(trader));
        if (tokens != 0) trader.swap(locked.poolKey(), false, -int256(tokens));
        assertLe(address(trader).balance, beforeEth);
        assertEq(coin.balanceOf(address(trader)), 0);
        assertEq(locked.liquidity(), liquidity);
        assertEq(coin.totalSupply(), SUPPLY, "fees accrue to LP; the token itself has no tax");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FeeMigrationPreservesPriceAndPrincipalAcrossBothTradeDirections(uint24 feeSeed, uint256 seed)
        public
    {
        _start();
        uint24 nextFee = uint24(bound(feeSeed, 0, 44_399));
        uint256 buy = bound(seed, 1, 10 ether);
        trader.swap(locked.poolKey(), true, -int256(buy));
        uint256 tokens = coin.balanceOf(address(trader));
        if (tokens > 1) trader.swap(locked.poolKey(), false, -int256(tokens / 2));
        PoolKey memory old = locked.poolKey();
        (uint160 price,,) = locked.state();
        uint128 liquidity = locked.liquidity();
        uint256 held = coin.balanceOf(address(launch));
        uint256 reserve = launch.claimReserve();
        uint256 launchEth = address(launch).balance;
        vm.prank(TIMELOCK);
        uint128 moved = locked.lowerFee(nextFee);
        (uint160 nextPrice,, uint128 active) = locked.state();
        assertEq(price, nextPrice);
        assertEq(moved, active);
        assertApproxEqRel(moved, liquidity, 1e9);
        assertEq(manager.getLiquidity(old.toId()), 0);
        assertEq(coin.balanceOf(address(launch)), held);
        assertEq(launch.claimReserve(), reserve);
        assertGt(address(launch).balance, launchEth, "old ETH fees reach the launch");
        assertEq(address(locked).balance, 0);
        assertEq(coin.balanceOf(address(locked)), 0);
        vm.startPrank(TIMELOCK);
        vm.expectRevert(IMD6900LockedPool.NotLower.selector);
        locked.lowerFee(nextFee);
        vm.expectRevert(IMD6900LockedPool.NotLower.selector);
        locked.lowerFee(type(uint24).max);
        vm.stopPrank();
        trader.swap(locked.poolKey(), true, -1 ether);
        (uint256 fees,) = locked.collect();
        assertApproxEqAbs(fees, uint256(nextFee) * 1 ether / 1_000_000, 2);
    }

    function test_StandaloneCreationAndRuntimeOpcodesMeetAdmissionRule() public {
        _start();
        _scan(type(IMD6900RobinhoodLaunch).creationCode);
        _scan(type(IMD6900LockedPool).creationCode);
        _scan(type(IMD6900Hook).creationCode);
        _scan(type(IMD6900).creationCode);
        _scan(address(launch).code);
        _scan(address(locked).code);
        _scan(address(hook).code);
        _scan(address(coin).code);
    }

    function _scan(bytes memory code) internal pure {
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            assertTrue(op != 0xf2 && op != 0xf4 && op != 0xff, "forbidden opcode outside PUSH immediate");
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
    }
}
