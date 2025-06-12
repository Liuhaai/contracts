// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/utils/Create2.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

import "erc6551/ERC6551Registry.sol";
import "erc6551/interfaces/IERC6551Account.sol";
import "erc6551/interfaces/IERC6551Executable.sol";

import "../src/AccountV3.sol";
import "../src/execute-delegate/ExecutionDelegatorManager.sol";
import "../src/interfaces/IExecutionDelegatorManager.sol";

import "./mocks/MockERC721.sol";

contract AccountExecutionDelegationTest is Test {
    AccountV3 internal _implementation;
    ERC6551Registry public registry;
    ExecutionDelegatorManager public executionDelegatorManager;
    MockERC721 public tokenCollection;
    DelegationMockExecutor public mockExecutor; // Target contract for execution
    ContractDelegator public contractDelegator; // Contract-based delegator

    address internal _owner = vm.addr(1); // Owner of the NFT and ExecutionDelegatorManager
    address internal _delegator; // Address of the ContractDelegator (will be set in setUp)
    address internal _user3 = vm.addr(3); // Another user address
    address internal _accountAddress;
    AccountV3 internal _account;

    function setUp() public {
        registry = new ERC6551Registry();
        executionDelegatorManager = new ExecutionDelegatorManager(_owner); // Deploy ExecutionDelegatorManager with owner
        
        // Deploy the contract delegator and set the owner to be able to call it
        contractDelegator = new ContractDelegator(_owner);
        _delegator = address(contractDelegator); // Set _delegator to be the contract address

        // Deploy AccountV3 implementation linking the ExecutionDelegatorManager
        _implementation = new AccountV3(address(1), address(1), address(registry), address(1), address(executionDelegatorManager));

        tokenCollection = new MockERC721();
        mockExecutor = new DelegationMockExecutor(); // Deploy target contract

        // Mint NFT and create account
        uint256 tokenId = 1;
        tokenCollection.mint(_owner, tokenId);
        _accountAddress = registry.createAccount(
            address(_implementation), 0, block.chainid, address(tokenCollection), tokenId
        );
        _account = AccountV3(payable(_accountAddress));

        // Fund the account
        vm.deal(_accountAddress, 1 ether);
    }

    // --- ExecutionDelegator Unit Tests ---

    function testAccountExecutionDelegationAuthorizeDelegator() public {
        bytes4 funcSig = mockExecutor.executeFromAccount.selector;
        vm.prank(_owner);
        executionDelegatorManager.authorizeDelegator(_delegator, address(mockExecutor), funcSig);
        assertTrue(executionDelegatorManager.isAuthorized(_delegator, address(mockExecutor), abi.encodeWithSelector(funcSig)));
    }

    function testAccountExecutionDelegationRevokeDelegator() public {
        bytes4 funcSig = mockExecutor.executeFromAccount.selector;
        vm.prank(_owner);
        executionDelegatorManager.authorizeDelegator(_delegator, address(mockExecutor), funcSig);
        assertTrue(executionDelegatorManager.isAuthorized(_delegator, address(mockExecutor), abi.encodeWithSelector(funcSig)));

        vm.prank(_owner);
        executionDelegatorManager.revokeDelegator(_delegator, address(mockExecutor), funcSig);
        assertFalse(executionDelegatorManager.isAuthorized(_delegator, address(mockExecutor), abi.encodeWithSelector(funcSig)));
    }

    function testAccountExecutionDelegationIsAuthorizedNotAuthorized() public {
        bytes4 funcSig = mockExecutor.executeFromAccount.selector;
        assertFalse(executionDelegatorManager.isAuthorized(_delegator, address(mockExecutor), abi.encodeWithSelector(funcSig)));
    }

    function testAccountExecutionDelegationAuthorizeDelegatorOnlyOwner() public {
        bytes4 funcSig = mockExecutor.executeFromAccount.selector;
        vm.prank(_user3); // Non-owner
        vm.expectRevert("Ownable: caller is not the owner");
        executionDelegatorManager.authorizeDelegator(_delegator, address(mockExecutor), funcSig);
    }

    function testAccountExecutionDelegationRevokeDelegatorOnlyOwner() public {
        bytes4 funcSig = mockExecutor.executeFromAccount.selector;
        // Authorize first
        vm.prank(_owner);
        executionDelegatorManager.authorizeDelegator(_delegator, address(mockExecutor), funcSig);

        // Attempt revoke by non-owner
        vm.prank(_user3);
        vm.expectRevert("Ownable: caller is not the owner");
        executionDelegatorManager.revokeDelegator(_delegator, address(mockExecutor), funcSig);
    }

    // --- AccountV3 Integration Tests ---

    function testAccountExecutionDelegationExecuteWithDelegatorDelegationDisabled() public {
        bytes4 funcSig = mockExecutor.executeFromAccount.selector;
        bytes memory callData = abi.encodeWithSelector(funcSig);

        // Authorize delegator in ExecutionDelegator contract
        vm.prank(_owner);
        executionDelegatorManager.authorizeDelegator(_delegator, address(mockExecutor), funcSig);
        assertTrue(executionDelegatorManager.isAuthorized(_delegator, address(mockExecutor), callData));

        // Delegation is disabled by default in AccountV3, so execute should fail
        vm.prank(_owner);
        vm.expectRevert(NotAuthorized.selector);
        contractDelegator.executeOnAccount(_account, address(mockExecutor), 0, callData, 0);
    }

     function testAccountExecutionDelegationExecuteWithDelegatorDelegationEnabled() public {
        bytes4 funcSig = mockExecutor.executeFromAccount.selector;
        bytes memory callData = abi.encodeWithSelector(funcSig);

        // Enable delegation on the account (must be done by owner)
        vm.prank(_owner);
        _account.setDelegationEnabled(true);

        // Authorize delegator in ExecutionDelegator contract
        vm.prank(_owner);
        executionDelegatorManager.authorizeDelegator(_delegator, address(mockExecutor), funcSig);
        assertTrue(executionDelegatorManager.isAuthorized(_delegator, address(mockExecutor), callData));

        // Execute call via the authorized delegator
        uint256 initialExecutorBalance = mockExecutor.getBalance();
        vm.prank(_owner);
        contractDelegator.executeOnAccount(_account, address(mockExecutor), 0.1 ether, callData, 0); // Send some ETH too

        // Check if MockExecutor received ETH and was called
        assertEq(address(mockExecutor).balance, 0.1 ether);
        assertEq(mockExecutor.getBalance(), initialExecutorBalance); // Internal balance shouldn't change
        assertEq(mockExecutor.lastCaller(), _accountAddress); // Called by the account
        assertEq(mockExecutor.valueReceived(), 0.1 ether); // Value received should be correct
    }

    function testAccountExecutionDelegationExecuteWithDelegatorRevoked() public {
        bytes4 funcSig = mockExecutor.executeFromAccount.selector;
        bytes memory callData = abi.encodeWithSelector(funcSig);

        // Enable delegation
        vm.prank(_owner);
        _account.setDelegationEnabled(true);

        // Authorize delegator
        vm.prank(_owner);
        executionDelegatorManager.authorizeDelegator(_delegator, address(mockExecutor), funcSig);

        // Revoke delegator
        vm.prank(_owner);
        executionDelegatorManager.revokeDelegator(_delegator, address(mockExecutor), funcSig);
        assertFalse(executionDelegatorManager.isAuthorized(_delegator, address(mockExecutor), callData));

        // Execute call via the (now revoked) delegator - should fail
        vm.prank(_owner);
        vm.expectRevert(NotAuthorized.selector);
        contractDelegator.executeOnAccount(_account, address(mockExecutor), 0, callData, 0);
    }

     function testAccountExecutionDelegationExecuteWithDelegatorDelegationDisabledAfterEnable() public {
        bytes4 funcSig = mockExecutor.executeFromAccount.selector;
        bytes memory callData = abi.encodeWithSelector(funcSig);

        // Enable delegation
        vm.prank(_owner);
        _account.setDelegationEnabled(true);

        // Authorize delegator
        vm.prank(_owner);
        executionDelegatorManager.authorizeDelegator(_delegator, address(mockExecutor), funcSig);
        assertTrue(executionDelegatorManager.isAuthorized(_delegator, address(mockExecutor), callData));

        // Disable delegation again
        vm.prank(_owner);
        _account.setDelegationEnabled(false);

        // Execute call via the authorized delegator - should fail as delegation is off
        vm.prank(_owner);
        vm.expectRevert(NotAuthorized.selector);
        contractDelegator.executeOnAccount(_account, address(mockExecutor), 0, callData, 0);
    }

    function testAccountExecutionDelegationSetDelegationEnabledOnlyOwner() public {
         vm.prank(_user3); // Not the owner
         vm.expectRevert(NotAuthorized.selector);
         _account.setDelegationEnabled(true);
    }

    function testAccountExecutionDelegationExecuteWithDelegatorWrongFunction() public {
        bytes4 authorizedFuncSig = mockExecutor.executeFromAccount.selector;
        bytes4 wrongFuncSig = bytes4(keccak256("wrongFunction()"));
        bytes memory wrongCallData = abi.encodeWithSelector(wrongFuncSig);

        // Enable delegation
        vm.prank(_owner);
        _account.setDelegationEnabled(true);

        // Authorize delegator for the correct function
        vm.prank(_owner);
        executionDelegatorManager.authorizeDelegator(_delegator, address(mockExecutor), authorizedFuncSig);
        assertTrue(executionDelegatorManager.isAuthorized(_delegator, address(mockExecutor), abi.encodeWithSelector(authorizedFuncSig)));

        // Check authorization for the wrong function (should be false)
        assertFalse(executionDelegatorManager.isAuthorized(_delegator, address(mockExecutor), wrongCallData));

        // Execute call via the delegator but with the wrong function - should fail authorization check
        vm.prank(_owner);
        vm.expectRevert(NotAuthorized.selector);
        contractDelegator.executeOnAccount(_account, address(mockExecutor), 0, wrongCallData, 0);
    }

     function testAccountExecutionDelegationExecuteWithDelegatorWrongTarget() public {
        bytes4 funcSig = mockExecutor.executeFromAccount.selector;
        bytes memory callData = abi.encodeWithSelector(funcSig);
        DelegationMockExecutor otherExecutor = new DelegationMockExecutor(); // Different target contract

        // Enable delegation
        vm.prank(_owner);
        _account.setDelegationEnabled(true);

        // Authorize delegator for the original mockExecutor
        vm.prank(_owner);
        executionDelegatorManager.authorizeDelegator(_delegator, address(mockExecutor), funcSig);
        assertTrue(executionDelegatorManager.isAuthorized(_delegator, address(mockExecutor), callData));

        // Check authorization for the wrong target (should be false)
        assertFalse(executionDelegatorManager.isAuthorized(_delegator, address(otherExecutor), callData));

        // Execute call via the delegator but to the wrong target - should fail authorization check
        vm.prank(_owner);
        vm.expectRevert(NotAuthorized.selector);
        contractDelegator.executeOnAccount(_account, address(otherExecutor), 0, callData, 0);
    }

    // --- ExecutionDelegatorManager Unit Tests ---

    function testAccountExecutionDelegationAuthorizeDelegatorInExecutionDelegatorManager() public {
        bytes4 funcSig = mockExecutor.executeFromAccount.selector;
        vm.prank(_owner);
        executionDelegatorManager.authorizeDelegator(_delegator, address(mockExecutor), funcSig);
        assertTrue(executionDelegatorManager.isAuthorized(_delegator, address(mockExecutor), abi.encodeWithSelector(funcSig)));
    }

    function testAccountExecutionDelegationRevokeDelegatorInExecutionDelegatorManager() public {
        bytes4 funcSig = mockExecutor.executeFromAccount.selector;
        vm.prank(_owner);
        executionDelegatorManager.authorizeDelegator(_delegator, address(mockExecutor), funcSig);
        assertTrue(executionDelegatorManager.isAuthorized(_delegator, address(mockExecutor), abi.encodeWithSelector(funcSig)));

        vm.prank(_owner);
        executionDelegatorManager.revokeDelegator(_delegator, address(mockExecutor), funcSig);
        assertFalse(executionDelegatorManager.isAuthorized(_delegator, address(mockExecutor), abi.encodeWithSelector(funcSig)));
    }

    function testAccountExecutionDelegationIsAuthorizedNotAuthorizedInExecutionDelegatorManager() public {
        bytes4 funcSig = mockExecutor.executeFromAccount.selector;
        assertFalse(executionDelegatorManager.isAuthorized(_delegator, address(mockExecutor), abi.encodeWithSelector(funcSig)));
    }

    function testAccountExecutionDelegationAuthorizeDelegatorOnlyOwnerInExecutionDelegatorManager() public {
        bytes4 funcSig = mockExecutor.executeFromAccount.selector;
        vm.prank(_user3); // Non-owner
        vm.expectRevert("Ownable: caller is not the owner");
        executionDelegatorManager.authorizeDelegator(_delegator, address(mockExecutor), funcSig);
    }

    function testAccountExecutionDelegationRevokeDelegatorOnlyOwnerInExecutionDelegatorManager() public {
        bytes4 funcSig = mockExecutor.executeFromAccount.selector;
        // Authorize first
        vm.prank(_owner);
        executionDelegatorManager.authorizeDelegator(_delegator, address(mockExecutor), funcSig);

        // Attempt revoke by non-owner
        vm.prank(_user3);
        vm.expectRevert("Ownable: caller is not the owner");
        executionDelegatorManager.revokeDelegator(_delegator, address(mockExecutor), funcSig);
    }
}

// Simple Mock Executor contract for testing calls specific to delegation
contract DelegationMockExecutor { // Renamed from MockExecutor
    address public lastCaller;
    uint256 public valueReceived;
    uint256 internal _balance; // Internal balance tracking if needed

    receive() external payable {
        valueReceived = msg.value;
        lastCaller = msg.sender; // This will be the Account contract address
    }

    function executeFromAccount() external payable {
        lastCaller = msg.sender; // This will be the Account contract address
        valueReceived = msg.value;
    }

    function getBalance() external view returns (uint256) {
        return _balance;
    }
}

// Contract delegator for testing delegation from a contract
contract ContractDelegator {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    // Function to execute calls on accounts via delegation
    function executeOnAccount(
        AccountV3 account, 
        address target, 
        uint256 value, 
        bytes calldata data, 
        uint8 operation
    ) external returns (bytes memory) {
        require(msg.sender == owner, "Only owner can call");
        return account.execute(target, value, data, operation);
    }
}
