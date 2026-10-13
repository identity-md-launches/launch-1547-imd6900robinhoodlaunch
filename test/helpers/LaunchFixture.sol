// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IMD6900} from "src/IMD6900.sol";
import {IMD6900Hook} from "src/IMD6900Hook.sol";
import {IMD6900LockedPool} from "src/IMD6900LockedPool.sol";
import {IMD6900RobinhoodLaunch} from "src/IMD6900RobinhoodLaunch.sol";
import {MockImdstr, Trader, LiquidityAdder} from "../IMD6900RobinhoodLaunch.t.sol";
import {HookSalt, CoinSalt} from "../HookSalt.sol";

/// Offline fixture: actual application contracts and vendored v4 PoolManager.
/// Only external tokens are stand-ins; no application storage/code is patched.
abstract contract LaunchFixture is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant TEAM = 0x35dA9C0303507ddf708E87F2568EdDf12c47a059;
    address internal constant TIMELOCK = 0x16D3f65B708883DF042d98E1C7a49B32A33E2A14;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant OPENING_BUY = 3 ether;
    // Aligned tick, approximately the existing fixture's opening market cap.
    int24 internal constant OPENING_TICK = 177_660;
    // IMD6900LockedPool.MARGIN: the wei of each currency the locked pool keeps back from every payout as the
    // rounding margin for lowerFee's move. Internal there, so it is restated here and checked by the tests.
    uint256 internal constant MARGIN = 1_000;

    IPoolManager internal manager;
    IMD6900RobinhoodLaunch internal launch;
    IMD6900LockedPool internal locked;
    IMD6900Hook internal hook;
    IMD6900 internal coin;
    MockImdstr internal legacy;
    Trader internal trader;
    bytes32 internal salt;
    address[3] internal users;
    uint256[3] internal allocations;

    function setUp() public virtual {
        manager = IPoolManager(address(new PoolManager(address(this))));
        legacy = new MockImdstr();
        launch = new IMD6900RobinhoodLaunch(TEAM, manager, address(legacy), TIMELOCK);
        locked = launch.pool();
        hook = launch.createHook(HookSalt.mine(launch));
        salt = CoinSalt.mine(launch);
        trader = new Trader(manager);
        vm.deal(address(trader), 100 ether);
        for (uint256 i; i < 3; ++i) {
            users[i] = makeAddr(string.concat("claimant-", vm.toString(i)));
            allocations[i] = (i + 1) * 10_000_000 ether;
            legacy.mint(users[i], allocations[i]);
            vm.prank(users[i]);
            legacy.approve(address(launch), type(uint256).max);
        }
        vm.prank(TEAM);
        launch.setClaims(_root(), 60_000_000 ether, block.timestamp + 90 days);
    }

    function _start() internal {
        address predicted = launch.tokenAddress(salt);
        vm.deal(TEAM, OPENING_BUY);
        vm.prank(TEAM);
        (address token,) = launch.launch{value: OPENING_BUY}(
            salt, predicted, TickMath.getSqrtPriceAtTick(OPENING_TICK), 0, address(launch)
        );
        coin = IMD6900(token);
    }

    function _imdLiquidity() internal returns (LiquidityAdder adder) {
        // The canonical address is needed by the unmodified launch. The mock
        // supplies ordinary ERC20 behavior; liquidity and settlement are real v4.
        vm.etch(launch.IMD(), address(new MockImdstr()).code);
        adder = new LiquidityAdder(manager);
        vm.deal(address(adder), 100 ether);
        MockImdstr(launch.IMD()).mint(address(adder), 1e30);
        PoolKey memory key = launch.imdPoolKey();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(55_600));
        adder.add(key, 1e21);
    }

    function _leaf(uint256 i) internal view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(users[i], allocations[i]))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _root() internal view returns (bytes32) {
        return _pair(_pair(_leaf(0), _leaf(1)), _leaf(2));
    }

    function _proof(uint256 i) internal view returns (bytes32[] memory p) {
        if (i == 2) {
            p = new bytes32[](1);
            p[0] = _pair(_leaf(0), _leaf(1));
        } else {
            p = new bytes32[](2);
            p[0] = _leaf(1 - i);
            p[1] = _leaf(2);
        }
    }

    function _claim(uint256 i, uint256 amount) internal {
        bytes32[] memory proof = _proof(i);
        vm.prank(users[i]);
        launch.claim(amount, allocations[i], proof);
    }

    /// A failed trade/withdrawal must restore custody AND pool state.
    function _financialState() internal view returns (bytes32) {
        (uint160 price, int24 tick, uint128 liquidity) = locked.state();
        return keccak256(
            abi.encode(
                price,
                tick,
                liquidity,
                locked.fee(),
                hook.poolId(),
                locked.liquidity(),
                coin.totalSupply(),
                coin.balanceOf(address(manager)),
                coin.balanceOf(address(locked)),
                coin.balanceOf(address(launch)),
                coin.balanceOf(address(trader)),
                address(manager).balance,
                address(locked).balance,
                address(launch).balance,
                launch.excessHeld(),
                launch.claimReserve(),
                launch.claimedTotal(),
                launch.imdBucket()
            )
        );
    }
}
