// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchFixture} from "./helpers/LaunchFixture.sol";
import {IMD6900RobinhoodLaunch} from "src/IMD6900RobinhoodLaunch.sol";
import {IMD6900LockedPool} from "src/IMD6900LockedPool.sol";
import {IMD6900Hook} from "src/IMD6900Hook.sol";
import {IMD6900} from "src/IMD6900.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract RefusingReceiver {
    receive() external payable {
        revert("receiver refuses ETH");
    }
}

contract ReenterSplitReceiver {
    IMD6900RobinhoodLaunch immutable target;
    bool public attempted;
    bool public reentered;
    bytes public reason;

    constructor(IMD6900RobinhoodLaunch target_) {
        target = target_;
    }

    receive() external payable {
        attempted = true;
        (reentered, reason) = address(target).call(abi.encodeCall(target.split, ()));
    }
}

contract LaunchPreconditionTest is LaunchFixture {
    function test_OperationsBeforeLaunchRejectWithoutMovingFunds() public {
        vm.expectRevert(IMD6900RobinhoodLaunch.NotLaunched.selector);
        launch.claim(1, allocations[0], _proof(0));
        vm.expectRevert(IMD6900RobinhoodLaunch.NotLaunched.selector);
        launch.split();
        vm.prank(TEAM);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotLaunched.selector);
        launch.releaseUnclaimed(users[0]);
        vm.prank(TIMELOCK);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotLaunched.selector);
        launch.endClaims();
        vm.prank(TIMELOCK);
        vm.expectRevert(IMD6900LockedPool.NotOpen.selector);
        locked.lowerFee(33_300);
        vm.expectRevert(IMD6900LockedPool.NotOpen.selector);
        locked.collect();
        vm.expectRevert(IMD6900RobinhoodLaunch.NoEth.selector);
        launch.burnImd(0);
        assertEq(launch.claimedTotal(), 0);
    }

    function test_ClaimsRootAndTotalMustAgreeAndRejectionPreservesOldList() public {
        bytes32 root = launch.claimRoot();
        uint256 deadline = launch.claimDeadline();
        vm.startPrank(TEAM);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadClaims.selector);
        launch.setClaims(bytes32(0), 1, deadline);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadClaims.selector);
        launch.setClaims(root, 0, deadline);
        vm.stopPrank();
        assertEq(launch.claimRoot(), root);
        assertEq(launch.claimTotal(), 60_000_000 ether);
        assertEq(launch.claimDeadline(), deadline);
    }

    function test_OneSecondShortClaimWindowRollsBackAndCanRetry() public {
        vm.prank(TEAM);
        launch.setClaims(_root(), 60_000_000 ether, block.timestamp + 90 days - 1);
        address predicted = launch.tokenAddress(salt);
        vm.deal(TEAM, OPENING_BUY);
        vm.prank(TEAM);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadClaims.selector);
        launch.launch{value: OPENING_BUY}(
            salt, predicted, TickMath.getSqrtPriceAtTick(OPENING_TICK), 0, address(launch)
        );
        _assertUnlaunched(predicted);
        assertEq(TEAM.balance, OPENING_BUY);
        vm.prank(TEAM);
        launch.setClaims(_root(), 60_000_000 ether, block.timestamp + 90 days);
        _start();
        assertEq(address(coin), predicted);
    }

    function test_ZeroEthLaunchRevertsAllCreationAndLiquidity() public {
        address predicted = launch.tokenAddress(salt);
        vm.prank(TEAM);
        vm.expectRevert(IMD6900RobinhoodLaunch.NoEth.selector);
        launch.launch(salt, predicted, TickMath.getSqrtPriceAtTick(OPENING_TICK), 0, address(launch));
        _assertUnlaunched(predicted);
        _start(); // same salt remains usable after rollback
    }

    function test_MinimumBuyFailureRollsBackEthCoinAndPool() public {
        address predicted = launch.tokenAddress(salt);
        vm.deal(TEAM, OPENING_BUY);
        vm.prank(TEAM);
        vm.expectPartialRevert(IMD6900RobinhoodLaunch.Short.selector);
        launch.launch{value: OPENING_BUY}(
            salt, predicted, TickMath.getSqrtPriceAtTick(OPENING_TICK), type(uint256).max, address(launch)
        );
        _assertUnlaunched(predicted);
        assertEq(TEAM.balance, OPENING_BUY);
        _start();
    }

    function test_PoolRejectsInvalidAndCollapsedPriceRanges() public {
        // Calling as the real launcher isolates the pool's own validation.
        vm.startPrank(address(launch));
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, uint160(0)));
        locked.open(address(legacy), 0, 1);
        vm.expectRevert(IMD6900LockedPool.BadPrice.selector);
        locked.open(address(legacy), TickMath.getSqrtPriceAtTick(-887_220), 1);
        vm.stopPrank();
        assertEq(locked.token(), address(0));
        assertEq(locked.liquidity(), 0);
    }

    function test_PoolRejectsZeroLiquidityAtomically() public {
        vm.startPrank(address(launch));
        legacy.approve(address(locked), 0);
        vm.expectRevert(IMD6900LockedPool.ZeroLiquidity.selector);
        locked.open(address(legacy), TickMath.getSqrtPriceAtTick(OPENING_TICK), 0);
        vm.stopPrank();
        assertEq(locked.token(), address(0));
        assertEq(locked.upperTick(), 0);
    }

    function test_OnlyLauncherCanWireAndOpenAndHookCannotBeReplaced() public {
        vm.expectRevert(IMD6900LockedPool.OnlyLauncher.selector);
        locked.setHook(address(hook));
        vm.expectRevert(IMD6900LockedPool.OnlyLauncher.selector);
        locked.open(address(legacy), TickMath.getSqrtPriceAtTick(OPENING_TICK), 1);
        vm.prank(address(launch));
        vm.expectRevert(IMD6900LockedPool.HookAlreadySet.selector);
        locked.setHook(users[0]);
        assertEq(locked.hook(), address(hook));
    }

    function test_WithdrawFailureAndZeroBalanceAreAtomic() public {
        vm.prank(TEAM);
        vm.expectRevert(IMD6900RobinhoodLaunch.NoEth.selector);
        launch.withdrawEth(TEAM, 0);
        vm.deal(address(launch), 1 ether);
        RefusingReceiver receiver = new RefusingReceiver();
        vm.startPrank(TEAM);
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        launch.withdrawEth(address(receiver), 0);
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        launch.withdrawEth(TEAM, 1 ether + 1);
        launch.withdrawEth(TEAM, 0);
        vm.stopPrank();
        assertEq(address(launch).balance, 0);
        assertEq(TEAM.balance, 1 ether);
    }

    function _assertUnlaunched(address predicted) internal view {
        assertEq(predicted.code.length, 0);
        assertEq(launch.token(), address(0));
        assertEq(locked.token(), address(0));
        assertEq(locked.liquidity(), 0);
        assertEq(launch.launchBought(), 0);
        assertEq(launch.excessHeld(), 0);
        assertEq(address(manager).balance, 0);
        assertEq(address(launch).balance, 0);
    }
}

contract LaunchCustodyFailureTest is LaunchFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        _start();
    }

    function test_ClaimZeroAndMaximumCannotConsumeReserve() public {
        bytes32 state = _financialState();
        bytes32[] memory proof = _proof(0);
        vm.startPrank(users[0]);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        launch.claim(0, allocations[0], proof);
        vm.expectRevert(IMD6900RobinhoodLaunch.OverClaim.selector);
        launch.claim(type(uint256).max, allocations[0], proof);
        vm.stopPrank();
        assertEq(_financialState(), state);
        assertEq(legacy.balanceOf(address(launch)), 0);
    }

    function test_FailedOldTokenTransferDoesNotConsumeClaim() public {
        vm.prank(users[0]);
        legacy.approve(address(launch), 0);
        bytes32[] memory proof = _proof(0);
        bytes32 state = _financialState();
        vm.prank(users[0]);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        launch.claim(1 ether, allocations[0], proof);
        assertEq(launch.claimedBy(users[0]), 0);
        assertEq(_financialState(), state);
        vm.prank(users[0]);
        legacy.approve(address(launch), 1 ether);
        _claim(0, 1 ether);
        assertEq(coin.balanceOf(users[0]), 1 ether);
    }

    function test_ProofCannotBeReusedByAnotherAccountOrForAnotherAllocation() public {
        bytes32[] memory proof = _proof(0);
        vm.prank(users[1]);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadProof.selector);
        launch.claim(1, allocations[0], proof);
        vm.prank(users[0]);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadProof.selector);
        launch.claim(1, allocations[0] + 1, proof);
        proof[0] = keccak256("not a sibling");
        vm.prank(users[0]);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadProof.selector);
        launch.claim(1, allocations[0], proof);
        assertEq(launch.claimedTotal(), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ClaimPartitionExchangesExactlyOneForOne(uint256 first, uint8 which) public {
        uint256 i = which % 3;
        uint256 allocation = allocations[i];
        first = bound(first, 1, allocation);
        uint256 reserve = launch.claimReserve();
        _claim(i, first);
        if (first < allocation) _claim(i, allocation - first);
        assertEq(coin.balanceOf(users[i]), allocation);
        assertEq(legacy.balanceOf(users[i]), 0);
        assertEq(legacy.balanceOf(address(launch)), allocation);
        assertEq(launch.claimedBy(users[i]), allocation);
        assertEq(launch.claimReserve(), reserve - allocation);
        assertEq(coin.balanceOf(address(launch)), launch.claimReserve() + launch.excessHeld());
        bytes32[] memory proof = _proof(i);
        vm.prank(users[i]);
        vm.expectRevert(IMD6900RobinhoodLaunch.OverClaim.selector);
        launch.claim(1, allocation, proof);
    }

    function test_DeadlineBoundaryAndClaimClosureCannotReopen() public {
        uint256 deadline = launch.claimDeadline();
        vm.warp(deadline - 1);
        vm.prank(TEAM);
        vm.expectRevert(IMD6900RobinhoodLaunch.ClaimsOpen.selector);
        launch.releaseUnclaimed(users[0]);
        _claim(1, 1 ether);
        uint256 left = launch.claimReserve();
        vm.warp(deadline);
        vm.prank(TEAM);
        launch.releaseUnclaimed(users[0]);
        assertEq(coin.balanceOf(users[0]), left);
        assertEq(launch.claimReserve(), 0);
        vm.prank(TEAM);
        vm.expectRevert(IMD6900RobinhoodLaunch.AlreadyReleased.selector);
        launch.releaseUnclaimed(users[0]);
        vm.prank(TIMELOCK);
        vm.expectRevert(IMD6900RobinhoodLaunch.AlreadyReleased.selector);
        launch.endClaims();
        bytes32[] memory proof = _proof(0);
        vm.prank(users[0]);
        vm.expectRevert(IMD6900RobinhoodLaunch.AlreadyReleased.selector);
        launch.claim(1, allocations[0], proof);
        vm.prank(TEAM);
        vm.expectRevert(IMD6900RobinhoodLaunch.AlreadyLaunched.selector);
        launch.setClaims(_root(), 60_000_000 ether, deadline + 90 days);
    }

    function test_SellSlippageAndRefusingRecipientRollBackSwapAndRefund() public {
        bytes32 state = _financialState();
        vm.prank(TIMELOCK);
        vm.expectPartialRevert(IMD6900RobinhoodLaunch.Short.selector);
        launch.sellHeld(0, type(uint256).max, TEAM);
        assertEq(_financialState(), state);
        RefusingReceiver receiver = new RefusingReceiver();
        vm.prank(TIMELOCK);
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        launch.sellHeld(0, 0, address(receiver));
        assertEq(_financialState(), state);
        vm.prank(TIMELOCK);
        uint256 got = launch.sellHeld(0, 0, TEAM);
        assertGt(got, 0, "both failures leave the held coins sellable");
        assertEq(coin.balanceOf(address(launch)), launch.claimReserve() + launch.excessHeld());
    }

    function test_ReleaseExcessBurnsOnlyExcessAndRejectsOverdraw() public {
        uint256 held = launch.excessHeld();
        uint256 reserve = launch.claimReserve();
        vm.prank(TIMELOCK);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        launch.releaseExcess(held + 1, users[0]);
        vm.prank(TIMELOCK);
        launch.releaseExcess(0, address(0));
        assertEq(coin.totalSupply(), SUPPLY - held);
        assertEq(coin.balanceOf(address(launch)), reserve);
        vm.startPrank(TIMELOCK);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        launch.releaseExcess(0, users[0]);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        launch.sellHeld(0, 0, TEAM);
        vm.stopPrank();
        _claim(0, allocations[0]);
        assertEq(coin.balanceOf(users[0]), allocations[0], "excess operations never spend claims");
    }

    function test_LegacyReleaseChecksCustodyAndCannotSpendNewCoins() public {
        vm.prank(TEAM);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        launch.releaseImdstr(0, TEAM);
        _claim(0, 2 ether);
        uint256 newHeld = coin.balanceOf(address(launch));
        vm.startPrank(TEAM);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        launch.releaseImdstr(2 ether + 1, TEAM);
        launch.releaseImdstr(1 ether, TEAM);
        launch.releaseImdstr(0, TEAM);
        vm.stopPrank();
        assertEq(legacy.balanceOf(TEAM), 2 ether);
        assertEq(legacy.balanceOf(address(launch)), 0);
        assertEq(coin.balanceOf(address(launch)), newHeld);
    }

    function test_RawCallbacksCannotBeSpoofed() public {
        bytes32 state = _financialState();
        uint256 held = launch.excessHeld();
        vm.expectRevert(IMD6900RobinhoodLaunch.OnlyPoolManager.selector);
        launch.unlockCallback(abi.encode(uint8(2), held));
        vm.expectRevert(IMD6900LockedPool.OnlyPoolManager.selector);
        locked.unlockCallback(abi.encode(uint8(1), uint128(0)));
        assertEq(_financialState(), state);
    }

    function test_AllTimelockCustodyFunctionsRejectTeamAndStrangers() public {
        bytes[] memory calls = new bytes[](7);
        calls[0] = abi.encodeCall(launch.recoverEth, (users[0], 0));
        calls[1] = abi.encodeCall(launch.releaseExcess, (0, users[0]));
        calls[2] = abi.encodeCall(launch.sellHeld, (0, 0, users[0]));
        calls[3] = abi.encodeCall(launch.endClaims, ());
        calls[4] = abi.encodeCall(launch.setImdBurn, (users[0]));
        calls[5] = abi.encodeCall(launch.setPerpFeeTo, (users[0]));
        calls[6] = abi.encodeCall(launch.setImdPool, (uint24(3000), int24(60), address(0)));
        bytes32 state = _financialState();
        for (uint256 i; i < calls.length; ++i) {
            for (uint256 j; j < 2; ++j) {
                vm.prank(j == 0 ? TEAM : users[0]);
                (bool ok, bytes memory reason) = address(launch).call(calls[i]);
                assertFalse(ok);
                assertEq(reason, abi.encodeWithSelector(IMD6900RobinhoodLaunch.NotTimelock.selector));
            }
        }
        assertEq(_financialState(), state);
    }

    function test_OwnerFunctionsRejectTimelockAndStrangers() public {
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(launch.releaseUnclaimed, (users[0]));
        calls[1] = abi.encodeCall(launch.releaseImdstr, (0, users[0]));
        calls[2] = abi.encodeCall(launch.withdrawEth, (users[0], 0));
        calls[3] = abi.encodeCall(launch.setClaims, (_root(), 1, block.timestamp));
        for (uint256 i; i < calls.length; ++i) {
            for (uint256 j; j < 2; ++j) {
                vm.prank(j == 0 ? TIMELOCK : users[0]);
                (bool ok, bytes memory reason) = address(launch).call(calls[i]);
                assertFalse(ok);
                assertEq(reason, abi.encodeWithSelector(Ownable.Unauthorized.selector));
            }
        }
    }
}

contract LaunchFeeFailureTest is LaunchFixture {
    function setUp() public override {
        super.setUp();
        _start();
    }

    function test_MalformedPayeesNeverReplaceTheWorkingSplit() public {
        (address[] memory original, uint16[] memory shares) = launch.payees();
        bytes32 originalHash = keccak256(abi.encode(original, shares));
        for (uint256 mode; mode < 6; ++mode) {
            uint256 n = mode == 0 ? 0 : mode == 1 ? 9 : 2;
            address[] memory payees = new address[](n);
            uint16[] memory bps = new uint16[](mode == 2 ? 1 : n);
            for (uint256 i; i < n; ++i) {
                payees[i] = users[i % 3];
            }
            if (bps.length >= 2) {
                bps[0] = 5000;
                bps[1] = 5000;
            }
            if (mode == 3) payees[1] = address(0);
            if (mode == 4) bps[1] = 4999;
            if (mode == 5) bps[1] = type(uint16).max;
            vm.prank(TIMELOCK);
            vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
            launch.setPayees(payees, bps);
            (address[] memory afterPayees, uint16[] memory afterShares) = launch.payees();
            assertEq(keccak256(abi.encode(afterPayees, afterShares)), originalHash);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_DefaultSplitConservesEthAndNeverResplitsBurnReserve(uint256 amount) public {
        amount = bound(amount, 0, 1_000 ether);
        vm.deal(address(launch), amount);
        address pot = launch.POT_BRIDGE();
        uint256 beforePot = pot.balance;
        launch.split();
        uint256 reserved = launch.imdBucket();
        uint256 paid = pot.balance - beforePot;
        assertEq(paid + address(launch).balance, amount);
        // 90:10 ratio up to one wei per separately rounded share.
        assertApproxEqAbs(paid, reserved * 9, 9);
        assertLe(address(launch).balance - reserved, 1);
        uint256 balance = address(launch).balance;
        launch.split();
        assertEq(launch.imdBucket(), reserved);
        assertEq(address(launch).balance, balance);
        assertEq(pot.balance, beforePot + paid);
    }

    function test_SplitDustEdgesZeroOneAndTenWei() public {
        vm.deal(address(launch), 0);
        assertEq(launch.split(), 0);
        vm.deal(address(launch), 1);
        launch.split();
        assertEq(address(launch).balance, 1);
        assertEq(launch.imdBucket(), 0);
        vm.deal(address(launch), 10);
        uint256 beforePot = launch.POT_BRIDGE().balance;
        launch.split();
        assertEq(launch.POT_BRIDGE().balance - beforePot, 9);
        assertEq(launch.imdBucket(), 1);
        assertEq(launch.split(), 0);
    }

    function test_RefusingPayeeLeavesEthRecoverableWithoutBlockingOthers() public {
        RefusingReceiver receiver = new RefusingReceiver();
        _setTwoPayees(address(receiver), users[0], 5000);
        vm.deal(address(launch), 1 ether);
        launch.split();
        assertEq(users[0].balance, 0.5 ether);
        assertEq(address(launch).balance, 0.5 ether);
        vm.prank(TIMELOCK);
        launch.recoverEth(TEAM, 0);
        assertEq(TEAM.balance, 0.5 ether);
        assertEq(address(launch).balance, 0);
    }

    function test_SplitReceiverCannotReenterAndDoubleSpend() public {
        ReenterSplitReceiver receiver = new ReenterSplitReceiver(launch);
        _setTwoPayees(address(receiver), users[0], 5000);
        vm.deal(address(launch), 1 ether);
        launch.split();
        assertTrue(receiver.attempted());
        assertFalse(receiver.reentered());
        assertEq(receiver.reason(), abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector));
        assertEq(address(receiver).balance, 0.5 ether);
        assertEq(users[0].balance, 0.5 ether);
        assertEq(address(launch).balance, 0);
    }

    function test_RecoveryClampsBurnBucketAndFailedRecoveryDoesNot() public {
        vm.deal(address(launch), 10 ether);
        launch.split();
        assertEq(launch.imdBucket(), 1 ether);
        RefusingReceiver receiver = new RefusingReceiver();
        vm.prank(TIMELOCK);
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        launch.recoverEth(address(receiver), 0);
        assertEq(launch.imdBucket(), 1 ether);
        vm.prank(TIMELOCK);
        launch.recoverEth(TEAM, 0.4 ether);
        assertEq(launch.imdBucket(), 0.6 ether);
        assertEq(launch.split(), 0);
        vm.prank(TIMELOCK);
        launch.recoverEth(TEAM, 0);
        assertEq(launch.imdBucket(), 0);
        assertEq(TEAM.balance, 1 ether);
        vm.prank(TIMELOCK);
        vm.expectRevert(IMD6900RobinhoodLaunch.NoEth.selector);
        launch.recoverEth(TEAM, 0);
    }

    function test_PerpFeesRejectBadDestinationsAndReturnFundsIfReceiverRefuses() public {
        vm.startPrank(TIMELOCK);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        launch.setPerpFeeTo(address(launch));
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        launch.setPerpFeeTo(address(0));
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        launch.setImdBurn(address(0));
        vm.stopPrank();
        RefusingReceiver receiver = new RefusingReceiver();
        vm.prank(TIMELOCK);
        launch.setPerpFeeTo(address(receiver));
        vm.deal(users[0], 1 ether);
        vm.prank(users[0]);
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        launch.addPerpFees{value: 1 ether}();
        assertEq(users[0].balance, 1 ether);
        assertEq(address(launch).balance, 0);
        assertEq(launch.imdBucket(), 0);
    }

    function _setTwoPayees(address a, address b, uint16 first) internal {
        address[] memory payees = new address[](2);
        uint16[] memory bps = new uint16[](2);
        (payees[0], payees[1], bps[0], bps[1]) = (a, b, first, 10_000 - first);
        vm.prank(TIMELOCK);
        launch.setPayees(payees, bps);
    }
}
