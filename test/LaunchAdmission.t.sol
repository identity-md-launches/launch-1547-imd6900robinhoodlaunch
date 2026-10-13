// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IMD6900RobinhoodLaunch} from "../src/IMD6900RobinhoodLaunch.sol";
import {IMD6900LockedPool} from "../src/IMD6900LockedPool.sol";

/// Exercises the factory's zero-value CREATE2 deployment without any initialization calls.
contract LaunchAdmissionFactory {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        require(deployed != address(0), "constructor failed");
    }
}

contract LaunchAdmissionTest is Test {
    address constant TEAM = 0x35dA9C0303507ddf708E87F2568EdDf12c47a059;
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant OLD_TOKEN = 0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F;
    address constant TIMELOCK = 0x16D3f65B708883DF042d98E1C7a49B32A33E2A14;

    function test_FactoryDeploymentWithExactArgumentsAndNoDependencies() public {
        vm.chainId(4663);
        assertEq(address(PM).code.length, 0);
        assertEq(OLD_TOKEN.code.length, 0);
        assertEq(TIMELOCK.code.length, 0);
        bytes memory initCode =
            abi.encodePacked(type(IMD6900RobinhoodLaunch).creationCode, abi.encode(TEAM, PM, OLD_TOKEN, TIMELOCK));
        assertLe(initCode.length, 49_152, "EIP-3860 initcode size");
        uint256 firstGas;
        for (uint256 i; i < 2; ++i) {
            LaunchAdmissionFactory factory = new LaunchAdmissionFactory();
            address deployed = factory.deploy(initCode, bytes32(i));
            // Measure the factory call itself, excluding this test's changing memory/ABI-encoding overhead.
            uint256 used = vm.lastCallGas().gasTotalUsed;
            emit log_named_uint("factory deployment gas", used);
            assertLt(used, 1 << 23, "deployment retains the project's transaction gas margin");
            if (i == 0) firstGas = used;
            else assertApproxEqAbs(used, firstGas, 2_000, "no address-dependent salt mining in the constructor");

            IMD6900RobinhoodLaunch launch = IMD6900RobinhoodLaunch(payable(deployed));
            assertEq(launch.owner(), TEAM, "the factory never owns the launch");
            assertEq(address(launch.poolManager()), address(PM));
            assertEq(launch.imdstr(), OLD_TOKEN);
            assertEq(launch.timelock(), TIMELOCK);
            assertEq(address(launch.hook()), address(0), "hook creation stays a later permissionless call");
            assertEq(launch.token(), address(0), "coin creation stays the owner's launch call");
            assertEq(vm.getNonce(deployed), 2, "the constructor creates exactly one child");
            IMD6900LockedPool pool = launch.pool();
            assertEq(pool.launcher(), deployed);
            assertEq(pool.timelock(), TIMELOCK);
            assertEq(address(pool.poolManager()), address(PM));
            assertEq(pool.fee(), 44_400);
            assertEq(pool.hook(), address(0));
            assertEq(vm.getNonce(address(pool)), 1, "the locked pool creates no children");
            assertLe(deployed.code.length, 24_576, "EIP-170 launch runtime size");
            assertLe(address(pool).code.length, 24_576, "EIP-170 pool runtime size");
        }
    }
}
