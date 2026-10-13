// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {MockImdstr, Trader, RefundingEngine, LiquidityAdder} from "./IMD6900RobinhoodLaunch.t.sol";
import {IMD6900} from "src/IMD6900.sol";
import {IMD6900Hook} from "src/IMD6900Hook.sol";
import {IMD6900LockedPool} from "src/IMD6900LockedPool.sol";
import {IMD6900RobinhoodLaunch} from "src/IMD6900RobinhoodLaunch.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// A payee that refuses its share until told to accept: what split books to it ({owed}) is the ledger under test
contract TogglePayee {
    bool public refusing = true;

    function setRefusing(bool r) external {
        refusing = r;
    }

    receive() external payable {
        if (refusing) revert("refused");
    }
}

/// Actions use bounded balances, not vm.deal on application contracts. Reverts
/// are failures unless explicitly expected; ghost updates follow successful calls.
contract LaunchSequenceHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IMD6900RobinhoodLaunch public immutable launch;
    IMD6900LockedPool public immutable locked;
    IMD6900Hook public immutable hook;
    IMD6900 public immutable coin;
    MockImdstr public immutable legacy;
    IPoolManager public immutable manager;
    Trader public immutable trader;
    RefundingEngine public immutable engine;
    address public immutable team;
    address public immutable timelock;
    address[3] public actors;
    uint256[3] public allocations;
    uint256[3] public ghostClaimed;
    PoolId[] public retiredPools;

    uint256 public ghostBurned;
    uint256 public ghostLegacyReleased;
    uint256 public ghostCoinDonatedToLaunch;
    uint256 public ghostImdDelivered;
    bool public ghostClosed;
    uint256 public claimsExecuted;
    uint256 public tradesExecuted;
    uint256 public refundsExecuted;
    uint256 public collectionsExecuted;
    uint256 public migrationsExecuted;
    uint256 public refusalsBooked;
    uint256 public booksCancelled;
    uint256 internal constant MARGIN = 1_000;
    /// the refusing payee, and every address the split can book ETH to while it runs
    TogglePayee public immutable refuser = new TogglePayee();
    address[] public payeesSeen;

    constructor(
        IMD6900RobinhoodLaunch launch_,
        MockImdstr legacy_,
        Trader trader_,
        RefundingEngine engine_,
        address[3] memory actors_,
        uint256[3] memory allocations_
    ) {
        launch = launch_;
        locked = launch_.pool();
        hook = launch_.hook();
        coin = IMD6900(launch_.token());
        manager = launch_.poolManager();
        team = launch_.owner();
        timelock = launch_.timelock();
        (legacy, trader, engine, actors, allocations) = (legacy_, trader_, engine_, actors_, allocations_);
        payeesSeen.push(launch_.POT_BRIDGE());
        payeesSeen.push(address(refuser));
        payeesSeen.push(actors_[1]);
    }

    /// The split's payees: the defaults, or a list with the refusing payee in it (a plain EOA beside it). The $IMD
    /// burn executor keeps its 10% in every list, as the real split does.
    function configurePayees(uint8 mode) external {
        vm.startPrank(timelock);
        if (mode % 3 == 0) {
            address[] memory to = new address[](2);
            uint16[] memory bps = new uint16[](2);
            (to[0], bps[0], to[1], bps[1]) = (launch.POT_BRIDGE(), 9_000, launch.imdBurn(), 1_000);
            launch.setPayees(to, bps);
        } else if (mode % 3 == 1) {
            address[] memory to = new address[](3);
            uint16[] memory bps = new uint16[](3);
            (to[0], bps[0]) = (address(refuser), 5_000);
            (to[1], bps[1]) = (launch.POT_BRIDGE(), 4_000);
            (to[2], bps[2]) = (launch.imdBurn(), 1_000);
            launch.setPayees(to, bps);
        } else {
            address[] memory to = new address[](3);
            uint16[] memory bps = new uint16[](3);
            (to[0], bps[0]) = (address(refuser), 4_500);
            (to[1], bps[1]) = (actors[1], 4_500);
            (to[2], bps[2]) = (launch.imdBurn(), 1_000);
            launch.setPayees(to, bps);
        }
        vm.stopPrank();
    }

    function toggleRefusal(bool refusing) external {
        refuser.setRefusing(refusing);
    }

    /// What the owed ledger must do on every split: a payee that refuses has its part booked, one that accepts is
    /// paid its part and everything booked to it, and the burn's share is never booked.
    function splitChecked() external {
        uint256 balance = address(launch).balance;
        uint256 bucket = launch.imdBucket();
        uint256 owedBefore = launch.owedTotal();
        uint256 refuserOwed = launch.owed(address(refuser));
        uint256 refuserBalance = address(refuser).balance;
        (address[] memory to, uint16[] memory bps) = launch.payees();
        uint256 refuserBps;
        for (uint256 i; i < to.length; ++i) {
            if (to[i] == address(refuser)) refuserBps += bps[i];
        }
        uint256 amount = launch.split();
        assertEq(amount, balance - bucket - owedBefore, "the split is what is neither reserved nor booked");
        uint256 part = amount * refuserBps / 10_000;
        if (amount == 0) {
            // split returns before the payee loop when there is nothing new: what is booked is not offered until
            // new ETH arrives (reported in .imd-findings.json as a liveness nit, not asserted correct here)
            assertEq(launch.owed(address(refuser)), refuserOwed);
            assertEq(address(refuser).balance, refuserBalance);
        } else if (refuserBps == 0) {
            assertEq(launch.owed(address(refuser)), refuserOwed, "a payee off the list is neither paid nor booked");
        } else if (refuser.refusing()) {
            if (part + refuserOwed != 0) {
                assertEq(launch.owed(address(refuser)), refuserOwed + part, "the refused part joins the books");
                assertEq(address(refuser).balance, refuserBalance);
                if (part != 0) ++refusalsBooked;
            }
        } else {
            assertEq(address(refuser).balance, refuserBalance + part + refuserOwed, "paid its part and its books");
            assertEq(launch.owed(address(refuser)), 0);
        }
        assertEq(launch.imdBucket(), bucket + amount * 1_000 / 10_000, "the burn's 10%, never booked");
    }

    function claim(uint256 actorSeed, uint256 amountSeed) external {
        uint256 i = actorSeed % 3;
        uint256 remaining = allocations[i] - ghostClaimed[i];
        if (ghostClosed || remaining == 0) return;
        uint256 amount = bound(amountSeed, 1, remaining);
        uint256 oldBalance = legacy.balanceOf(actors[i]);
        uint256 newBalance = coin.balanceOf(actors[i]);
        bytes32[] memory proof = _proof(i);
        vm.prank(actors[i]);
        launch.claim(amount, allocations[i], proof);
        ghostClaimed[i] += amount;
        ++claimsExecuted;
        assertEq(oldBalance - legacy.balanceOf(actors[i]), amount, "claim debits old token exactly");
        assertEq(coin.balanceOf(actors[i]) - newBalance, amount, "claim credits new coin exactly");
    }

    function trade(bool buy, uint256 amountSeed) external {
        uint256 available = buy ? address(trader).balance : coin.balanceOf(address(trader));
        if (available == 0) return;
        if (buy && available > 2 ether) available = 2 ether;
        uint256 amount = bound(amountSeed, 1, available);
        uint128 liquidity = locked.liquidity();
        uint256 supply = coin.totalSupply();
        trader.swap(locked.poolKey(), buy, -int256(amount));
        ++tradesExecuted;
        assertEq(locked.liquidity(), liquidity, "trades cannot unlock liquidity");
        assertEq(coin.totalSupply(), supply, "plain transfers have no coin tax");
    }

    function refundedTrade(bool buy, uint256 amountSeed) external {
        uint256 available = buy ? address(engine).balance : coin.balanceOf(address(engine));
        if (available == 0) return;
        if (buy && available > 1 ether) available = 1 ether;
        uint256 amount = bound(amountSeed, 1, available);
        uint256 ethBefore = address(engine).balance;
        uint256 coinsBefore = coin.balanceOf(address(engine));
        (uint256 ethRefund, uint256 coinRefund) = engine.swap(locked.poolKey(), buy, -int256(amount));
        ++refundsExecuted;
        // At these sizes the active range fully fills; the charged fee cannot
        // exceed input, nor can a refund include fees from earlier traders.
        if (buy) {
            assertLe(ethRefund, amount * locked.fee() / 1_000_000 + 1);
            assertEq(coinRefund, 0);
            assertEq(address(engine).balance, ethBefore - amount + ethRefund);
        } else {
            assertLe(coinRefund, amount * locked.fee() / 1_000_000 + 1);
            assertEq(ethRefund, 0);
            assertEq(coin.balanceOf(address(engine)), coinsBefore - amount + coinRefund);
        }
    }

    function transferCoin(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % 3];
        address to = actors[toSeed % 3];
        uint256 amount = bound(amountSeed, 0, coin.balanceOf(from));
        uint256 supply = coin.totalSupply();
        vm.prank(from);
        coin.transfer(to, amount);
        assertEq(coin.totalSupply(), supply);
    }

    function donateCoin(uint256 actorSeed, uint256 amountSeed, bool toPool) external {
        address from = actors[actorSeed % 3];
        uint256 amount = bound(amountSeed, 0, coin.balanceOf(from));
        vm.prank(from);
        coin.transfer(toPool ? address(locked) : address(launch), amount);
        if (!toPool) ghostCoinDonatedToLaunch += amount;
    }

    function donateEth(uint256 amountSeed, bool toPool) external {
        uint256 available = address(this).balance;
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 0, available < 1 ether ? available : 1 ether);
        (bool ok,) = (toPool ? address(locked) : address(launch)).call{value: amount}("");
        assertTrue(ok);
    }

    function collect(bool alsoSplit) external {
        uint128 liquidity = locked.liquidity();
        uint256 supply = coin.totalSupply();
        uint256 balance = address(launch).balance;
        address recipient = locked.coinFeeTo();
        uint256 recipientBefore = coin.balanceOf(recipient);
        uint256 ethHeld = address(locked).balance;
        uint256 coinsHeld = coin.balanceOf(address(locked));
        (uint256 eth, uint256 coins) = locked.collect();
        ++collectionsExecuted;
        assertEq(address(launch).balance - balance, eth);
        // the margin: a payout leaves exactly MARGIN when there was at least that much, all of it otherwise
        assertLe(address(locked).balance, MARGIN);
        assertLe(coin.balanceOf(address(locked)), MARGIN);
        if (eth != 0) assertEq(address(locked).balance, MARGIN, "paying out leaves the full margin");
        if (coins != 0) assertEq(coin.balanceOf(address(locked)), MARGIN);
        assertGe(address(locked).balance, ethHeld > MARGIN ? MARGIN : ethHeld, "a collect never eats the margin");
        assertGe(coin.balanceOf(address(locked)), coinsHeld > MARGIN ? MARGIN : coinsHeld);
        assertEq(locked.liquidity(), liquidity, "collection cannot remove principal");
        if (recipient == address(0)) {
            ghostBurned += coins;
            assertEq(supply - coin.totalSupply(), coins);
        } else {
            assertEq(coin.balanceOf(recipient) - recipientBefore, coins);
            assertEq(coin.totalSupply(), supply);
        }
        if (alsoSplit) launch.split();
    }

    function split() external {
        launch.split();
    }

    function lowerFee(uint256 seed) external {
        uint24 oldFee = locked.fee();
        if (oldFee == 0) return;
        uint24 next = uint24(bound(seed, 0, oldFee - 1));
        PoolKey memory previous = locked.poolKey();
        (uint160 price,,) = locked.state();
        uint128 oldLiquidity = locked.liquidity();
        uint256 managerCoins = coin.balanceOf(address(manager));
        uint256 heldCoins = coin.balanceOf(address(locked));
        uint256 supply = coin.totalSupply();
        address recipient = locked.coinFeeTo();
        uint256 recipientBefore = coin.balanceOf(recipient);
        uint256 launchEth = address(launch).balance;
        uint256 heldEth = address(locked).balance;
        uint256 managerEth = address(manager).balance;
        vm.prank(timelock);
        uint128 newLiquidity = locked.lowerFee(next);
        retiredPools.push(previous.toId());
        ++migrationsExecuted;
        // coins: what the manager and the locked pool held together is what they hold now plus what was paid out,
        // burned or sent to the fee recipient; nobody else receives a coin during a move
        uint256 releasedCoins =
            recipient == address(0) ? supply - coin.totalSupply() : coin.balanceOf(recipient) - recipientBefore;
        if (recipient == address(0)) {
            ghostBurned += releasedCoins;
        } else {
            assertEq(coin.totalSupply(), supply);
        }
        assertEq(
            managerCoins + heldCoins,
            coin.balanceOf(address(manager)) + coin.balanceOf(address(locked)) + releasedCoins,
            "a move pays out fees only"
        );
        assertEq(
            managerEth + heldEth,
            address(manager).balance + address(locked).balance + (address(launch).balance - launchEth),
            "a move's ETH goes to the pool, the margin or the launch"
        );
        assertLe(address(locked).balance, MARGIN, "the move leaves at most the margin");
        assertLe(coin.balanceOf(address(locked)), MARGIN);
        if (heldEth >= MARGIN && heldCoins >= MARGIN) {
            assertEq(newLiquidity, oldLiquidity, "with a full margin the whole position moves, to the unit");
        }
        (uint160 afterPrice,,) = locked.state();
        assertEq(afterPrice, price, "fee move preserves the exact sqrt price");
        assertEq(locked.fee(), next);
        assertLt(next, oldFee);
        // One part per billion is much larger than integer rounding in this
        // fixture, but rejects any meaningful principal removal during a move.
        assertApproxEqRel(newLiquidity, oldLiquidity, 1e9, "whole position must migrate");
        assertEq(_position(previous.toId()), 0, "old position is completely retired");
    }

    function sellHeld(uint256 seed) external {
        uint256 available = launch.excessHeld();
        if (available == 0) return;
        uint256 amount = bound(seed, 1, available);
        uint256 beforeCoin = coin.balanceOf(address(launch));
        uint256 recipientBalance = actors[2].balance;
        vm.prank(timelock);
        uint256 eth = launch.sellHeld(amount, 0, actors[2]);
        assertEq(actors[2].balance - recipientBalance, eth);
        assertEq(beforeCoin - coin.balanceOf(address(launch)), available - launch.excessHeld());
        assertLe(available - launch.excessHeld(), amount, "sale cannot spend claim reserve");
    }

    function releaseExcess(uint256 seed, bool burn) external {
        uint256 available = launch.excessHeld();
        if (available == 0) return;
        uint256 amount = bound(seed, 1, available);
        vm.prank(timelock);
        launch.releaseExcess(amount, burn ? address(0) : actors[0]);
        if (burn) ghostBurned += amount;
    }

    function closeClaims(bool early, uint8 mode) external {
        if (ghostClosed) return;
        if (early) {
            uint256 held = launch.excessHeld();
            uint256 reserve = launch.claimReserve();
            vm.prank(timelock);
            launch.endClaims();
            assertEq(launch.excessHeld(), held + reserve, "the unclaimed rest joins the held coins");
        } else {
            if (block.timestamp < launch.claimDeadline()) {
                vm.prank(team);
                vm.expectRevert(IMD6900RobinhoodLaunch.ClaimsOpen.selector);
                launch.releaseUnclaimed(actors[0]);
                return;
            }
            uint256 reserve = launch.claimReserve();
            uint256 held = launch.excessHeld();
            address to = mode % 3 == 0 ? address(0) : mode % 3 == 1 ? actors[0] : address(launch);
            vm.prank(team);
            launch.releaseUnclaimed(to);
            if (to == address(0)) ghostBurned += reserve;
            // released to the launch itself, the rest is held for the timelock rather than lost to the books
            assertEq(launch.excessHeld(), to == address(launch) ? held + reserve : held);
        }
        ghostClosed = true;
        vm.prank(team);
        vm.expectRevert(IMD6900RobinhoodLaunch.AlreadyReleased.selector);
        launch.releaseUnclaimed(actors[0]);
    }

    function releaseLegacy(uint256 seed) external {
        uint256 held = legacy.balanceOf(address(launch));
        if (held == 0) return;
        uint256 amount = bound(seed, 1, held);
        vm.prank(team);
        launch.releaseImdstr(amount, team);
        ghostLegacyReleased += amount;
    }

    function burnCoin(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 amount = bound(amountSeed, 0, coin.balanceOf(actor));
        vm.prank(actor);
        coin.burn(amount);
        ghostBurned += amount;
    }

    function burnImd(bool nextBlock) external {
        uint256 currentBlock = vm.getBlockNumber();
        if (nextBlock) vm.roll(++currentBlock);
        uint256 bucket = launch.imdBucket();
        if (currentBlock < launch.nextImdBurnBlock()) {
            vm.expectRevert(IMD6900RobinhoodLaunch.BurnRateLimited.selector);
            launch.burnImd(0);
            return;
        }
        if (bucket == 0) return;
        uint256 balance = address(launch).balance;
        uint256 beforeImd = MockImdstr(launch.IMD()).balanceOf(launch.imdBurn());
        uint256 bought = launch.burnImd(0);
        ghostImdDelivered += bought;
        assertEq(MockImdstr(launch.IMD()).balanceOf(launch.imdBurn()) - beforeImd, bought);
        assertEq(balance - address(launch).balance, bucket - launch.imdBucket());
        assertLe(bucket - launch.imdBucket(), launch.IMD_BUY_MAX());
        vm.expectRevert(IMD6900RobinhoodLaunch.BurnRateLimited.selector);
        launch.burnImd(0);
    }

    function recoverEth(uint256 seed) external {
        uint256 held = address(launch).balance;
        if (held == 0) return;
        uint256 amount = bound(seed, 1, held);
        uint256 bucket = launch.imdBucket();
        uint256 owedBefore = launch.owedTotal();
        uint256 refuserOwed = launch.owed(address(refuser));
        vm.prank(timelock);
        launch.recoverEth(actors[1], amount);
        uint256 left = held - amount;
        if (bucket + owedBefore > left) {
            // beyond the unbooked ETH: every book is cancelled, then the burn's bucket shrinks to what is left
            assertEq(launch.owedTotal(), 0, "the books are cancelled, all of them");
            assertEq(launch.owed(address(refuser)), 0);
            if (owedBefore != 0) ++booksCancelled;
            assertEq(launch.imdBucket(), bucket > left ? left : bucket);
        } else {
            assertEq(launch.owedTotal(), owedBefore, "unbooked ETH goes first: the books stand");
            assertEq(launch.owed(address(refuser)), refuserOwed);
            assertEq(launch.imdBucket(), bucket);
        }
    }

    function perpFees(uint256 seed) external {
        uint256 held = address(this).balance;
        if (held == 0) return;
        uint256 amount = bound(seed, 0, held < 1 ether ? held : 1 ether);
        uint256 launchBefore = address(launch).balance;
        uint256 potBefore = launch.POT_BRIDGE().balance;
        launch.addPerpFees{value: amount}();
        assertEq(address(launch).balance, launchBefore);
        assertEq(launch.POT_BRIDGE().balance - potBefore, amount);
    }

    function configureCoinFees(bool burn) external {
        vm.prank(timelock);
        locked.setCoinFeeTo(burn ? address(0) : actors[0]);
    }

    function advance(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1, 30 days));
        vm.roll(block.number + 1);
    }

    function rejectedCalls(uint256 actorSeed, uint256 op) external {
        address actor = actors[actorSeed % 3];
        vm.startPrank(actor);
        if (op % 4 == 0) {
            vm.expectRevert(IMD6900RobinhoodLaunch.NotTimelock.selector);
            launch.releaseExcess(0, actor);
        } else if (op % 4 == 1) {
            vm.expectRevert(IMD6900LockedPool.OnlyTimelock.selector);
            locked.lowerFee(0);
        } else if (op % 4 == 2) {
            vm.expectRevert(IMD6900LockedPool.NotRefunded.selector);
            locked.feeCheckpoint();
        } else {
            vm.expectRevert(IMD6900LockedPool.NoCheckpoint.selector);
            locked.feeRefund(actor);
        }
        vm.stopPrank();
        // the owner cannot walk away from the claims, and the timelock cannot "release" held coins to the launch itself
        vm.prank(team);
        vm.expectRevert(IMD6900RobinhoodLaunch.NoRenounce.selector);
        launch.renounceOwnership();
        vm.prank(timelock);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadTo.selector);
        launch.releaseExcess(1, address(launch));
        assertEq(launch.owner(), team);
    }

    function _position(PoolId id) internal view returns (uint128 liquidity) {
        (liquidity,,) = manager.getPositionInfo(id, address(locked), locked.LOWER_TICK(), locked.upperTick(), 0);
    }

    function retiredCount() external view returns (uint256) {
        return retiredPools.length;
    }

    function _leaf(uint256 i) internal view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(actors[i], allocations[i]))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _proof(uint256 i) internal view returns (bytes32[] memory p) {
        p = new bytes32[](i == 2 ? 1 : 2);
        if (i == 2) {
            p[0] = _pair(_leaf(0), _leaf(1));
        } else {
            p[0] = _leaf(1 - i);
            p[1] = _leaf(2);
        }
    }

    receive() external payable {}
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchInvariantTest is LaunchFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    LaunchSequenceHandler internal handler;
    address[] internal holders;
    uint256 internal initialEth;
    uint128 internal initialLiquidity;

    function setUp() public override {
        super.setUp();
        _start();
        LiquidityAdder adder = _imdLiquidity();
        RefundingEngine engine = new RefundingEngine(manager, locked);
        vm.deal(address(engine), 30 ether);
        vm.startPrank(TIMELOCK);
        hook.setPerpEngine(address(engine));
        hook.setPerpRefunded(true);
        vm.stopPrank();
        handler = new LaunchSequenceHandler(launch, legacy, trader, engine, users, allocations);
        vm.deal(address(handler), 100 ether);
        holders.push(address(manager));
        holders.push(address(locked));
        holders.push(address(launch));
        holders.push(address(trader));
        holders.push(address(engine));
        holders.push(address(adder));
        holders.push(address(handler));
        holders.push(TEAM);
        holders.push(TIMELOCK);
        holders.push(launch.POT_BRIDGE());
        holders.push(launch.IMD_BURN());
        holders.push(address(handler.refuser()));
        for (uint256 i; i < 3; ++i) {
            holders.push(users[i]);
        }
        for (uint256 i; i < holders.length; ++i) {
            initialEth += holders[i].balance;
        }
        initialLiquidity = locked.liquidity();

        bytes4[] memory selectors = new bytes4[](24);
        selectors[21] = handler.configurePayees.selector;
        selectors[22] = handler.toggleRefusal.selector;
        selectors[23] = handler.splitChecked.selector;
        selectors[0] = handler.claim.selector;
        selectors[1] = handler.trade.selector;
        selectors[2] = handler.refundedTrade.selector;
        selectors[3] = handler.transferCoin.selector;
        selectors[4] = handler.donateCoin.selector;
        selectors[5] = handler.donateEth.selector;
        selectors[6] = handler.collect.selector;
        selectors[7] = handler.split.selector;
        selectors[8] = handler.lowerFee.selector;
        selectors[9] = handler.sellHeld.selector;
        selectors[10] = handler.releaseExcess.selector;
        selectors[11] = handler.closeClaims.selector;
        selectors[12] = handler.releaseLegacy.selector;
        selectors[13] = handler.burnCoin.selector;
        selectors[14] = handler.burnImd.selector;
        selectors[15] = handler.recoverEth.selector;
        selectors[16] = handler.perpFees.selector;
        selectors[17] = handler.configureCoinFees.selector;
        selectors[18] = handler.advance.selector;
        selectors[19] = handler.rejectedCalls.selector;
        // More claim opportunities before the one-way close action.
        selectors[20] = handler.claim.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// Exact custody identities; includes gifts so unsolicited tokens cannot
    /// create a false insolvency failure or hide a lost claim reserve.
    function invariant_ClaimsAndHeldCoinsStayFullyBacked() public view {
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            uint256 claimed = handler.ghostClaimed(i);
            assertEq(launch.claimedBy(users[i]), claimed);
            assertLe(claimed, allocations[i]);
            total += claimed;
            assertEq(legacy.balanceOf(users[i]), allocations[i] - claimed);
        }
        assertEq(launch.claimedTotal(), total);
        assertLe(total, launch.claimTotal());
        assertEq(legacy.balanceOf(address(launch)) + handler.ghostLegacyReleased(), total);
        assertEq(legacy.balanceOf(TEAM), handler.ghostLegacyReleased());
        assertEq(launch.unclaimedReleased(), handler.ghostClosed());
        assertEq(launch.claimReserve(), handler.ghostClosed() ? 0 : launch.claimTotal() - total);
        assertEq(
            coin.balanceOf(address(launch)),
            launch.claimReserve() + launch.excessHeld() + handler.ghostCoinDonatedToLaunch()
        );
    }

    /// All addresses that can receive ETH or either token are enumerated. This
    /// independently constrains ledger totals and the burn ghost across swaps.
    function invariant_ValueIsConservedAndOnlyExplicitBurnsReduceSupply() public view {
        uint256 nativeTotal;
        uint256 coinTotal;
        uint256 imdTotal;
        for (uint256 i; i < holders.length; ++i) {
            nativeTotal += holders[i].balance;
            coinTotal += coin.balanceOf(holders[i]);
            imdTotal += MockImdstr(launch.IMD()).balanceOf(holders[i]);
        }
        assertEq(nativeTotal, initialEth, "no ETH appears or escapes custody");
        assertEq(coinTotal, coin.totalSupply(), "sum of balances equals supply");
        assertEq(coin.totalSupply() + handler.ghostBurned(), SUPPLY, "only accounted burns reduce supply");
        assertEq(imdTotal, 1e30, "buying for the executor transfers, not mints, IMD");
        assertEq(launch.imdBurned(), handler.ghostImdDelivered());
        assertEq(MockImdstr(launch.IMD()).balanceOf(launch.IMD_BURN()), handler.ghostImdDelivered());
        assertLe(launch.imdBucket(), address(launch).balance, "burn ETH is always backed");
    }

    /// The owed ledger: what the split booked to refusing payees is backed by ETH held here beside the burn's
    /// bucket, and the total agrees with the per-payee books of everyone the split could ever have booked.
    function invariant_RefusedSharesStayBookedAndBacked() public view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            sum += launch.owed(handler.payeesSeen(i));
        }
        assertEq(launch.owedTotal(), sum, "the books add up to the total");
        assertLe(launch.owedTotal() + launch.imdBucket(), address(launch).balance, "booked and reserved ETH is held");
        assertEq(launch.owed(launch.imdBurn()), 0, "the burn's share is reserved, never booked");
        assertEq(launch.owner(), TEAM, "the owner never changes nor renounces");
    }

    /// Principal remains a v4 position owned only by the locked pool, including
    /// when the market price is outside its active range.
    function invariant_LiquidityStaysLockedAndRetiredPoolsStayEmpty() public view {
        PoolId current = locked.poolId();
        (uint128 position,,) =
            manager.getPositionInfo(current, address(locked), locked.LOWER_TICK(), locked.upperTick(), 0);
        assertEq(position, locked.liquidity());
        assertGt(position, 0);
        assertApproxEqRel(position, initialLiquidity, 1e11, "only cumulative rounding can reduce principal");
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(current));
        assertLe(locked.fee(), 44_400);
        for (uint256 i; i < handler.retiredCount(); ++i) {
            PoolId retired = handler.retiredPools(i);
            (uint128 oldPosition,,) =
                manager.getPositionInfo(retired, address(locked), locked.LOWER_TICK(), locked.upperTick(), 0);
            assertEq(oldPosition, 0);
            assertEq(manager.getLiquidity(retired), 0);
        }
    }

    /// Pins a reachable mixed sequence alongside the random campaigns. The
    /// counters ensure the handlers actually trade, claim, refund and migrate.
    function test_HandlerExercisesMixedCustodySequence() public {
        handler.claim(0, 100 ether);
        handler.trade(true, 1 ether);
        handler.refundedTrade(true, 1 ether);
        handler.refundedTrade(false, 100 ether);
        handler.trade(false, 100 ether);
        handler.donateCoin(0, 2 ether, true);
        handler.donateCoin(0, 1 ether, false);
        handler.donateEth(0.5 ether, true);
        handler.collect(true);
        handler.burnImd(true);
        handler.lowerFee(33_300);
        handler.configureCoinFees(false);
        handler.trade(false, 100 ether);
        handler.collect(false);
        handler.configurePayees(1);
        handler.donateEth(1 ether, false);
        handler.splitChecked(); // the refuser's half is booked
        handler.donateEth(1 ether, false);
        handler.splitChecked(); // and again, on top
        handler.toggleRefusal(false);
        handler.donateEth(1 ether, false);
        handler.splitChecked(); // paid all of it
        handler.toggleRefusal(true);
        handler.donateEth(1 ether, false);
        handler.splitChecked();
        handler.recoverEth(type(uint256).max); // all of it: the books are cancelled, the bucket emptied
        handler.releaseLegacy(50 ether);
        handler.sellHeld(100 ether);
        handler.releaseExcess(100 ether, true);
        handler.closeClaims(true, 0);
        handler.perpFees(0.1 ether);
        handler.rejectedCalls(1, 2);
        invariant_ClaimsAndHeldCoinsStayFullyBacked();
        invariant_ValueIsConservedAndOnlyExplicitBurnsReduceSupply();
        invariant_LiquidityStaysLockedAndRetiredPoolsStayEmpty();
        invariant_RefusedSharesStayBookedAndBacked();
        assertGt(handler.claimsExecuted(), 0);
        assertGt(handler.tradesExecuted(), 0);
        assertGt(handler.refundsExecuted(), 0);
        assertGt(handler.collectionsExecuted(), 0);
        assertGt(handler.migrationsExecuted(), 0);
        assertEq(handler.refusalsBooked(), 3);
        assertEq(handler.booksCancelled(), 1);
        assertEq(launch.owedTotal(), 0);
        assertEq(launch.imdBucket(), 0);
    }
}
