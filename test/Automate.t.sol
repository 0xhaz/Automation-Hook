// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import "forge-std/console2.sol";
import "forge-std/console.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {AutomateSetup} from "test/AutomateSetup.sol";
import {Automate} from "src/Automate.sol";
import {AutoMateHook} from "src/AutomateHook.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAutoMate} from "src/interfaces/IAutomate.sol";
import {Disperse} from "test/mock/Disperse.sol";

contract TestAutoMate is AutomateSetup {
    using PoolIdLibrary for PoolKey;

    /*//////////////////////////////////////////////////////////////
                            TASK SUBSCRIPTION
    //////////////////////////////////////////////////////////////*/
    function test_subscribeTask_Revert_If_ScheduledAt_Is_0() public userPrank(alice) {
        bytes memory taskInfo = abi.encode(
            defaultBounty,
            IAutoMate.TaskType.ERC20_TRANSFER,
            address(token0),
            address(token0),
            0, // scheduledAt
            1000 ether,
            abi.encodeCall(IERC20.transfer, (bob, 1000 ether))
        );
        IERC20(address(token0)).approve(address(automate), 1000 ether);
        vm.expectRevert(IAutoMate.InvalidTaskInput.selector);
        automate.subscribeTask{value: defaultBounty + protocolFee}(taskInfo);
    }

    function test_subscribeTask_Revert_If_Token_Address_Is_0() public userPrank(alice) {
        bytes memory taskInfo = abi.encode(
            defaultBounty,
            IAutoMate.TaskType.ERC20_TRANSFER,
            address(0), // tokenAddress can only be 0 when taskType is NATIVE_TRANSFER or CONTRACT_CALL_WITH_NATIVE
            address(token0),
            uint64(block.timestamp + 1 days),
            1000 ether,
            abi.encodeCall(IERC20.transfer, (bob, 1000 ether))
        );
        IERC20(address(token0)).approve(address(automate), 1000 ether);
        vm.expectRevert(IAutoMate.InvalidTaskInput.selector);
        automate.subscribeTask{value: defaultBounty + protocolFee}(taskInfo);
    }

    function test_subscribeTask_Revert_If_Calling_Address_Is_0() public userPrank(alice) {
        bytes memory taskInfo = abi.encode(
            defaultBounty,
            IAutoMate.TaskType.ERC20_TRANSFER,
            address(token0),
            address(0),
            uint64(block.timestamp + 1 days),
            1000 ether,
            abi.encodeCall(IERC20.transfer, (bob, 1000 ether))
        );
        IERC20(address(token0)).approve(address(automate), 1000 ether);
        vm.expectRevert(IAutoMate.InvalidTaskInput.selector);
        automate.subscribeTask{value: defaultBounty + protocolFee}(taskInfo);
    }

    function test_subscribeTask_Revert_If_JIT_Bounty_Is_Less_Than_Minimum() public userPrank(alice) {
        uint256 jitBounty = 0.009 ether;
        protocolFee = (jitBounty + defaultProtocolFeeBP) / _BASIS_POINTS;

        bytes memory taskInfo = abi.encode(
            jitBounty,
            IAutoMate.TaskType.ERC20_TRANSFER,
            address(token0),
            address(token0),
            uint64(block.timestamp + 1 days),
            1000 ether,
            abi.encodeCall(IERC20.transfer, (bob, 1000 ether))
        );
        IERC20(address(token0)).approve(address(automate), 1000 ether);
        vm.expectRevert(IAutoMate.InvalidTaskInput.selector);
        automate.subscribeTask{value: jitBounty + protocolFee}(taskInfo);
    }

    function test_subscribeTask_Revert_If_Call_Amount_Is_0() public userPrank(alice) {
        bytes memory taskInfo = abi.encode(
            defaultBounty,
            IAutoMate.TaskType.ERC20_TRANSFER,
            address(token0),
            address(token0),
            uint64(block.timestamp + 1 days),
            0, // callAmount
            abi.encodeCall(IERC20.transfer, (bob, 0))
        );
        vm.expectRevert(IAutoMate.InvalidTaskInput.selector);
        automate.subscribeTask{value: defaultBounty + protocolFee}(taskInfo);
    }

    function test_subscribeTask_Revert_If_CallData_Is_Empty() public userPrank(alice) {
        bytes memory taskInfo = abi.encode(
            defaultBounty,
            IAutoMate.TaskType.ERC20_TRANSFER,
            address(token0),
            address(token0),
            uint64(block.timestamp + 1 days),
            1000,
            ZERO_BYTES // callData
        );
        vm.expectRevert(IAutoMate.InvalidTaskInput.selector);
        automate.subscribeTask{value: defaultBounty + protocolFee}(taskInfo);
    }

    function test_subscribeTask_Revert_If_Insufficient_Fund_For_Protocol_Fee() public userPrank(alice) {
        // Bounty = 110 => Protocol fee = 11 ether (10%)
        // MinRequiredAmount = 121 ether; But Alice has 110 only
        uint256 bounty = 110 ether;
        bytes memory taskInfo = abi.encode(
            bounty,
            IAutoMate.TaskType.ERC20_TRANSFER,
            address(token0),
            address(token0),
            uint64(block.timestamp + 1 days),
            1000,
            abi.encodeCall(IERC20.transfer, (bob, 0))
        );
        IERC20(address(token0)).approve(address(automate), 1000 ether);
        vm.expectRevert(IAutoMate.InsufficientSetupFunds.selector);
        automate.subscribeTask{value: bounty}(taskInfo);
    }

    /// @notice Detailed walkthrough of how eth/tokens are transferred in subscribeTask
    function test_subscribeTask_Can_Subscribe_ERC20_Transfer_Task() public {
        uint256 scheduledTransferAmount = 1000 ether;

        assertEq(alice.balance, 110 ether);
        assertEq(token0.balanceOf(alice), 10_000 ether);
        // Default bounty = 100 ether
        // Protocol fee = 10 ether (10%)
        // Task: Transfer 1000 token0 to Bob, scheduled after 1 day
        taskId = subscribeERC20TransferTaskBy(alice, defaultBounty, scheduledTransferAmount);
        assertEq(taskId, 0);

        // Transferred 100 eth (Bounty) + 10 eth (Protocol fee) => 0 eth remaining
        assertEq(alice.balance, 0 ether);
        // Transferred 1000 units of token0 to Automate contract for task execution
        assertEq(token0.balanceOf(alice), 9000 ether);
        assertEq(feeAdmin.balance, 10 ether); // 10% fee of 100 eth

        IAutoMate.Task memory task = automate.getTask(taskId);

        assertEq(task.id, taskId);
        assertEq(task.subscriber, alice);
        assertEq(task.jitBounty, defaultBounty);
        assertEq(uint256(task.taskType), uint256(IAutoMate.TaskType.ERC20_TRANSFER));
        assertEq(task.callingAddress, address(token0));
        assertEq(task.scheduleAt, defaultScheduleAt);
        assertEq(task.callAmount, scheduledTransferAmount);
        assertEq(task.callData, abi.encodeCall(IERC20.transfer, (bob, scheduledTransferAmount)));
    }
}
