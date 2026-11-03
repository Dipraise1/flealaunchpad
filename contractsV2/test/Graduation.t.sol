// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {DeployPermit2} from "../test-lib/v4-periphery/lib/permit2/test/utils/DeployPermit2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// v4-core's PoolSwapTest router, deployed from the test-lib build.
interface IPoolSwapTest {
    struct TestSettings {
        bool takeClaims;
        bool settleUsingBurn;
    }

    function swap(PoolKey memory key, SwapParams memory params, TestSettings memory settings, bytes memory hookData)
        external
        payable
        returns (int256);
}

interface IPosmLike {
    function nextTokenId() external view returns (uint256);
}

// FLÈA contracts (compiled against the vendored interfaces)
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2LaunchDeployer} from "../src/v2/PonsV2LaunchDeployer.sol";
import {PonsV2GraduationExecutor} from "../src/v2/PonsV2GraduationExecutor.sol";
import {PonsV2LaunchLocker} from "../src/v2/PonsV2LaunchLocker.sol";
import {PonsV2BuybackVault} from "../src/v2/PonsV2BuybackVault.sol";
import {PonsV2FeeEscrow} from "../src/v2/PonsV2FeeEscrow.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {PonsV2LauncherToken} from "../src/v2/PonsV2LauncherToken.sol";
import {PonsV2MemeHook} from "../src/v2/hooks/PonsV2MemeHook.sol";
import {GraduationPhase, IPonsV2FeeEscrow, IPonsV2LaunchFactory} from "../src/v2/interfaces/ILaunchpadV2.sol";

contract GraduationTest is Test, DeployPermit2 {
    uint256 constant THRESHOLD = 4.2 ether;

    string constant V4_OUT = "test-lib/v4-periphery/foundry-out/";

    address manager;
    IPosmLike posm;
    IPoolSwapTest router;
    PonsV2FeeEscrow escrow;
    PonsV2MemeHook hook;
    PonsV2BuybackVault vault;
    PonsV2LaunchLocker locker;
    PonsV2LaunchFactory factory;

    address protocol = makeAddr("protocol");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address trader = makeAddr("trader");

    function setUp() public {
        vm.warp(1_000_000);
        manager = deployCode(string.concat(V4_OUT, "PoolManager.sol/PoolManager.json"), abi.encode(address(this)));
        address permit2 = deployPermit2();
        posm = IPosmLike(
            deployCode(
                string.concat(V4_OUT, "PositionManager.sol/PositionManager.json"),
                abi.encode(manager, permit2, uint256(100_000), address(0), address(0))
            )
        );
        router = IPoolSwapTest(deployCode(string.concat(V4_OUT, "PoolSwapTest.sol/PoolSwapTest.json"), abi.encode(manager)));
        escrow = new PonsV2FeeEscrow();

        // V4 reads hook permissions from the low address bits.
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        address hookAddr = address(flags | (uint160(0x4444) << 144));
        deployCodeTo(
            "PonsV2MemeHook.sol:PonsV2MemeHook",
            abi.encode(manager, address(escrow), protocol, address(this)),
            hookAddr
        );
        hook = PonsV2MemeHook(payable(hookAddr));

        vault = new PonsV2BuybackVault(address(this), hook, IPonsV2FeeEscrow(address(escrow)));
        locker = new PonsV2LaunchLocker(address(this), address(posm));
        factory = new PonsV2LaunchFactory(
            address(this),
            IPoolManager(manager),
            IPositionManager(address(posm)),
            IAllowanceTransfer(address(permit2)),
            locker,
            hook,
            IPonsV2FeeEscrow(address(escrow)),
            vault,
            0
        );
        factory.setLaunchDeployer(new PonsV2LaunchDeployer(address(factory)));
        factory.setGraduationExecutor(
            new PonsV2GraduationExecutor(
                IPositionManager(address(posm)), IAllowanceTransfer(address(permit2)), locker, address(factory)
            )
        );
        hook.setFactory(address(factory));
        hook.setBuybackVault(vault);
        vault.setFactory(address(factory));
        locker.setFactory(address(factory));

        factory.addLaunchConfig(
            PonsV2LaunchFactory.LaunchConfig({
                supply: 1_000_000_000 ether,
                curveFeeBps: 100,
                phantomQuote: 1.5 ether,
                graduationThreshold: THRESHOLD,
                poolFee: 0,
                tickSpacing: 200,
                enabled: true
            })
        );
        factory.setLaunchEnabled(true);

        vm.deal(alice, 100 ether);
        vm.deal(trader, 100 ether);
        vm.deal(creator, 1 ether);
    }

    function _launch(bool burn) internal returns (PonsV2LauncherToken token, PonsV2BondingCurve curve) {
        PonsV2LaunchFactory.TokenParams memory p;
        p.name = "Flea";
        p.symbol = "FLEA";
        p.creatorTaxBps = 100;
        p.buybackEnabled = true;
        p.buybackBurn = burn;
        p.salt = keccak256(abi.encode(burn));
        vm.prank(creator);
        (address t, address c) = factory.launchToken(p, 0, address(0));
        token = PonsV2LauncherToken(t);
        curve = PonsV2BondingCurve(payable(c));
    }

    function _graduate(PonsV2LauncherToken token, PonsV2BondingCurve curve) internal {
        vm.warp(block.timestamp + 60); // past the snipe window
        vm.prank(alice);
        curve.buy{value: 10 ether}(10 ether, 1, alice);
        assertTrue(curve.graduated(), "crossing buy graduates the curve");
        assertEq(uint8(factory.getLaunchedToken(address(token)).phase), uint8(GraduationPhase.Swept));
        factory.createGraduatedPool(address(token));
        assertEq(uint8(factory.getLaunchedToken(address(token)).phase), uint8(GraduationPhase.PoolCreated));
    }

    function _key(address token) internal view returns (PoolKey memory) {
        // ETH (address 0) always sorts first.
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
    }

    function _poolId(address token) internal view returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(_key(token))));
    }

    function _buyOnPool(address token, uint256 ethIn) internal {
        vm.prank(trader);
        router.swap{value: ethIn}(
            _key(token),
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            IPoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_graduatesIntoLockedV4Pool() public {
        (PonsV2LauncherToken token, PonsV2BondingCurve curve) = _launch(false);
        _graduate(token, curve);
        uint256 positionId = posm.nextTokenId() - 1;
        assertEq(IERC721(address(posm)).ownerOf(positionId), address(locker), "LP NFT is locked");
        (bool registered,,,,,,,,,,,,,) = hook.launches(_poolId(address(token)));
        assertTrue(registered, "hook registered the pool");
    }

    function test_poolSwapsChargeHookFeeAndCreatorTax() public {
        (PonsV2LauncherToken token, PonsV2BondingCurve curve) = _launch(false);
        _graduate(token, curve);

        uint256 before = token.balanceOf(trader);
        _buyOnPool(address(token), 1 ether);
        assertGt(token.balanceOf(trader), before, "trader received tokens");

        // hook fee 1% + creator tax 1%, taken on the unspecified (token) leg and converted on sweep
        PoolId id = _poolId(address(token));
        uint256 pendingMeme = hook.pendingFees(id, address(token)) + hook.pendingCreatorTax(id, address(token));
        assertGt(pendingMeme, 0, "fees accrued in the hook");

        hook.sweepPoolFees(id, 1, 1); // test contract is the sweep operator
        assertGt(escrow.balanceOf(protocol), 0, "protocol paid in ETH");
        assertGt(escrow.balanceOf(creator), 0, "creator paid in ETH");
    }

    function test_burnModeBurnsPostGraduationBuyback() public {
        (PonsV2LauncherToken token, PonsV2BondingCurve curve) = _launch(true);
        _graduate(token, curve);
        _buyOnPool(address(token), 2 ether);
        uint256 supplyBefore = token.totalSupply();
        hook.sweepPoolFees(_poolId(address(token)), 1, 1);
        assertLt(token.totalSupply(), supplyBefore, "buyback burned supply");
        assertEq(vault.totalLocked(address(token)), 0, "nothing vested");
    }

    function test_lockModeVestsPostGraduationBuyback() public {
        (PonsV2LauncherToken token, PonsV2BondingCurve curve) = _launch(false);
        _graduate(token, curve);
        _buyOnPool(address(token), 2 ether);
        uint256 lockedBefore = vault.totalLocked(address(token));
        uint256 supplyBefore = token.totalSupply();
        hook.sweepPoolFees(_poolId(address(token)), 1, 1);
        assertGt(vault.totalLocked(address(token)), lockedBefore, "buyback vested");
        assertEq(token.totalSupply(), supplyBefore, "supply unchanged");
    }

    function test_snipeTaxAppliesThroughFactoryLaunch() public {
        (PonsV2LauncherToken token, PonsV2BondingCurve curve) = _launch(false);
        assertGt(curve.currentSnipeTaxBps(alice), 9_000);
        assertEq(curve.currentSnipeTaxBps(creator), 0, "launcher is auto-exempt");
        token; // silence
    }
}
