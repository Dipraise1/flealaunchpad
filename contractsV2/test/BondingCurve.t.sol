// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {PonsV2LauncherToken} from "../src/v2/PonsV2LauncherToken.sol";
import {PonsV2BuybackVault} from "../src/v2/PonsV2BuybackVault.sol";
import {PonsV2FeeEscrow} from "../src/v2/PonsV2FeeEscrow.sol";
import {
    FeePolicySnapshot,
    GraduationPhase,
    IPonsV2FeeEscrow,
    IPonsV2FeePolicy,
    IPonsV2LaunchFactory
} from "../src/v2/interfaces/ILaunchpadV2.sol";

/// Stands in for the meme hook's policy surface; the curve only reads the sweep operator live.
contract MockPolicy {
    address public feeSweepOperator;
    constructor(address op) { feeSweepOperator = op; }
}

/// The test contract plays the factory: it deploys the curve, answers the
/// vault's `getLaunchedToken` lookup, and receives graduation proceeds.
contract BondingCurveTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant PHANTOM = 1.5 ether;
    uint256 constant THRESHOLD = 4.2 ether;

    PonsV2FeeEscrow escrow;
    PonsV2BuybackVault vault;
    MockPolicy policy;
    PonsV2BondingCurve curve;
    PonsV2LauncherToken token;

    address creator = makeAddr("creator");
    address protocol = makeAddr("protocol");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address sniper = makeAddr("sniper");
    address bundle = makeAddr("bundle");

    bool graduatedViaFactory;

    function setUp() public {
        vm.warp(1_000_000);
        policy = new MockPolicy(operator);
        escrow = new PonsV2FeeEscrow();
        vault = new PonsV2BuybackVault(address(this), IPonsV2FeePolicy(address(policy)), IPonsV2FeeEscrow(address(escrow)));
        vault.setFactory(address(this));
        _launch(9_900, 15, true, false);
        vm.deal(alice, 100 ether);
        vm.deal(sniper, 100 ether);
        vm.deal(bundle, 100 ether);
    }

    function _launch(uint256 snipeBps, uint256 snipeSecs, bool buyback, bool burn) internal {
        FeePolicySnapshot memory snap = FeePolicySnapshot({
            protocolFeeRecipient: protocol,
            protocolFeeShareBps: 5_000,
            buybackBurnBps: 5_000,
            hookFeeBps: 100,
            maxInternalPriceImpactBps: 500
        });
        curve = new PonsV2BondingCurve(
            address(0), creator, address(this), IPonsV2FeePolicy(address(policy)), snap,
            IPonsV2FeeEscrow(address(escrow)), vault, PHANTOM, 100, 100, buyback, THRESHOLD, snipeBps, snipeSecs, burn
        );
        token = new PonsV2LauncherToken(
            "Flea", "FLEA", "", "", PonsV2LauncherToken.Socials("", "", "", "", ""), creator, address(curve),
            address(this), SUPPLY
        );
        curve.initialize(address(token));
        curve.exemptFromSnipeTax(creator);
        curve.exemptFromSnipeTax(bundle);
    }

    // --- factory surface used by curve + vault ---
    function getLaunchedToken(address) external view returns (IPonsV2LaunchFactory.LaunchedToken memory t) {
        t.curve = address(curve);
        t.exists = true;
        t.phase = GraduationPhase.NotGraduated;
    }

    function graduate(address) external {
        curve.graduate(address(this));
        graduatedViaFactory = true;
    }

    receive() external payable {}

    // --- tests ---

    function test_buyAndSellRoundTrip() public {
        vm.warp(block.timestamp + 60);
        vm.startPrank(alice);
        uint256 out = curve.buy{value: 1 ether}(1 ether, 1, alice);
        assertGt(out, 0);
        assertEq(token.balanceOf(alice), out);
        token.approve(address(curve), out);
        uint256 back = curve.sell(out, 1, alice);
        vm.stopPrank();
        // 1% fee + 1% creator tax on each leg
        assertApproxEqRel(back, 0.96 ether, 0.01e18);
    }

    function test_snipeTaxHitsUndeclaredWalletInLaunchSecond() public {
        vm.prank(sniper);
        uint256 sniped = curve.buy{value: 1 ether}(1 ether, 1, sniper);
        vm.prank(bundle);
        uint256 declared = curve.buy{value: 1 ether}(1 ether, 1, bundle);
        // sniper paid ~97.9% (capped at 99% total), the declared bundle wallet paid 2%
        assertLt(sniped * 20, declared);
        assertEq(curve.currentSnipeTaxBps(bundle), 0);
    }

    function test_snipeTaxDecaysToZero() public {
        uint256 t0 = curve.currentSnipeTaxBps(sniper);
        vm.warp(block.timestamp + 7);
        uint256 t7 = curve.currentSnipeTaxBps(sniper);
        vm.warp(block.timestamp + 8);
        assertEq(curve.currentSnipeTaxBps(sniper), 0);
        assertGt(t0, t7);
        assertGt(t7, 0);
    }

    function test_cannotExemptAfterFirstTrade() public {
        vm.prank(alice);
        curve.buy{value: 0.1 ether}(0.1 ether, 1, alice);
        vm.expectRevert(PonsV2BondingCurve.TradingAlreadyStarted.selector);
        curve.exemptFromSnipeTax(sniper);
    }

    function test_sweepSplitsFeesAndLocksBuyback() public {
        vm.warp(block.timestamp + 60);
        vm.prank(alice);
        curve.buy{value: 2 ether}(2 ether, 1, alice);
        // 2 ETH * 1% fee = 0.02; protocol 50% = 0.01; creator bucket 0.01 -> 50% buyback
        vm.prank(operator);
        curve.sweepFees(1);
        assertEq(escrow.balanceOf(protocol), 0.01 ether);
        // creator: 0.005 fee remainder + 0.02 creator tax
        assertEq(escrow.balanceOf(creator), 0.025 ether);
        assertGt(vault.totalLocked(address(token)), 0);

        uint256 before = creator.balance;
        vm.prank(creator);
        escrow.claim();
        assertEq(creator.balance - before, 0.025 ether);
    }

    function test_creatorCannotSweepWhenBuybackPending() public {
        vm.warp(block.timestamp + 60);
        vm.prank(alice);
        curve.buy{value: 1 ether}(1 ether, 1, alice);
        vm.prank(creator);
        vm.expectRevert(PonsV2BondingCurve.InternalSwapRequiresOperator.selector);
        curve.sweepFees(1);
    }

    function test_crossingBuyGraduatesAndRefunds() public {
        vm.warp(block.timestamp + 60);
        vm.deal(alice, 50 ether);
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        curve.buy{value: 20 ether}(20 ether, 1, alice);
        assertTrue(curve.graduated());
        assertTrue(graduatedViaFactory);
        // partial fill: alice spent ~threshold grossed up for fees, rest refunded
        uint256 spent = balBefore - alice.balance;
        assertApproxEqRel(spent, THRESHOLD * 10_000 / 9_800, 0.001e18);
        assertEq(token.balanceOf(address(this)), curve.reservedTokens());
    }

    function test_burnModeBurnsBuybackInsteadOfLocking() public {
        _launch(9_900, 15, true, true);
        vm.warp(block.timestamp + 60);
        vm.prank(alice);
        curve.buy{value: 2 ether}(2 ether, 1, alice);
        uint256 supplyBefore = token.totalSupply();
        uint256 reserved = curve.reservedTokens();
        vm.prank(operator);
        curve.sweepFees(1);
        assertLt(token.totalSupply(), supplyBefore, "supply burned");
        assertEq(vault.totalLocked(address(token)), 0, "nothing vested");
        assertEq(curve.reservedTokens(), reserved, "pool allocation untouched");
        assertEq(escrow.balanceOf(creator), 0.025 ether);
    }

    function test_burnModeStillGraduatesWithFullAllocation() public {
        _launch(9_900, 15, true, true);
        vm.warp(block.timestamp + 60);
        vm.prank(alice);
        curve.buy{value: 2 ether}(2 ether, 1, alice);
        vm.prank(operator);
        curve.sweepFees(1);
        vm.deal(alice, 50 ether);
        vm.prank(alice);
        curve.buy{value: 20 ether}(20 ether, 1, alice);
        assertTrue(curve.graduated());
        assertEq(token.balanceOf(address(this)), curve.reservedTokens());
    }

    function testFuzz_buyNeverExceedsSellable(uint96 amount) public {
        vm.assume(amount > 1e9 && amount < 100 ether);
        vm.warp(block.timestamp + 60);
        vm.deal(alice, amount);
        vm.prank(alice);
        curve.buy{value: amount}(amount, 1, alice);
        assertGe(token.balanceOf(address(curve)) + token.balanceOf(address(this)), curve.reservedTokens());
    }
}
