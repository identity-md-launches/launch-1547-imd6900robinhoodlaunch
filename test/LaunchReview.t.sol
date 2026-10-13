// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {IMD6900RobinhoodLaunch} from "../src/IMD6900RobinhoodLaunch.sol";
import {IMD6900LockedPool} from "../src/IMD6900LockedPool.sol";
import {IMD6900Hook} from "../src/IMD6900Hook.sol";
import {IMD6900} from "../src/IMD6900.sol";
import {MockImdstr, Trader, LiquidityAdder, CountingEngine} from "./IMD6900RobinhoodLaunch.t.sol";
import {HookSalt, CoinSalt} from "./HookSalt.sol";

/// A payee that cannot take ETH for now (a bridge whose deposit path is paused), until it can
contract RefusingPayee {
    bool public accepting;

    function accept() external {
        accepting = true;
    }

    receive() external payable {
        require(accepting, "paused");
    }
}

/// A trader that sells coins up to an exact sqrt price limit
contract LimitTrader {
    IPoolManager immutable pm;
    PoolKey key;
    uint160 limit;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function sell(PoolKey calldata k, uint256 coins, uint160 limit_) external {
        (key, limit) = (k, limit_);
        pm.unlock(abi.encode(coins));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        uint256 coins = abi.decode(data, (uint256));
        BalanceDelta d = pm.swap(key, SwapParams(false, -int256(coins), limit), "");
        pm.sync(key.currency1);
        IMD6900(Currency.unwrap(key.currency1)).transfer(address(pm), uint128(-d.amount1()));
        pm.settle();
        if (d.amount0() > 0) pm.take(key.currency0, address(this), uint128(d.amount0()));
        return "";
    }
    receive() external payable {}
}

/// A perps engine whose post-trade sweep liquidates one position (a sale of coins into the pool), with the refund
/// pair around it the way PerpSwapLib does, or without it
contract SweepingEngine {
    IPoolManager immutable pm;
    IMD6900LockedPool immutable lp;
    bool immutable refunds;
    uint256 public liquidation;
    uint256 public sweeps;

    constructor(IPoolManager pm_, IMD6900LockedPool lp_, bool refunds_) {
        (pm, lp, refunds) = (pm_, lp_, refunds_);
    }

    function openCount() external pure returns (uint256) {
        return 0;
    }

    function arm(uint256 coins) external {
        liquidation = coins;
    }

    function sweepLiquidations(address, int256 spec, bool, uint160) external returns (uint8) {
        ++sweeps;
        if (spec != 0 || liquidation == 0) return 0;
        uint256 coins = liquidation;
        liquidation = 0;
        _swap(false, coins); // inside the trader's unlock
        return 0;
    }

    function buy(uint256 eth) external {
        pm.unlock(abi.encode(true, eth));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool isBuy, uint256 amount) = abi.decode(data, (bool, uint256));
        _swap(isBuy, amount);
        return "";
    }

    function _swap(bool isBuy, uint256 amount) internal {
        PoolKey memory k = lp.poolKey();
        if (refunds) lp.feeCheckpoint();
        BalanceDelta d = pm.swap(
            k, SwapParams(isBuy, -int256(amount), isBuy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), ""
        );
        if (refunds) lp.feeRefund(address(this));
        if (isBuy) {
            pm.settle{value: uint128(-d.amount0())}();
            pm.take(k.currency1, address(this), uint128(d.amount1()));
        } else {
            pm.sync(k.currency1);
            IMD6900(Currency.unwrap(k.currency1)).transfer(address(pm), uint128(-d.amount1()));
            pm.settle();
            pm.take(k.currency0, address(this), uint128(d.amount0()));
        }
    }
    receive() external payable {}
}

/// Regressions for the independent review's findings (ADAPTATION.md lists them by id)
contract LaunchReviewTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    address constant OWNER = address(0xA11CE);
    address constant TL = address(0x71E10C);
    address constant R = address(0x2E7);
    uint256 constant BUY = 2.81 ether;

    IPoolManager pm;
    IMD6900RobinhoodLaunch launch;
    IMD6900LockedPool pool;
    IMD6900Hook hook;
    MockImdstr oldToken;
    bytes32 coinSalt;
    address token;

    function setUp() public {
        pm = IPoolManager(address(new PoolManager(address(this))));
        oldToken = new MockImdstr();
        launch = new IMD6900RobinhoodLaunch(OWNER, pm, address(oldToken), TL);
        hook = launch.createHook(HookSalt.mine(launch));
        pool = launch.pool();
        coinSalt = CoinSalt.mine(launch);
    }

    /*                 4891b788d800: a refused share is booked, never re-split                 */

    function test_RefusedShareIsBookedNotResplit() public {
        _launch(address(launch));
        RefusingPayee pot = new RefusingPayee();
        _payees(address(pot));
        vm.deal(address(this), 1 ether);
        launch.addFees{value: 1 ether}();
        for (uint256 i; i < 10; ++i) {
            launch.split();
        }
        assertEq(launch.imdBucket(), 0.1 ether, "the burn's share, once");
        assertEq(launch.owed(address(pot)), 0.9 ether, "the pot's share is booked to it");
        assertEq(launch.owedTotal(), 0.9 ether);
        assertEq(launch.split(), 0, "nothing left to split");
        // more fees while it still refuses: its new share joins the books, the burn's stays 10%
        launch.addFees{value: 0}();
        vm.deal(address(this), 1 ether);
        launch.addFees{value: 1 ether}();
        launch.split();
        assertEq(launch.imdBucket(), 0.2 ether);
        assertEq(launch.owed(address(pot)), 1.8 ether);
        // once it accepts, the next split pays everything booked with its share of what is new
        pot.accept();
        vm.deal(address(this), 1 ether);
        launch.addFees{value: 1 ether}();
        launch.split();
        assertEq(address(pot).balance, 2.7 ether, "all of its 90%, in the end");
        assertEq(launch.owed(address(pot)), 0);
        assertEq(launch.owedTotal(), 0);
        assertEq(launch.imdBucket(), 0.3 ether);
        assertEq(address(launch).balance, 0.3 ether);
    }

    function test_RecoverEthCancelsTheBooksOnlyWhenItReachesThem() public {
        _launch(address(launch));
        RefusingPayee pot = new RefusingPayee();
        _payees(address(pot));
        vm.deal(address(this), 2 ether);
        launch.addFees{value: 1 ether}();
        launch.split(); // 0.9 booked, 0.1 the burn's
        launch.addFees{value: 1 ether}(); // 1 ETH not booked
        vm.prank(TL);
        launch.recoverEth(R, 1 ether);
        assertEq(launch.owed(address(pot)), 0.9 ether, "what was not booked went first");
        assertEq(launch.imdBucket(), 0.1 ether);
        vm.prank(TL);
        launch.recoverEth(R, 0.5 ether);
        assertEq(launch.owed(address(pot)), 0, "beyond it, the books are cancelled");
        assertEq(launch.owedTotal(), 0);
        assertEq(launch.imdBucket(), 0.1 ether, "the burn's bucket only shrinks when it has to");
        pot.accept();
        assertEq(launch.split(), 0.4 ether, "what is left beyond the bucket splits again");
        assertEq(address(pot).balance, 0.36 ether);
    }

    /*          959b71d4fb20: lowerFee moves all of the liquidity even with a wei of ETH left          */

    function test_LowerFeeMovesAllOfItWithOneWeiOfEthInThePosition() public {
        LimitTrader trader = new LimitTrader(pm);
        _launch(address(trader)); // no claims: every circulating coin is the trader's
        vm.prank(TL);
        pool.setCoinFeeTo(address(trader)); // its sells' fees come back to it, so it can push the price to the top
        uint160 b = TickMath.getSqrtPriceAtTick(pool.upperTick());
        uint128 l0 = pool.liquidity();
        uint256 oneWei = FullMath.mulDiv(b, b, uint256(l0) << 96); // the sqrt-price distance worth a wei of ETH
        uint160 limit = uint160(uint256(b) - (oneWei * 3) / 2); // ~1.5 wei of ETH stays in the position
        for (uint256 i; i < 80; ++i) {
            trader.sell(pool.poolKey(), IMD6900(token).balanceOf(address(trader)), limit);
            pool.collect();
            (uint160 p,,) = pool.state();
            if (p == limit) break;
        }
        (uint160 price,,) = pool.state();
        assertEq(price, limit, "the sale stopped at the limit");
        assertEq(SqrtPriceMath.getAmount0Delta(price, b, l0, false), 1, "the position's ETH rounds to one wei");
        pool.collect(); // the old pool's fees are out: principal only, and the margin kept here
        assertEq(address(pool).balance, 1_000, "the ETH margin kept back");
        assertEq(IMD6900(token).balanceOf(address(pool)), 1_000, "the coin margin kept back");
        uint256 held0 = IMD6900(token).balanceOf(address(trader));
        uint256 supply0 = IMD6900(token).totalSupply();
        vm.prank(TL);
        uint128 l1 = pool.lowerFee(33_300);
        assertEq(l1, l0, "all of the liquidity moved, to the wei");
        (uint160 p1,, uint128 inPool) = pool.state();
        assertEq(p1, price, "same price");
        assertEq(inPool, l1);
        assertEq(IMD6900(token).balanceOf(address(trader)), held0, "nothing of the position was paid out");
        assertEq(IMD6900(token).totalSupply(), supply0, "nor burned");
    }

    function test_LowerFeeMovesAllOfItRightAfterCollect() public {
        Trader trader = new Trader(pm);
        vm.deal(address(trader), 100 ether);
        _launch(address(launch));
        trader.swap(pool.poolKey(), true, -5 ether);
        pool.collect(); // no fees earned since: the kept margin is all there is
        uint128 l0 = pool.liquidity();
        for (uint24 f = 33_300; f != 0; f -= 1_110) {
            vm.prank(TL);
            assertEq(pool.lowerFee(f), l0, "all of it moved, every time");
        }
        assertEq(pool.liquidity(), l0);
    }

    /*     a8a1088f7ba1: no liquidation sweep inside the launch's sale: its fee refund stays its own     */

    function test_TheSaleStaysFeeFreeWithARefundingEngineArmed() public {
        _launch(address(launch));
        SweepingEngine engine = new SweepingEngine(pm, pool, true);
        _wire(engine);
        engine.arm(IMD6900(token).balanceOf(address(engine)) / 10);
        uint256 sale = launch.excessHeld() / 2;
        vm.prank(TL);
        launch.sellHeld(sale, 0, R);
        assertEq(engine.sweeps(), 0, "the sale runs no sweep");
        (, uint256 coinFee) = pool.collect();
        assertLt(coinFee, sale / 1_000_000, "the sale paid no fee");
        // the next trade's sweep closes what the sale sank
        Trader trader = new Trader(pm);
        vm.deal(address(trader), 1 ether);
        trader.swap(pool.poolKey(), true, -0.5 ether);
        assertEq(engine.sweeps(), 2, "before and after the trader's swap");
        assertEq(engine.liquidation(), 0, "the armed liquidation ran there");
    }

    function test_TheSaleIsNotBrokenByANonRefundingEnginesLiquidation() public {
        _launch(address(launch));
        SweepingEngine engine = new SweepingEngine(pm, pool, false);
        _wire(engine);
        engine.arm(IMD6900(token).balanceOf(address(engine))); // far larger than the sale's rounds
        uint256 held = launch.excessHeld();
        vm.prank(TL);
        uint256 eth = launch.sellHeld(1 ether, 0, R);
        assertEq(R.balance, eth);
        // sold what it was told but the sale's documented remainder (4.44% cubed of it stays held)
        assertApproxEqRel(held - launch.excessHeld(), 1 ether, 1e14, "sold what it was told");
        assertEq(engine.liquidation() != 0, true, "the engine's liquidation waits for the next trade");
    }

    /*        8d3fd3ae881f: the engine can't be unwired or replaced while it has positions open        */

    function test_NoUnwiringWhilePerpsAreOpen() public {
        _launch(address(launch));
        CountingEngine engine = new CountingEngine();
        vm.prank(TL);
        hook.setPerpEngine(address(engine));
        engine.set(3, false);
        CountingEngine fresh = new CountingEngine();
        vm.startPrank(TL);
        vm.expectRevert(IMD6900Hook.PerpsOpen.selector);
        hook.setPerpEngine(address(0));
        vm.expectRevert(IMD6900Hook.PerpsOpen.selector);
        hook.setPerpEngine(address(fresh));
        hook.setPerpEngine(address(engine)); // the same engine again is no change
        vm.expectRevert(IMD6900LockedPool.PerpsOpen.selector);
        pool.lowerFee(33_300);
        engine.set(0, false);
        hook.setPerpEngine(address(0));
        pool.lowerFee(33_300);
        vm.stopPrank();
        assertEq(pool.fee(), 33_300);
    }

    function test_AnEngineThatCantSayIsReplaceable() public {
        _launch(address(launch));
        vm.startPrank(TL);
        hook.setPerpEngine(address(1)); // a mistaken wiring: no code
        hook.setPerpEngine(address(0));
        CountingEngine engine = new CountingEngine();
        hook.setPerpEngine(address(engine));
        vm.etch(address(engine), hex"fe"); // a broken one
        hook.setPerpEngine(address(0));
        vm.stopPrank();
        assertEq(hook.perpEngine(), address(0));
    }

    /*            bbf57e19fc03: a burn on a thin $IMD pool is too small to sandwich at a profit            */

    function test_BurnOnAThinPoolCantBeSandwiched() public {
        _imdPool(2e19); // ~1.24 ETH a side at 261 $IMD/ETH
        _launch(address(launch));
        _earnBurnFees();
        PoolKey memory k = launch.imdPoolKey();
        uint256 bucket = launch.imdBucket();
        uint256 honest;
        {
            uint256 snap = vm.snapshotState();
            honest = launch.burnImd(0);
            uint256 spent = bucket - launch.imdBucket();
            assertLt(spent, 0.1 ether, "less than the cap on a thin pool");
            assertApproxEqRel(spent, 0.0124 ether, 0.05e18, "1% of the ETH the in-range liquidity stands for");
            vm.revertToState(snap);
        }
        uint256[4] memory fronts = [uint256(0.05 ether), 0.1 ether, 0.3 ether, 1 ether];
        for (uint256 i; i < fronts.length; ++i) {
            uint256 snap = vm.snapshotState();
            Trader attacker = new Trader(pm);
            vm.deal(address(attacker), 10 ether);
            attacker.swap(k, true, -int256(fronts[i]));
            uint256 got = launch.burnImd(0);
            attacker.swap(k, false, -int256(MockImdstr(launch.IMD()).balanceOf(address(attacker))));
            emit log_named_decimal_uint("attacker ETH after", address(attacker).balance, 18);
            assertLt(address(attacker).balance, 10 ether, "the sandwich loses");
            assertGt(got, honest / 2, "and the burn still gets the better part of the honest buy");
            vm.revertToState(snap);
        }
    }

    function test_BurnOnADeepPoolSpendsTheCap() public {
        _imdPool(2e20); // ~12.4 ETH a side
        _launch(address(launch));
        _earnBurnFees();
        uint256 bucket = launch.imdBucket();
        launch.burnImd(0);
        assertEq(bucket - launch.imdBucket(), 0.1 ether, "the full 0.1 ETH where the pool takes it");
    }

    /*                               9907b6c0017b: no renouncing                               */

    function test_TheOwnerCantRenounce() public {
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NoRenounce.selector);
        launch.renounceOwnership();
        vm.expectRevert(Ownable.Unauthorized.selector);
        launch.renounceOwnership();
        assertEq(launch.owner(), OWNER);
    }

    /*                     937f1074b052: a release to this contract keeps the coins accounted                     */

    function test_ReleasesToThisContractStayAccounted() public {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(R, 1_000_000 ether))));
        vm.prank(OWNER);
        launch.setClaims(leaf, 1_000_000 ether, block.timestamp + 100 days);
        _launch(address(launch));
        uint256 held = launch.excessHeld();
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadTo.selector);
        launch.releaseExcess(0, address(launch));
        assertEq(launch.excessHeld(), held);
        vm.warp(launch.claimDeadline());
        vm.prank(OWNER);
        launch.releaseUnclaimed(address(launch));
        assertEq(launch.excessHeld(), held + 1_000_000 ether, "the unclaimed reserve joins the held coins");
        assertEq(launch.claimReserve(), 0);
        assertEq(IMD6900(token).balanceOf(address(launch)), launch.excessHeld(), "every coin here is accounted");
    }

    /*                   8166dd84de84: too low an opening price is BadPrice, not v4's overflow                   */

    function test_TooLowAnOpeningPriceIsBadPrice() public {
        address expected = launch.tokenAddress(coinSalt);
        vm.deal(OWNER, 1 ether);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900LockedPool.BadPrice.selector);
        launch.launch{value: 1 ether}(coinSalt, expected, TickMath.getSqrtPriceAtTick(-887_160), 0, address(launch));
    }

    /*                                        HELPERS                                        */

    function _launch(address excessTo) internal {
        address expected = launch.tokenAddress(coinSalt);
        uint160 price = uint160(_sqrt(FullMath.mulDiv(1_000_000_000 ether, 1 << 192, 19.18 ether)));
        vm.deal(OWNER, BUY);
        vm.prank(OWNER);
        (token,) = launch.launch{value: BUY}(coinSalt, expected, price, 0, excessTo);
    }

    function _payees(address pot) internal {
        address[] memory to = new address[](2);
        uint16[] memory bps = new uint16[](2);
        (to[0], bps[0], to[1], bps[1]) = (pot, 9_000, launch.imdBurn(), 1_000);
        vm.prank(TL);
        launch.setPayees(to, bps);
    }

    function _wire(SweepingEngine engine) internal {
        vm.deal(address(engine), 10 ether);
        vm.startPrank(TL);
        hook.setPerpEngine(address(engine));
        hook.setPerpRefunded(true);
        vm.stopPrank();
        engine.buy(1 ether); // it holds coins, as positions it may have to close
    }

    function _imdPool(uint256 liquidity) internal {
        vm.etch(launch.IMD(), address(new MockImdstr()).code);
        pm.initialize(launch.imdPoolKey(), uint160(_sqrt(261 << 192)));
        LiquidityAdder adder = new LiquidityAdder(pm);
        vm.deal(address(adder), 100 ether);
        MockImdstr(launch.IMD()).mint(address(adder), 1e30);
        adder.add(launch.imdPoolKey(), liquidity);
    }

    function _earnBurnFees() internal {
        Trader buyer = new Trader(pm);
        vm.deal(address(buyer), 150 ether);
        buyer.swap(pool.poolKey(), true, -150 ether);
        launch.harvest();
        assertGt(launch.imdBucket(), 0.6 ether);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) (y, z) = (z, (x / z + z) / 2);
    }
}
