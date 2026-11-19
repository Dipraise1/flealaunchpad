// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FleaV2BondingCurve} from "../src/v2/FleaV2BondingCurve.sol";
import {FleaV2LauncherToken} from "../src/v2/FleaV2LauncherToken.sol";
import {FleaV2BuybackVault} from "../src/v2/FleaV2BuybackVault.sol";
import {FleaV2FeeEscrow} from "../src/v2/FleaV2FeeEscrow.sol";
import {FleaV2CreatorSplitter} from "../src/v2/periphery/FleaV2CreatorSplitter.sol";
import {FleaV2CreatorSplitterFactory} from "../src/v2/periphery/FleaV2CreatorSplitterFactory.sol";
import {
    FeePolicySnapshot,
    GraduationPhase,
    IFleaV2FeeEscrow,
    IFleaV2FeePolicy,
    IFleaV2LaunchFactory
} from "../src/v2/interfaces/ILaunchpadV2.sol";
import {MockPolicy} from "./BondingCurve.t.sol";

contract CreatorSplitterTest is Test {
    FleaV2FeeEscrow escrow;
    FleaV2BuybackVault vault;
    FleaV2CreatorSplitterFactory splitters;
    FleaV2CreatorSplitter splitter;
    FleaV2BondingCurve curve;
    FleaV2LauncherToken token;

    address operator = makeAddr("operator");
    address protocol = makeAddr("protocol");
    address dev = makeAddr("dev");
    address artist = makeAddr("artist");
    address marketer = makeAddr("marketer");
    address alice = makeAddr("alice");

    address[] payees;
    uint256[] shares;

    function setUp() public {
        vm.warp(1_000_000);
        MockPolicy policy = new MockPolicy(operator);
        escrow = new FleaV2FeeEscrow();
        vault = new FleaV2BuybackVault(address(this), IFleaV2FeePolicy(address(policy)), IFleaV2FeeEscrow(address(escrow)));
        vault.setFactory(address(this));
        splitters = new FleaV2CreatorSplitterFactory(IFleaV2FeeEscrow(address(escrow)));

        payees = [dev, artist, marketer];
        shares = [5_000, 3_000, 2_000];
        address predicted = splitters.predictSplitter(dev, payees, shares, bytes32("flea"));
        splitter = FleaV2CreatorSplitter(payable(splitters.createSplitter(dev, payees, shares, bytes32("flea"))));
        assertEq(address(splitter), predicted);

        FeePolicySnapshot memory snap = FeePolicySnapshot(protocol, 5_000, 5_000, 100, 500);
        // creator fee recipient = the splitter; buybacks off so the creator role can sweep
        curve = new FleaV2BondingCurve(
            address(0), address(splitter), address(this), IFleaV2FeePolicy(address(policy)), snap,
            IFleaV2FeeEscrow(address(escrow)), vault, 1.5 ether, 100, 100, false, 4.2 ether, 0, 0, false
        );
        token = new FleaV2LauncherToken(
            "Flea", "FLEA", "", "", FleaV2LauncherToken.Socials("", "", "", "", ""), dev, address(curve),
            address(this), 1_000_000_000 ether
        );
        curve.initialize(address(token));
        vm.deal(alice, 100 ether);
    }

    function getLaunchedToken(address) external view returns (IFleaV2LaunchFactory.LaunchedToken memory t) {
        t.curve = address(curve);
        t.exists = true;
        t.phase = GraduationPhase.NotGraduated;
    }

    function graduate(address) external {}

    function test_feesFlowThroughSplitterToCoCreators() public {
        vm.prank(alice);
        curve.buy{value: 2 ether}(2 ether, 1, alice);

        // anyone can trigger the creator-role sweep through the splitter
        splitter.sweepCurveFees(address(curve));
        // creator bucket: 2 * 1% * 50% = 0.01, plus 1% creator tax 0.02 = 0.03 ETH
        assertEq(splitter.pendingInEscrow(address(0)), 0.03 ether);

        splitter.distribute(address(0));
        assertEq(dev.balance, 0.015 ether);
        assertEq(artist.balance, 0.009 ether);
        assertEq(marketer.balance, 0.006 ether);
        assertEq(address(splitter).balance, 0);
    }

    function test_incrementalPayoutsStayFair() public {
        vm.prank(alice);
        curve.buy{value: 2 ether}(2 ether, 1, alice);
        splitter.sweepCurveFees(address(curve));
        splitter.pullFromEscrow(address(0));
        splitter.release(address(0), artist); // only the artist claims round 1

        vm.prank(alice);
        curve.buy{value: 2 ether}(2 ether, 1, alice);
        splitter.sweepCurveFees(address(curve));
        splitter.distribute(address(0));

        assertApproxEqAbs(dev.balance, 0.03 ether, 2);
        assertApproxEqAbs(artist.balance, 0.018 ether, 2);
        assertApproxEqAbs(marketer.balance, 0.012 ether, 2);
    }

    function test_splitsTokensSentDirectly() public {
        vm.prank(alice);
        uint256 got = curve.buy{value: 1 ether}(1 ether, 1, alice);
        vm.prank(alice);
        token.transfer(address(splitter), got);
        splitter.distribute(address(token));
        assertEq(token.balanceOf(dev), got / 2);
        assertEq(token.balanceOf(artist), got * 3 / 10);
    }

    function test_onlyAdminTogglesBuyback() public {
        vm.prank(artist);
        vm.expectRevert(FleaV2CreatorSplitter.NotAdmin.selector);
        splitter.setBuybackEnabled(address(this), address(token), true);
    }

    function test_cannotReinitialize() public {
        vm.expectRevert(FleaV2CreatorSplitter.AlreadyInitialized.selector);
        splitter.initialize(IFleaV2FeeEscrow(address(escrow)), alice, payees, shares);
        FleaV2CreatorSplitter impl = FleaV2CreatorSplitter(payable(splitters.implementation()));
        vm.expectRevert(FleaV2CreatorSplitter.AlreadyInitialized.selector);
        impl.initialize(IFleaV2FeeEscrow(address(escrow)), alice, payees, shares);
    }

    function test_rejectsBadPayeeSets() public {
        address[] memory dup = new address[](2);
        dup[0] = dev;
        dup[1] = dev;
        uint256[] memory s = new uint256[](2);
        s[0] = 1;
        s[1] = 1;
        vm.expectRevert(abi.encodeWithSelector(FleaV2CreatorSplitter.DuplicatePayee.selector, dev));
        splitters.createSplitter(address(0), dup, s, bytes32(0));
    }

    function test_nonPayeeOwedNothing() public {
        vm.expectRevert(abi.encodeWithSelector(FleaV2CreatorSplitter.NotPayee.selector, alice));
        splitter.release(address(0), alice);
    }
}
