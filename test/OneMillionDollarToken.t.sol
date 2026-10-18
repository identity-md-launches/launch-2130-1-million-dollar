// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OneMillionDollarToken} from "../src/OneMillionDollarToken.sol";
import {DeployOneMillionDollarToken} from "../script/Deploy.s.sol";

/// @notice Stands in for the launch factory: deploys the token through CREATE2 so that the
///         constructor's `msg.sender` is this contract, exactly as `ProjectFactory.launchCustom` does.
contract FactoryStandIn {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    function move(IERC20 token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract OneMillionDollarTokenTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 ether; // 1e9 * 1e18 minor units
    uint256 internal constant SWARM_BPS = 1000;
    uint256 internal constant POOL_BPS = 8000;

    OneMillionDollarToken internal token;
    address internal deployer;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant CLAIMANT = address(0xC1A1);
    address internal constant ATTACKER = address(0xBEEF);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        deployer = address(this);
        token = new OneMillionDollarToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "1 Million Dollar", "name");
        assertEq(token.symbol(), "1MD", "symbol");
        assertEq(uint256(token.decimals()), 18, "decimals");
        assertEq(token.TOKEN_NAME(), "1 Million Dollar", "TOKEN_NAME constant");
        assertEq(token.TOKEN_SYMBOL(), "1MD", "TOKEN_SYMBOL constant");
        assertEq(uint256(token.TOKEN_DECIMALS()), 18, "TOKEN_DECIMALS constant");
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(EXPECTED_SUPPLY, 1_000_000_000 * 10 ** 18, "test constant sanity");
        assertEq(token.INITIAL_SUPPLY(), EXPECTED_SUPPLY, "INITIAL_SUPPLY constant");
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "totalSupply");
    }

    function test_wholeSupplyIsMintedToTheDeployer() public view {
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY, "deployer holds everything");
        assertEq(token.balanceOf(address(token)), 0, "the token holds nothing itself");
        assertEq(token.balanceOf(address(0)), 0, "nothing went to the zero address");
    }

    function test_constructorEmitsASingleMintTransfer() public {
        vm.recordLogs();
        OneMillionDollarToken fresh = new OneMillionDollarToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Exactly one log from the token: one mint from the zero address to the deployer, nothing else.
        uint256 fromToken;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(fresh)) continue;
            fromToken++;
            assertEq(logs[i].topics.length, 3, "Transfer has three topics");
            assertEq(logs[i].topics[0], Transfer.selector, "Transfer signature");
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(0)))), "minted from the zero address");
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(this)))), "minted to the deployer");
            assertEq(abi.decode(logs[i].data, (uint256)), EXPECTED_SUPPLY, "minted the whole supply");
        }
        assertEq(fromToken, 1, "constructor emitted more or less than the single mint");
    }

    /// @dev The launch factory deploys through CREATE2 and must end up holding the whole supply.
    function test_factoryDeploymentMintsEverythingToTheFactory() public {
        FactoryStandIn factory = new FactoryStandIn();
        address at = factory.deploy(type(OneMillionDollarToken).creationCode, bytes32(uint256(42)));
        OneMillionDollarToken launched = OneMillionDollarToken(at);
        assertEq(launched.totalSupply(), EXPECTED_SUPPLY, "supply");
        assertEq(launched.balanceOf(address(factory)), EXPECTED_SUPPLY, "factory holds the supply");
        assertEq(launched.balanceOf(address(this)), 0, "the test got nothing");
    }

    /// @dev The creation code has no constructor arguments, so the bytecode the launch hashes is
    ///      exactly the creation code and every deployment is identical.
    function test_creationCodeTakesNoConstructorArguments() public {
        FactoryStandIn factory = new FactoryStandIn();
        bytes memory code = type(OneMillionDollarToken).creationCode;
        address a = factory.deploy(code, bytes32(uint256(1)));
        address b = factory.deploy(code, bytes32(uint256(2)));
        assertEq(keccak256(a.code), keccak256(b.code), "runtime differs between deployments");
        assertEq(OneMillionDollarToken(a).totalSupply(), EXPECTED_SUPPLY);
        assertEq(OneMillionDollarToken(b).totalSupply(), EXPECTED_SUPPLY);
    }

    function test_deployScriptDeploysTheSameToken() public {
        DeployOneMillionDollarToken script = new DeployOneMillionDollarToken();
        OneMillionDollarToken deployed = script.deploy();
        assertEq(deployed.totalSupply(), EXPECTED_SUPPLY);
        assertEq(deployed.balanceOf(address(script)), EXPECTED_SUPPLY, "the script's caller is the deployer");
        assertEq(deployed.name(), "1 Million Dollar");
        assertEq(deployed.symbol(), "1MD");
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: success paths
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmountAndEmits() public {
        uint256 amount = 123_456 ether;
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(deployer, ALICE, amount);
        assertTrue(token.transfer(ALICE, amount), "transfer returned false");
        assertEq(token.balanceOf(ALICE), amount, "recipient balance");
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount, "sender balance");
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "supply unchanged by a transfer");
    }

    function test_transferOfZeroSucceeds() public {
        assertTrue(token.transfer(ALICE, 0));
        assertEq(token.balanceOf(ALICE), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        assertTrue(token.transfer(deployer, 1 ether));
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_transferWholeBalance() public {
        assertTrue(token.transfer(ALICE, EXPECTED_SUPPLY));
        assertEq(token.balanceOf(ALICE), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_approveAndTransferFrom() public {
        token.transfer(ALICE, 100 ether);

        vm.prank(ALICE);
        vm.expectEmit(true, true, true, true, address(token));
        emit Approval(ALICE, BOB, 60 ether);
        assertTrue(token.approve(BOB, 60 ether), "approve returned false");
        assertEq(token.allowance(ALICE, BOB), 60 ether, "allowance set");

        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, CLAIMANT, 40 ether), "transferFrom returned false");
        assertEq(token.balanceOf(CLAIMANT), 40 ether, "recipient got the amount");
        assertEq(token.balanceOf(ALICE), 60 ether, "owner was debited");
        assertEq(token.allowance(ALICE, BOB), 20 ether, "allowance decreased");
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(ALICE, CLAIMANT, 100 ether);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max, "max allowance stays max");
        assertEq(token.balanceOf(CLAIMANT), 100 ether);
    }

    function test_approveOverwritesPreviousAllowance() public {
        token.approve(BOB, 5 ether);
        token.approve(BOB, 2 ether);
        assertEq(token.allowance(deployer, BOB), 2 ether);
        token.approve(BOB, 0);
        assertEq(token.allowance(deployer, BOB), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: failure paths
    // ---------------------------------------------------------------------------------------------

    function test_RevertWhen_transferExceedsBalance() public {
        token.transfer(ALICE, 10 ether);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10 ether, 10 ether + 1)
        );
        token.transfer(BOB, 10 ether + 1);
        assertEq(token.balanceOf(ALICE), 10 ether, "failed transfer changed nothing");
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_RevertWhen_transferFromAccountWithNothing() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ATTACKER, 0, 1));
        token.transfer(BOB, 1);
    }

    function test_RevertWhen_transferToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "nothing burned");
    }

    function test_RevertWhen_transferFromExceedsAllowance() public {
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(BOB, 10 ether);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 10 ether, 10 ether + 1)
        );
        token.transferFrom(ALICE, CLAIMANT, 10 ether + 1);
        assertEq(token.balanceOf(ALICE), 100 ether, "nothing moved");
        assertEq(token.allowance(ALICE, BOB), 10 ether, "allowance untouched");
    }

    function test_RevertWhen_transferFromWithoutAnyAllowance() public {
        token.transfer(ALICE, 100 ether);
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ATTACKER, 0, 1));
        token.transferFrom(ALICE, ATTACKER, 1);
        assertEq(token.balanceOf(ALICE), 100 ether);
    }

    function test_RevertWhen_transferFromExceedsBalanceEvenWithAllowance() public {
        token.transfer(ALICE, 5 ether);
        vm.prank(ALICE);
        token.approve(BOB, 100 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 5 ether, 6 ether));
        token.transferFrom(ALICE, CLAIMANT, 6 ether);
    }

    function test_RevertWhen_approveZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1 ether);
    }

    function test_RevertWhen_sendingEtherToTheToken() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token must not accept ether");
        assertEq(address(token).balance, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // The supply is fixed: nothing mints, nothing privileged exists
    // ---------------------------------------------------------------------------------------------

    function test_noCommonAdminCallIncreasesSupply() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "owner()",
            "renounceOwnership()"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ATTACKER, type(uint128).max);
            vm.prank(ATTACKER);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, string.concat("unexpected entry point answered: ", signatures[i]));
            vm.prank(deployer);
            (ok,) = address(token).call(data);
            assertFalse(ok, string.concat("unexpected entry point answered the deployer: ", signatures[i]));
            assertEq(token.totalSupply(), EXPECTED_SUPPLY, signatures[i]);
            assertEq(token.balanceOf(ATTACKER), 0, signatures[i]);
        }
    }

    function test_noPrivilegedHandMovesOrFreezesAHolder() public {
        token.transfer(ALICE, EXPECTED_SUPPLY / 1000);
        uint256 held = token.balanceOf(ALICE);
        string[14] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "burn(uint256)",
            "seize(address)",
            "forceTransfer(address,address,uint256)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, true);
            vm.prank(deployer);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, string.concat("unexpected entry point answered: ", signatures[i]));
        }
        // The deployer has no allowance from the holder, so it cannot pull funds either.
        vm.prank(deployer);
        vm.expectRevert();
        token.transferFrom(ALICE, deployer, 1);

        assertEq(token.balanceOf(ALICE), held, "a privileged call moved the holder's balance");
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, held / 2), "the holder can no longer transfer");
        assertEq(token.balanceOf(BOB), held / 2);
    }

    function test_runtimeCodeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0, "no runtime");
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F); // skip PUSH data
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Launch flows: everything arrives whole, because there is no fee, tax or burn on transfer
    // ---------------------------------------------------------------------------------------------

    function test_launchFlowsArriveWhole() public {
        FactoryStandIn factory = new FactoryStandIn();
        OneMillionDollarToken launched =
            OneMillionDollarToken(factory.deploy(type(OneMillionDollarToken).creationCode, bytes32(uint256(7))));

        uint256 swarm = (EXPECTED_SUPPLY * SWARM_BPS) / 10_000;
        uint256 pool = (EXPECTED_SUPPLY * POOL_BPS) / 10_000;
        uint256 remainder = EXPECTED_SUPPLY - swarm - pool;
        address poolManager = address(0x9001);
        address remainderTo = address(0x7E57);

        assertTrue(factory.move(launched, DISTRIBUTOR, swarm), "swarm transfer");
        assertTrue(factory.move(launched, poolManager, pool), "pool seed transfer");
        assertTrue(factory.move(launched, remainderTo, remainder), "remainder transfer");
        assertEq(launched.balanceOf(DISTRIBUTOR), swarm, "swarm share short");
        assertEq(launched.balanceOf(poolManager), pool, "pool share short");
        assertEq(launched.balanceOf(remainderTo), remainder, "remainder short");
        assertEq(launched.balanceOf(address(factory)), 0, "factory kept something");

        vm.prank(DISTRIBUTOR);
        assertTrue(launched.transfer(CLAIMANT, swarm), "claim");
        assertEq(launched.balanceOf(CLAIMANT), swarm, "claim short");
        assertEq(launched.balanceOf(DISTRIBUTOR), 0, "distributor kept something");
        assertEq(launched.totalSupply(), EXPECTED_SUPPLY, "flows changed the supply");
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: conservation and exactness
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupplyAndIsExact(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount, "recipient got exactly the amount");
        assertEq(token.balanceOf(deployer) + token.balanceOf(to), EXPECTED_SUPPLY, "conservation");
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "supply fixed");
    }

    function testFuzz_transferAboveBalanceReverts(address from, uint256 balance, uint256 extra) public {
        vm.assume(from != address(0) && from != deployer);
        balance = bound(balance, 0, EXPECTED_SUPPLY);
        extra = bound(extra, 1, type(uint256).max - balance);
        token.transfer(from, balance);
        vm.prank(from);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, balance + extra)
        );
        token.transfer(BOB, balance + extra);
        assertEq(token.balanceOf(from), balance, "failed transfer changed nothing");
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowanceAmount, uint256 spend) public {
        allowanceAmount = bound(allowanceAmount, 0, EXPECTED_SUPPLY);
        spend = bound(spend, 0, EXPECTED_SUPPLY);
        token.approve(BOB, allowanceAmount);
        vm.prank(BOB);
        if (spend <= allowanceAmount) {
            assertTrue(token.transferFrom(deployer, ALICE, spend));
            assertEq(token.balanceOf(ALICE), spend);
            assertEq(token.allowance(deployer, BOB), allowanceAmount - spend);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, allowanceAmount, spend)
            );
            token.transferFrom(deployer, ALICE, spend);
            assertEq(token.balanceOf(ALICE), 0);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_multiHopTransfersConserveSupply(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, EXPECTED_SUPPLY);
        b = bound(b, 0, a);
        c = bound(c, 0, b);
        token.transfer(ALICE, a);
        vm.prank(ALICE);
        token.transfer(BOB, b);
        vm.prank(BOB);
        token.transfer(CLAIMANT, c);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - a);
        assertEq(token.balanceOf(ALICE), a - b);
        assertEq(token.balanceOf(BOB), b - c);
        assertEq(token.balanceOf(CLAIMANT), c);
        assertEq(
            token.balanceOf(deployer) + token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(CLAIMANT),
            EXPECTED_SUPPLY
        );
    }
}
