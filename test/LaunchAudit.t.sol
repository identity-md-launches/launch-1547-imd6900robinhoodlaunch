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
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IMD6900RobinhoodLaunch} from "../src/IMD6900RobinhoodLaunch.sol";
import {IMD6900} from "../src/IMD6900.sol";
import {MockImdstr, Trader, LiquidityAdder} from "./IMD6900RobinhoodLaunch.t.sol";
import {HookSalt, CoinSalt} from "./HookSalt.sol";

/// Regression tests for the three actionable imported audit findings, using the real v4 PoolManager.
contract LaunchAuditTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    address constant OWNER = address(0xA11CE);
    address constant TL = address(0x71E10C);
    address constant A = address(0xA);
    address constant B = address(0xB);
    uint256 constant AA = 40_000_000 ether;
    uint256 constant BB = 20_000_000 ether;
    uint256 constant RESERVE = 50_000_000 ether;

    IPoolManager pm;
    IMD6900RobinhoodLaunch launch;
    MockImdstr oldToken;
    bytes32 coinSalt;

    function setUp() public {
        pm = IPoolManager(address(new PoolManager(address(this))));
        oldToken = new MockImdstr();
        launch = new IMD6900RobinhoodLaunch(OWNER, pm, address(oldToken), TL);
        launch.createHook(HookSalt.mine(launch));
        coinSalt = CoinSalt.mine(launch);
        vm.prank(TL);
        launch.setImdKeeper(address(this)); // this test runs the burns
    }

    // d7faa1b3073d: the same 10 ETH sandwich loses money around one 0.1 ETH burn,
    // but used to profit by looping over the entire ~0.678 ETH bucket in one transaction.
    function test_SingleBurnSandwichControl() public {
        _imdPool(2e20);
        _launch();
        _earnBurnFees();
        Trader attacker = _frontRun();
        launch.burnImd(0);
        _backRun(attacker);
        emit log_named_decimal_uint("single-burn attacker ETH", address(attacker).balance, 18);
        assertLt(address(attacker).balance, 100 ether);
    }

    function test_BurnLoopCannotSandwichWholeBucket() public {
        _imdPool(2e20);
        _launch();
        _earnBurnFees();
        uint256 bucket = launch.imdBucket();
        Trader attacker = _frontRun();
        for (uint256 i; i < 8; ++i) {
            try launch.burnImd(0) {} catch {}
        }
        _backRun(attacker);
        emit log_named_decimal_uint("looped-burn attacker ETH", address(attacker).balance, 18);
        emit log_named_decimal_uint("burn bucket spent", bucket - launch.imdBucket(), 18);
        assertLe(address(attacker).balance, 100 ether, "looping the burn must not make this sandwich profitable");
        assertEq(bucket - launch.imdBucket(), 0.1 ether, "the cap applies across calls");
    }

    // 1e3202b54640: no ETH leaves an initialized empty pool, so no reserved burn ETH may be written off.
    function test_EmptyImdPoolDoesNotWriteOffBucket() public {
        _imdPool(0);
        _launch();
        _earnBurnFees();
        uint256 bucket = launch.imdBucket();
        uint256 balance = address(launch).balance;
        uint256 potBalance = launch.POT_BRIDGE().balance;
        try launch.burnImd(0) {} catch {}
        assertEq(balance - address(launch).balance, 0, "empty pool spends nothing");
        assertEq(launch.imdBucket(), bucket, "unspent ETH remains reserved for the burn");
        assertEq(launch.imdBurned(), 0);
        assertEq(launch.split(), balance - bucket, "only pre-existing rounding dust is unreserved");
        assertEq(launch.POT_BRIDGE().balance, potBalance);
    }

    function test_BurnCapIsSharedAcrossCallersAndResetsOnNextBlock() public {
        _imdPool(2e20);
        _launch();
        _earnBurnFees();
        uint256 bucket = launch.imdBucket();
        uint256 nextBlock = block.number + 1;
        vm.prank(TL);
        launch.setImdKeeper(A);
        vm.prank(A);
        uint256 first = launch.burnImd(0);
        assertEq(launch.nextImdBurnBlock(), nextBlock);
        // A new keeper and a later timestamp cannot bypass a cap for the same block.number.
        vm.warp(block.timestamp + 60);
        vm.prank(TL);
        launch.setImdKeeper(B);
        vm.prank(B);
        vm.expectRevert(IMD6900RobinhoodLaunch.BurnRateLimited.selector);
        launch.burnImd(0);
        assertEq(launch.imdBucket(), bucket - 0.1 ether);
        vm.roll(nextBlock);
        vm.prank(B);
        uint256 second = launch.burnImd(0);
        assertEq(launch.imdBucket(), bucket - 0.2 ether);
        assertEq(launch.imdBurned(), first + second);
        assertEq(MockImdstr(launch.IMD()).balanceOf(launch.imdBurn()), first + second);
    }

    function test_SmallBurnCannotBeRefilledAndRepeatedInSameBlock() public {
        _imdPool(2e20);
        _launch();
        launch.harvest();
        uint256 smallBucket = launch.imdBucket();
        assertGt(smallBucket, 0);
        assertLt(smallBucket, 0.1 ether);
        launch.burnImd(0);
        assertEq(launch.imdBucket(), 0);
        _earnBurnFees();
        vm.expectRevert(IMD6900RobinhoodLaunch.BurnRateLimited.selector);
        launch.burnImd(0);
        vm.roll(block.number + 1);
        assertGt(launch.burnImd(0), 0);
    }

    function test_BucketCanDrainAcrossBlocksStartingAtBlockZero() public {
        _imdPool(2e20);
        _launch();
        _earnBurnFees();
        vm.roll(0); // zero is a valid first block; it must not be mistaken for an already-used block.
        uint256 balance = address(launch).balance;
        uint256 bucket = launch.imdBucket();
        uint256 totalBought;
        uint256 calls;
        while (launch.imdBucket() != 0) {
            uint256 before = launch.imdBucket();
            totalBought += launch.burnImd(0);
            uint256 spent = before - launch.imdBucket();
            assertEq(spent, before < 0.1 ether ? before : 0.1 ether);
            ++calls;
            vm.roll(calls); // an explicit counter avoids solc caching block.number within this test transaction.
        }
        assertEq(calls, 7);
        assertEq(balance - address(launch).balance, bucket);
        assertEq(MockImdstr(launch.IMD()).balanceOf(launch.imdBurn()), totalBought);
        vm.expectRevert(IMD6900RobinhoodLaunch.NoEth.selector);
        launch.burnImd(0);
    }

    function test_RevertedSlippageDoesNotConsumeBurnAllowance() public {
        _imdPool(2e20);
        _launch();
        _earnBurnFees();
        uint256 bucket = launch.imdBucket();
        uint256 balance = address(launch).balance;
        PoolKey memory key = launch.imdPoolKey();
        (uint160 price,,,) = pm.getSlot0(key.toId());
        vm.expectPartialRevert(IMD6900RobinhoodLaunch.Short.selector);
        launch.burnImd(type(uint256).max);
        _assertBurnUnchanged(key, price, bucket, balance);
        assertGt(launch.burnImd(0), 0, "a failed slippage check can retry in the same block");
    }

    function test_EmptyPoolFailureCanRetryAfterLiquidityReturns() public {
        _imdPool(0);
        _launch();
        _earnBurnFees();
        uint256 bucket = launch.imdBucket();
        uint256 balance = address(launch).balance;
        PoolKey memory key = launch.imdPoolKey();
        (uint160 price,,,) = pm.getSlot0(key.toId());
        vm.expectRevert(IMD6900RobinhoodLaunch.IncompleteImdBuy.selector);
        launch.burnImd(0);
        _assertBurnUnchanged(key, price, bucket, balance);
        _addImdLiquidity(2e20);
        assertGt(launch.burnImd(0), 0, "restored liquidity allows a retry in the same block");
        assertEq(launch.imdBucket(), bucket - 0.1 ether);
    }

    function test_PartialImdBuyRevertsAtomically() public {
        _imdPool(0);
        PoolKey memory key = launch.imdPoolKey();
        AuditRangeLiquidity adder = new AuditRangeLiquidity(pm);
        vm.deal(address(adder), 1 ether);
        MockImdstr(launch.IMD()).mint(address(adder), 1e24);
        adder.add(key);
        _launch();
        _earnBurnFees();
        // Establish that this live, nonempty range accepts some ETH, but cannot fill a 0.1 ETH buy.
        uint256 snapshot = vm.snapshotState();
        Trader probe = new Trader(pm);
        vm.deal(address(probe), 0.1 ether);
        BalanceDelta d = probe.swap(key, true, -0.1 ether);
        assertGt(uint128(-d.amount0()), 0);
        assertLt(uint128(-d.amount0()), 0.1 ether);
        assertGt(d.amount1(), 0);
        assertTrue(vm.revertToState(snapshot));
        uint256 bucket = launch.imdBucket();
        uint256 balance = address(launch).balance;
        (uint160 price,,,) = pm.getSlot0(key.toId());
        vm.expectRevert(IMD6900RobinhoodLaunch.IncompleteImdBuy.selector);
        launch.burnImd(0);
        _assertBurnUnchanged(key, price, bucket, balance);
    }

    // a53739e05c5d: a valid Merkle root can contain more coins than the separately entered reserve.
    function test_ClaimsCannotConsumeHeldExcess() public {
        _oversubscribedClaims();
        _launch();
        uint256 held = launch.excessHeld();
        _claimA();
        bytes32[] memory proof = _proof(_leaf(A, AA));
        vm.startPrank(B);
        oldToken.approve(address(launch), BB);
        vm.expectRevert(IMD6900RobinhoodLaunch.OverClaim.selector);
        launch.claim(BB, BB, proof);
        vm.stopPrank();
        assertEq(launch.claimedTotal(), AA);
        assertEq(launch.claimedBy(B), 0);
        assertEq(oldToken.balanceOf(B), BB, "a rejected claim takes no old tokens");
        assertEq(launch.claimReserve(), RESERVE - AA);
        assertEq(launch.excessHeld(), held);
        assertEq(IMD6900(launch.token()).balanceOf(address(launch)), held + RESERVE - AA);
        vm.prank(TL);
        launch.endClaims();
        assertEq(launch.claimReserve(), 0);
        assertEq(launch.excessHeld(), held + RESERVE - AA);
        vm.prank(TL);
        assertGt(launch.sellHeld(0, 0, TL), 0, "held coins remain sellable");
    }

    function test_ClaimsCanUseExactlyTheRemainingReserve() public {
        _oversubscribedClaims();
        _launch();
        _claimA();
        bytes32[] memory proof = _proof(_leaf(A, AA));
        vm.startPrank(B);
        oldToken.approve(address(launch), BB);
        launch.claim(RESERVE - AA, BB, proof);
        vm.expectRevert(IMD6900RobinhoodLaunch.OverClaim.selector);
        launch.claim(1, BB, proof);
        vm.stopPrank();
        assertEq(launch.claimedTotal(), RESERVE);
        assertEq(launch.claimReserve(), 0);
        assertEq(launch.claimedBy(B), RESERVE - AA);
        assertEq(IMD6900(launch.token()).balanceOf(address(launch)), launch.excessHeld());
        vm.warp(launch.claimDeadline());
        vm.prank(OWNER);
        launch.releaseUnclaimed(OWNER); // a fully used reserve closes without underflow.
        assertTrue(launch.unclaimedReleased());
    }

    function test_RejectedOverclaimDoesNotBlockUnclaimedRelease() public {
        _oversubscribedClaims();
        _launch();
        _claimA();
        bytes32[] memory proof = _proof(_leaf(A, AA));
        vm.startPrank(B);
        oldToken.approve(address(launch), BB);
        vm.expectRevert(IMD6900RobinhoodLaunch.OverClaim.selector);
        launch.claim(BB, BB, proof);
        vm.stopPrank();
        vm.warp(launch.claimDeadline());
        vm.prank(OWNER);
        launch.releaseUnclaimed(OWNER);
        assertEq(IMD6900(launch.token()).balanceOf(OWNER), RESERVE - AA);
        assertEq(launch.claimReserve(), 0);
        assertEq(IMD6900(launch.token()).balanceOf(address(launch)), launch.excessHeld());
    }

    function testFuzz_ClaimReserveBoundsBothClaimOrders(bool bFirst, uint256 secondAmount) public {
        _oversubscribedClaims();
        _launch();
        address first = bFirst ? B : A;
        address second = bFirst ? A : B;
        uint256 firstAllowance = bFirst ? BB : AA;
        uint256 secondAllowance = bFirst ? AA : BB;
        bytes32[] memory firstProof = _proof(_leaf(second, secondAllowance));
        bytes32[] memory secondProof = _proof(_leaf(first, firstAllowance));
        vm.startPrank(first);
        oldToken.approve(address(launch), firstAllowance);
        launch.claim(firstAllowance, firstAllowance, firstProof);
        vm.stopPrank();
        secondAmount = bound(secondAmount, 1, secondAllowance);
        vm.startPrank(second);
        oldToken.approve(address(launch), secondAllowance);
        if (secondAmount > RESERVE - firstAllowance) vm.expectRevert(IMD6900RobinhoodLaunch.OverClaim.selector);
        launch.claim(secondAmount, secondAllowance, secondProof);
        vm.stopPrank();
        assertLe(launch.claimedTotal(), RESERVE);
        assertEq(launch.claimReserve(), RESERVE - launch.claimedTotal());
        assertEq(oldToken.balanceOf(address(launch)), launch.claimedTotal());
        assertEq(IMD6900(launch.token()).balanceOf(address(launch)), launch.claimReserve() + launch.excessHeld());
    }

    function _imdPool(uint256 liquidity) internal {
        vm.etch(launch.IMD(), address(new MockImdstr()).code);
        PoolKey memory key = launch.imdPoolKey();
        pm.initialize(key, uint160(_sqrt(261 << 192)));
        if (liquidity != 0) _addImdLiquidity(liquidity);
    }

    function _addImdLiquidity(uint256 liquidity) internal {
        LiquidityAdder adder = new LiquidityAdder(pm);
        vm.deal(address(adder), 100 ether);
        MockImdstr(launch.IMD()).mint(address(adder), 1e30);
        adder.add(launch.imdPoolKey(), liquidity);
    }

    function _assertBurnUnchanged(PoolKey memory key, uint160 price, uint256 bucket, uint256 balance) internal view {
        assertEq(launch.imdBucket(), bucket);
        assertEq(address(launch).balance, balance);
        assertEq(launch.imdBurned(), 0);
        assertEq(launch.nextImdBurnBlock(), 0);
        assertEq(MockImdstr(launch.IMD()).balanceOf(launch.imdBurn()), 0);
        assertEq(MockImdstr(launch.IMD()).balanceOf(address(launch)), 0);
        (uint160 afterPrice,,,) = pm.getSlot0(key.toId());
        assertEq(afterPrice, price, "a rejected buy must also roll back the pool's price");
    }

    function _launch() internal {
        address expected = launch.tokenAddress(coinSalt);
        uint160 price = uint160(_sqrt(FullMath.mulDiv(1_000_000_000 ether, 1 << 192, 19.18 ether)));
        vm.deal(OWNER, 2.81 ether);
        vm.prank(OWNER);
        launch.launch{value: 2.81 ether}(coinSalt, expected, price, 0, address(launch));
    }

    function _earnBurnFees() internal {
        Trader buyer = new Trader(pm);
        vm.deal(address(buyer), 150 ether);
        buyer.swap(launch.pool().poolKey(), true, -150 ether);
        launch.harvest();
        assertGt(launch.imdBucket(), 0.6 ether);
        assertApproxEqAbs(address(launch).balance, launch.imdBucket(), 1, "at most one wei of split rounding dust");
    }

    function _frontRun() internal returns (Trader attacker) {
        attacker = new Trader(pm);
        vm.deal(address(attacker), 100 ether);
        attacker.swap(launch.imdPoolKey(), true, -10 ether);
    }

    function _backRun(Trader attacker) internal {
        uint256 imd = MockImdstr(launch.IMD()).balanceOf(address(attacker));
        attacker.swap(launch.imdPoolKey(), false, -int256(imd));
    }

    function _oversubscribedClaims() internal {
        bytes32 a = _leaf(A, AA);
        bytes32 b = _leaf(B, BB);
        bytes32 root = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        vm.prank(OWNER);
        launch.setClaims(root, RESERVE, block.timestamp + 100 days);
        oldToken.mint(A, AA);
        oldToken.mint(B, BB);
    }

    function _claimA() internal {
        bytes32[] memory proof = _proof(_leaf(B, BB));
        vm.startPrank(A);
        oldToken.approve(address(launch), AA);
        launch.claim(AA, AA, proof);
        vm.stopPrank();
    }

    function _leaf(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    function _proof(bytes32 sibling) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = sibling;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) (y, z) = (z, (x / z + z) / 2);
    }
}

/// Supplies a narrow active range around the fixture's 261 IMD/ETH price, exhausted by a 0.1 ETH buy.
contract AuditRangeLiquidity {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    IPoolManager immutable pm;
    PoolKey key;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function add(PoolKey memory key_) external {
        key = key_;
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(pm));
        (, int24 tick,,) = pm.getSlot0(key.toId());
        int24 lower = tick - tick % key.tickSpacing;
        (BalanceDelta d,) = pm.modifyLiquidity(key, ModifyLiquidityParams(lower, lower + key.tickSpacing, 1e18, 0), "");
        pm.settle{value: uint128(-d.amount0())}();
        pm.sync(key.currency1);
        MockImdstr(Currency.unwrap(key.currency1)).transfer(address(pm), uint128(-d.amount1()));
        pm.settle();
        return "";
    }
}
