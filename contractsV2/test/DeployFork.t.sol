// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {PonsV2LauncherToken} from "../src/v2/PonsV2LauncherToken.sol";
import {FleaLaunchRouter} from "../src/v2/periphery/FleaLaunchRouter.sol";
import {PonsV2CreatorSplitter} from "../src/v2/periphery/PonsV2CreatorSplitter.sol";
import {GraduationPhase} from "../src/v2/interfaces/ILaunchpadV2.sol";

/**
 * Runs the real deploy script against a fork of Robinhood Chain and takes one token through its whole life on the
 * chain's actual Uniswap V4: launch, curve buys, sell, graduation, and the locked pool. Skipped unless
 * RH_FORK_URL is set:  RH_FORK_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract DeployFork -vv
 */
contract DeployForkTest is Test {
    using StateLibrary for IPoolManager;

    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    Deploy.Deployed internal d;
    address internal protocol = makeAddr("protocol");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    bool internal forked;

    function setUp() public {
        string memory url = vm.envOr("RH_FORK_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;
        vm.setEnv("PROTOCOL_FEE_RECIPIENT", vm.toString(protocol));
        vm.setEnv("LAUNCH_ENABLED", "true");
        vm.setEnv("WRITE_DEPLOYMENT", "false");
        d = new Deploy().run();
        vm.deal(creator, 1 ether);
        vm.deal(alice, 100 ether);
    }

    function test_deployedStackIsWiredOnRobinhoodChain() public view {
        if (!forked) return;
        assertEq(block.chainid, 4663);
        assertEq(address(d.factory.poolManager()), POOL_MANAGER);
        assertEq(address(d.factory.launchDeployer()), address(d.launchDeployer));
        assertEq(address(d.factory.graduationExecutor()), address(d.executor));
        assertEq(d.factory.launchFee(), 0.0005 ether);
        assertTrue(d.factory.launchEnabled());
        assertEq(d.factory.launchConfigCount(), 1);
        // Hook address carries exactly beforeInitialize | afterSwap | afterSwapReturnDelta.
        assertEq(uint160(address(d.hook)) & 0x3FFF, (1 << 13) | (1 << 6) | (1 << 2));
    }

    function _params(bytes32 salt) internal pure returns (PonsV2LaunchFactory.TokenParams memory p) {
        p.name = "Flea Split Test";
        p.symbol = "FST";
        p.creatorTaxBps = 100;
        p.buybackEnabled = false;
        p.salt = salt;
    }

    function test_routerLaunchesWithFeeSplitAndFirstBuyInOneTransaction() public {
        if (!forked) return;
        address artist = makeAddr("artist");
        address marketer = makeAddr("marketer");
        FleaLaunchRouter.Split memory split;
        split.payees = new address[](3);
        split.shares = new uint256[](3);
        (split.payees[0], split.payees[1], split.payees[2]) = (creator, artist, marketer);
        (split.shares[0], split.shares[1], split.shares[2]) = (50, 30, 20);

        uint256 before = creator.balance;
        vm.prank(creator);
        (address t, address c, address splitter, uint256 out) =
            d.router.launch{value: 0.9 ether}(_params("split"), 0, new address[](0), split, 0.2 ether, 1);
        assertGt(out, 0, "first buy filled");
        assertEq(PonsV2LauncherToken(t).balanceOf(creator), out, "tokens go to the creator, not the router");
        assertEq(d.factory.getLaunchedToken(t).deployer, creator, "creator is the recorded deployer");
        assertEq(d.factory.getLaunchedToken(t).creatorFeeRecipient, splitter, "fees are routed to the splitter");
        assertEq(before - creator.balance, 0.2005 ether, "charged the first buy plus the launch fee; the rest came back");
        assertEq(address(d.router).balance, 0, "router keeps nothing");

        // Someone else trades; then anyone can pay the split out.
        vm.warp(block.timestamp + 60);
        vm.prank(alice);
        PonsV2BondingCurve(payable(c)).buy{value: 2 ether}(2 ether, 1, alice);
        (uint256 c0, uint256 a0, uint256 m0) = (creator.balance, artist.balance, marketer.balance);
        PonsV2CreatorSplitter(payable(splitter)).sweepCurveFees(c);
        PonsV2CreatorSplitter(payable(splitter)).distribute(address(0));
        uint256 paid = (creator.balance - c0) + (artist.balance - a0) + (marketer.balance - m0);
        assertGt(paid, 0, "creator fees were paid out");
        assertApproxEqAbs(creator.balance - c0, (paid * 50) / 100, 2, "creator gets 50%");
        assertApproxEqAbs(artist.balance - a0, (paid * 30) / 100, 2, "artist gets 30%");
        assertApproxEqAbs(marketer.balance - m0, (paid * 20) / 100, 2, "marketer gets 20%");
    }

    function test_routerRefusesAFirstBuyThatWouldBeSnipeTaxed() public {
        if (!forked) return;
        FleaLaunchRouter.Split memory none;
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(FleaLaunchRouter.FirstBuyOverExemptAllowance.selector, 0.5 ether, 0.42 ether));
        d.router.launch{value: 0.6 ether}(_params("big"), 0, new address[](0), none, 0.5 ether, 1);
    }

    function test_onlyTheRouterMayLaunchOnBehalfOfSomeoneElse() public {
        if (!forked) return;
        vm.prank(alice);
        vm.expectRevert(PonsV2LaunchFactory.NotLaunchForwarder.selector);
        d.factory.launchTokenFor{value: 0.0005 ether}(_params("spoof"), 0, address(0), creator, new address[](0));
    }

    function test_launchTradeAndGraduateIntoTheRealV4Pool() public {
        if (!forked) return;
        PonsV2LaunchFactory.TokenParams memory p;
        p.name = "Flea Fork Test";
        p.symbol = "FFT";
        p.creatorTaxBps = 100;
        p.buybackEnabled = true;
        p.buybackBurn = true;
        p.salt = keccak256("fork-test");

        uint256 protocolBefore = protocol.balance;
        vm.prank(creator);
        (address t, address c) = d.factory.launchToken{value: 0.0005 ether}(p, 0, address(0));
        PonsV2LauncherToken token = PonsV2LauncherToken(t);
        PonsV2BondingCurve curve = PonsV2BondingCurve(payable(c));
        assertEq(token.totalSupply(), 1_000_000_000 ether);

        vm.warp(block.timestamp + 60); // past the snipe window
        vm.startPrank(alice);
        curve.buy{value: 0.5 ether}(0.5 ether, 1, alice);
        uint256 bought = token.balanceOf(alice);
        assertGt(bought, 0, "curve buy delivers tokens");
        token.approve(address(curve), bought / 2);
        uint256 ethBefore = alice.balance;
        curve.sell(bought / 2, 1, alice);
        assertGt(alice.balance, ethBefore, "curve sell pays ETH");
        curve.buy{value: 10 ether}(10 ether, 1, alice);
        vm.stopPrank();

        assertTrue(curve.graduated(), "crossing buy graduates");
        d.factory.createGraduatedPool(t);
        assertEq(uint8(d.factory.getLaunchedToken(t).phase), uint8(GraduationPhase.PoolCreated));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)), currency1: Currency.wrap(t), fee: 0, tickSpacing: 200, hooks: IHooks(address(d.hook))
        });
        (uint160 sqrtPriceX96,,,) = IPoolManager(POOL_MANAGER).getSlot0(PoolId.wrap(keccak256(abi.encode(key))));
        assertGt(sqrtPriceX96, 0, "pool is initialized on the chain's real PoolManager");
        assertGt(IPoolManager(POOL_MANAGER).getLiquidity(PoolId.wrap(keccak256(abi.encode(key)))), 0, "pool holds the graduated liquidity");
        assertGe(protocol.balance + d.escrow.balanceOf(protocol), protocolBefore, "protocol accrued fees");
    }
}
