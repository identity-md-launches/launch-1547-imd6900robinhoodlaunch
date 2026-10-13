// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

interface IFeeSink {
    function addFees() external payable;
}

interface IBurnable {
    function burn(uint256 amount) external;
}

/// @notice The hook's perps engine, and whether it has positions open
interface IPerpsWiring {
    function perpEngine() external view returns (address);
    function openCount() external view returns (uint256);
}

/// @title IMD6900LockedPool - the ETH / IMD6900 pool's liquidity on Robinhood Chain, locked for good
/// @notice Owns the pool's one position. Its launch opens it once, with IMD6900 only: the whole range from the pool's
///         lowest price up to the opening price, so the opening needs no ETH and every coin enters the market from
///         here. There is no owner and no function that takes liquidity out to anyone: what is in the pool stays in a
///         pool. Two things happen to it:
///          - {collect} (anyone): the fee the position earns comes out, its ETH to the launch's fee split (the NFT
///            pot and $IMD's burn), its IMD6900 burned (or where the timelock points it, {setCoinFeeTo});
///          - {lowerFee} (the Robinhood timelock, behind its delay): the pool's fee is static (that is what keeps
///            Uniswap's routing automatic), so a lower fee is a new pool. This moves the position, in one unlock, from
///            the current pool into a fresh one at the lower fee and the same price: the two legs settle against each
///            other, nothing is paid out but the old pool's earned fees (to the split and the burn), and the fee can
///            only ever go down. Never while the perps engine has positions open: the engine is bound to its pool
///            for good, so they could no longer close; after a move it fails closed until a new one is wired.
///         And one exemption, by refund: the hook's perps engine and the launch (its timelock's sale of held coins)
///         trade fee-free. Inside its own swap a refunded caller calls {feeCheckpoint} just before and {feeRefund}
///         just after: this contract owns all of the pool's liquidity, so the fees earned between the two are that
///         swap's, to the wei, and they go straight back. The pool's fee stays static for everyone else (no dynamic
///         fee, no deltas: Uniswap's routing is unaffected).
contract IMD6900LockedPool is ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int24 public constant TICK_SPACING = 60;
    int24 public constant LOWER_TICK = -887_220; // TickMath.minUsableTick(60)
    uint8 internal constant OPEN = 0;
    uint8 internal constant COLLECT = 1;
    uint8 internal constant MOVE = 2;
    /// @dev What stays here of each currency: the rounding margin {lowerFee}'s move needs (a wei of each per move,
    ///      {_move}); any fee tops it up
    uint256 internal constant MARGIN = 1_000;
    /// @dev Transient: a refunded caller's open checkpoint in this transaction, one slot per caller
    bytes32 internal constant CHECKPOINT_SEED = keccak256("IMD6900LockedPool.checkpoint");

    IPoolManager public immutable poolManager;
    /// @notice IMD6900RobinhoodLaunch: sets the hook once, opens the pool once, and takes the ETH fees
    address public immutable launcher;
    /// @notice The Robinhood timelock: the only one who can lower the fee
    address public immutable timelock;

    /// @notice The pool's static fee, in hundredths of a bip: lowered only by {lowerFee}, never raised
    uint24 public fee;
    address public hook;
    /// @notice IMD6900, once the pool is open
    address public token;
    /// @notice The top of the position's range: the opening price, on a tick
    int24 public upperTick;
    /// @notice The position's liquidity
    uint128 public liquidity;
    /// @notice Where the fee paid in IMD6900 goes: burned (zero, the default) unless the timelock points it elsewhere
    address public coinFeeTo;

    event HookSet(address hook);
    event Opened(uint160 sqrtPriceX96, int24 upperTick, uint256 tokens, uint128 liquidity);
    event Collected(uint256 eth, uint256 tokensBurned);
    event FeeLowered(uint24 from, uint24 to, PoolId pool, uint128 liquidity);
    event FeeRefunded(address indexed caller, address to, uint256 eth, uint256 tokens);
    event CoinFeeToSet(address to);

    error OnlyLauncher();
    error OnlyTimelock();
    error OnlyPoolManager();
    error HookAlreadySet();
    error NoHook();
    error AlreadyOpen();
    error NotOpen();
    error BadPrice();
    error ZeroLiquidity();
    error NotLower();
    /// @notice The perps engine has positions open: its pool is fixed for good, so moving the liquidity would strand them
    error PerpsOpen();
    error NotRefunded();
    error NoCheckpoint();

    constructor(IPoolManager poolManager_, uint24 fee_, address launcher_, address timelock_) {
        poolManager = poolManager_;
        launcher = launcher_;
        timelock = timelock_;
        fee = fee_;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), fee, TICK_SPACING, IHooks(hook));
    }

    function poolId() external view returns (PoolId) {
        return poolKey().toId();
    }

    /*                               LAUNCHER                               */

    function setHook(address hook_) external {
        if (msg.sender != launcher) revert OnlyLauncher();
        if (hook != address(0)) revert HookAlreadySet();
        hook = hook_;
        emit HookSet(hook_);
    }

    /// @notice Opens the pool once: initializes it at `sqrtPriceX96` rounded down onto a tick, and puts `amount` of
    ///         the launcher's IMD6900 (approved) into the range from the lowest price up to that tick. What the
    ///         liquidity can't take (rounding dust) goes back to the launcher, but for {MARGIN} wei.
    function open(address token_, uint160 sqrtPriceX96, uint256 amount) external nonReentrant returns (uint128 liq) {
        if (msg.sender != launcher) revert OnlyLauncher();
        if (hook == address(0)) revert NoHook();
        if (token != address(0)) revert AlreadyOpen();
        int24 t = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 upper = t - (((t % TICK_SPACING) + TICK_SPACING) % TICK_SPACING); // floor onto the spacing
        if (upper <= LOWER_TICK || upper > TickMath.maxUsableTick(TICK_SPACING)) revert BadPrice();
        token = token_;
        upperTick = upper;
        uint160 start = TickMath.getSqrtPriceAtTick(upper);
        uint160 low = TickMath.getSqrtPriceAtTick(LOWER_TICK);
        SafeTransferLib.safeTransferFrom(token_, msg.sender, address(this), amount);
        poolManager.initialize(poolKey(), start);
        // every coin sits below the price: amount1 = L * (sqrt(upper) - sqrt(lower)) / 2^96, rounded down
        uint256 l = FullMath.mulDiv(amount, 1 << 96, start - low);
        if (l <= 1) revert ZeroLiquidity();
        if (l - 1 > type(uint128).max) revert BadPrice(); // too low a price for one position to hold the amount
        liq = uint128(l - 1);
        liquidity = liq;
        (, uint256 used) = abi.decode(poolManager.unlock(abi.encode(OPEN, liq)), (uint256, uint256));
        uint256 back = amount - used;
        if (back > MARGIN) SafeTransferLib.safeTransfer(token_, msg.sender, back - MARGIN); // {_payOutHeld}
        emit Opened(start, upper, used, liq);
    }

    /*                        THE ROBINHOOD TIMELOCK                        */

    /// @notice Moves the position into a new pool at the lower static fee `newFee` (hundredths of a bip; 0 is no fee),
    ///         at the current price, in one unlock. The old pool's earned fees go to the split and the burn like any
    ///         {collect}; the rest of it is the new pool's, to the wei the rounding allows.
    function lowerFee(uint24 newFee) external nonReentrant returns (uint128 liq) {
        if (msg.sender != timelock) revert OnlyTimelock();
        if (token == address(0)) revert NotOpen();
        if (newFee >= fee) revert NotLower();
        address engine = IPerpsWiring(hook).perpEngine();
        if (engine != address(0)) {
            // an engine that can't say how many positions it holds counts as holding some
            (bool ok, bytes memory ret) = engine.staticcall{gas: 100_000}(abi.encodeCall(IPerpsWiring.openCount, ()));
            if (!ok || ret.length < 32 || abi.decode(ret, (uint256)) != 0) revert PerpsOpen();
        }
        PoolKey memory old = poolKey();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(old.toId());
        uint24 from = fee;
        fee = newFee;
        poolManager.initialize(poolKey(), sqrtPriceX96); // the hook serves the new pool from here on
        (,, liq) = abi.decode(poolManager.unlock(abi.encode(MOVE, old)), (uint256, uint256, uint128));
        liquidity = liq;
        _payOutHeld(); // the old pool's earned fees, with anything checkpoints booked
        emit FeeLowered(from, newFee, poolKey().toId(), liq);
    }

    /// @notice Where the fee paid in IMD6900 goes from now on: zero burns it (the default)
    function setCoinFeeTo(address to) external {
        if (msg.sender != timelock) revert OnlyTimelock();
        coinFeeTo = to;
        emit CoinFeeToSet(to);
    }

    /*                               ANYONE                                 */

    /// @notice Collects the fees the position has earned: the ETH to the launcher's fee split, the IMD6900 burned
    function collect() external nonReentrant returns (uint256 eth, uint256 tokens) {
        if (token == address(0)) revert NotOpen();
        poolManager.unlock(abi.encode(COLLECT, uint128(0)));
        return _payOutHeld(); // with what fee checkpoints booked since the last collect
    }

    /*                          REFUNDED CALLERS                            */

    /// @notice Who trades in the pool fee-free: the hook's perps engine, and the launch (its timelock's sale of held
    ///         coins back into the pool)
    function isRefunded(address a) public view returns (bool) {
        return a == launcher || (a != address(0) && a == IPerpsWiring(hook).perpEngine());
    }

    /// @notice A refunded caller, inside its own PoolManager unlock, just before its swap: books every fee the position
    ///         has earned so far (it is paid out at the next collect, like any), so {feeRefund} just after hands back
    ///         exactly what that swap paid
    function feeCheckpoint() external {
        if (!isRefunded(msg.sender)) revert NotRefunded();
        _poke(address(this));
        bytes32 slot = _checkpointSlot(msg.sender);
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
    }

    /// @notice Just after the swap: the fees the position earned since the caller's {feeCheckpoint}, to `to`. Once per
    ///         checkpoint, from the same caller, in the same transaction.
    function feeRefund(address to) external returns (uint256 eth, uint256 tokens) {
        bytes32 slot = _checkpointSlot(msg.sender);
        uint256 armed;
        assembly ("memory-safe") {
            armed := tload(slot)
            tstore(slot, 0)
        }
        if (armed == 0) revert NoCheckpoint();
        (eth, tokens) = _poke(to);
        emit FeeRefunded(msg.sender, to, eth, tokens);
    }

    /// @notice The pool's price and in-range liquidity
    function state() external view returns (uint160 sqrtPriceX96, int24 tick, uint128 poolLiquidity) {
        PoolId id = poolKey().toId();
        (sqrtPriceX96, tick,,) = poolManager.getSlot0(id);
        poolLiquidity = poolManager.getLiquidity(id);
    }

    /*                            POOL MANAGER                              */

    /// @dev OPEN adds the opening liquidity; COLLECT pokes the position for its fees; MOVE takes the position out of
    ///      the old pool and puts what it returned into the new one, then takes what is left over (the old pool's fees
    ///      and rounding). Nothing here ever takes liquidity out without putting it straight back into a pool.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        uint8 op = abi.decode(data, (uint8));
        if (op == MOVE) {
            (, PoolKey memory old) = abi.decode(data, (uint8, PoolKey));
            return _move(old);
        }
        (, uint128 liq) = abi.decode(data, (uint8, uint128));
        (BalanceDelta d,) = _modifyLiquidity(poolKey(), int256(uint256(liq)));
        _settle(d.amount0(), d.amount1());
        return abi.encode(_abs(d.amount0()), _abs(d.amount1()));
    }

    /// @notice ETH fees from the pool manager
    receive() external payable {}

    /*                              INTERNAL                                */

    function _move(PoolKey memory old) internal returns (bytes memory) {
        uint128 liq = liquidity;
        (BalanceDelta out,) = _modifyLiquidity(old, -int256(uint256(liq)));
        // the same liquidity again, in the same range at the same price. v4 rounds what a position returns down and
        // what one takes up, so the new position may need a wei more of either than the old one returned: the old
        // pool's earned fees (in `out`) or the margin kept here ({_payOutHeld}) cover it. Only if neither can
        // (nothing earned, nothing kept) does the liquidity drop to what the amounts hold.
        uint256 eth = uint256(uint128(out.amount0())) + address(this).balance;
        uint256 coins = uint256(uint128(out.amount1())) + SafeTransferLib.balanceOf(token, address(this));
        (uint256 need0, uint256 need1) = _amountsFor(liq);
        if (need0 > eth || need1 > coins) liq = _liquidityFor(eth, coins);
        if (liq == 0) revert ZeroLiquidity();
        (BalanceDelta into,) = _modifyLiquidity(poolKey(), int256(uint256(liq)));
        int128 net0 = out.amount0() + into.amount0(); // what's left (the fees), or the wei the position needed
        int128 net1 = out.amount1() + into.amount1();
        _settle(net0, net1);
        return abi.encode(_abs(net0), _abs(net1), liq);
    }

    /// @dev What v4 takes for `liq` in the position's range at the current price, rounded up as it rounds (Pool.sol's
    ///      modifyLiquidity, by tick)
    function _amountsFor(uint128 liq) internal view returns (uint256 eth, uint256 coins) {
        (uint160 p, int24 tick,,) = poolManager.getSlot0(poolKey().toId());
        uint160 a = TickMath.getSqrtPriceAtTick(LOWER_TICK);
        uint160 b = TickMath.getSqrtPriceAtTick(upperTick);
        if (tick < LOWER_TICK) {
            eth = SqrtPriceMath.getAmount0Delta(a, b, liq, true);
        } else if (tick < upperTick) {
            eth = SqrtPriceMath.getAmount0Delta(p, b, liq, true);
            coins = SqrtPriceMath.getAmount1Delta(a, p, liq, true);
        } else {
            coins = SqrtPriceMath.getAmount1Delta(a, b, liq, true);
        }
    }

    function _modifyLiquidity(PoolKey memory key, int256 delta) internal returns (BalanceDelta, BalanceDelta) {
        return poolManager.modifyLiquidity(key, ModifyLiquidityParams(LOWER_TICK, upperTick, delta, 0), "");
    }

    /// @dev Each currency: owed is paid in (only ever IMD6900, at the opening), freed is taken here
    function _settle(int128 a0, int128 a1) internal {
        PoolKey memory key = poolKey();
        if (a0 < 0) poolManager.settle{value: uint256(uint128(-a0))}();
        else if (a0 > 0) poolManager.take(key.currency0, address(this), uint256(uint128(a0)));
        if (a1 < 0) {
            poolManager.sync(key.currency1);
            SafeTransferLib.safeTransfer(token, address(poolManager), uint256(uint128(-a1)));
            poolManager.settle();
        } else if (a1 > 0) {
            poolManager.take(key.currency1, address(this), uint256(uint128(a1)));
        }
    }

    /// @dev The most liquidity `eth` and `coins` back in the position's range at the current price, rounded down
    function _liquidityFor(uint256 eth, uint256 coins) internal view returns (uint128) {
        (uint160 p,,,) = poolManager.getSlot0(poolKey().toId());
        uint160 a = TickMath.getSqrtPriceAtTick(LOWER_TICK);
        uint160 b = TickMath.getSqrtPriceAtTick(upperTick);
        uint256 l;
        if (p >= b) {
            l = FullMath.mulDiv(coins, 1 << 96, b - a);
        } else {
            uint256 fromEth = FullMath.mulDiv(eth, FullMath.mulDiv(p, b, 1 << 96), b - p);
            uint256 fromCoins = FullMath.mulDiv(coins, 1 << 96, p - a);
            l = fromEth < fromCoins ? fromEth : fromCoins;
        }
        if (l <= 1) return 0;
        l -= 1;
        return l > type(uint128).max ? type(uint128).max : uint128(l);
    }

    /// @dev Everything this contract holds is fees (it never keeps liquidity outside the pool): ETH to the launch's
    ///      split, IMD6900 burned or to {coinFeeTo}. {MARGIN} wei of each stays behind: the rounding margin
    ///      {lowerFee}'s move needs to put the whole position back ({_move}).
    function _payOutHeld() internal returns (uint256 eth, uint256 tokens) {
        eth = address(this).balance;
        tokens = SafeTransferLib.balanceOf(token, address(this));
        eth = eth > MARGIN ? eth - MARGIN : 0;
        tokens = tokens > MARGIN ? tokens - MARGIN : 0;
        if (eth != 0) IFeeSink(launcher).addFees{value: eth}();
        if (tokens != 0) {
            address to = coinFeeTo;
            if (to == address(0)) IBurnable(token).burn(tokens);
            else SafeTransferLib.safeTransfer(token, to, tokens);
        }
        emit Collected(eth, tokens);
    }

    /// @dev Inside the caller's unlock: the position's fees so far, taken to `to`
    function _poke(address to) internal returns (uint256 eth, uint256 tokens) {
        PoolKey memory key = poolKey();
        (BalanceDelta d,) = _modifyLiquidity(key, 0);
        eth = uint256(uint128(d.amount0()));
        tokens = uint256(uint128(d.amount1()));
        if (eth != 0) poolManager.take(key.currency0, to, eth);
        if (tokens != 0) poolManager.take(key.currency1, to, tokens);
    }

    function _checkpointSlot(address a) internal pure returns (bytes32) {
        return keccak256(abi.encode(CHECKPOINT_SEED, a));
    }

    function _abs(int128 v) internal pure returns (uint256) {
        return v < 0 ? uint256(uint128(-v)) : uint256(uint128(v));
    }
}
