// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {AutoMateHook} from "src/AutomateHook.sol";
import {Automate} from "src/Automate.sol";
import {Disperse} from "test/mock/Disperse.sol";
import {IAutoMate} from "src/interfaces/IAutomate.sol";

contract AutomateSetup is Test, Deployers {
    // use the libraries
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    // Contracts
    Automate public automate;
    AutoMateHook public automateHook;
    PoolId public poolId;
    Disperse public disperse;

    uint256 public constant _BASIS_POINTS = 10_000;
    bytes32 private constant _CLAIM_BOUNTY_TYPEHASH = keccak256("ClaimBounty(address receiver)");

    // Native tokens are represented by address(0)
    Currency currency = Currency.wrap(address(0));
    MockERC20 token0;
    MockERC20 token1;

    IPoolManager public poolManager;

    // Users
    mapping(uint256 userId => uint256 privateKey) public userPrivateKeys;
    mapping(uint256 userId => uint256 disperseAmount) public disperseAmounts;
    mapping(address userAddress => uint256 userId) public userIds;
    address public feeAdmin = vm.addr(9999);
    address public alice;
    address public bob;
    address public cat;
    address public derek;

    // For automate test casses
    uint256 taskId;
    uint64 defaultScheduleAt = uint64(block.timestamp + 1 hours);
    uint256 defaultBounty = 100 ether;
    uint256 defaultTransferAmount = 10_000 ether;
    uint256 defaultProtocolFeeBP = 1000;
    uint256 protocolFee = (defaultBounty * defaultProtocolFeeBP) / _BASIS_POINTS;
    uint256 bountyDecayBPPerMinute = 100;

    // receive bounty if any
    fallback() external payable {}

    modifier userPrank(address user) {
        vm.startPrank(user);
        _;
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // 1 - Deploy v4 core contracts (PoolManager, periphery Router contracts for swapping, modifying liquidity, etc.)
        deployFreshManagerAndRouters();

        // 2 - Deploy two test tokens
        (currency0, currency1) = deployMintAndApprove2Currencies();
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        // 3 - Deploy our Automate contract
        automate = new Automate(1000, 100, feeAdmin); // 10% fee, 1% decay per minute

        // 4 - Deploy Hook contract to specified address
        address hookAddress = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));
        // Daily auction, 1% drop
        deployCodeTo("AutomateHook.sol", abi.encode(manager, address(automate)), hookAddress);
        automateHook = AutoMateHook(hookAddress);

        // 5 = Set the hook address in the automate contract
        automate.setHookAddress(address(automateHook));

        // 6 - Initialize a pool with these two tokens
        (key,) = initPool(
            currency0,
            currency1,
            automateHook, // Hook contract
            3000, // Swap fee
            SQRT_PRICE_1_1, // Initial Sqrt(P) value = 1
            ZERO_BYTES // No additional `initData`
        );
        poolId = key.toId();

        // 7 - Add initial Liquidity to the pool
        token0.approve(hookAddress, type(uint256).max);
        token1.approve(hookAddress, type(uint256).max);
        token0.approve(address(automate), type(uint256).max);
        token1.approve(address(automate), type(uint256).max);

        // some liquidity from -60 to 60 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: ""}),
            ZERO_BYTES
        );
        // some liqiuidity from -120 to 120 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 10 ether, salt: ""}),
            ZERO_BYTES
        );
        // some liquidity for full range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: ""
            }),
            ZERO_BYTES
        );

        // 8 - Setup users
        setUpUsers();

        // 9 - Deploy Disperse contract for other kinds of contract calls in tasks
        disperse = new Disperse();
    }

    function setUpUsers() public {
        // Private Keys
        userPrivateKeys[0] = 1; // alice
        userPrivateKeys[1] = 2; // bob
        userPrivateKeys[2] = 3; // cat
        userPrivateKeys[3] = 4; // derek

        // Disperse Amounts (for disperse contract)
        disperseAmounts[0] = 5 ether;
        disperseAmounts[1] = 10 ether;
        disperseAmounts[2] = 20 ether;
        disperseAmounts[3] = 30 ether;

        // User Addresses
        alice = vm.addr(userPrivateKeys[0]);
        bob = vm.addr(userPrivateKeys[1]);
        cat = vm.addr(userPrivateKeys[2]);
        derek = vm.addr(userPrivateKeys[3]);
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(cat, "Cat");
        vm.label(derek, "Derek");

        // User Ids
        userIds[alice] = 0;
        userIds[bob] = 1;
        userIds[cat] = 2;
        userIds[derek] = 3;

        // Eth Distribution
        deal(alice, 110 ether);
        deal(bob, 1 ether);
        deal(cat, 1 ether);

        // Token Distribution
        deal(address(token0), alice, 10_000 ether);
        deal(address(token0), cat, 10_000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        TEST UTILS
    //////////////////////////////////////////////////////////////*/
    /// @dev subscribe Native Transfer task with specific user
    function subscribeNativeTransferTaskBy(address subscriber, uint256 bounty, uint256 transferAmount, address receiver)
        public
        userPrank(subscriber)
        returns (uint256 id)
    {
        protocolFee = (bounty * defaultProtocolFeeBP) / _BASIS_POINTS;
        bytes memory taskInfo = abi.encode(
            bounty,
            IAutoMate.TaskType.NATIVE_TRANSFER,
            address(0),
            receiver,
            defaultScheduleAt, // scheduled at 1 hour from now
            transferAmount,
            ZERO_BYTES
        );

        uint256 expectedTaskId = _getExpectedTaskId();

        vm.expectEmit(address(automate));
        emit IAutoMate.TaskSubscribed(address(subscriber), expectedTaskId);
        id = automate.subscribeTask{value: bounty + protocolFee + transferAmount}(taskInfo);
    }

    /// @dev subscribe ERC20 Transfer task with specific user
    function subscribeERC20TransferTaskBy(address subscriber, uint256 bounty, uint256 transferAmount)
        public
        userPrank(subscriber)
        returns (uint256 id)
    {
        protocolFee = (bounty * defaultProtocolFeeBP) / _BASIS_POINTS;
        bytes memory taskInfo = abi.encode(
            bounty,
            IAutoMate.TaskType.ERC20_TRANSFER,
            address(token0),
            address(token0),
            defaultScheduleAt, // scheduled at 1 hour from now
            transferAmount,
            abi.encodeCall(IERC20.transfer, (bob, transferAmount))
        );

        uint256 expectedTaskId = _getExpectedTaskId();

        token0.approve(address(automate), transferAmount);
        vm.expectEmit(address(automate));
        emit IAutoMate.TaskSubscribed(address(subscriber), expectedTaskId);
        id = automate.subscribeTask{value: bounty + protocolFee}(taskInfo);
    }

    /// @dev subscribe Disperse Ether task with specific user
    function subscribeContractCallWithNativeTaskBy(address subscriber, uint256 bounty, uint256 transferAmount)
        public
        userPrank(subscriber)
        returns (uint256 id)
    {
        address[] memory recipients = new address[](3);
        recipients[0] = bob;
        recipients[1] = cat;
        recipients[2] = derek;

        // 10 eth to bob, 20 eth to cat, 30 eth to derek
        uint256[] memory values = new uint256[](3);
        values[0] = disperseAmounts[1];
        values[1] = disperseAmounts[2];
        values[2] = disperseAmounts[3];

        protocolFee = (bounty * defaultProtocolFeeBP) / _BASIS_POINTS;
        bytes memory taskInfo = abi.encode(
            bounty,
            IAutoMate.TaskType.CONTRACT_CALL_WITH_NATIVE,
            address(0),
            address(disperse),
            defaultScheduleAt, // scheduled at 1 hour from now
            transferAmount,
            abi.encodeCall(Disperse.disperseEther, (recipients, values)) // encodeCall is to call the function with the arguments
        );

        uint256 expectedTaskId = _getExpectedTaskId();

        vm.expectEmit(address(automate));
        emit IAutoMate.TaskSubscribed(address(subscriber), expectedTaskId);
        id = automate.subscribeTask{value: bounty + protocolFee + transferAmount}(taskInfo);
    }

    /// @dev subscribe Disperse Token task with specific user
    function subscribeContractCallWithERC20TaskBy(address subscriber, uint256 bounty, uint256 transferAmount)
        public
        userPrank(subscriber)
        returns (uint256 id)
    {
        address[] memory recipients = new address[](3);
        recipients[0] = bob;
        recipients[1] = cat;
        recipients[2] = derek;

        // 10 tokens to bob, 20 tokens to cat, 30 tokens to derek
        uint256[] memory values = new uint256[](3);
        values[0] = disperseAmounts[1];
        values[1] = disperseAmounts[2];
        values[2] = disperseAmounts[3];

        protocolFee = (bounty * defaultProtocolFeeBP) / _BASIS_POINTS;
        bytes memory taskInfo = abi.encode(
            bounty,
            IAutoMate.TaskType.CONTRACT_CALL_WITH_ERC20,
            address(token0),
            address(disperse),
            defaultScheduleAt, // scheduled at 1 hour from now
            transferAmount,
            abi.encodeCall(Disperse.disperseToken, (address(token0), recipients, values))
        );

        uint256 expectedTaskId = _getExpectedTaskId();

        token0.approve(address(automate), transferAmount);
        vm.expectEmit(address(automate));
        emit IAutoMate.TaskSubscribed(address(subscriber), expectedTaskId);
        id = automate.subscribeTask{value: bounty + protocolFee}(taskInfo);
    }

    function _getExpectedTaskId() private view returns (uint256 expectedTaskId) {
        uint256 numOfTask = automate.getNumOfTasks();
        if (numOfTask != 0) expectedTaskId = numOfTask;
    }

    /// @dev swap token to trigger executeTask
    /// @param searcher Address of the user who will perform the swap and receive the JIT Bounty
    /// @param swapTime Timing for swap (Determines the bounty decay)
    /// @param zeroForOne Whether to swap token0 for token1 or vice versa
    /// @param amountSpecified Amount to swap, positive indicate exact output swap, negative indicate exact input swap
    function swapToken(address searcher, uint256 swapTime, bool zeroForOne, int256 amountSpecified)
        public
        userPrank(searcher)
    {
        vm.warp(swapTime);

        IAutoMate.ClaimBounty memory claimBounty = IAutoMate.ClaimBounty({receiver: searcher});
        bytes memory sig =
            getEIP712Signature(claimBounty, userPrivateKeys[userIds[searcher]], automate.DOMAIN_SEPARATOR());
        bytes memory encodedHookData = abi.encode(claimBounty, sig);

        if (zeroForOne) {
            token0.approve(address(swapRouter), type(uint256).max);
        } else {
            token1.approve(address(swapRouter), type(uint256).max);
        }
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, encodedHookData);
        assertEq(int256(swapDelta.amount0()), amountSpecified);
    }

    /// @dev get EIP712 signature for a receiver
    function getEIP712Signature(IAutoMate.ClaimBounty memory claimBounty, uint256 privateKey, bytes32 domainSeparator)
        public
        pure
        returns (bytes memory sig)
    {
        (uint8 v, bytes32 r, bytes32 s) = _getEIP712SignatureRaw(claimBounty, privateKey, domainSeparator);
        return bytes.concat(r, s, bytes1(v));
    }

    function approveNecessarySpenders(address user, uint256 amount) public userPrank(user) {
        address[2] memory toApprove = [address(swapRouter), address(automate)];

        for (uint256 i; i < toApprove.length; i++) {
            token0.approve(toApprove[i], amount);
            token1.approve(toApprove[i], amount);
        }
    }

    function calculateRemainingBountyByMin(uint256 minExecutedTooEarly)
        public
        view
        returns (uint256 remainingBounty, uint256 decayAmount)
    {
        remainingBounty = defaultBounty;
        decayAmount = (defaultBounty * minExecutedTooEarly * bountyDecayBPPerMinute) / _BASIS_POINTS;
        remainingBounty -= decayAmount;
    }

    function _getEIP712SignatureRaw(
        IAutoMate.ClaimBounty memory claimBounty,
        uint256 privateKey,
        bytes32 domainSeparator
    ) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 msgHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, _hash(claimBounty)));

        (v, r, s) = vm.sign(privateKey, msgHash);
    }

    // computes hash of a permit
    function _hash(IAutoMate.ClaimBounty memory claimBounty) internal pure returns (bytes32) {
        return keccak256(abi.encode(_CLAIM_BOUNTY_TYPEHASH, claimBounty.receiver));
    }

    function normallize(uint256 amount) internal pure returns (uint256) {
        return amount / 10 ** 18;
    }
}
